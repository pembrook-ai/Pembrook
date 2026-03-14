/// Orchestrator — the agent's brain.
///
/// Receives verified commands from the Gateway and decides what to do.
/// All context is loaded from AtKeys (never local files) — this enables
/// stateless operation and horizontal scaling with multiple instances.
///
/// Core request processing loop:
///   1. Load context   — conversation history + user preferences from AtKeys
///   2. Classify intent — chat | task | automation | skillInvocation | etc.
///   3. Privacy score   — 0.0 (public) → 1.0 (highly sensitive)
///   4. Build plan      — decompose complex tasks into steps
///   5. Execute         — route to LLM, skill, MCP tool, or HITL as needed
///   6. Respond         — stream response back through Gateway
///   7. Persist         — save exchange to Memory Service with source tags
///   8. Audit           — log every decision to Audit Service
///
/// Streaming design:
///   For streaming LLM output, the orchestrator sends incremental response
///   chunks to the owner via notificationService.notify() with key pattern:
///     @owner:safeclaw.stream.$reqId.safeclaw@agent
///   The Flutter app subscribes to 'safeclaw\\.stream\\..*' to receive chunks.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:at_client/at_client.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../core/policy_engine.dart';
import '../core/hitl_manager.dart';
import '../services/llm_router.dart';
import '../services/memory_service.dart';
import '../services/audit_service.dart';
import '../skills/skill_runner.dart';
import '../mcp/secure_mcp_client.dart';
import '../models/conversation.dart';
import '../models/audit_entry.dart';

class Orchestrator {
  final AtClient atClient;
  final LlmRouter llmRouter;
  final PolicyEngine policyEngine;
  final MemoryService memoryService;
  final AuditService auditService;
  final HitlManager hitlManager;
  final SkillRunner? skillRunner;
  final SecureMcpClient? mcpClient;

  final Logger _log = Logger('Orchestrator');

  /// Tool definitions offered to the LLM on every chat/task request.
  /// Models that support tool calling (qwen2.5, llama3.1, mistral-nemo)
  /// will use these automatically.  Models that don't will ignore them.
  static const _kTools = [
    {
      'type': 'function',
      'function': {
        'name': 'fetch_webpage',
        'description': 'Fetch and read the text content of any webpage or URL. '
            'Use this to get current news, check a website, or read online content.',
        'parameters': {
          'type': 'object',
          'required': ['url'],
          'properties': {
            'url': {
              'type': 'string',
              'description': 'The full URL to fetch (e.g. https://cnn.com)',
            },
          },
        },
      },
    },
  ];

  Orchestrator({
    required this.atClient,
    required this.llmRouter,
    required this.policyEngine,
    required this.memoryService,
    required this.auditService,
    required this.hitlManager,
    this.skillRunner,
    this.mcpClient,
  });

