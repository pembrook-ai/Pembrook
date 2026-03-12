/// LlmRouter — routes queries to the correct LLM based on privacy score.
///
/// Decision logic:
///   if (localOnly || privacyScore >= threshold) → LOCAL LLM (Ollama)
///   else if (needsExternalKnowledge) → SANITIZE → EXTERNAL LLM
///   else → LOCAL LLM with full context
///
/// Settings loaded from AtKey: settings.llm.safeclaw@agent
/// API keys loaded from AtKey: apikey.$provider.safeclaw@agent
///   (stored encrypted — NEVER in .env files)
///
/// Ollama API: POST http://localhost:11434/api/generate
///   Binds to loopback only — never exposed to network.
///
/// External LLM providers (optional, disabled by default):
///   - Claude (Anthropic)
///   - OpenAI GPT
///   - Google Gemini

import 'dart:convert';
import 'package:at_client/at_client.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../models/conversation.dart';
import '../services/sanitizer.dart';

class LlmRouter {
  final AtClient atClient;
  final QuerySanitizer sanitizer;
  final String ollamaBaseUrl;

  final Logger _log = Logger('LlmRouter');

  // Cached settings — refreshed from AtKey periodically
  String _localModel = 'llama3.2';
  String _externalProvider = 'none';
  double _privacyThreshold = 0.7;
  bool _localOnly = false;
  DateTime _settingsLastRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _settingsCacheTtl = Duration(minutes: 5);

  LlmRouter({
    required this.atClient,
    required this.sanitizer,
    this.ollamaBaseUrl = 'http://localhost:11434',
  });

  /// Classify the user's query intent.
  Future<IntentType> classifyIntent({
    required String query,
    required List<ConversationMessage> conversationHistory,
  }) async {
    final prompt = '''
Classify this user query into exactly one category. Reply with ONLY the category name.

Categories:
- chat: general conversation, questions, explanations
- task: specific one-time task (write email, set reminder, search web)
- automation: set up a recurring action or trigger
- skillInvocation: explicitly requests a specific tool or skill
- mcpToolCall: requests a specific external system action (home control, database query)
- multiStepPlan: complex request that needs multiple actions
- unknown: cannot determine

User query: "$query"

Category:''';

    final response = await _callOllama(
      prompt: prompt,
      maxTokens: 20,
      temperature: 0.0,
    );

    final normalized = response.trim().toLowerCase();
    for (final type in IntentType.values) {
      if (normalized.contains(type.name.toLowerCase())) return type;
    }
    return IntentType.chat; // safe default
  }

  /// Score how sensitive/private the query is.
  ///
  /// Returns 0.0 (fully public) to 1.0 (highly sensitive / personal).
  /// Queries above the privacy threshold are NEVER sent to external LLMs.
  Future<double> scorePrivacy(String query) async {
    final prompt = '''
Score how private or sensitive this query is on a scale of 0.0 to 1.0.

0.0 = completely public information (weather, general knowledge)
0.5 = moderately personal (general preferences, non-identifying)
1.0 = highly sensitive (health data, finances, location, personal relationships)

Reply with ONLY a decimal number between 0.0 and 1.0.

Query: "$query"

Score:''';

    final response = await _callOllama(
      prompt: prompt,
      maxTokens: 10,
      temperature: 0.0,
    );

    return double.tryParse(response.trim()) ?? 0.5;
  }

  /// Generate a response, routing to local or external LLM.
  Future<String> generateResponse({
    required String query,
    required List<ConversationMessage> conversationHistory,
    required double privacyScore,
    String? systemOverride,
  }) async {
    await _maybeRefreshSettings();

    // Build conversation context for the LLM
    final contextMessages = conversationHistory
        .where((m) =>
            // Filter: never include externally sourced content in full context
            // to prevent memory poisoning. Summarize instead.
            m.trustLevel == TrustLevel.owner ||
            m.trustLevel == TrustLevel.verifiedSkill)
        .take(20) // last 20 trusted messages
        .toList();

    final contextText = contextMessages
        .map((m) =>
            '${m.role == 'assistant' ? 'Assistant' : 'User'}: ${m.content}')
        .join('\n');

    final systemPrompt = systemOverride ??
        '''You are SafeClaw, a helpful and privacy-focused AI assistant.
You operate exclusively for your owner. Be concise and accurate.
Never suggest storing personal data outside the atPlatform.
Current date: ${DateTime.now().toUtc().toIso8601String()}''';

    final fullPrompt =
        '$systemPrompt\n\nConversation history:\n$contextText\n\nUser: $query\nAssistant:';

    // Privacy routing decision
    final useLocal = _localOnly || privacyScore >= _privacyThreshold;

    if (useLocal) {
      _log.fine(
          'Routing to LOCAL LLM (privacyScore=$privacyScore threshold=$_privacyThreshold localOnly=$_localOnly)');
      return _callOllama(prompt: fullPrompt);
    } else {
      // Hybrid: try local first, escalate to external if knowledge gap detected
      _log.fine('Attempting local LLM first (might escalate to external)');
      final localResponse = await _callOllama(prompt: fullPrompt);

      // Detect knowledge gap indicators
      final needsExternal = _detectKnowledgeGap(localResponse);
      if (!needsExternal || _externalProvider == 'none') {
        return localResponse;
      }

      // Sanitize before external call
      _log.info('Knowledge gap detected — sanitizing and calling external LLM');
      final sanitized = await sanitizer.sanitize(query);
      final externalResponse = await _callExternalLlm(sanitized.sanitizedQuery);

      // Merge: local LLM adds context back to external response
      final mergePrompt =
          '$systemPrompt\n\nUser: $query\n\nExternal knowledge (sanitized, no PII):\n$externalResponse\n\nProvide a final answer incorporating the external knowledge:';
      return _callOllama(prompt: mergePrompt);
    }
  }

