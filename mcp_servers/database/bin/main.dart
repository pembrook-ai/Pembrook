/// Database MCP Server — Phase 4.
///
/// Listens on the atNetwork for JSON-RPC 2.0 tool calls from @agent.
/// Opens a local SQLite database and executes queries.
///
/// Start:
///   dart run bin/main.dart --atsign @mcp_db --storage-dir /data/mcp_db
///
/// Exposed tools:
///   db.query(sql, params?)        — SELECT queries (read-only)
///   db.execute(sql, params?)      — write queries (agent enforces HITL)
///   db.list_tables()              — list all tables in the database
///   db.describe_table(table)      — list columns / types for a table
///
/// The database path is passed in request arguments:
///   dbPath : String  — absolute path inside the container / host

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_cli_commons/at_cli_commons.dart';
import 'package:at_client/at_client.dart';
import 'package:logging/logging.dart';
import 'package:sqlite3/sqlite3.dart';

final _log = Logger('mcp_database');

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
        'Usage: dart run bin/main.dart --atsign @mcp_db --key-file /path/to/@mcp_db_key.atKeys');
    exit(1);
  }

  final atClient = cli.atClient;
  // CLIBase sets Logger.root.level = Level.SHOUT internally — restore.
  Logger.root.level = Level.INFO;
  _log.info(
    'Database MCP server started as ${atClient.getCurrentAtSign()}',
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
    _log.warning('Failed to parse JSON-RPC envelope');
    return;
  }

  final requestId = envelope['id'] as String? ?? '';
  final method = envelope['method'] as String? ?? '';
  final params = envelope['params'] as Map<String, dynamic>? ?? {};
  final callerAtSign = notification.from;

  _log.info('Request from $callerAtSign: method=$method id=$requestId');

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
    case 'db.query':
      return _query(args, readOnly: true);
    case 'db.execute':
      return _query(args, readOnly: false);
    case 'db.list_tables':
      return _listTables(args);
    case 'db.describe_table':
      return _describeTable(args);
    default:
      throw ArgumentError('Unknown tool: $toolName');
  }
}

List<Map<String, dynamic>> _toolList() => [
      {
        'name': 'db.query',
        'description': 'Execute a read-only SQL SELECT query.',
        'inputSchema': {
          'type': 'object',
          'required': ['dbPath', 'sql'],
          'properties': {
            'dbPath': {
              'type': 'string',
              'description': 'Absolute path to the SQLite database file'
            },
            'sql': {'type': 'string'},
            'params': {
              'type': 'array',
              'items': {},
              'description': 'Positional query parameters'
            },
          },
        },
      },
      {
        'name': 'db.execute',
        'description':
            'Execute a write SQL statement (INSERT/UPDATE/DELETE/DDL). Requires HITL approval.',
        'inputSchema': {
          'type': 'object',
          'required': ['dbPath', 'sql'],
          'properties': {
            'dbPath': {'type': 'string'},
            'sql': {'type': 'string'},
            'params': {'type': 'array', 'items': {}},
          },
        },
      },
      {
        'name': 'db.list_tables',
        'description': 'List all tables in the SQLite database.',
        'inputSchema': {
          'type': 'object',
          'required': ['dbPath'],
          'properties': {
            'dbPath': {'type': 'string'},
          },
        },
      },
      {
        'name': 'db.describe_table',
        'description': 'Describe the columns of a specific table.',
        'inputSchema': {
          'type': 'object',
          'required': ['dbPath', 'table'],
          'properties': {
            'dbPath': {'type': 'string'},
            'table': {'type': 'string'},
          },
        },
      },
    ];

// ─────────────────────────────────────────────────────────────────────────────
//  SQLITE HELPERS
// ─────────────────────────────────────────────────────────────────────────────

Future<List<Map<String, dynamic>>> _query(
  Map<String, dynamic> args, {
  required bool readOnly,
}) async {
  final dbPath = _req(args, 'dbPath') as String;
  final sql = _req(args, 'sql') as String;
  final params = (args['params'] as List<dynamic>?) ?? [];

  // Safety: refuse write SQL when readOnly flag is set
  if (readOnly) {
    final trimmed = sql.trim().toUpperCase();
    if (!trimmed.startsWith('SELECT') &&
        !trimmed.startsWith('EXPLAIN') &&
        !trimmed.startsWith('PRAGMA')) {
      throw ArgumentError(
        'db.query only accepts SELECT/EXPLAIN/PRAGMA. '
        'Use db.execute for write operations.',
      );
    }
  }

  final db = sqlite3.open(dbPath,
      mode: readOnly ? OpenMode.readOnly : OpenMode.readWriteCreate);
  try {
    final ResultSet resultSet;
    if (params.isEmpty) {
      resultSet = db.select(sql);
    } else {
      final stmt = db.prepare(sql);
      resultSet = stmt.select(params);
      stmt.dispose();
    }

    final rows = resultSet.map((row) {
      final map = <String, dynamic>{};
      for (final key in row.keys) {
        map[key] = row[key];
      }
      return map;
    }).toList();

    final text = rows.isEmpty
        ? 'Query returned 0 rows.'
        : 'Query returned ${rows.length} row(s):\n'
            '${rows.take(50).map((r) => jsonEncode(r)).join('\n')}'
            '${rows.length > 50 ? '\n... (${rows.length - 50} more rows)' : ''}';

    return [
      {'type': 'text', 'text': text},
      {'type': 'json', 'data': rows},
    ];
  } finally {
    db.dispose();
  }
}

Future<List<Map<String, dynamic>>> _listTables(
    Map<String, dynamic> args) async {
  final dbPath = _req(args, 'dbPath') as String;

  final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
  try {
    final result = db.select(
      "SELECT name, type FROM sqlite_master WHERE type IN ('table','view') ORDER BY name",
    );
    final tables =
        result.map((r) => {'name': r['name'], 'type': r['type']}).toList();
    final text = tables.isEmpty
        ? 'No tables found.'
        : 'Tables:\n${tables.map((t) => '  ${t['type']}: ${t['name']}').join('\n')}';
    return [
      {'type': 'text', 'text': text},
      {'type': 'json', 'data': tables},
    ];
  } finally {
    db.dispose();
  }
}

Future<List<Map<String, dynamic>>> _describeTable(
    Map<String, dynamic> args) async {
  final dbPath = _req(args, 'dbPath') as String;
  final table = _req(args, 'table') as String;

  final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
  try {
    final result = db.select('PRAGMA table_info("$table")');
    if (result.isEmpty) {
      throw StateError('Table "$table" not found or has no columns.');
    }
    final columns = result
        .map((r) => {
              'cid': r['cid'],
              'name': r['name'],
              'type': r['type'],
              'notnull': r['notnull'],
              'default': r['dflt_value'],
              'pk': r['pk'],
            })
        .toList();

    final text = 'Table "$table" columns:\n'
        '${columns.map((c) => '  [${c['cid']}] ${c['name']} ${c['type']}'
            '${c['pk'] != 0 ? ' PK' : ''}'
            '${c['notnull'] != 0 ? ' NOT NULL' : ''}').join('\n')}';

    return [
      {'type': 'text', 'text': text},
      {'type': 'json', 'data': columns},
    ];
  } finally {
    db.dispose();
  }
}

// ─────────────────────────────────────────────────────────────────────────────

Object _req(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v == null) throw ArgumentError('Missing required argument: "$key"');
  return v;
}
