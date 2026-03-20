/// Pembrook Agent — Entry point
///
/// Usage:
///   dart run bin/main.dart -a @agent --key-file /path/to/@agent_key.atKeys
///
/// For multi-instance horizontal scaling, use unique temp dirs per instance:
///   PEMBROOK_INSTANCE_ID=1 dart run bin/main.dart ...
///
/// atSign: @agent (placeholder — replace with your provisioned atSign)
/// Namespace: pembrook

import 'dart:async';
import 'dart:io';

import 'package:at_cli_commons/at_cli_commons.dart';
import 'package:logging/logging.dart';

import 'package:pembrook_agent/core/orchestrator.dart';
import 'package:pembrook_agent/core/policy_engine.dart';
import 'package:pembrook_agent/core/hitl_manager.dart';
import 'package:pembrook_agent/gateway/gateway.dart';
import 'package:pembrook_agent/services/llm_router.dart';
import 'package:pembrook_agent/services/sanitizer.dart';
import 'package:pembrook_agent/services/memory_service.dart';
import 'package:pembrook_agent/services/audit_service.dart';
import 'package:pembrook_agent/services/at_platform_service.dart';
import 'package:pembrook_agent/skills/registry.dart';
import 'package:pembrook_agent/skills/sandbox_manager.dart';
import 'package:pembrook_agent/skills/skill_runner.dart';
import 'package:pembrook_agent/mcp/secure_mcp_client.dart';
import 'package:pembrook_agent/automation/scheduler.dart';
import 'package:pembrook_agent/automation/notification_manager.dart';
import 'package:pembrook_agent/automation/heartbeat.dart';

const String kNamespace = 'pembrook';

