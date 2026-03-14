/// Slack Bot Bridge — Phase 6.
///
/// Uses Slack Events API (HTTP webhook).
///
/// FLOW:
///   1. Shelf HTTP server on 127.0.0.1:$PORT receives POST from Slack.
///   2. Verify x-slack-signature HMAC-SHA256 (v0 scheme).
///   3. Respond to url_verification challenge (Slack setup step).
///   4. On app_mention or DM message: forward to @agent, reply with result.
///
/// Slack App configuration required:
///   • Event Subscriptions: enable, set Request URL, subscribe to:
///       - app_mention
///       - message.im
///   • OAuth scopes: chat:write, chat:write.public, im:read, im:history
///     channels:history (for mentions)
///
/// Config (env vars or AtKeys):
///   SLACK_BOT_TOKEN     — Bot OAuth token (xoxb-...)
///   SLACK_SIGNING_SECRET — Signing secret for request verification
///   PORT                — Webhook listen port (default 8080)
///
/// AtKeys:
///   bridge.slack.token.safeclaw@bridge_slack
///   bridge.slack.signing_secret.safeclaw@bridge_slack
///
/// Deploy behind a TLS reverse proxy. Slack requires HTTPS.

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

const _namespace = 'safeclaw';
String _agentAtSign =
    '@agent'; // overridden at startup from AGENT_AT_SIGN env var
const _platform = 'slack';
const _requestTimeout = Duration(seconds: 60);
const _slackApiBase = 'https://slack.com/api';
final _log = Logger('bridge_slack');
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
      'Usage: dart run bin/main.dart --atsign @bridge_slack '
      '--key-file /path/to/@bridge_slack_key.atKeys',
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
      'Slack bridge started as ${atClient.getCurrentAtSign()} → agent: $_agentAtSign');

  final config = await _loadConfig(atClient);
  _log.info('Config loaded — port=${config.port}');

  await _startServer(atClient, config);
}

// ─────────────────────────────────────────────────────────────────────────────
//  CONFIG
// ─────────────────────────────────────────────────────────────────────────────

class _Config {
  final String botToken;
  final String signingSecret;
  final int port;

  const _Config({
    required this.botToken,
    required this.signingSecret,
    required this.port,
  });
}

Future<_Config> _loadConfig(AtClient atClient) async {
  String _env(String key) => Platform.environment[key] ?? '';

  Future<String?> _atKey(String sub) async {
    try {
      final keyStr = 'bridge.slack.$sub.safeclaw'
          '@${atClient.getCurrentAtSign()!.replaceAll('@', '')}';
      final r = await atClient.get(AtKey.fromString(keyStr),
          getRequestOptions: GetRequestOptions()..useRemoteAtServer = true);
      return r.value as String?;
    } catch (_) {
      return null;
    }
  }

  final token = _env('SLACK_BOT_TOKEN').isNotEmpty
      ? _env('SLACK_BOT_TOKEN')
      : await _atKey('token') ?? '';
  final secret = _env('SLACK_SIGNING_SECRET').isNotEmpty
      ? _env('SLACK_SIGNING_SECRET')
      : await _atKey('signing_secret') ?? '';
  final port = int.tryParse(_env('PORT')) ?? 8080;

  return _Config(botToken: token, signingSecret: secret, port: port);
}

// ─────────────────────────────────────────────────────────────────────────────
//  SHELF SERVER
// ─────────────────────────────────────────────────────────────────────────────

Future<void> _startServer(AtClient atClient, _Config config) async {
  final router = Router();

  router.post('/slack/events', (Request req) async {
    final body = await req.readAsString();

    // Verify request signature
    if (config.signingSecret.isNotEmpty) {
      final ts = req.headers['x-slack-request-timestamp'] ?? '';
      final sig = req.headers['x-slack-signature'] ?? '';
      if (!_verifySlackSignature(body, ts, config.signingSecret, sig)) {
        _log.warning('Invalid Slack signature');
        return Response.forbidden('Invalid signature');
      }
      // Replay attack guard: timestamp must be within 5 minutes
      final tsInt = int.tryParse(ts) ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch ~/ 1000 - tsInt;
      if (age.abs() > 300) {
        _log.warning('Request timestamp too old: age=${age}s');
        return Response.forbidden('Request too old');
      }
    }

    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      return Response.badRequest(body: 'Invalid JSON');
    }

    final type = payload['type'] as String?;

    // Slack URL verification challenge (one-time during app setup)
    if (type == 'url_verification') {
      return Response.ok(payload['challenge'] as String? ?? '',
          headers: {'Content-Type': 'text/plain'});
    }

    if (type == 'event_callback') {
      unawaited(_handleEvent(atClient, config, payload));
    }

    // Always return 200 quickly to Slack
    return Response.ok('OK');
  });

  final handler =
      Pipeline().addMiddleware(logRequests()).addHandler(router.call);
  final server = await shelf_io.serve(handler, '127.0.0.1', config.port);
  _log.info('Slack webhook listening on ${server.address}:${server.port}');

  await Completer<Never>().future;
}

