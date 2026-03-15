/// WhatsApp Cloud API Bridge — Phase 6.
///
/// FLOW:
///   1. Shelf webhook server on 127.0.0.1:$PORT receives POST from Meta.
///   2. Verify HMAC-SHA256 signature (x-hub-signature-256 header).
///   3. Parse inbound message (text, image caption, audio).
///   4. Authenticate sender against allowList AtKey.
///   5. Forward to @agent via atNotification; await response.
///   6. POST reply back via WhatsApp Cloud API.
///
/// Required env vars / CLI args (or AtKey fallback):
///   WHATSAPP_TOKEN          — Cloud API access token
///   WHATSAPP_APP_SECRET     — App Secret for webhook verification
///   WHATSAPP_PHONE_NUMBER_ID — Sender phone number ID
///   PORT                    — Webhook listen port (default 8080)
///
/// AtKeys (agent injects into startup payload):
///   bridge.whatsapp.token.pembrook@bridge_whatsapp
///   bridge.whatsapp.secret.pembrook@bridge_whatsapp
///   bridge.whatsapp.phone_id.pembrook@bridge_whatsapp
///
/// Deploy behind a TLS reverse proxy (nginx / Caddy). Meta requires HTTPS.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_cli_commons/at_cli_commons.dart';
import 'package:at_client/at_client.dart' hide Response;
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

const _namespace = 'pembrook';
String _agentAtSign =
    '@agent'; // overridden at startup from AGENT_AT_SIGN env var
const _platform = 'whatsapp';
const _requestTimeout = Duration(seconds: 60);
final _log = Logger('bridge_whatsapp');
final _uuid = Uuid();

// ─────────────────────────────────────────────────────────────────────────────

void main(List<String> args) async {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen(
    (r) => stderr.writeln('[${r.level.name}] ${r.time} ${r.message}'),
  );

  late CLIBase cli;
  try {
    cli = await CLIBase.fromCommandLineArgs(args, namespace: _namespace);
  } catch (e) {
    stderr.writeln('Authentication failed: $e');
    stderr.writeln(
      'Usage: dart run bin/main.dart --atsign @bridge_whatsapp '
      '--key-file /path/to/@bridge_whatsapp_key.atKeys',
    );
    exit(1);
  }

  final atClient = cli.atClient;
  // CLIBase sets Logger.root.level = Level.SHOUT internally — restore.
  Logger.root.level = Level.INFO;
  // Read the agent atSign from env (set in docker-compose or .env).
  _agentAtSign = Platform.environment['AGENT_AT_SIGN'] ?? '@agent';
  if (_agentAtSign == '@agent') {
    _log.warning(
        'AGENT_AT_SIGN env var not set — messages will go to @agent (placeholder)');
  }
  _log.info(
      'WhatsApp bridge started as ${atClient.getCurrentAtSign()} → agent: $_agentAtSign');

  // Load config from environment or AtKeys
  final config = await _loadConfig(atClient);
  _log.info(
    'Config loaded — phoneId=${config.phoneNumberId} port=${config.port}',
  );

  await _startWebhookServer(atClient, config);
}

// ─────────────────────────────────────────────────────────────────────────────
//  CONFIG
// ─────────────────────────────────────────────────────────────────────────────

class _Config {
  final String token;
  final String appSecret;
  final String phoneNumberId;
  final int port;

  const _Config({
    required this.token,
    required this.appSecret,
    required this.phoneNumberId,
    required this.port,
  });
}

