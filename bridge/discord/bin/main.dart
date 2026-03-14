/// Discord Bot Bridge — Phase 6.
///
/// Uses Discord Gateway WebSocket API (no external proxy required when bot is
/// invited to server with MESSAGE_CONTENT privileged intent enabled in the
/// Discord Developer Portal).
///
/// SUPPORTED INTERACTION PATTERNS:
///   • Slash command  /ask <question>   in any channel the bot can read
///   • Direct message (DM) to the bot
///   • @mention of the bot in a guild channel
///
/// FLOW:
///   1. Connect to Discord Gateway via WebSocket.
///   2. Heartbeat loop + IDENTIFY with bot token + intents.
///   3. On INTERACTION_CREATE (/ask): acknowledge immediately (deferred),
///      forward to @agent, follow-up with result.
///   4. On MESSAGE_CREATE (DM or @mention): reply in same channel.
///   5. Register /ask command on first boot (stored in application state AtKey).
///
/// Config (env vars or AtKeys):
///   DISCORD_BOT_TOKEN   — Bot token (required)
///
/// AtKey:
///   bridge.discord.token.safeclaw@bridge_discord
///
/// IMPORTANT: Enable MESSAGE_CONTENT privileged intent in the
///   Discord Developer Portal → Bot → Privileged Gateway Intents.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_cli_commons/at_cli_commons.dart';
import 'package:at_client/at_client.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _namespace = 'safeclaw';
String _agentAtSign =
    '@agent'; // overridden at startup from AGENT_AT_SIGN env var
const _platform = 'discord';
const _requestTimeout = Duration(seconds: 60);
const _apiBase = 'https://discord.com/api/v10';

// Intents: GUILDS(1) | GUILD_MESSAGES(512) | MESSAGE_CONTENT(32768)
//          | DIRECT_MESSAGES(4096)
const _intents = 1 | 512 | 32768 | 4096;

final _log = Logger('bridge_discord');
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
      'Usage: dart run bin/main.dart --atsign @bridge_discord '
      '--key-file /path/to/@bridge_discord_key.atKeys',
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
      'Discord bridge started as ${atClient.getCurrentAtSign()} → agent: $_agentAtSign');

  final token = await _loadToken(atClient);
  if (token.isEmpty) {
    _log.severe('DISCORD_BOT_TOKEN not set. Exiting.');
    exit(1);
  }

  final bot = _DiscordBridge(atClient: atClient, token: token);
  await bot.run();
}

// ─────────────────────────────────────────────────────────────────────────────
//  CONFIG
// ─────────────────────────────────────────────────────────────────────────────

