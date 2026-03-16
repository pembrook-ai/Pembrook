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
///     @owner:pembrook.stream.$reqId.pembrook@agent
///   The Flutter app subscribes to 'pembrook\\.stream\\..*' to receive chunks.

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
import '../automation/scheduler.dart';
import '../automation/notification_manager.dart';
import '../models/task.dart';

class Orchestrator {
  final AtClient atClient;
  final LlmRouter llmRouter;
  final PolicyEngine policyEngine;
  final MemoryService memoryService;
  final AuditService auditService;
  final HitlManager hitlManager;
  final SkillRunner? skillRunner;
  final SecureMcpClient? mcpClient;
  final TaskScheduler? taskScheduler;
  final NotificationManager? notificationManager;

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
    {
      'type': 'function',
      'function': {
        'name': 'schedule_task',
        'description': 'Schedule a recurring or one-shot background task. Use this whenever '
            'the user asks you to monitor something, send periodic updates, '
            'remind them, or automate a repeated action. The task runs in the '
            'background and results are pushed directly to the owner as messages. '
            'Examples: "get me CNN headlines every 30 minutes", '
            '"remind me to drink water every hour", "check weather every morning".',
        'parameters': {
          'type': 'object',
          'required': ['description', 'command'],
          'properties': {
            'description': {
              'type': 'string',
              'description':
                  'Human-readable label for the task, e.g. "CNN headlines every 30 min"',
            },
            'command': {
              'type': 'string',
              'description':
                  'The instruction to run at each tick, e.g. "Fetch the latest CNN headlines and summarise them in 3 bullet points"',
            },
            'cronExpression': {
              'type': 'string',
              'description': 'Cron expression for recurring tasks. Examples: '
                  '"*/30 * * * *" (every 30 min), "0 8 * * *" (daily 8am). '
                  'Omit for one-shot tasks.',
            },
            'runAt': {
              'type': 'string',
              'description':
                  'ISO-8601 datetime for a one-shot task, e.g. "2026-03-14T09:00:00Z". '
                      'Omit when using cronExpression.',
            },
            'skillToInvoke': {
              'type': 'string',
              'description':
                  'Optional skill ID to use (e.g. "web_search", "email", "calendar"). '
                      'If omitted the task is handled by the LLM directly.',
            },
          },
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'notify_owner',
        'description':
            'Send an immediate push message to the owner. Use this to proactively '
                'inform the user about something without them asking — e.g. after '
                'completing an action, detecting an event, or when you have important info.',
        'parameters': {
          'type': 'object',
          'required': ['message'],
          'properties': {
            'message': {
              'type': 'string',
              'description': 'The message text to deliver to the owner',
            },
            'urgency': {
              'type': 'string',
              'enum': ['low', 'medium', 'high', 'critical'],
              'description': 'Urgency level (default: medium)',
            },
          },
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'list_tasks',
        'description':
            'List all currently scheduled background tasks. Use this when the '
                'user asks "what tasks are running?", "what have you scheduled?", '
                '"show me my reminders", or similar.',
        'parameters': {
          'type': 'object',
          'properties': {},
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'cancel_task',
        'description':
            'Cancel and remove a scheduled background task by its ID. '
                'Use this when the user says "stop the CNN headlines task", '
                '"cancel my water reminder", "remove task X", or similar. '
                'Call list_tasks first if you do not already know the task ID.',
        'parameters': {
          'type': 'object',
          'required': ['taskId'],
          'properties': {
            'taskId': {
              'type': 'string',
              'description': 'The task ID to cancel, e.g. "task_1741234567890"',
            },
          },
        },
      },
    },
  ];

  // ── Skill tool definitions (keyed by built-in skillId) ───────────────────────
  // Merged with _kTools at request time based on which skills are installed.
  static final _kSkillToolDefs = <String, List<Map<String, dynamic>>>{
    'email': [
      {
        'type': 'function',
        'function': {
          'name': 'send_email',
          'description': 'Send an email to one or more recipients via SMTP.',
          'parameters': {
            'type': 'object',
            'required': ['to', 'subject', 'body'],
            'properties': {
              'to': {
                'type': 'string',
                'description':
                    'Recipient email address (or comma-separated list)',
              },
              'cc': {
                'type': 'string',
                'description': 'Optional CC addresses',
              },
              'subject': {
                'type': 'string',
                'description': 'Email subject line',
              },
              'body': {
                'type': 'string',
                'description': 'Plain-text email body',
              },
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'list_inbox',
          'description': 'List recent emails in the IMAP inbox.',
          'parameters': {
            'type': 'object',
            'properties': {
              'maxMessages': {
                'type': 'integer',
                'description': 'Maximum messages to return (default 20)',
              },
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'read_email',
          'description': 'Read the full body of an email by its IMAP UID.',
          'parameters': {
            'type': 'object',
            'required': ['uid'],
            'properties': {
              'uid': {
                'type': 'integer',
                'description': 'Message UID from list_inbox',
              },
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'delete_email',
          'description':
              'Permanently delete an email by its IMAP UID. Requires owner approval.',
          'parameters': {
            'type': 'object',
            'required': ['uid'],
            'properties': {
              'uid': {
                'type': 'integer',
                'description': 'Message UID to delete',
              },
            },
          },
        },
      },
    ],
    'calendar': [
      {
        'type': 'function',
        'function': {
          'name': 'list_events',
          'description':
              'List upcoming Google Calendar events in a date range.',
          'parameters': {
            'type': 'object',
            'properties': {
              'start': {
                'type': 'string',
                'description': 'ISO-8601 start time (default: now)',
              },
              'end': {
                'type': 'string',
                'description': 'ISO-8601 end time (default: 7 days from now)',
              },
              'maxResults': {
                'type': 'integer',
                'description': 'Max events to return (default 10)',
              },
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'create_event',
          'description': 'Create a new Google Calendar event.',
          'parameters': {
            'type': 'object',
            'required': ['title', 'start', 'end'],
            'properties': {
              'title': {
                'type': 'string',
                'description': 'Event title / summary',
              },
              'start': {
                'type': 'string',
                'description': 'ISO-8601 start time',
              },
              'end': {
                'type': 'string',
                'description': 'ISO-8601 end time',
              },
              'description': {
                'type': 'string',
                'description': 'Optional event description',
              },
              'attendees': {
                'type': 'array',
                'items': {'type': 'string'},
                'description': 'Attendee email addresses',
              },
              'timeZone': {
                'type': 'string',
                'description': 'IANA time zone (default UTC)',
              },
              'location': {
                'type': 'string',
                'description': 'Event location',
              },
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'delete_event',
          'description':
              'Delete a Google Calendar event by ID. Requires owner approval.',
          'parameters': {
            'type': 'object',
            'required': ['eventId'],
            'properties': {
              'eventId': {
                'type': 'string',
                'description': 'Calendar event ID from list_events',
              },
            },
          },
        },
      },
    ],
    'web_search': [
      {
        'type': 'function',
        'function': {
          'name': 'web_search',
          'description':
              'Search the web using a privacy-respecting engine (SearXNG or Brave). '
                  'Prefer this over fetch_webpage when you need to find current '
                  'information by query rather than fetching a known URL.',
          'parameters': {
            'type': 'object',
            'required': ['q'],
            'properties': {
              'q': {'type': 'string', 'description': 'Search query'},
              'numResults': {
                'type': 'integer',
                'description': 'Max results to return (default 10)',
              },
            },
          },
        },
      },
    ],
  };

  /// Maps LLM tool function names → the skillId that handles them.
  static const _toolToSkillId = <String, String>{
    'send_email': 'email',
    'list_inbox': 'email',
    'read_email': 'email',
    'delete_email': 'email',
    'list_events': 'calendar',
    'create_event': 'calendar',
    'delete_event': 'calendar',
    'web_search': 'web_search',
  };

  // Mutable context captured at the start of each processRequest invocation.
  // Used by _executeTool to route skill tool calls without changing its signature.
  String _toolFromAtSign = '';
  String _toolConvId = '';

  Orchestrator({
    required this.atClient,
    required this.llmRouter,
    required this.policyEngine,
    required this.memoryService,
    required this.auditService,
    required this.hitlManager,
    this.skillRunner,
    this.mcpClient,
    this.taskScheduler,
    this.notificationManager,
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
    bool streamingEnabled = true,
  }) async {
    _log.info('Processing request convId=$conversationId '
        'from=$fromAtSign platform=$platform');

    final startTime = DateTime.now();
    _toolFromAtSign = fromAtSign;
    _toolConvId = conversationId;

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
    _log.info('Intent classified as: ${intentType.name}');

    // ── 3. Privacy score ──────────────────────────────────────────────────
    final privacyScore = await llmRouter.scorePrivacy(command);
    _log.info('Privacy score: $privacyScore | intent: ${intentType.name}');

    // Build the active tool list: built-in tools + tools for installed, enabled skills.
    final activeTools = await _buildTools();

    // ── 4. Execute by intent ──────────────────────────────────────────────
    String responseText;
    // Audit capture vars — filled in per-branch below.
    String _auditTarget = intentType.name;
    String? _auditSkillId;
    String? _auditMcpServer;

    // Per-request streaming chunk counter shared across all branches.
    var _chunkIndex = 0;

    // ── Token batching ────────────────────────────────────────────────────
    // Each sendStreamChunk() is an at-platform notification (encrypted,
    // atServer round-trip). Sending one per token is very slow.
    // Buffer tokens and flush every ~80 chars OR every 400 ms instead.
    //
    // _pendingChunks tracks in-flight sendStreamChunk futures so we can
    // await them all BEFORE the RPC reply goes out. Without this the RPC
    // reply races the notifications, arrives first, sets _isLoading=false
    // in the app, and the !_isLoading guard discards every chunk.
    const _flushChars = 80;
    final _tokenBuf = <String>[];
    final _pendingChunks = <Future<void>>[];

    Future<void> _flushTokenBuf() {
      if (_tokenBuf.isEmpty) return Future.value();
      final text = _tokenBuf.join();
      _tokenBuf.clear();
      final f = sendStreamChunk(
        ownerAtSign: fromAtSign,
        reqId: reqId,
        chunkIndex: _chunkIndex++,
        chunk: text,
        conversationId: conversationId,
      );
      _pendingChunks.add(f);
      return f;
    }

    // Called fire-and-forget from inside _callOllamaStreaming.
    // Runs synchronously up to the first await, so _tokenBuf mutations
    // and size checks happen before any suspension.
    Future<void> _batchChunk(String chunk) async {
      _tokenBuf.add(chunk);
      final bufLen = _tokenBuf.fold<int>(0, (s, t) => s + t.length);
      if (bufLen >= _flushChars) {
        await _flushTokenBuf();
      }
    }

    switch (intentType) {
      case IntentType.chat:
      case IntentType.task:
      case IntentType.unknown:
        // Route to LLM — pass web tools + active skill tools so tool-capable
        // models (qwen2.5, llama3.1) can invoke skills and fetch live content.
        responseText = await llmRouter.generateResponse(
          query: command,
          conversationHistory: conversation.messages,
          privacyScore: privacyScore,
          tools: activeTools,
          toolExecutor: _executeTool,
          onChunk: streamingEnabled ? _batchChunk : null,
        );
        if (streamingEnabled)
          await _flushTokenBuf(); // drain any buffered remainder

      case IntentType.skillInvocation:
        if (skillRunner == null) {
          responseText =
              'Skill invocation is not available (SkillRunner not wired).';
        } else {
          // Extract skill id from command payload (expected field: "skillId")
          final skillId = _extractField(command, 'skillId') ?? 'unknown';
          _auditSkillId = skillId;
          _auditTarget = 'skill:$skillId';
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
          _auditMcpServer = mcpAtSign;
          _auditTarget = 'mcp:$toolName';
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
        // Route through LLM with full tool set so the model can call
        // schedule_task, notify_owner, or skill tools as appropriate.
        responseText = await llmRouter.generateResponse(
          query: command,
          conversationHistory: conversation.messages,
          privacyScore: privacyScore,
          tools: activeTools,
          toolExecutor: _executeTool,
          onChunk: streamingEnabled ? _batchChunk : null,
        );
        if (streamingEnabled) await _flushTokenBuf();

      case IntentType.multiStepPlan:
        // Decompose and execute each step via LLM
        responseText = await llmRouter.generateResponse(
          query: command,
          conversationHistory: conversation.messages,
          privacyScore: privacyScore,
          systemOverride: 'Break this request into steps and execute each one. '
              'Show your reasoning.',
          onChunk: streamingEnabled ? _batchChunk : null,
        );
        if (streamingEnabled) await _flushTokenBuf();
    }

    // Drain any remainder and wait for ALL in-flight sendStreamChunk
    // notifications to complete before sending the RPC reply.
    // Without this the RPC reply races the notifications, arrives first,
    // sets _isLoading=false in the app, and the guard discards every chunk.
    if (streamingEnabled) {
      await _flushTokenBuf();
      if (_pendingChunks.isNotEmpty) await Future.wait(_pendingChunks);
    }

    final elapsed = DateTime.now().difference(startTime).inMilliseconds;

    // ── 5. Stream response to owner in real-time ──────────────────────────
    // NOTE: Streaming IS now active — tokens are sent live via sendStreamChunk
    // inside the onChunk callbacks above.  The full responseText is still
    // returned so the RPC reply and memory save paths work unchanged.

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
      final preview =
          command.length > 150 ? '${command.substring(0, 150)}\u2026' : command;
      await auditService.log(AuditEntry(
        actionType: intentType.name,
        initiatorAtSign: fromAtSign,
        targetResource: _auditTarget,
        policyDecision: 'allowed',
        inputHash: 'sha256:${AuditService.contentHash(command)}',
        outputHash: 'sha256:${AuditService.contentHash(responseText)}',
        executionDurationMs: elapsed,
        skillId: _auditSkillId,
        mcpServer: _auditMcpServer,
        notes: preview,
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
  /// The Flutter app subscribes to 'pembrook\\.stream\\..*' to receive them.
  ///
  /// Chunk key pattern: @owner:pembrook.stream.$reqId.$chunkIndex.pembrook@agent
  Future<void> sendStreamChunk({
    required String ownerAtSign,
    required int reqId,
    required int chunkIndex,
    required String chunk,
    required String conversationId,
    bool done = false,
  }) async {
    final key = AtKey()
      ..key = 'pembrook.stream.$reqId.$chunkIndex'
      ..namespace = 'pembrook'
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
  /// Returns the merged tool list for the LLM: built-in tools plus any tools
  /// for skills that are currently installed and enabled.
  Future<List<Map<String, dynamic>>> _buildTools() async {
    final tools = List<Map<String, dynamic>>.from(_kTools);
    if (skillRunner == null) return tools;
    try {
      final skills = await skillRunner!.registry.listInstalledSkills();
      for (final skill in skills) {
        final isEnabled = skill.ownerPolicyOverrides['enabled'] != false;
        if (!isEnabled) continue;
        final skillTools = _kSkillToolDefs[skill.skillId];
        if (skillTools != null) tools.addAll(skillTools);
      }
    } catch (e) {
      _log.warning('_buildTools: failed to load skill tools: $e');
    }
    return tools;
  }

  Future<String> _executeTool(
      String toolName, Map<String, dynamic> args) async {
    _log.info('[TOOL] Executing tool="$toolName" args=$args');
    switch (toolName) {
      case 'fetch_webpage':
        final url = args['url'] as String? ?? '';
        return _fetchWebpage(url);
      case 'schedule_task':
        return _toolScheduleTask(args);
      case 'cancel_task':
        return _toolCancelTask(args);
      case 'list_tasks':
        return _toolListTasks();
      case 'notify_owner':
        return _toolNotifyOwner(args);
      default:
        // Check if this is a skill tool call.
        final skillId = _toolToSkillId[toolName];
        if (skillId != null && skillRunner != null) {
          _log.info('[TOOL] Routing $toolName → skill:$skillId');
          final result = await skillRunner!.invoke(
            skillId: skillId,
            initiatorAtSign: _toolFromAtSign,
            payload: {...args, 'action': toolName},
            conversationId: _toolConvId,
          );
          if (result.success && result.result != null) {
            return jsonEncode(result.result);
          }
          return 'Skill "$skillId" failed: '
              '${result.error ?? result.denialReason ?? "unknown error"}';
        }
        _log.warning('[TOOL] Unknown tool requested: $toolName');
        return 'Unknown tool: $toolName';
    }
  }

  /// Create a scheduled / recurring task via the TaskScheduler.
  Future<String> _toolScheduleTask(Map<String, dynamic> args) async {
    if (taskScheduler == null) {
      return 'Scheduling is not available — TaskScheduler not wired.';
    }
    final description = args['description'] as String? ?? 'Scheduled task';
    final command = args['command'] as String? ?? description;
    final cron = args['cronExpression'] as String?;
    final runAtStr = args['runAt'] as String?;
    final skillId = args['skillToInvoke'] as String?;

    if (cron == null && runAtStr == null) {
      return 'Error: provide either cronExpression (recurring) or runAt (one-shot).';
    }

    DateTime? runAt;
    if (runAtStr != null) {
      runAt = DateTime.tryParse(runAtStr);
      if (runAt == null) {
        return 'Error: invalid runAt format — use ISO-8601 (e.g. 2026-03-14T09:00:00Z).';
      }
    }

    final task = TaskDefinition(
      taskId: 'task_${DateTime.now().millisecondsSinceEpoch}',
      cronExpression: cron,
      runAt: runAt,
      skillToInvoke: skillId,
      parameters: {'command': command, 'description': description},
      hitlRequired: false,
      ownerAtSign: Platform.environment['OWNER_AT_SIGN'] ?? '@owner',
      createdAt: DateTime.now().toUtc(),
    );

    await taskScheduler!.scheduleTask(task);

    final scheduleDesc =
        cron != null ? 'every $cron (cron)' : 'once at $runAtStr';
    _log.info(
        '[schedule_task] Created task ${task.taskId}: $description ($scheduleDesc)');
    return 'Task scheduled — I will run "$description" $scheduleDesc and '
        'push the results to you automatically. '
        'Task ID: ${task.taskId}';
  }

  /// List all currently scheduled tasks.
  Future<String> _toolListTasks() async {
    if (taskScheduler == null) {
      return 'Scheduling is not available — TaskScheduler not wired.';
    }
    final tasks = await taskScheduler!.listTasks();
    if (tasks.isEmpty) {
      return 'No tasks are currently scheduled.';
    }
    final lines = <String>['Currently scheduled tasks (${tasks.length}):'];
    for (final t in tasks) {
      final schedule = t.cronExpression != null
          ? 'cron: ${t.cronExpression}'
          : t.runAt != null
              ? 'runs at: ${t.runAt!.toIso8601String()}'
              : 'unknown schedule';
      final description = t.parameters['description'] as String? ?? t.taskId;
      lines.add('- ${t.taskId}: "$description" ($schedule)');
    }
    return lines.join('\n');
  }

  /// Cancel a scheduled task by ID.
  Future<String> _toolCancelTask(Map<String, dynamic> args) async {
    if (taskScheduler == null) {
      return 'Scheduling is not available — TaskScheduler not wired.';
    }
    final taskId = args['taskId'] as String? ?? '';
    if (taskId.isEmpty) return 'Error: taskId is required.';
    await taskScheduler!.cancelTask(taskId);
    _log.info('[cancel_task] Cancelled task $taskId');
    return 'Task "$taskId" has been cancelled and will no longer run.';
  }

  /// Send an immediate push notification to the owner.
  Future<String> _toolNotifyOwner(Map<String, dynamic> args) async {
    if (notificationManager == null) {
      return 'Push notifications not available — NotificationManager not wired.';
    }
    final message = args['message'] as String? ?? '';
    if (message.isEmpty) return 'Error: message is required.';

    final urgencyStr = args['urgency'] as String? ?? 'medium';
    final urgency = NotificationUrgency.values.firstWhere(
      (u) => u.name == urgencyStr,
      orElse: () => NotificationUrgency.medium,
    );

    await notificationManager!.sendAlert(Alert(
      alertId: 'push_${DateTime.now().millisecondsSinceEpoch}',
      title: 'Agent',
      message: message,
      urgency: urgency,
      forceImmediate: true,
    ));

    return 'Message pushed to owner.';
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

    // Rewrite Google / Bing search URLs → DuckDuckGo HTML (scraper-friendly).
    if ((uri.host.contains('google.com') || uri.host.contains('bing.com')) &&
        (uri.path == '/search' || uri.queryParameters.containsKey('q'))) {
      final q = uri.queryParameters['q'] ?? '';
      if (q.isNotEmpty) {
        uri = Uri.parse(
            'https://html.duckduckgo.com/html/?q=${Uri.encodeQueryComponent(q)}');
        _log.info('[fetch_webpage] Rewrote search URL → $uri');
      }
    }

    try {
      _log.info('[fetch_webpage] GET $uri');
      final resp = await http.get(uri, headers: {
        // Use a real browser UA so sites don't serve bot-blocking pages.
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
            'AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/124.0.0.0 Safari/537.36',
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
      }).timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) {
        _log.warning('[fetch_webpage] HTTP ${resp.statusCode} from $uri');
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
      _log.info(
          '[fetch_webpage] OK — ${text.length} chars extracted from $uri');
      return text.isEmpty ? '(page had no readable text)' : text;
    } on TimeoutException {
      _log.warning('[fetch_webpage] Timed out fetching $uri');
      return 'Error: timed out fetching $uri';
    } catch (e) {
      _log.warning('[fetch_webpage] Error: $e');
      return 'Error fetching $uri: $e';
    }
  }
}