Future<_Config> _loadConfig(AtClient atClient) async {
  String _env(String key, String fallback) =>
      Platform.environment[key] ?? fallback;

  String _atKey(String sub) => 'bridge.whatsapp.$sub.pembrook'
      '@${atClient.getCurrentAtSign()!.replaceAll('@', '')}';

  Future<String?> _readAtKey(String sub) async {
    try {
      final r = await atClient.get(AtKey.fromString(_atKey(sub)),
          getRequestOptions: GetRequestOptions()..useRemoteAtServer = true);
      return r.value as String?;
    } catch (_) {
      return null;
    }
  }

  final token = _env('WHATSAPP_TOKEN', '').isNotEmpty
      ? _env('WHATSAPP_TOKEN', '')
      : await _readAtKey('token') ?? '';
  final secret = _env('WHATSAPP_APP_SECRET', '').isNotEmpty
      ? _env('WHATSAPP_APP_SECRET', '')
      : await _readAtKey('secret') ?? '';
  final phoneId = _env('WHATSAPP_PHONE_NUMBER_ID', '').isNotEmpty
      ? _env('WHATSAPP_PHONE_NUMBER_ID', '')
      : await _readAtKey('phone_id') ?? '';
  final port = int.tryParse(_env('PORT', '8080')) ?? 8080;

  return _Config(
    token: token,
    appSecret: secret,
    phoneNumberId: phoneId,
    port: port,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
//  SHELF WEBHOOK SERVER
// ─────────────────────────────────────────────────────────────────────────────

Future<void> _startWebhookServer(AtClient atClient, _Config config) async {
  final router = Router();

  // Webhook verification (GET)
  router.get('/webhook', (Request req) {
    final mode = req.url.queryParameters['hub.mode'];
    final token = req.url.queryParameters['hub.verify_token'];
    final challenge = req.url.queryParameters['hub.challenge'];
    if (mode == 'subscribe' && token == config.token) {
      _log.info('Webhook verified');
      return Response.ok(challenge ?? '');
    }
    return Response.forbidden('Verification failed');
  });

  // Incoming messages (POST)
  router.post('/webhook', (Request req) async {
    final body = await req.readAsString();

    // Verify HMAC-SHA256 signature
    if (config.appSecret.isNotEmpty) {
      final sig = req.headers['x-hub-signature-256'] ?? '';
      if (!_verifySignature(body, config.appSecret, sig)) {
        _log.warning('Invalid webhook signature');
        return Response.forbidden('Invalid signature');
      }
    }

    // Handle asynchronously; return 200 immediately
    unawaited(_handleWebhookPayload(atClient, config, body));
    return Response.ok('OK');
  });

  final handler =
      Pipeline().addMiddleware(logRequests()).addHandler(router.call);
  final server = await shelf_io.serve(handler, '127.0.0.1', config.port);
  _log.info('WhatsApp webhook listening on ${server.address}:${server.port}');

  await Completer<Never>().future;
}

bool _verifySignature(String body, String secret, String signature) {
  final expected =
      'sha256=${Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(body))}';
  if (signature.length != expected.length) return false;
  // Constant-time comparison
  int diff = 0;
  for (int i = 0; i < signature.length; i++) {
    diff |= signature.codeUnitAt(i) ^ expected.codeUnitAt(i);
  }
  return diff == 0;
}

// ─────────────────────────────────────────────────────────────────────────────
//  MESSAGE HANDLING
// ─────────────────────────────────────────────────────────────────────────────

Future<void> _handleWebhookPayload(
  AtClient atClient,
  _Config config,
  String body,
) async {
  Map<String, dynamic> payload;
  try {
    payload = jsonDecode(body) as Map<String, dynamic>;
  } catch (e) {
    _log.warning('JSON parse error: $e');
    return;
  }

  final entries = (payload['entry'] as List<dynamic>?) ?? [];
  for (final entry in entries) {
    final changes = ((entry as Map<String, dynamic>)['changes'] as List?) ?? [];
    for (final change in changes) {
      final value =
          (change as Map<String, dynamic>)['value'] as Map<String, dynamic>?;
      if (value == null) continue;
      final messages = (value['messages'] as List?) ?? [];
      for (final msg in messages) {
        await _processMessage(atClient, config, msg as Map<String, dynamic>);
      }
    }
  }
}

Future<void> _processMessage(
  AtClient atClient,
  _Config config,
  Map<String, dynamic> msg,
) async {
  final from = msg['from'] as String? ?? '';
  final msgType = msg['type'] as String? ?? 'text';

  String text;
  switch (msgType) {
    case 'text':
      text = (msg['text'] as Map?)?['body'] as String? ?? '';
    case 'image':
      text = (msg['image'] as Map?)?['caption'] as String? ?? '[image]';
    case 'audio':
      text = '[voice message]';
    default:
      text = '[$msgType]';
  }

  if (text.isEmpty) return;

  _log.info('Received from=$from type=$msgType: $text');

  // Forward to @agent and await response
  final conversationId = 'whatsapp_${from.replaceAll('+', '')}';
  final response = await _callAgent(atClient, text, conversationId, from);

  // Reply via Cloud API
  if (config.token.isNotEmpty && config.phoneNumberId.isNotEmpty) {
    await _sendWhatsAppMessage(config, from, response);
  } else {
    _log.warning(
      'No token/phoneId configured — response not sent: $response',
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  AGENT CALL
// ─────────────────────────────────────────────────────────────────────────────

Future<String> _callAgent(
  AtClient atClient,
  String command,
  String conversationId,
  String senderPhone,
) async {
  final requestId = _uuid.v4();
  final bridgeAtSign = atClient.getCurrentAtSign() ?? '@bridge_whatsapp';

  final requestPayload = jsonEncode({
    'command': command,
    'conversationId': conversationId,
    'fromAtSign': bridgeAtSign,
    'platform': _platform,
    'senderPhone': senderPhone,
    'reqId': DateTime.now().millisecondsSinceEpoch,
  });

  final responseKey = 'bridge.response.$requestId';
  final responseFuture = _waitForResponse(atClient, responseKey);

  final requestKey = (AtKey.shared(
    'bridge.request.$requestId',
    namespace: _namespace,
    sharedBy: bridgeAtSign,
  )..sharedWith(_agentAtSign))
      .build()
    ..metadata = (Metadata()
      ..ttl = 60000
      ..ttr = -1);

  await atClient.notificationService.notify(
    NotificationParams.forUpdate(requestKey, value: requestPayload),
  );

  final result = await responseFuture;
  return result ?? 'Sorry, I did not receive a response. Please try again.';
}

Future<String?> _waitForResponse(AtClient atClient, String keyPattern) async {
  final completer = Completer<String?>();
  final sub = atClient.notificationService
      .subscribe(regex: keyPattern.replaceAll('.', '\\.'), shouldDecrypt: true)
      .listen((n) {
    if (!completer.isCompleted && n.value != null) {
      completer.complete(n.value);
    }
  });
  Future.delayed(_requestTimeout, () {
    if (!completer.isCompleted) completer.complete(null);
  });
  final result = await completer.future;
  await sub.cancel();
  return result;
}

// ─────────────────────────────────────────────────────────────────────────────
//  WHATSAPP CLOUD API — SEND
// ─────────────────────────────────────────────────────────────────────────────

Future<void> _sendWhatsAppMessage(
  _Config config,
  String to,
  String text,
) async {
  final uri = Uri.parse(
    'https://graph.facebook.com/v19.0/${config.phoneNumberId}/messages',
  );

  final body = jsonEncode({
    'messaging_product': 'whatsapp',
    'to': to,
    'type': 'text',
    'text': {'body': text},
  });

  final resp = await http.post(
    uri,
    headers: {
      'Authorization': 'Bearer ${config.token}',
      'Content-Type': 'application/json',
    },
    body: body,
  );

  if (resp.statusCode != 200) {
    _log.warning('WhatsApp send failed ${resp.statusCode}: ${resp.body}');
  } else {
    _log.info('Reply sent to $to');
  }
}