bool _verifySlackSignature(
    String body, String ts, String secret, String signature) {
  final sigBase = 'v0:$ts:$body';
  final expected =
      'v0=${Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(sigBase))}';
  if (signature.length != expected.length) return false;
  int diff = 0;
  for (int i = 0; i < signature.length; i++) {
    diff |= signature.codeUnitAt(i) ^ expected.codeUnitAt(i);
  }
  return diff == 0;
}

// ─────────────────────────────────────────────────────────────────────────────
//  EVENT HANDLING
// ─────────────────────────────────────────────────────────────────────────────

Future<void> _handleEvent(
    AtClient atClient, _Config config, Map<String, dynamic> payload) async {
  final event = payload['event'] as Map<String, dynamic>?;
  if (event == null) return;

  final eventType = event['type'] as String? ?? '';
  final botId = event['bot_id'] as String?;
  // Ignore messages from bots (including this bot)
  if (botId != null) return;

  switch (eventType) {
    case 'app_mention':
      await _handleMention(atClient, config, event);
    case 'message':
      // Only direct messages
      final channelType = event['channel_type'] as String?;
      if (channelType == 'im') {
        await _handleDirectMessage(atClient, config, event);
      }
  }
}

Future<void> _handleMention(
    AtClient atClient, _Config config, Map<String, dynamic> event) async {
  final userId = event['user'] as String? ?? 'unknown';
  final channelId = event['channel'] as String? ?? '';
  String text = (event['text'] as String?) ?? '';
  // Strip <@BOTID> prefix
  text = text.replaceAll(RegExp(r'<@[A-Z0-9]+>'), '').trim();
  if (text.isEmpty) return;

  _log.info('Mention from $userId in $channelId: $text');
  final conversationId = '${_platform}_${channelId}_$userId';
  final response = await _callAgent(atClient, text, conversationId, userId);
  await _slackSend(config.botToken, channelId, response);
}

Future<void> _handleDirectMessage(
    AtClient atClient, _Config config, Map<String, dynamic> event) async {
  final userId = event['user'] as String? ?? 'unknown';
  final channelId = event['channel'] as String? ?? '';
  final text = (event['text'] as String?) ?? '';
  if (text.isEmpty) return;

  _log.info('DM from $userId: $text');
  final conversationId = '${_platform}_dm_$userId';
  final response = await _callAgent(atClient, text, conversationId, userId);
  await _slackSend(config.botToken, channelId, response);
}

// ─────────────────────────────────────────────────────────────────────────────
//  AGENT CALL
// ─────────────────────────────────────────────────────────────────────────────

Future<String> _callAgent(
  AtClient atClient,
  String command,
  String conversationId,
  String senderUser,
) async {
  final requestId = _uuid.v4();
  final bridgeAtSign = atClient.getCurrentAtSign() ?? '@bridge_slack';

  final payload = jsonEncode({
    'command': command,
    'conversationId': conversationId,
    'fromAtSign': bridgeAtSign,
    'platform': _platform,
    'senderUser': senderUser,
    'reqId': DateTime.now().millisecondsSinceEpoch,
  });

  final responseKey = 'bridge\\.response\\.$requestId';
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
    NotificationParams.forUpdate(requestKey, value: payload),
  );

  final result = await responseFuture;
  return result ?? 'Sorry, I did not receive a response. Please try again.';
}

Future<String?> _waitForResponse(AtClient atClient, String keyRegex) async {
  final completer = Completer<String?>();
  final sub = atClient.notificationService
      .subscribe(regex: keyRegex, shouldDecrypt: true)
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
//  SLACK — SEND MESSAGE
// ─────────────────────────────────────────────────────────────────────────────

Future<void> _slackSend(String botToken, String channelId, String text) async {
  // Slack has a 3,000-char limit for blocks text, 4,000 for plain text messages.
  // Split into blocks of 3000 chars to be safe.
  const maxLength = 3000;
  for (int i = 0; i < text.length; i += maxLength) {
    final chunk = text.substring(
        i, (i + maxLength) > text.length ? text.length : i + maxLength);
    final resp = await http.post(
      Uri.parse('$_slackApiBase/chat.postMessage'),
      headers: {
        'Authorization': 'Bearer $botToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'channel': channelId, 'text': chunk}),
    );
    final respBody = jsonDecode(resp.body) as Map<String, dynamic>;
    if (respBody['ok'] != true) {
      _log.warning(
          'chat.postMessage failed: ${respBody['error']} — ${resp.body}');
    } else {
      _log.info('Reply sent to channel=$channelId');
    }
  }
}
