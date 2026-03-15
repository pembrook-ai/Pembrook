/// Home Automation MCP Server — Phase 4.
///
/// Listens on the atNetwork for JSON-RPC 2.0 tool calls from @agent.
/// Proxies requests to the Home Assistant REST API on the local network.
///
/// Start:
///   dart run bin/main.dart --atsign @mcp_home --storage-dir /data/mcp_home
///
/// Exposed tools:
///   homeassistant.get_state(entity_id)
///   homeassistant.call_service(domain, service, entity_id, data?)
///   homeassistant.list_entities(domain?)
///
/// Configuration (passed in request arguments by agent, read from AtKey
/// settings.ha.pembrook@mcp_home by the agent before calling):
///   haBaseUrl  : String  — e.g. "http://homeassistant.local:8123"
///   haToken    : String  — long-lived access token

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_cli_commons/at_cli_commons.dart';
import 'package:at_client/at_client.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

final _log = Logger('mcp_home');

const _namespace = 'pembrook';
const _requestPattern = r'mcp\.request\.';

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
        'Usage: dart run bin/main.dart --atsign @mcp_home --key-file /path/to/@mcp_home_key.atKeys');
    exit(1);
  }

  final atClient = cli.atClient;
  // CLIBase sets Logger.root.level = Level.SHOUT internally — restore.
  Logger.root.level = Level.INFO;
  _log.info(
    'Home MCP server started as ${atClient.getCurrentAtSign()}',
  );

  await _listen(atClient);
}

// ─────────────────────────────────────────────────────────────────────────────
//  NOTIFICATION LISTENER
// ─────────────────────────────────────────────────────────────────────────────

Future<void> _listen(AtClient atClient) async {
  _log.info('Subscribing to MCP request notifications...');

  atClient.notificationService
      .subscribe(regex: _requestPattern, shouldDecrypt: true)
      .listen((notification) async {
    try {
      await _handleNotification(atClient, notification);
    } catch (e, st) {
      _log.severe('Error handling notification', e, st);
    }
  });

  // Keep alive
  await Completer<Never>().future;
}

Future<void> _handleNotification(
  AtClient atClient,
  AtNotification notification,
) async {
  final rawValue = notification.value;
  if (rawValue == null || rawValue.isEmpty) return;

  Map<String, dynamic> envelope;
  try {
    envelope = jsonDecode(rawValue) as Map<String, dynamic>;
  } catch (_) {
    _log.warning('Failed to parse JSON-RPC envelope: $rawValue');
    return;
  }

  final requestId = envelope['id'] as String? ?? '';
  final method = envelope['method'] as String? ?? '';
  final params = envelope['params'] as Map<String, dynamic>? ?? {};
  final callerAtSign = notification.from;

  _log.info(
    'Request from $callerAtSign: method=$method id=$requestId',
  );

  Map<String, dynamic> response;
  if (method == 'tools/call') {
    final toolName = params['name'] as String? ?? '';
    final arguments = params['arguments'] as Map<String, dynamic>? ?? {};
    try {
      final result = await _callTool(toolName, arguments);
      response = {
        'jsonrpc': '2.0',
        'result': {'content': result},
        'id': requestId,
      };
    } catch (e) {
      response = {
        'jsonrpc': '2.0',
        'error': {'code': -32000, 'message': e.toString()},
        'id': requestId,
      };
    }
  } else if (method == 'tools/list') {
    response = {
      'jsonrpc': '2.0',
      'result': {'tools': _toolList()},
      'id': requestId,
    };
  } else {
    response = {
      'jsonrpc': '2.0',
      'error': {'code': -32601, 'message': 'Method not found: $method'},
      'id': requestId,
    };
  }

  // Send response back to the caller
  final responseKey = (AtKey.shared(
    'mcp.response.$requestId',
    namespace: _namespace,
    sharedBy: atClient.getCurrentAtSign() ?? '',
  )..sharedWith(callerAtSign))
      .build()
    ..metadata = (Metadata()
      ..ttl = 30000
      ..ttr = -1);

  await atClient.notificationService.notify(
    NotificationParams.forUpdate(
      responseKey,
      value: jsonEncode(response),
    ),
  );

  _log.info('Response sent to $callerAtSign for request $requestId');
}

// ─────────────────────────────────────────────────────────────────────────────
//  TOOL DISPATCH
// ─────────────────────────────────────────────────────────────────────────────

Future<List<Map<String, dynamic>>> _callTool(
  String toolName,
  Map<String, dynamic> args,
) async {
  switch (toolName) {
    case 'homeassistant.get_state':
      return _getState(args);
    case 'homeassistant.call_service':
      return _callService(args);
    case 'homeassistant.list_entities':
      return _listEntities(args);
    default:
      throw ArgumentError('Unknown tool: $toolName');
  }
}

