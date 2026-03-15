/// LlmRouter — routes queries to the correct LLM based on privacy score.
///
/// Decision logic:
///   if (localOnly || privacyScore >= threshold) → LOCAL LLM (Ollama)
///   else if (needsExternalKnowledge) → SANITIZE → EXTERNAL LLM
///   else → LOCAL LLM with full context
///
/// Settings loaded from AtKey: settings.llm.pembrook@agent
/// API keys loaded from AtKey: apikey.$provider.pembrook@agent
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
  String _localModel = 'qwen2.5:7b';
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
  ///
  /// When [tools] and [toolExecutor] are provided the local model is called
  /// with the Ollama native tool-calling API.  On each iteration the model
  /// may return a tool call; the executor runs it and the result is fed back
  /// until the model produces a plain-text reply.
  Future<String> generateResponse({
    required String query,
    required List<ConversationMessage> conversationHistory,
    required double privacyScore,
    String? systemOverride,
    List<Map<String, dynamic>> tools = const [],
    Future<String> Function(String toolName, Map<String, dynamic> args)?
        toolExecutor,
    Future<void> Function(String chunk)? onChunk,
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

    final systemPrompt = systemOverride ??
        '''You are Pem, a helpful and privacy-focused AI assistant. Pem is short for Pembrook.
You operate exclusively for your owner. Be concise and accurate.
Never suggest storing personal data outside the atPlatform.
Current date: ${DateTime.now().toUtc().toIso8601String()}''';

    // Privacy routing decision
    final useLocal = _localOnly || privacyScore >= _privacyThreshold;

    if (tools.isNotEmpty && toolExecutor != null) {
      // ── Agentic tool-calling loop (local model + tools) ──────────────────
      // Tool calling always runs on the local model (Ollama) regardless of
      // the privacy score — the privacyScore only governs whether to send
      // text to an external LLM.  Never skip tools for low-privacy queries.
      _log.info(
          'Using tool-calling loop (${tools.length} tool(s), model=$_localModel)');

      // Append strict tool-use rules so the model doesn't answer from memory.
      final toolSystemPrompt = '''$systemPrompt

TOOL USE RULES — follow these exactly, every time:
- To create any recurring or scheduled action: ALWAYS call schedule_task. Never just say "I'll set that up" without calling it.
- To list scheduled tasks: ALWAYS call list_tasks. Never say "no tasks" without calling it first.
- To stop or remove a task: ALWAYS call list_tasks then cancel_task. Never say "cancelled" without calling cancel_task.
- To fetch live web content: ALWAYS call fetch_webpage. Never guess at current news, weather, prices, etc.
- Do NOT answer task management questions from memory or conversation history. Always use the appropriate tool.''';

      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': toolSystemPrompt},
        for (final m in contextMessages)
          {
            'role': m.role == 'assistant' ? 'assistant' : 'user',
            'content': m.content
          },
        {'role': 'user', 'content': query},
      ];
      return generateResponseWithTools(
        messages: messages,
        tools: tools,
        toolExecutor: toolExecutor,
        onChunk: onChunk,
      );
    }

    // ── Plain text path (no tools, or privacy-routed to external) ─────────
    final contextText = contextMessages
        .map((m) =>
            '${m.role == 'assistant' ? 'Assistant' : 'User'}: ${m.content}')
        .join('\n');

    final fullPrompt =
        '$systemPrompt\n\nConversation history:\n$contextText\n\nUser: $query\nAssistant:';

    if (useLocal) {
      _log.fine(
          'Routing to LOCAL LLM (privacyScore=$privacyScore threshold=$_privacyThreshold localOnly=$_localOnly)');
      return _callOllama(prompt: fullPrompt, onChunk: onChunk);
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

  /// Call the local Ollama /api/chat endpoint.
  ///
  /// Uses the chat format (messages array) which all Ollama models support
  /// and which enables structured tool calling on capable models
  /// (qwen2.5:7b, llama3.1:8b, mistral-nemo, etc.)
  ///
  /// [tools] — optional list of tool definitions in Ollama/OpenAI schema.
  /// Returns the raw response message map so callers can inspect tool_calls.
  Future<Map<String, dynamic>> _callOllamaChat({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools = const [],
    int maxTokens = 2048,
    double temperature = 0.7,
  }) async {
    try {
      final body = <String, dynamic>{
        'model': _localModel,
        'messages': messages,
        'stream': false,
        'options': {
          'num_predict': maxTokens,
          'temperature': temperature,
        },
      };
      if (tools.isNotEmpty) body['tools'] = tools;

      final response = await http
          .post(
            Uri.parse('$ollamaBaseUrl/api/chat'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 120));

      if (response.statusCode != 200) {
        _log.warning(
            'Ollama chat returned ${response.statusCode}: ${response.body}');
        return {
          'role': 'assistant',
          'content':
              'I apologize — the local AI model is temporarily unavailable.'
        };
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return (data['message'] as Map<String, dynamic>?) ??
          {'role': 'assistant', 'content': ''};
    } catch (e) {
      _log.severe('Ollama chat call failed: $e');
      return {
        'role': 'assistant',
        'content':
            'I apologize — I could not reach the local AI model. Error: $e'
      };
    }
  }

  /// Call the local Ollama API (simple text-in/text-out wrapper).
  ///
  /// Uses the chat endpoint internally so the same model weights handle
  /// both plain chat and tool-calling conversations.
  /// When [onChunk] is provided, uses Ollama streaming mode so tokens arrive
  /// incrementally instead of all at once.
  Future<String> _callOllama({
    required String prompt,
    int maxTokens = 2048,
    double temperature = 0.7,
    Future<void> Function(String chunk)? onChunk,
  }) async {
    final messages = [
      {'role': 'user', 'content': prompt}
    ];
    if (onChunk != null) {
      return _callOllamaStreaming(
        messages: messages,
        onChunk: onChunk,
        maxTokens: maxTokens,
        temperature: temperature,
      );
    }
    final msg = await _callOllamaChat(
      messages: messages,
      maxTokens: maxTokens,
      temperature: temperature,
    );
    return (msg['content'] as String? ?? '').trim();
  }

  /// Streaming variant of [_callOllamaChat] — uses Ollama NDJSON streaming.
  /// Calls [onChunk] for every token as it is produced.
  Future<String> _callOllamaStreaming({
    required List<Map<String, dynamic>> messages,
    required Future<void> Function(String chunk) onChunk,
    int maxTokens = 2048,
    double temperature = 0.7,
  }) async {
    final client = http.Client();
    try {
      final request = http.Request(
        'POST',
        Uri.parse('\$ollamaBaseUrl/api/chat'),
      );
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode({
        'model': _localModel,
        'messages': messages,
        'stream': true,
        'options': {
          'num_predict': maxTokens,
          'temperature': temperature,
        },
      });

      final streamedResp =
          await client.send(request).timeout(const Duration(seconds: 120));

      if (streamedResp.statusCode != 200) {
        _log.warning('Ollama streaming returned \${streamedResp.statusCode}');
        return 'I apologize — the local AI model is temporarily unavailable.';
      }

      final chunks = <String>[];
      await for (final line in streamedResp.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (line.isEmpty) continue;
        try {
          final data = jsonDecode(line) as Map<String, dynamic>;
          final message = data['message'] as Map<String, dynamic>?;
          final content = message?['content'] as String? ?? '';
          if (content.isNotEmpty) {
            chunks.add(content);
            await onChunk(content);
          }
          if (data['done'] == true) break;
        } catch (_) {}
      }
      return chunks.join().trim();
    } catch (e) {
      _log.severe('Ollama streaming call failed: \$e');
      return 'I apologize — I could not reach the local AI model. Error: \$e';
    } finally {
      client.close();
    }
  }

  /// Agentic tool-use loop using Ollama's native tool-calling API.
  ///
  /// [tools] — list of tool definitions (Ollama/OpenAI schema).
  /// [toolExecutor] — async callback that executes a tool call and returns
  ///   the result string.  Called with (toolName, arguments).
  /// [messages] — initial message history (system + user messages).
  ///
  /// The loop runs until the model returns a plain text response (no tool
  /// calls), or until [maxIterations] is reached (safety guard).
  Future<String> generateResponseWithTools({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required Future<String> Function(String toolName, Map<String, dynamic> args)
        toolExecutor,
    int maxIterations = 5,
    Future<void> Function(String chunk)? onChunk,
  }) async {
    final history = List<Map<String, dynamic>>.from(messages);

    for (var iteration = 0; iteration < maxIterations; iteration++) {
      _log.info(
          '[tool-loop] iteration=${iteration + 1}/$maxIterations — calling model');
      final assistantMsg = await _callOllamaChat(
        messages: history,
        tools: tools,
      );
      history.add(assistantMsg);

      final toolCalls = assistantMsg['tool_calls'] as List<dynamic>?;

      // No tool calls → model produced a final text answer.
      if (toolCalls == null || toolCalls.isEmpty) {
        _log.info(
            '[tool-loop] model returned plain text answer (no tool calls) after ${iteration + 1} iteration(s)');
        final rawAnswer = (assistantMsg['content'] as String? ?? '').trim();
        // Feed the answer through onChunk so the app sees it token-by-token
        // even though the tool-calling path used a non-streaming call.
        // We re-stream the text in small bursts (word-by-word) so the UI
        // still animates smoothly rather than popping in all at once.
        if (onChunk != null && rawAnswer.isNotEmpty) {
          final words = rawAnswer.split(' ');
          for (var i = 0; i < words.length; i++) {
            await onChunk(i == 0 ? words[i] : ' ${words[i]}');
          }
        }
        return rawAnswer;
      }

      _log.info('[tool-loop] model requested ${toolCalls.length} tool call(s)');

      // Execute each tool call and feed results back.
      for (final call in toolCalls) {
        final fn = call['function'] as Map<String, dynamic>;
        final toolName = fn['name'] as String;
        final rawArgs = fn['arguments'];
        final args = (rawArgs is Map)
            ? Map<String, dynamic>.from(rawArgs)
            : (rawArgs is String
                ? (jsonDecode(rawArgs) as Map<String, dynamic>)
                : <String, dynamic>{});

        _log.info('Tool call: $toolName($args)');
        String result;
        try {
          result = await toolExecutor(toolName, args);
        } catch (e) {
          result = 'Error calling $toolName: $e';
        }
        _log.info('Tool result for $toolName: ${result.length} chars');

        // Ollama expects the tool result as a message with role 'tool'.
        history.add({
          'role': 'tool',
          'content': result,
        });
      }
    }

    // Safety: return whatever the last assistant message contained.
    final last = history.lastWhere((m) => m['role'] == 'assistant',
        orElse: () => {'content': ''});
    return (last['content'] as String? ?? '').trim();
  }

  // ── External LLM ──────────────────────────────────────────────────────────

  /// Call an external LLM with a SANITIZED query (no PII).
  ///
  /// API key is loaded from encrypted AtKey: apikey.$provider.pembrook@agent
  Future<String> _callExternalLlm(String sanitizedQuery) async {
    // Retrieve API key from encrypted AtKey (NEVER from .env files)
    String? apiKey;
    try {
      final keyAtKey = AtKey()
        ..key = 'apikey.$_externalProvider'
        ..namespace = 'pembrook';
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
        ..namespace = 'pembrook';
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
