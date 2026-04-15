/// Web Search skill — STDIN/STDOUT JSON line protocol entry point.
///
/// The SandboxManager sends:
///   {"command": "run", "payload": {...}, "requestId": "..."}
///
/// Supported actions (payload.action):
///   search.query  — perform a web search
///   search.get_page — fetch a URL and return clean text
///
/// For search.query, payload fields:
///   q             : String   — search query (required)
///   numResults    : int?     — max results (default 10)
///   searchApiUrl  : String?  — SearXNG base URL (e.g. https://searx.example.com)
///   braveApiKey   : String?  — Brave Search API key
///   engines       : List?    — SearXNG engines list (default: ['google','bing'])
///
/// For search.get_page, payload fields:
///   url           : String   — URL to fetch
///
/// NOTE: This skill requires network access. It will not function inside a
/// Docker sandbox with --network=none. Production deployment requires a
/// network-enabled sandbox profile with DNS and HTTPS allow-list.

import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

final _log = Logger('web_search');

void main() async {
  Logger.root.level = Level.WARNING;
  Logger.root.onRecord
      .listen((r) => stderr.writeln('[${r.level}] ${r.message}'));

  // SandboxManager passes the payload as a base64-encoded env var to avoid
  // `docker run --interactive` which requires HTTP hijacking the proxy can't forward.
  // Fall back to stdin for local testing / legacy callers.
  final Map<String, dynamic> input;
  final skillInputEnv = Platform.environment['SKILL_INPUT'];
  if (skillInputEnv != null && skillInputEnv.isNotEmpty) {
    input = jsonDecode(utf8.decode(base64.decode(skillInputEnv)))
        as Map<String, dynamic>;
  } else {
    final line = await stdin.first;
    input = jsonDecode(utf8.decode(line)) as Map<String, dynamic>;
  }
  final requestId = input['requestId'] as String? ?? '';
  final payload = input['payload'] as Map<String, dynamic>? ?? {};

  try {
    final result = await _handleCommand(payload);
    stdout.writeln(
      jsonEncode({'status': 'ok', 'result': result, 'requestId': requestId}),
    );
  } catch (e, st) {
    _log.severe('Unhandled error', e, st);
    stdout.writeln(
      jsonEncode({
        'status': 'error',
        'error': e.toString(),
        'requestId': requestId,
      }),
    );
    exit(1);
  }
}

// ─────────────────────────────────────────────────────────────────────────────

