/// Telegram Bot Bridge — Phase 6.
///
/// Uses Telegram Bot API long-polling (no public HTTPS endpoint required).
///
/// FLOW:
///   1. Poll `getUpdates` with 30-second timeout for incoming messages.
///   2. On text/command message: forward to @agent via atNotification.
///   3. Subscribe for @agent response; reply to the Telegram chat.
///
/// Config (env vars or AtKeys):
///   TELEGRAM_BOT_TOKEN — Bot token from @BotFather
///
/// AtKey:
///   bridge.telegram.token.safeclaw@bridge_telegram

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_cli_commons/at_cli_commons.dart';
import 'package:at_client/at_client.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

const _namespace = 'safeclaw';
String _agentAtSign =
    '@agent'; // overridden at startup from AGENT_AT_SIGN env var
const _platform = 'telegram';
const _pollTimeout = 30; // seconds (long-poll)
const _requestTimeout = Duration(seconds: 60);
final _log = Logger('bridge_telegram');
final _uuid = Uuid();

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
      'Usage: dart run bin/main.dart --atsign @bridge_telegram '
      '--key-file /path/to/@bridge_telegram_key.atKeys',
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
      'Telegram bridge started as ${atClient.getCurrentAtSign()} → agent: $_agentAtSign');

  final token = await _loadToken(atClient);
  if (token.isEmpty) {
    _log.severe('TELEGRAM_BOT_TOKEN not set. Exiting.');
    exit(1);
  }

  _log.info('Bot token loaded, starting long-poll loop…');
  await _pollLoop(atClient, token);
}

// ─────────────────────────────────────────────────────────────────────────────
//  CONFIG
// ─────────────────────────────────────────────────────────────────────────────

Future<String> _loadToken(AtClient atClient) async {
  final envToken = Platform.environment['TELEGRAM_BOT_TOKEN'] ?? '';
  if (envToken.isNotEmpty) return envToken;

  try {
    final keyStr = 'bridge.telegram.token.safeclaw'
        '@${atClient.getCurrentAtSign()!.replaceAll('@', '')}';
    final r = await atClient.get(AtKey.fromString(keyStr),
        getRequestOptions: GetRequestOptions()..useRemoteAtServer = true);
    return (r.value as String?) ?? '';
  } catch (_) {
    return '';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  LONG-POLL LOOP
// ─────────────────────────────────────────────────────────────────────────────

Future<void> _pollLoop(AtClient atClient, String token) async {
  int lastUpdateId = -1;

  while (true) {
    try {
      final updates = await _getUpdates(token, lastUpdateId + 1);
      for (final update in updates) {
        final id = update['update_id'] as int;
        if (id > lastUpdateId) lastUpdateId = id;

        final message = update['message'] as Map<String, dynamic>?;
        if (message == null) continue;

        final chatId =
            ((message['chat'] as Map<String, dynamic>)['id'] as num).toInt();
        final text = (message['text'] as String?) ?? '';
        if (text.isEmpty) continue;

        final from = message['from'] as Map<String, dynamic>?;
        final fromUser = from?['username'] as String? ??
            from?['first_name'] as String? ??
            chatId.toString();

        _log.info('Message from $fromUser ($chatId): $text');

        // Handle in the background; continue polling
        unawaited(_handleMessage(atClient, token, chatId, fromUser, text));
      }
    } catch (e, st) {
      _log.warning('Poll error: $e\n$st');
      await Future.delayed(const Duration(seconds: 5));
    }
  }
}

Future<List<Map<String, dynamic>>> _getUpdates(String token, int offset) async {
  final uri = Uri.parse(
    'https://api.telegram.org/bot$token/getUpdates'
    '?offset=$offset&timeout=$_pollTimeout&allowed_updates=message',
  );
  final resp =
      await http.get(uri).timeout(Duration(seconds: _pollTimeout + 10));
  if (resp.statusCode != 200) {
    throw Exception('getUpdates ${resp.statusCode}: ${resp.body}');
  }
  final body = jsonDecode(resp.body) as Map<String, dynamic>;
  if (body['ok'] != true) {
    throw Exception('Telegram error: ${body['description']}');
  }
  return (body['result'] as List<dynamic>).cast<Map<String, dynamic>>();
}

// ─────────────────────────────────────────────────────────────────────────────
//  MESSAGE → AGENT → REPLY
// ─────────────────────────────────────────────────────────────────────────────

Future<void> _handleMessage(
  AtClient atClient,
  String token,
  int chatId,
  String fromUser,
  String text,
) async {
  final conversationId = '${_platform}_$chatId';
  final response = await _callAgent(atClient, text, conversationId, fromUser);
  await _sendTelegramMessage(token, chatId, response);
}

Future<String> _callAgent(
  AtClient atClient,
  String command,
  String conversationId,
  String senderUser,
) async {
  final requestId = _uuid.v4();
  final bridgeAtSign = atClient.getCurrentAtSign() ?? '@bridge_telegram';

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
//  TELEGRAM — SEND MESSAGE
// ─────────────────────────────────────────────────────────────────────────────

Future<void> _sendTelegramMessage(String token, int chatId, String text) async {
  const maxLength = 4096; // Telegram message limit
  // Split if needed
  final chunks = <String>[];
  for (int i = 0; i < text.length; i += maxLength) {
    chunks.add(text.substring(
        i, i + maxLength > text.length ? text.length : i + maxLength));
  }

  for (final chunk in chunks) {
    final resp = await http.post(
      Uri.parse('https://api.telegram.org/bot$token/sendMessage'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'chat_id': chatId, 'text': chunk}),
    );
    if (resp.statusCode != 200) {
      _log.warning('sendMessage failed ${resp.statusCode}: ${resp.body}');
    } else {
      _log.info('Reply sent to chatId=$chatId');
    }
  }
}
