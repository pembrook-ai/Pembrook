/// Browser MCP Server — Phase 4.
///
/// Listens on the atNetwork for JSON-RPC 2.0 tool calls from @agent.
/// Provides HTTP fetch + HTML text extraction without a headless browser.
/// Full browser automation (screenshot, click, fill_form) requires a
/// separate Playwright/Puppeteer sidecar — those tools return a
/// descriptive error if the sidecar is not configured.
///
/// Start:
///   dart run bin/main.dart --atsign @mcp_browser --storage-dir /data/mcp_browser
///
/// Exposed tools:
///   browser.fetch(url)           — return raw HTML of a page
///   browser.extract_text(url)    — return human-readable text of a page
///   browser.screenshot(url)      — base64 PNG via Playwright sidecar
///   browser.click(url, selector) — click element via Playwright sidecar
///   browser.fill_form(url, fields)— fill + submit form (HITL required)
///
/// Playwright sidecar config (optional, passed in arguments):
///   playwrightWsUrl : String — ws://playwright-sidecar:3000

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_cli_commons/at_cli_commons.dart';
import 'package:at_client/at_client.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

final _log = Logger('mcp_browser');

const _namespace = 'pembrook';
const _requestPattern = r'mcp\.request\.';

/// Consecutive `notificationService.notify()` failures.
/// If this reaches [_maxNotifyFailures] the process exits so Docker restarts it.
int _notifyFailures = 0;
const _maxNotifyFailures = 3;

const _userAgent =
    'Mozilla/5.0 (compatible; PembrookBot/1.0; +https://github.com/pembrook)';

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
        'Usage: dart run bin/main.dart --atsign @mcp_browser --key-file /path/to/@mcp_browser_key.atKeys');
    exit(1);
  }

  final atClient = cli.atClient;
  // CLIBase.fromCommandLineArgs() sets Logger.root.level = Level.SHOUT — restore it.
  Logger.root.level = Level.INFO;
  _log.info(
    'Browser MCP server started as ${atClient.getCurrentAtSign()}',
  );

  // Pre-warm the shared encryption key with @llama by doing a test put.
  // The first shared-key creation after an atServer restart can take a while;
  // doing it here avoids blocking the first real request.
  await _warmSharedKeys(atClient);

  await _listen(atClient);
}

// ─────────────────────────────────────────────────────────────────────────────
//  SHARED-KEY WARM-UP
// ─────────────────────────────────────────────────────────────────────────────