Future<Map<String, dynamic>> _handleCommand(
  Map<String, dynamic> payload,
) async {
  final action = payload['action'] as String? ?? 'search.query';

  switch (action) {
    case 'search':
    case 'search.query':
      return _search(payload);
    case 'get_page':
    case 'search.get_page':
      return _getPage(payload);
    default:
      throw ArgumentError('Unknown action: $action');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SEARCH
// ─────────────────────────────────────────────────────────────────────────────

Future<Map<String, dynamic>> _search(Map<String, dynamic> payload) async {
  final query = payload['q'] as String? ?? payload['query'] as String?;
  if (query == null || query.isEmpty) {
    throw ArgumentError('search.query requires a non-empty "q" field');
  }

  final numResults = (payload['numResults'] as int?) ?? 10;
  final braveApiKey = payload['braveApiKey'] as String?;
  final searchApiUrl = payload['searchApiUrl'] as String?;

  if (braveApiKey != null && braveApiKey.isNotEmpty) {
    return _braveSearch(query, braveApiKey, numResults);
  } else if (searchApiUrl != null && searchApiUrl.isNotEmpty) {
    final engines = (payload['engines'] as List<dynamic>?)?.cast<String>() ??
        ['google', 'bing'];
    return _searxSearch(query, searchApiUrl, numResults, engines);
  } else {
    throw ArgumentError(
      'Payload must include either "braveApiKey" or "searchApiUrl"',
    );
  }
}

/// Call the Brave Search REST API.
Future<Map<String, dynamic>> _braveSearch(
  String query,
  String apiKey,
  int count,
) async {
  final uri = Uri.https('api.search.brave.com', '/res/v1/web/search', {
    'q': query,
    'count': count.clamp(1, 20).toString(),
    'safesearch': 'moderate',
    'text_decorations': '0',
  });

  final response = await http.get(uri, headers: {
    'Accept': 'application/json',
    'Accept-Encoding': 'gzip',
    'X-Subscription-Token': apiKey,
  });

  if (response.statusCode != 200) {
    throw StateError(
      'Brave Search API returned ${response.statusCode}: ${response.body}',
    );
  }

  final body = jsonDecode(response.body) as Map<String, dynamic>;
  final webResults =
      ((body['web'] as Map<String, dynamic>?)?['results'] as List<dynamic>?) ??
          [];

  final results = webResults.map((r) {
    final item = r as Map<String, dynamic>;
    return {
      'title': item['title'] as String? ?? '',
      'url': item['url'] as String? ?? '',
      'description': item['description'] as String? ?? '',
    };
  }).toList();

  return {
    'query': query,
    'source': 'brave',
    'results': results,
    'totalResults': results.length,
  };
}

/// Call a SearXNG JSON endpoint.
Future<Map<String, dynamic>> _searxSearch(
  String query,
  String baseUrl,
  int count,
  List<String> engines,
) async {
  final uri = Uri.parse(baseUrl.trimRight()).replace(
    path: '/search',
    queryParameters: {
      'q': query,
      'format': 'json',
      'engines': engines.join(','),
      'pageno': '1',
      'safesearch': '1',
    },
  );

  final response = await http.get(
    uri,
    headers: {'Accept': 'application/json'},
  );

  if (response.statusCode != 200) {
    throw StateError(
      'SearXNG returned ${response.statusCode}: ${response.body}',
    );
  }

  final body = jsonDecode(response.body) as Map<String, dynamic>;
  final rawResults = (body['results'] as List<dynamic>?) ?? [];

  final results = rawResults.take(count).map((r) {
    final item = r as Map<String, dynamic>;
    return {
      'title': item['title'] as String? ?? '',
      'url': item['url'] as String? ?? '',
      'description': item['content'] as String? ?? '',
      'engines': (item['engines'] as List<dynamic>?)?.cast<String>() ?? [],
      'score': (item['score'] as num?)?.toDouble() ?? 0.0,
    };
  }).toList();

  return {
    'query': query,
    'source': 'searxng',
    'results': results,
    'totalResults': results.length,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
//  GET PAGE
// ─────────────────────────────────────────────────────────────────────────────

Future<Map<String, dynamic>> _getPage(Map<String, dynamic> payload) async {
  final url = payload['url'] as String?;
  if (url == null || url.isEmpty) {
    throw ArgumentError('search.get_page requires a "url" field');
  }

  final uri = Uri.parse(url);
  final response = await http.get(uri, headers: {
    'User-Agent':
        'Mozilla/5.0 (compatible; PembrookBot/1.0; +https://github.com/pembrook)',
    'Accept': 'text/html,application/xhtml+xml',
  });

  if (response.statusCode != 200) {
    throw StateError('HTTP ${response.statusCode} fetching $url');
  }

  final contentType = response.headers['content-type'] ?? '';
  if (!contentType.contains('text/html') &&
      !contentType.contains('application/xhtml')) {
    // Return raw text for non-HTML content (plain text, JSON, etc.)
    return {
      'url': url,
      'contentType': contentType,
      'text': response.body,
      'title': null,
    };
  }

  final document = html_parser.parse(response.body);
  final title = document.querySelector('title')?.text.trim();
  final text = _extractText(document);

  return {
    'url': url,
    'contentType': contentType,
    'text': text,
    'title': title,
    'wordCount': text.split(RegExp(r'\s+')).length,
  };
}

/// Extract human-readable text from an HTML document.
/// Removes scripts, styles, nav, and ads; collapses whitespace.
String _extractText(Document document) {
  // Remove clutter elements
  for (final tag in ['script', 'style', 'nav', 'header', 'footer', 'aside']) {
    for (final el in document.querySelectorAll(tag)) {
      el.remove();
    }
  }

  // Prefer <main> or <article>, fall back to <body>
  final content = document.querySelector('main') ??
      document.querySelector('article') ??
      document.querySelector('body');

  if (content == null) return '';

  final buffer = StringBuffer();
  _appendText(content, buffer);

  final text = buffer.toString();
  // Collapse runs of whitespace and blank lines
  return text
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

void _appendText(Element element, StringBuffer buffer) {
  for (final node in element.nodes) {
    if (node is Text) {
      final t = node.text.trim();
      if (t.isNotEmpty) buffer.write('$t ');
    } else if (node is Element) {
      // Add newline before block elements
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
      if (blockTags.contains(node.localName)) buffer.write('\n');
      _appendText(node, buffer);
    }
  }
}