void main(List<String> args) async {
  // Configure structured logging
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    var msg = '[${record.level.name}] ${record.loggerName}: ${record.message}';
    if (record.error != null) msg += '\n  Error: ${record.error}';
    if (record.stackTrace != null) msg += '\n  Stack: ${record.stackTrace}';
    stderr.writeln(msg);
  });

  final log = Logger('PembrookAgent');

  // ── Authentication ────────────────────────────────────────────────────────
  // at_cli_commons CLIBase handles:
  //   -a / --atsign         atSign to authenticate as
  //   -k / --key-file       path to .atKeys file
  //   --root-domain         root server (default: root.atsign.org)
  //   --namespace           namespace (default: pembrook)
  //
  // IMPORTANT: Each agent instance MUST use a unique hiveStoragePath and
  // commitLogPath. We derive them from a temp directory created per-process.
  // Using shared hive paths across processes causes BHive collision errors.
  final storageDir = Directory.systemTemp.createTempSync('pembrook_agent_');

  log.info('Starting Pembrook agent — storage: ${storageDir.path}');

  late CLIBase cliBase;
  try {
    // Inject storage dir and namespace into CLI args so CLIBase uses them.
    // This ensures each process gets a unique Hive storage path.
    final augmentedArgs = [
      ...args,
      if (!args.contains('--storage-dir') && !args.contains('-s')) ...[
        '--storage-dir',
        storageDir.path
      ],
      if (!args.contains('--namespace') && !args.contains('-n')) ...[
        '--namespace',
        kNamespace
      ],
      // Skip initial atServer sync — agent reads AtKeys directly via
      // useRemoteAtServer=true, so local Hive sync is not needed and would
      // block startup for minutes on heavily-used atSigns.
      if (!args.contains('--never-sync')) '--never-sync',
    ];
    cliBase = await CLIBase.fromCommandLineArgs(
      augmentedArgs,
      namespace: kNamespace,
    );
  } catch (e) {
    log.severe('Authentication failed: $e');
    stderr.writeln('''
Pembrook Agent — Authentication failed.

Usage: dart run bin/main.dart \\
  --atsign @agent \\
  --key-file /path/to/@agent_key.atKeys

Ensure you have:
  1. Provisioned @agent at my.atsign.com
  2. Downloaded the .atKeys file
  3. Run "dart pub get" in the agent/ directory
''');
    exit(1);
  }

  final atClient = cliBase.atClient;
  // CLIBase internally sets Logger.root.level = Level.SHOUT to suppress its
  // own verbose output — restore our desired level after it returns.
  Logger.root.level = Level.INFO;
  log.info('Authenticated as ${atClient.getCurrentAtSign()}');

  // ── Service Wiring ────────────────────────────────────────────────────────
  // All services are stateless classes that read/write AtKeys.
  // They do NOT use local files — all state flows through the atServer.

  // Read Ollama URL from env — allows docker-compose to inject
  // http://host.docker.internal:11434 (or http://ollama:11434 for bundled mode).
  final ollamaBaseUrl =
      Platform.environment['OLLAMA_BASE_URL'] ?? 'http://localhost:11434';
  log.info('Ollama base URL: $ollamaBaseUrl');

  // Read Ollama model from env — allows docker-compose to inject via .env.
  final ollamaModel = Platform.environment['OLLAMA_MODEL'] ?? 'qwen2.5:7b';
  log.info('Ollama model: $ollamaModel');

  final auditService = AuditService(atClient: atClient);
  final sanitizer = QuerySanitizer(ollamaBaseUrl: ollamaBaseUrl);
  final llmRouter = LlmRouter(
    atClient: atClient,
    sanitizer: sanitizer,
    ollamaBaseUrl: ollamaBaseUrl,
    model: ollamaModel,
  );
  // Pass llmRouter to MemoryService so summarizeOldConversations() works.
  final memoryService = MemoryService(atClient: atClient, llmRouter: llmRouter);
  final policyEngine = PolicyEngine(atClient: atClient);
  final hitlManager = HitlManager(atClient: atClient);

  // ── Skills ────────────────────────────────────────────────────────────────
  final skillRegistry = SkillRegistry(atClient: atClient);
  await skillRegistry
      .loadCache(); // restore persisted skills from remote atServer
  final sandboxManager = SandboxManager();
  final skillRunner = SkillRunner(
    registry: skillRegistry,
    sandboxManager: sandboxManager,
    policyEngine: policyEngine,
    hitlManager: hitlManager,
    auditService: auditService,
  );

  // ── MCP ───────────────────────────────────────────────────────────────────
  final mcpClient = SecureMcpClient(
    atClient: atClient,
    policyEngine: policyEngine,
    hitlManager: hitlManager,
    auditService: auditService,
  );

  // MCP server atSigns — populated from SERVICES_AT_SIGN env var.
  // These are queried for available tools on first chat request.
  final servicesAtSign = Platform.environment['SERVICES_AT_SIGN'] ?? '';
  final mcpServerAtSigns =
      servicesAtSign.isNotEmpty ? [servicesAtSign] : <String>[];
  if (mcpServerAtSigns.isNotEmpty) {
    log.info('MCP server atSigns: $mcpServerAtSigns');
  }

  // ── Automation ────────────────────────────────────────────────────────────
  final notificationManager = NotificationManager(atClient: atClient);
  // Note: AtPlatformService provides CRUD helpers used by individual services.
  // Kept here for future direct use (Phase 3+).
  // ignore: unused_local_variable
  final atPlatformService =
      AtPlatformService(atClient: atClient, namespace: kNamespace);

  // Construct scheduler first so orchestrator can receive it.
  final scheduler = TaskScheduler(
    atClient: atClient,
    policyEngine: policyEngine,
    hitlManager: hitlManager,
    auditService: auditService,
    skillRunner: skillRunner,
    notificationManager: notificationManager,
    llmRouter: llmRouter,
  );

  final orchestrator = Orchestrator(
    atClient: atClient,
    llmRouter: llmRouter,
    policyEngine: policyEngine,
    memoryService: memoryService,
    auditService: auditService,
    hitlManager: hitlManager,
    skillRunner: skillRunner,
    mcpClient: mcpClient,
    taskScheduler: scheduler,
    notificationManager: notificationManager,
    mcpServerAtSigns: mcpServerAtSigns,
  );

  final heartbeat = HeartbeatEngine(
    atClient: atClient,
    scheduler: scheduler,
    notificationManager: notificationManager,
    memoryService: memoryService,
  );

  // ── Gateway (AtRpc server, zero inbound ports) ────────────────────────────
  final gateway = Gateway(
    atClient: atClient,
    orchestrator: orchestrator,
    policyEngine: policyEngine,
    auditService: auditService,
    skillRegistry: skillRegistry,
  );

  // Register signal handlers for graceful shutdown
  ProcessSignal.sigint.watch().listen((_) async {
    log.info('Received SIGINT — shutting down');
    await heartbeat.stop();
    await gateway.stop();
    await notificationManager.flushDailyDigest();
    await storageDir.delete(recursive: true);
    exit(0);
  });
  ProcessSignal.sigterm.watch().listen((_) async {
    log.info('Received SIGTERM — shutting down');
    await heartbeat.stop();
    await gateway.stop();
    await notificationManager.flushDailyDigest();
    await storageDir.delete(recursive: true);
    exit(0);
  });

  await gateway.start();
  heartbeat.start();

  // Pre-load MCP tools so they're available before the first user request.
  // Without this, the first request runs before browser.* tools are known
  // and fetch_webpage stays in the tool list.
  unawaited(orchestrator.preloadMcpTools());

  // Clean up audit entries older than 7 days on startup (fire-and-forget).
  unawaited(auditService.cleanupOldLogs());

  log.info('Pembrook agent is running. Listening for commands via atPlatform.');
  final ownerForLog = Platform.environment['OWNER_AT_SIGN'] ??
      Platform.environment['ALLOWED_USERS'] ??
      '(see ALLOWED_USERS env var)';
  log.info(
      'Agent: ${atClient.getCurrentAtSign()} — allowed senders: $ownerForLog');

  // Keep process alive — gateway handles all work via notification subscriptions
  await Future.delayed(Duration(days: 365 * 10));
}