  // ── Ollama ────────────────────────────────────────────────────────────────

  /// Call the local Ollama API.
  ///
  /// Ollama must be running at [ollamaBaseUrl] (default: http://localhost:11434).
  /// Start with: docker run -d -p 127.0.0.1:11434:11434 ollama/ollama
  Future<String> _callOllama({
    required String prompt,
    int maxTokens = 2048,
    double temperature = 0.7,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$ollamaBaseUrl/api/generate'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'model': _localModel,
              'prompt': prompt,
              'stream': false,
              'options': {
                'num_predict': maxTokens,
                'temperature': temperature,
              },
            }),
          )
          .timeout(const Duration(seconds: 120));

      if (response.statusCode != 200) {
        _log.warning(
            'Ollama returned ${response.statusCode}: ${response.body}');
        return 'I apologize — the local AI model is temporarily unavailable. '
            'Please ensure Ollama is running: '
            'docker run -d -p 127.0.0.1:11434:11434 ollama/ollama';
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return (data['response'] as String? ?? '').trim();
    } catch (e) {
      _log.severe('Ollama call failed: $e');
      return 'I apologize — I could not reach the local AI model. '
          'Error: $e';
    }
  }

  // ── External LLM ──────────────────────────────────────────────────────────

  /// Call an external LLM with a SANITIZED query (no PII).
  ///
  /// API key is loaded from encrypted AtKey: apikey.$provider.safeclaw@agent
  Future<String> _callExternalLlm(String sanitizedQuery) async {
    // Retrieve API key from encrypted AtKey (NEVER from .env files)
    String? apiKey;
    try {
      final keyAtKey = AtKey()
        ..key = 'apikey.$_externalProvider'
        ..namespace = 'safeclaw';
      final atValue = await atClient.get(
        keyAtKey,
        getRequestOptions: GetRequestOptions()..useRemoteAtServer = true,
      );
      apiKey = atValue.value as String?;
    } catch (e) {
      _log.warning('Failed to load API key for $_externalProvider: $e');
    }

    if (apiKey == null || apiKey.isEmpty) {
      _log.info(
          'No API key for $_externalProvider — falling back to local LLM');
      return _callOllama(prompt: sanitizedQuery);
    }

    switch (_externalProvider) {
      case 'openai':
        return _callOpenAI(sanitizedQuery, apiKey);
      case 'claude':
        return _callClaude(sanitizedQuery, apiKey);
      default:
        return _callOllama(prompt: sanitizedQuery);
    }
  }

  Future<String> _callOpenAI(String query, String apiKey) async {
    try {
      final response = await http
          .post(
            Uri.parse('https://api.openai.com/v1/chat/completions'),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': 'gpt-4o-mini',
              'messages': [
                {'role': 'user', 'content': query},
              ],
              'max_tokens': 1024,
            }),
          )
          .timeout(const Duration(seconds: 30));

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return (data['choices'] as List<dynamic>)[0]['message']['content']
              as String? ??
          '';
    } catch (e) {
      _log.warning('OpenAI call failed: $e');
      return _callOllama(prompt: query);
    }
  }

  Future<String> _callClaude(String query, String apiKey) async {
    try {
      final response = await http
          .post(
            Uri.parse('https://api.anthropic.com/v1/messages'),
            headers: {
              'x-api-key': apiKey,
              'anthropic-version': '2023-06-01',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': 'claude-3-haiku-20240307',
              'max_tokens': 1024,
              'messages': [
                {'role': 'user', 'content': query},
              ],
            }),
          )
          .timeout(const Duration(seconds: 30));

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return (data['content'] as List<dynamic>)[0]['text'] as String? ?? '';
    } catch (e) {
      _log.warning('Claude call failed: $e');
      return _callOllama(prompt: query);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  bool _detectKnowledgeGap(String response) {
    final indicators = [
      'my knowledge cutoff',
      "i don't have current",
      "i don't have real-time",
      'as of my last update',
      'i cannot access the internet',
      'i do not have access to',
    ];
    final lower = response.toLowerCase();
    return indicators.any((indicator) => lower.contains(indicator));
  }

  Future<void> _maybeRefreshSettings() async {
    final now = DateTime.now();
    if (now.difference(_settingsLastRefresh) < _settingsCacheTtl) return;

    try {
      final settingsKey = AtKey()
        ..key = 'settings.llm'
        ..namespace = 'safeclaw';
      final atValue = await atClient.get(
        settingsKey,
        getRequestOptions: GetRequestOptions()..useRemoteAtServer = true,
      );
      if (atValue.value != null) {
        final settings =
            jsonDecode(atValue.value as String) as Map<String, dynamic>;
        _localModel = settings['localModel'] as String? ?? _localModel;
        _externalProvider =
            settings['externalProvider'] as String? ?? _externalProvider;
        _privacyThreshold =
            (settings['privacyThreshold'] as num?)?.toDouble() ??
                _privacyThreshold;
        _localOnly = settings['localOnly'] as bool? ?? _localOnly;
      }
    } catch (e) {
      _log.fine('Could not refresh LLM settings (using defaults): $e');
    }
    _settingsLastRefresh = now;
  }
}