List<Map<String, dynamic>> _toolList() => [
      {
        'name': 'homeassistant.get_state',
        'description': 'Get the state of a Home Assistant entity.',
        'inputSchema': {
          'type': 'object',
          'required': ['haBaseUrl', 'haToken', 'entity_id'],
          'properties': {
            'haBaseUrl': {'type': 'string'},
            'haToken': {'type': 'string'},
            'entity_id': {'type': 'string'},
          },
        },
      },
      {
        'name': 'homeassistant.call_service',
        'description': 'Call a Home Assistant service (e.g. turn on a light).',
        'inputSchema': {
          'type': 'object',
          'required': ['haBaseUrl', 'haToken', 'domain', 'service'],
          'properties': {
            'haBaseUrl': {'type': 'string'},
            'haToken': {'type': 'string'},
            'domain': {'type': 'string'},
            'service': {'type': 'string'},
            'entity_id': {'type': 'string'},
            'data': {'type': 'object'},
          },
        },
      },
      {
        'name': 'homeassistant.list_entities',
        'description':
            'List all Home Assistant entities, optionally filtered by domain.',
        'inputSchema': {
          'type': 'object',
          'required': ['haBaseUrl', 'haToken'],
          'properties': {
            'haBaseUrl': {'type': 'string'},
            'haToken': {'type': 'string'},
            'domain': {
              'type': 'string',
              'description': 'Filter by domain (e.g. "light", "switch")'
            },
          },
        },
      },
    ];

// ─────────────────────────────────────────────────────────────────────────────
//  HOME ASSISTANT API HELPERS
// ─────────────────────────────────────────────────────────────────────────────

Map<String, String> _haHeaders(String token) => {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };

Future<List<Map<String, dynamic>>> _getState(Map<String, dynamic> args) async {
  final baseUrl = _req(args, 'haBaseUrl') as String;
  final token = _req(args, 'haToken') as String;
  final entityId = _req(args, 'entity_id') as String;

  final uri = Uri.parse('$baseUrl/api/states/$entityId');
  final resp = await http.get(uri, headers: _haHeaders(token));

  if (resp.statusCode != 200) {
    throw StateError('HA API returned ${resp.statusCode}: ${resp.body}');
  }

  final data = jsonDecode(resp.body) as Map<String, dynamic>;
  final text = 'Entity: ${data['entity_id']}\n'
      'State: ${data['state']}\n'
      'Attributes: ${jsonEncode(data['attributes'] ?? {})}';

  return [
    {'type': 'text', 'text': text},
    {'type': 'json', 'data': data},
  ];
}

Future<List<Map<String, dynamic>>> _callService(
    Map<String, dynamic> args) async {
  final baseUrl = _req(args, 'haBaseUrl') as String;
  final token = _req(args, 'haToken') as String;
  final domain = _req(args, 'domain') as String;
  final service = _req(args, 'service') as String;

  final body = <String, dynamic>{};
  if (args['entity_id'] != null) body['entity_id'] = args['entity_id'];
  if (args['data'] is Map) body.addAll(args['data'] as Map<String, dynamic>);

  final uri = Uri.parse('$baseUrl/api/services/$domain/$service');
  final resp = await http.post(
    uri,
    headers: _haHeaders(token),
    body: jsonEncode(body),
  );

  if (resp.statusCode != 200 && resp.statusCode != 201) {
    throw StateError(
        'HA service call returned ${resp.statusCode}: ${resp.body}');
  }

  List<dynamic> resultStates = [];
  try {
    resultStates = jsonDecode(resp.body) as List<dynamic>;
  } catch (_) {}

  return [
    {
      'type': 'text',
      'text': 'Service $domain.$service called successfully. '
          'Affected ${resultStates.length} entity/entities.',
    },
  ];
}

Future<List<Map<String, dynamic>>> _listEntities(
    Map<String, dynamic> args) async {
  final baseUrl = _req(args, 'haBaseUrl') as String;
  final token = _req(args, 'haToken') as String;
  final domainFilter = args['domain'] as String?;

  final uri = Uri.parse('$baseUrl/api/states');
  final resp = await http.get(uri, headers: _haHeaders(token));

  if (resp.statusCode != 200) {
    throw StateError('HA API returned ${resp.statusCode}: ${resp.body}');
  }

  final all =
      (jsonDecode(resp.body) as List<dynamic>).cast<Map<String, dynamic>>();

  final filtered = domainFilter == null
      ? all
      : all.where((e) {
          final eid = e['entity_id'] as String? ?? '';
          return eid.startsWith('${domainFilter}.');
        }).toList();

  final summary =
      filtered.map((e) => '${e['entity_id']}: ${e['state']}').join('\n');

  return [
    {
      'type': 'text',
      'text': 'Found ${filtered.length} entities'
          '${domainFilter != null ? ' in domain $domainFilter' : ''}:\n$summary',
    },
    {
      'type': 'json',
      'data': filtered
          .map((e) => {
                'entity_id': e['entity_id'],
                'state': e['state'],
              })
          .toList(),
    },
  ];
}

// ─────────────────────────────────────────────────────────────────────────────

Object _req(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v == null) throw ArgumentError('Missing required argument: "$key"');
  return v;
}
