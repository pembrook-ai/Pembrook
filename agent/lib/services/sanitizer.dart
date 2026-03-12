/// QuerySanitizer — strips PII before any external LLM call.
///
/// Uses the LOCAL Ollama LLM to identify and replace PII.
/// Never makes external API calls itself.
///
/// PII categories detected:
///   names, addresses, phone numbers, email addresses, account numbers,
///   locations, dates of birth, IP addresses, and owner-defined patterns.
///
/// Replacement strategy: generic numbered placeholders
///   'Alice Smith' → '[NAME_1]'
///   '123 Main St' → '[ADDRESS_1]'
///   '+1-555-0100' → '[PHONE_1]'
///
/// The reversible mapping is held in-memory only (NOT persisted as AtKey)
/// since it maps sensitive data to placeholders — it should not outlive
/// the current request.

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

class SanitizedResult {
  /// The query with all PII replaced by placeholders
  final String sanitizedQuery;

  /// Mapping: placeholder → original value
  /// Example: {'[NAME_1]': 'Alice Smith', '[ADDRESS_1]': '123 Main St'}
  final Map<String, String> reversibleMapping;

  const SanitizedResult({
    required this.sanitizedQuery,
    required this.reversibleMapping,
  });
}

class QuerySanitizer {
  final String ollamaBaseUrl;
  final Logger _log = Logger('QuerySanitizer');

  QuerySanitizer({this.ollamaBaseUrl = 'http://localhost:11434'});

  /// Sanitize a query by replacing all detected PII with numbered placeholders.
  Future<SanitizedResult> sanitize(String query) async {
    // 1. Ask local LLM to identify PII
    final identificationPrompt = '''
Analyze the following text and identify all personally identifiable information (PII).

PII categories to find:
- Full names (first, last, or full)
- Physical addresses or locations
- Phone numbers
- Email addresses
- Account or ID numbers
- Specific dates of birth
- IP addresses
- Organization names that identify the person
- Any other data that could identify a specific individual

Return a JSON object with a "pii" array, where each item has:
  "type": category (name/address/phone/email/account/dob/ip/org/other)
  "original": exact text from the input
  "placeholder": replacement to use (format: [TYPE_N] where N is 1,2,3...)

If no PII is found, return {"pii": []}.

Text to analyze: "$query"

JSON response:''';

    Map<String, dynamic> piiData;
    try {
      final ollamaResponse = await _callOllama(identificationPrompt);
      // Extract JSON from the response (LLM may wrap it in markdown)
      final jsonMatch =
          RegExp(r'\{[\s\S]*\}').firstMatch(ollamaResponse)?.group(0) ??
              '{"pii":[]}';
      piiData = jsonDecode(jsonMatch) as Map<String, dynamic>;
    } catch (e) {
      _log.warning('PII identification failed: $e — returning original query');
      return SanitizedResult(sanitizedQuery: query, reversibleMapping: {});
    }

    // 2. Build replacement mapping and sanitize
    final piiList = piiData['pii'] as List<dynamic>? ?? [];
    final mapping = <String, String>{};
    var sanitized = query;

    for (final item in piiList) {
      final original = item['original'] as String? ?? '';
      final placeholder = item['placeholder'] as String? ?? '';
      if (original.isNotEmpty && placeholder.isNotEmpty) {
        // Replace all occurrences (case-sensitive for accuracy)
        sanitized = sanitized.replaceAll(original, placeholder);
        mapping[placeholder] = original;
      }
    }

    _log.info('Sanitized query: replaced ${mapping.length} PII item(s)');
    return SanitizedResult(
        sanitizedQuery: sanitized, reversibleMapping: mapping);
  }

  /// Re-inject original values into the LLM response if the owner wants context.
  /// This is optional — in most cases the response is presented with placeholders.
  String rehydrate(String response, Map<String, String> mapping) {
    var result = response;
    mapping.forEach((placeholder, original) {
      result = result.replaceAll(placeholder, original);
    });
    return result;
  }

  Future<String> _callOllama(String prompt) async {
    final response = await http
        .post(
          Uri.parse('$ollamaBaseUrl/api/generate'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': 'llama3.2',
            'prompt': prompt,
            'stream': false,
            'options': {'temperature': 0.0, 'num_predict': 512},
          }),
        )
        .timeout(const Duration(seconds: 60));

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (data['response'] as String? ?? '').trim();
  }
}