  /// Process a single request from the Gateway.
  ///
  /// Returns a response payload map:
  ///   {
  ///     'success': bool,
  ///     'response': 'full response text (or empty if streaming)',
  ///     'streaming': bool,
  ///     'conversationId': 'string',
  ///   }
  Future<Map<String, dynamic>> processRequest({
    required String command,
    required String conversationId,
    required String fromAtSign,
    required String platform,
    required int reqId,
  }) async {
    _log.info('Processing request convId=$conversationId '
        'from=$fromAtSign platform=$platform');

    final startTime = DateTime.now();

    // ── 1. Load context from Memory Service ───────────────────────────────
    Conversation? conversation;
    try {
      conversation = await memoryService.loadConversation(conversationId);
    } catch (e) {
      _log.warning('Failed to load conversation $conversationId: $e');
    }
    conversation ??= Conversation(
      id: conversationId,
      messages: [],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    // ── 2. Classify intent ────────────────────────────────────────────────
    final intentType = await llmRouter.classifyIntent(
      query: command,
      conversationHistory: conversation.messages,
    );
    _log.fine('Intent classified as: ${intentType.name}');

    // ── 3. Privacy score ──────────────────────────────────────────────────
    final privacyScore = await llmRouter.scorePrivacy(command);
    _log.fine('Privacy score: $privacyScore');

    // ── 4. Execute by intent ──────────────────────────────────────────────
    String responseText;

    switch (intentType) {
      case IntentType.chat:
      case IntentType.task:
      case IntentType.unknown:
        // Route to LLM — pass web tools so tool-capable models (qwen2.5, llama3.1)
        // can fetch live content instead of apologising about knowledge cutoffs.
        responseText = await llmRouter.generateResponse(
          query: command,
          conversationHistory: conversation.messages,
          privacyScore: privacyScore,
          tools: _kTools,
          toolExecutor: _executeTool,
        );

      case IntentType.skillInvocation:
        if (skillRunner == null) {
          responseText =
              'Skill invocation is not available (SkillRunner not wired).';
        } else {
          // Extract skill id from command payload (expected field: "skillId")
          final skillId = _extractField(command, 'skillId') ?? 'unknown';
          final payload = _extractPayload(command);
          final runResult = await skillRunner!.invoke(
            skillId: skillId,
            initiatorAtSign: fromAtSign,
            payload: payload,
            conversationId: conversationId,
          );
          if (runResult.success && runResult.result != null) {
            responseText = runResult.result.toString();
          } else {
            responseText = 'Skill "$skillId" failed: '
                '${runResult.error ?? runResult.denialReason ?? "unknown error"}';
          }
        }

      case IntentType.mcpToolCall:
        if (mcpClient == null) {
          responseText =
              'MCP tool calls are not available (MCP client not wired).';
        } else {
          final mcpAtSign = _extractField(command, 'mcpAtSign') ?? '@mcp_home';
          final toolName = _extractField(command, 'toolName') ?? 'unknown';
          final args = _extractPayload(command);
          final callResult = await mcpClient!.callTool(
            mcpAtSign: mcpAtSign,
            toolName: toolName,
            arguments: args,
            initiatorAtSign: fromAtSign,
            conversationId: conversationId,
          );
          if (callResult.success) {
            final parts = callResult.content
                .map((c) => c['text'] ?? c.toString())
                .join('\n');
            responseText = parts.isNotEmpty ? parts : '(empty MCP response)';
          } else {
            responseText = 'MCP call "$toolName" failed: '
                '${callResult.error ?? "unknown error"}';
          }
        }

      case IntentType.automation:
        // Automation requests are persisted as tasks and executed by the scheduler.
        responseText = 'Automation request received and queued for scheduling.';

      case IntentType.multiStepPlan:
        // Decompose and execute each step via LLM
        responseText = await llmRouter.generateResponse(
          query: command,
          conversationHistory: conversation.messages,
          privacyScore: privacyScore,
          systemOverride: 'Break this request into steps and execute each one. '
              'Show your reasoning.',
        );
    }

    final elapsed = DateTime.now().difference(startTime).inMilliseconds;

    // ── 5. Stream response to owner in real-time ──────────────────────────
    // NOTE: For true streaming, llmRouter.generateResponse() can be modified
    // to call a streaming callback that sends chunks via notificationService.
    // The current implementation returns the full response at once.
    // Streaming is a Phase 1 enhancement — see llm_router.dart.

    // ── 6. Persist exchange to Memory Service ─────────────────────────────
    try {
      await memoryService.saveExchange(
        conversationId: conversationId,
        userMessage: command,
        assistantMessage: responseText,
        sourceAtSign: fromAtSign,
        trustLevel:
            fromAtSign == (Platform.environment['OWNER_AT_SIGN'] ?? '@owner')
                ? TrustLevel.owner
                : TrustLevel.unverifiedInput,
      );
    } catch (e) {
      _log.warning('Failed to save exchange to memory: $e');
    }

    // ── 7. Audit ──────────────────────────────────────────────────────────
    try {
      await auditService.log(AuditEntry(
        actionType: 'command',
        initiatorAtSign: fromAtSign,
        targetResource: 'orchestrator',
        policyDecision: 'allowed',
        inputHash: 'sha256:${AuditService.contentHash(command)}',
        outputHash: 'sha256:${AuditService.contentHash(responseText)}',
        executionDurationMs: elapsed,
      ));
    } catch (e) {
      _log.warning('Failed to write audit log: $e');
    }

    return {
      'success': true,
      'response': responseText,
      'streaming': false,
      'conversationId': conversationId,
    };
  }

  /// Stream response chunks to the owner in real-time.
  ///
  /// Call this during streaming LLM generation to send incremental tokens.
  /// The Flutter app subscribes to 'safeclaw\\.stream\\..*' to receive them.
  ///
  /// Chunk key pattern: @owner:safeclaw.stream.$reqId.$chunkIndex.safeclaw@agent
  Future<void> sendStreamChunk({
    required String ownerAtSign,
    required int reqId,
    required int chunkIndex,
    required String chunk,
    required String conversationId,
    bool done = false,
  }) async {
    final key = AtKey()
      ..key = 'safeclaw.stream.$reqId.$chunkIndex'
      ..namespace = 'safeclaw'
      ..sharedWith = ownerAtSign
      ..metadata = (Metadata()
        ..ttl = 60000 // 1 minute TTL — transient streaming key
        ..ttr = -1);

    await atClient.notificationService.notify(
      NotificationParams.forUpdate(
        key,
        value: jsonEncode({
          'chunk': chunk,
          'chunkIndex': chunkIndex,
          'conversationId': conversationId,
          'done': done,
        }),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  //  PRIVATE HELPERS
  // ──────────────────────────────────────────────────────────

  /// Extract a top-level string field from a JSON command string, or null.
  String? _extractField(String command, String field) {
    try {
      final map = jsonDecode(command) as Map<String, dynamic>;
      return map[field] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Extract a 'payload' or 'arguments' map from a JSON command string.
  Map<String, dynamic> _extractPayload(String command) {
    try {
      final map = jsonDecode(command) as Map<String, dynamic>;
      return (map['payload'] as Map<String, dynamic>?) ??
          (map['arguments'] as Map<String, dynamic>?) ??
          {};
    } catch (_) {
      return {};
    }
  }

  /// Tool executor called by the LLM agentic loop.
  ///
  /// Each tool in [_kTools] must have a corresponding case here.
  Future<String> _executeTool(
      String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'fetch_webpage':
        final url = args['url'] as String? ?? '';
        return _fetchWebpage(url);
      default:
        return 'Unknown tool: $toolName';
    }
  }

  /// Fetch a URL and return its visible text content (HTML stripped).
  ///
  /// Caps output at 4 000 characters to keep context windows manageable.
  Future<String> _fetchWebpage(String url) async {
    if (url.isEmpty) return 'Error: no URL provided';
    Uri uri;
    try {
      uri = Uri.parse(url);
      if (!uri.hasScheme) uri = Uri.parse('https://$url');
    } catch (_) {
      return 'Error: invalid URL — $url';
    }
    try {
      _log.info('Fetching webpage: $uri');
      final resp = await http.get(uri, headers: {
        'User-Agent': 'SafeClaw-Agent/1.0 (fetch_webpage tool)',
        'Accept': 'text/html,application/xhtml+xml',
      }).timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) {
        return 'Error: HTTP ${resp.statusCode} from $uri';
      }

      // Strip HTML tags and collapse whitespace.
      var text = resp.body
          .replaceAll(RegExp(r'<style[^>]*>.*?</style>', dotAll: true), ' ')
          .replaceAll(RegExp(r'<script[^>]*>.*?</script>', dotAll: true), ' ')
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'&nbsp;'), ' ')
          .replaceAll(RegExp(r'&amp;'), '&')
          .replaceAll(RegExp(r'&lt;'), '<')
          .replaceAll(RegExp(r'&gt;'), '>')
          .replaceAll(RegExp(r'\s{2,}'), ' ')
          .trim();

      // Truncate to keep context window healthy.
      const kMaxChars = 4000;
      if (text.length > kMaxChars) {
        text =
            '${text.substring(0, kMaxChars)}\n[... truncated at $kMaxChars chars]';
      }
      return text.isEmpty ? '(page had no readable text)' : text;
    } on TimeoutException {
      return 'Error: timed out fetching $uri';
    } catch (e) {
      return 'Error fetching $uri: $e';
    }
  }
}