/// Attempt a test `put` of a shared key to `@llama` at startup.
/// This forces the at_client to establish the shared encryption key
/// (fetch @llama's public key, create symmetric key, exchange).
/// Allow up to 120 s — the first call after an atServer restart can be slow.
Future<void> _warmSharedKeys(AtClient atClient) async {
  const target = '@llama';
  _log.info('Warming shared encryption keys with $target ...');
  final sw = Stopwatch()..start();
  try {
    final key = (AtKey.shared(
      'mcp.warmup',
      namespace: _namespace,
      sharedBy: atClient.getCurrentAtSign()!,
    )..sharedWith(target))
        .build()
      ..metadata = (Metadata()
        ..ttl = 30000
        ..ttr = -1);

    await atClient
        .put(
          key,
          'warmup',
          putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
        )
        .timeout(const Duration(seconds: 120));

    _log.info('Shared-key warmup with $target succeeded '
        '(${sw.elapsedMilliseconds} ms)');
  } catch (e) {
    _log.warning('Shared-key warmup with $target failed after '
        '${sw.elapsedMilliseconds} ms: $e');
  }
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
      // Count notify-level failures so the keepalive exit threshold is reached
      // sooner if requests are failing due to a broken notify connection.
      if (e is TimeoutException) {
        _notifyFailures++;
        _log.warning(
            'Notify timed out on request ($_notifyFailures/$_maxNotifyFailures)');
        if (_notifyFailures >= _maxNotifyFailures) {
          _log.severe('Notify path dead — exiting for Docker restart');
          exit(1);
        }
      }
    }
  });

  // Keepalive: send a self-notification every 2 minutes to keep the notify
  // path warm.  If notify starts hanging (connection lost) we detect it early,
  // increment _notifyFailures, and eventually exit so Docker restarts us.
  Timer.periodic(const Duration(minutes: 2), (_) async {
    try {
      final self = atClient.getCurrentAtSign()!;
      final pingKey =
          (AtKey.shared('mcp.keepalive', namespace: _namespace, sharedBy: self)
                ..sharedWith(self))
              .build()
            ..metadata = (Metadata()
              ..ttl = 30000
              ..ttr = -1);
      await atClient.notificationService
          .notify(NotificationParams.forUpdate(pingKey, value: 'ping'))
          .timeout(const Duration(seconds: 10));
      _notifyFailures = 0;
      _log.info('Keepalive OK');
    } catch (e) {
      _notifyFailures++;
      _log.warning(
          'Keepalive failed ($_notifyFailures/$_maxNotifyFailures): $e');
      if (_notifyFailures >= _maxNotifyFailures) {
        _log.severe('Notify path dead — exiting for Docker restart');
        exit(1);
      }
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

  _log.info(
      'Sending response via put() to $callerAtSign for request $requestId ...');
  try {
    await atClient
        .put(
          responseKey,
          jsonEncode(response),
          putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
        )
        .timeout(const Duration(seconds: 30));

    _log.info('Response put() succeeded for $callerAtSign request $requestId');
  } catch (e) {
    _log.severe('put() failed for $requestId: $e');
    rethrow;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  TOOL DISPATCH
// ─────────────────────────────────────────────────────────────────────────────

Future<List<Map<String, dynamic>>> _callTool(
  String toolName,
  Map<String, dynamic> args,
) async {
  switch (toolName) {
    case 'browser.fetch':
      return _fetchPage(args);
    case 'browser.extract_text':
      return _extractText(args);
    case 'browser.screenshot':
      return _withPlaywright(args, 'screenshot');
    case 'browser.click':
      return _withPlaywright(args, 'click');
    case 'browser.fill_form':
      return _withPlaywright(args, 'fill_form');
    default:
      throw ArgumentError('Unknown tool: $toolName');
  }
}

List<Map<String, dynamic>> _toolList() => [
      {
        'name': 'browser.fetch',
        'description': 'Fetch the raw HTML of a URL.',
        'inputSchema': {
          'type': 'object',
          'required': ['url'],
          'properties': {
            'url': {'type': 'string'},
            'timeoutMs': {'type': 'integer', 'default': 15000},
          },
        },
      },
      {
        'name': 'browser.extract_text',
        'description':
            'Fetch a URL and return human-readable text (removes HTML boilerplate).',
        'inputSchema': {
          'type': 'object',
          'required': ['url'],
          'properties': {
            'url': {'type': 'string'},
            'timeoutMs': {'type': 'integer', 'default': 15000},
          },
        },
      },
      {
        'name': 'browser.screenshot',
        'description':
            'Take a screenshot of a URL (requires Playwright sidecar).',
        'inputSchema': {
          'type': 'object',
          'required': ['url'],
          'properties': {
            'url': {'type': 'string'},
            'playwrightWsUrl': {'type': 'string'},
          },
        },
      },
      {
        'name': 'browser.click',
        'description': 'Click a page element (requires Playwright sidecar).',
        'inputSchema': {
          'type': 'object',
          'required': ['url', 'selector'],
          'properties': {
            'url': {'type': 'string'},
            'selector': {'type': 'string'},
            'playwrightWsUrl': {'type': 'string'},
          },
        },
      },
      {
        'name': 'browser.fill_form',
        'description':
            'Fill and submit an HTML form (requires Playwright sidecar, HITL required).',
        'inputSchema': {
          'type': 'object',
          'required': ['url', 'fields'],
          'properties': {
            'url': {'type': 'string'},
            'fields': {
              'type': 'object',
              'description': 'Map of CSS selector to value'
            },
            'submitSelector': {'type': 'string'},
            'playwrightWsUrl': {'type': 'string'},
          },
        },
      },
    ];

// ─────────────────────────────────────────────────────────────────────────────
//  HTTP FETCH
// ─────────────────────────────────────────────────────────────────────────────

Future<List<Map<String, dynamic>>> _fetchPage(Map<String, dynamic> args) async {
  final url = _req(args, 'url') as String;
  final timeoutMs = (args['timeoutMs'] as int?) ?? 15000;

  final response = await http.get(
    Uri.parse(url),
    headers: {'User-Agent': _userAgent, 'Accept': 'text/html,*/*'},
  ).timeout(Duration(milliseconds: timeoutMs));

  if (response.statusCode != 200) {
    throw StateError('HTTP ${response.statusCode} for $url');
  }

  return [
    {
      'type': 'text',
      'text': 'URL: $url\nStatus: ${response.statusCode}\n'
          'Content-Type: ${response.headers['content-type'] ?? 'unknown'}\n'
          'Size: ${response.body.length} bytes',
    },
    {
      'type': 'text',
      'text': response.body,
    },
  ];
}

Future<List<Map<String, dynamic>>> _extractText(
    Map<String, dynamic> args) async {
  final url = _req(args, 'url') as String;
  final timeoutMs = (args['timeoutMs'] as int?) ?? 15000;

  final response = await http.get(
    Uri.parse(url),
    headers: {'User-Agent': _userAgent, 'Accept': 'text/html,*/*'},
  ).timeout(Duration(milliseconds: timeoutMs));

  if (response.statusCode != 200) {
    throw StateError('HTTP ${response.statusCode} for $url');
  }

  final contentType = response.headers['content-type'] ?? '';
  if (!contentType.contains('text/html') &&
      !contentType.contains('application/xhtml')) {
    return [
      {'type': 'text', 'text': response.body},
    ];
  }

  final document = html_parser.parse(response.body);
  final title = document.querySelector('title')?.text.trim();
  final text = _cleanText(document);

  return [
    {
      'type': 'text',
      'text': '${title != null ? 'Title: $title\n\n' : ''}$text',
    },
  ];
}

// ─────────────────────────────────────────────────────────────────────────────
//  PLAYWRIGHT SIDECAR (stub — requires external process)
// ─────────────────────────────────────────────────────────────────────────────

/// Delegate a tool call to an optional Playwright sidecar process.
///
/// The sidecar is expected to accept HTTP POST requests on
/// [playwrightWsUrl]/api/[action] with a JSON body of [args].
/// If [playwrightWsUrl] is not provided, returns a descriptive error.
Future<List<Map<String, dynamic>>> _withPlaywright(
  Map<String, dynamic> args,
  String action,
) async {
  final wsUrl = args['playwrightWsUrl'] as String?;
  if (wsUrl == null || wsUrl.isEmpty) {
    return [
      {
        'type': 'text',
        'text': 'browser.$action requires a running Playwright sidecar. '
            'Set the "playwrightWsUrl" argument to the sidecar base URL, '
            'e.g. "http://playwright:3000". '
            'See https://playwright.dev/docs/docker for deployment instructions.',
      },
    ];
  }

  // Attempt to call the sidecar REST endpoint
  final endpoint = '${wsUrl.trimRight()}/api/$action';
  final response = await http
      .post(
        Uri.parse(endpoint),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(args),
      )
      .timeout(const Duration(seconds: 60));

  if (response.statusCode != 200) {
    throw StateError(
      'Playwright sidecar returned ${response.statusCode}: ${response.body}',
    );
  }

  final data = jsonDecode(response.body) as Map<String, dynamic>;
  return [
    {'type': 'json', 'data': data},
  ];
}

// ─────────────────────────────────────────────────────────────────────────────
//  HTML TEXT EXTRACTION
// ─────────────────────────────────────────────────────────────────────────────

String _cleanText(Document document) {
  for (final tag in [
    'script',
    'style',
    'nav',
    'header',
    'footer',
    'aside',
    'noscript',
  ]) {
    for (final el in document.querySelectorAll(tag)) {
      el.remove();
    }
  }

  final content = document.querySelector('main') ??
      document.querySelector('article') ??
      document.querySelector('body');

  if (content == null) return '';

  final parts = <String>[];
  _collectText(content, parts);

  return parts
      .join()
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

void _collectText(Element element, List<String> parts) {
  const blockTags = {
    'p',
    'div',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'li',
    'tr',
    'br',
    'blockquote',
    'pre',
    'section',
  };
  for (final node in element.nodes) {
    if (node is Text) {
      final t = node.text.trim();
      if (t.isNotEmpty) parts.add('$t ');
    } else if (node is Element) {
      if (blockTags.contains(node.localName)) parts.add('\n');
      _collectText(node, parts);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────

Object _req(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v == null) throw ArgumentError('Missing required argument: "$key"');
  return v;
}