Future<String> _loadToken(AtClient atClient) async {
  final envToken = Platform.environment['DISCORD_BOT_TOKEN'] ?? '';
  if (envToken.isNotEmpty) return envToken;
  try {
    final keyStr = 'bridge.discord.token.safeclaw'
        '@${atClient.getCurrentAtSign()!.replaceAll('@', '')}';
    final r = await atClient.get(AtKey.fromString(keyStr),
        getRequestOptions: GetRequestOptions()..useRemoteAtServer = true);
    return (r.value as String?) ?? '';
  } catch (_) {
    return '';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  DISCORD BRIDGE CONTROLLER
// ─────────────────────────────────────────────────────────────────────────────

class _DiscordBridge {
  final AtClient atClient;
  final String token;

  String? _botUserId;
  String? _applicationId;
  int? _lastSeqNum;
  bool _slashCommandRegistered = false;

  Timer? _heartbeatTimer;
  WebSocketChannel? _ws;
  int _reconnectDelay = 1;

  _DiscordBridge({required this.atClient, required this.token});

  Future<void> run() async {
    while (true) {
      try {
        await _connect();
      } catch (e, st) {
        _log.warning('Gateway connection error: $e\n$st');
      }
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      _log.info('Reconnecting in ${_reconnectDelay}s…');
      await Future.delayed(Duration(seconds: _reconnectDelay));
      _reconnectDelay = (_reconnectDelay * 2).clamp(1, 60);
    }
  }

  Future<void> _connect() async {
    final gatewayUrl = await _getGatewayUrl();
    _log.info('Connecting to Gateway: $gatewayUrl');

    _ws = WebSocketChannel.connect(Uri.parse('$gatewayUrl?v=10&encoding=json'));
    _reconnectDelay = 1; // reset on success

    await for (final raw in _ws!.stream) {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;
      await _handleGatewayMessage(data);
    }
  }

  Future<String> _getGatewayUrl() async {
    final resp = await http.get(
      Uri.parse('$_apiBase/gateway'),
      headers: {'Authorization': 'Bot $token'},
    );
    if (resp.statusCode != 200) {
      throw Exception('Could not fetch Gateway URL: ${resp.body}');
    }
    return (jsonDecode(resp.body) as Map)['url'] as String;
  }

  void _send(Map<String, dynamic> payload) {
    _ws?.sink.add(jsonEncode(payload));
  }

  Future<void> _handleGatewayMessage(Map<String, dynamic> msg) async {
    final op = msg['op'] as int;
    final seq = msg['s'] as int?;
    if (seq != null) _lastSeqNum = seq;

    switch (op) {
      case 10: // HELLO
        final interval =
            ((msg['d'] as Map<String, dynamic>)['heartbeat_interval'] as num)
                .toInt();
        _startHeartbeat(interval);
        _identify();

      case 11: // HEARTBEAT ACK
        _log.fine('Heartbeat ACK');

      case 1: // Heartbeat request
        _send({'op': 1, 'd': _lastSeqNum});

      case 9: // Invalid session
        _log.warning('Invalid session; re-identifying…');
        await Future.delayed(const Duration(seconds: 2));
        _identify();

      case 0: // Dispatch
        await _handleDispatch(msg);
    }
  }

  void _startHeartbeat(int intervalMs) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (_) => _send({'op': 1, 'd': _lastSeqNum}),
    );
    _log.fine('Heartbeat started at ${intervalMs}ms interval');
  }

  void _identify() {
    _send({
      'op': 2,
      'd': {
        'token': token,
        'intents': _intents,
        'properties': {
          'os': Platform.operatingSystem,
          'browser': 'safeclaw',
          'device': 'safeclaw',
        },
      },
    });
  }

  Future<void> _handleDispatch(Map<String, dynamic> msg) async {
    final t = msg['t'] as String?;
    final d = msg['d'] as Map<String, dynamic>?;
    if (d == null) return;

    switch (t) {
      case 'READY':
        _botUserId = (d['user'] as Map<String, dynamic>)['id'] as String?;
        _applicationId =
            (d['application'] as Map<String, dynamic>?)?['id'] as String?;
        _log.info('READY — botId=$_botUserId appId=$_applicationId');
        // Register /ask command once
        if (!_slashCommandRegistered && _applicationId != null) {
          unawaited(_registerSlashCommand());
        }

      case 'INTERACTION_CREATE':
        unawaited(_handleInteraction(d));

      case 'MESSAGE_CREATE':
        unawaited(_handleMessage(d));
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  //  SLASH COMMAND /ask
  // ────────────────────────────────────────────────────────────────────────

  Future<void> _registerSlashCommand() async {
    final appId = _applicationId!;
    // Check if already registered
    final listResp = await http.get(
      Uri.parse('$_apiBase/applications/$appId/commands'),
      headers: {'Authorization': 'Bot $token'},
    );
    if (listResp.statusCode == 200) {
      final commands = jsonDecode(listResp.body) as List;
      if (commands.any((c) => (c as Map)['name'] == 'ask')) {
        _log.info('/ask command already registered');
        _slashCommandRegistered = true;
        return;
      }
    }

    final resp = await http.post(
      Uri.parse('$_apiBase/applications/$appId/commands'),
      headers: {
        'Authorization': 'Bot $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'name': 'ask',
        'description': 'Ask the SafeClaw AI agent a question',
        'options': [
          {
            'type': 3, // STRING
            'name': 'question',
            'description': 'Your question or command',
            'required': true,
          },
        ],
      }),
    );

    if (resp.statusCode == 200 || resp.statusCode == 201) {
      _log.info('/ask command registered');
      _slashCommandRegistered = true;
    } else {
      _log.warning(
          'Failed to register /ask command: ${resp.statusCode} ${resp.body}');
    }
  }

  Future<void> _handleInteraction(Map<String, dynamic> d) async {
    final type = d['type'] as int;
    if (type != 2) return; // Only APPLICATION_COMMAND

    final interactionId = d['id'] as String;
    final interactionToken = d['token'] as String;
    final appId = _applicationId ?? '';
    final data = d['data'] as Map<String, dynamic>?;
    if (data?['name'] != 'ask') return;

    final options = (data?['options'] as List?) ?? [];
    final question = options
            .cast<Map<String, dynamic>>()
            .where((o) => o['name'] == 'question')
            .map((o) => o['value'] as String)
            .firstOrNull ??
        '';

    if (question.isEmpty) return;

    final guildId = d['guild_id'] as String?;
    final channelId = d['channel_id'] as String?;
    final userId = ((d['member'] as Map?)?['user'] as Map?) != null
        ? ((d['member'] as Map)['user'] as Map)['id'] as String?
        : (d['user'] as Map?)?['id'] as String?;
    final conversationId =
        '${_platform}_${guildId ?? channelId ?? userId ?? 'dm'}';

    _log.info('/ask from user=$userId: $question');

    // Acknowledge immediately (deferred public response)
    await _acknowledgeInteraction(interactionId, interactionToken);

    // Call agent
    final response = await _callAgent(
      command: question,
      conversationId: conversationId,
      senderUser: userId ?? 'unknown',
    );

    // Edit the original deferred response
    await _editOriginalInteractionResponse(appId, interactionToken, response);
  }

  Future<void> _acknowledgeInteraction(String id, String token) async {
    await http.post(
      Uri.parse('$_apiBase/interactions/$id/$token/callback'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'type': 5}), // DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE
    );
  }

  Future<void> _editOriginalInteractionResponse(
      String appId, String token, String text) async {
    const maxLength = 2000;
    final truncated = text.length > maxLength
        ? '${text.substring(0, maxLength - 3)}...'
        : text;

    final resp = await http.patch(
      Uri.parse('$_apiBase/webhooks/$appId/$token/messages/@original'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'content': truncated}),
    );
    if (resp.statusCode != 200) {
      _log.warning('Edit interaction response failed: ${resp.statusCode}');
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  //  MESSAGE_CREATE (DM + @mention)
  // ────────────────────────────────────────────────────────────────────────

  Future<void> _handleMessage(Map<String, dynamic> msg) async {
    final authorId = (msg['author'] as Map<String, dynamic>?)?['id'] as String?;
    // Ignore bot messages
    if (authorId == _botUserId) return;
    if ((msg['author'] as Map<String, dynamic>?)?['bot'] == true) return;

    final channelId = msg['channel_id'] as String? ?? '';
    final content = (msg['content'] as String?) ?? '';
    final guildId = msg['guild_id'] as String?;
    final isDm = guildId == null;

    // In guild: only respond to @mentions
    if (!isDm && _botUserId != null) {
      final mentions = (msg['mentions'] as List?) ?? [];
      final mentioned = mentions.cast<Map>().any((m) => m['id'] == _botUserId);
      if (!mentioned) return;
    }

    // Strip mention prefix
    String text = content;
    if (_botUserId != null) {
      text = content
          .replaceAll('<@$_botUserId>', '')
          .replaceAll('<@!$_botUserId>', '')
          .trim();
    }
    if (text.isEmpty) return;

    _log.info('Message from $authorId: $text');

    final conversationId =
        '${_platform}_${guildId ?? channelId}_${authorId ?? ''}';
    final response = await _callAgent(
      command: text,
      conversationId: conversationId,
      senderUser: authorId ?? 'unknown',
    );

    await _sendChannelMessage(channelId, response);
  }

  Future<void> _sendChannelMessage(String channelId, String text) async {
    const maxLength = 2000;
    // Split long responses
    for (int i = 0; i < text.length; i += maxLength) {
      final chunk = text.substring(
          i, (i + maxLength) > text.length ? text.length : i + maxLength);
      final resp = await http.post(
        Uri.parse('$_apiBase/channels/$channelId/messages'),
        headers: {
          'Authorization': 'Bot $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'content': chunk}),
      );
      if (resp.statusCode != 200) {
        _log.warning(
            'sendMessage to channel=$channelId failed: ${resp.statusCode}');
      }
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  //  AGENT CALL
  // ────────────────────────────────────────────────────────────────────────

  Future<String> _callAgent({
    required String command,
    required String conversationId,
    required String senderUser,
  }) async {
    final requestId = _uuid.v4();
    final bridgeAtSign = atClient.getCurrentAtSign() ?? '@bridge_discord';

    final payload = jsonEncode({
      'command': command,
      'conversationId': conversationId,
      'fromAtSign': bridgeAtSign,
      'platform': _platform,
      'senderUser': senderUser,
      'reqId': DateTime.now().millisecondsSinceEpoch,
    });

    final responseKey = 'bridge\\.response\\.$requestId';
    final responseFuture = _waitForResponse(responseKey);

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

  Future<String?> _waitForResponse(String keyRegex) async {
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
}
