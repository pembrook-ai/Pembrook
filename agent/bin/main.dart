/// SafeClaw Agent — Entry point
///
/// Usage:
///   dart run bin/main.dart -a @agent --key-file /path/to/@agent_key.atKeys
///
/// For multi-instance horizontal scaling, use unique temp dirs per instance:
///   SAFECLAW_INSTANCE_ID=1 dart run bin/main.dart ...
///
/// atSign: @agent (placeholder — replace with your provisioned atSign)
/// Namespace: safeclaw

import 'dart:io';

import 'package:at_cli_commons/at_cli_commons.dart';
import 'package:at_client/at_client.dart';
import 'package:logging/logging.dart';

import 'package:safeclaw_agent/core/orchestrator.dart';
import 'package:safeclaw_agent/core/policy_engine.dart';
import 'package:safeclaw_agent/core/hitl_manager.dart';
import 'package:safeclaw_agent/gateway/gateway.dart';
import 'package:safeclaw_agent/services/llm_router.dart';
import 'package:safeclaw_agent/services/sanitizer.dart';
import 'package:safeclaw_agent/services/memory_service.dart';
import 'package:safeclaw_agent/services/audit_service.dart';
import 'package:safeclaw_agent/services/at_platform_service.dart';
import 'package:safeclaw_agent/skills/registry.dart';
import 'package:safeclaw_agent/skills/sandbox_manager.dart';
import 'package:safeclaw_agent/skills/skill_runner.dart';
import 'package:safeclaw_agent/mcp/secure_mcp_client.dart';
import 'package:safeclaw_agent/automation/scheduler.dart';
import 'package:safeclaw_agent/automation/notification_manager.dart';
import 'package:safeclaw_agent/automation/heartbeat.dart';

const String kNamespace = 'safeclaw';

void main(List<String> args) async {
  // Configure structured logging
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    stderr.writeln(
        '[${record.level.name}] ${record.loggerName}: ${record.message}');
    if (record.error != null) stderr.writeln('  Error: ${record.error}');
    if (record.stackTrace != null)
      stderr.writeln('  Stack: ${record.stackTrace}');
  });

  final log = Logger('SafeClawAgent');

  // ── Authentication ────────────────────────────────────────────────────────
  // at_cli_commons CLIBase handles:
  //   -a / --atsign         atSign to authenticate as
  //   -k / --key-file       path to .atKeys file
  //   --root-domain         root server (default: root.atsign.org)
  //   --namespace           namespace (default: safeclaw)
  //
  // IMPORTANT: Each agent instance MUST use a unique hiveStoragePath and
  // commitLogPath. We derive them from a temp directory created per-process.
  // Using shared hive paths across processes causes BHive collision errors.
  final storageDir = Directory.systemTemp.createTempSync('safeclaw_agent_');

  log.info('Starting SafeClaw agent — storage: ${storageDir.path}');

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
    ];
    cliBase = await CLIBase.fromCommandLineArgs(
      augmentedArgs,
      namespace: kNamespace,
    );
  } catch (e) {
    log.severe('Authentication failed: $e');
    stderr.writeln('''
SafeClaw Agent — Authentication failed.

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
  log.info('Authenticated as ${atClient.getCurrentAtSign()}');

  // ── Service Wiring ────────────────────────────────────────────────────────
  // All services are stateless classes that read/write AtKeys.
  // They do NOT use local files — all state flows through the atServer.

  final auditService = AuditService(atClient: atClient);
  final sanitizer = QuerySanitizer(ollamaBaseUrl: 'http://localhost:11434');
  final llmRouter = LlmRouter(
    atClient: atClient,
    sanitizer: sanitizer,
    ollamaBaseUrl: 'http://localhost:11434',
  );
  // Pass llmRouter to MemoryService so summarizeOldConversations() works.
  final memoryService = MemoryService(atClient: atClient, llmRouter: llmRouter);
  final policyEngine = PolicyEngine(atClient: atClient);
  final hitlManager = HitlManager(atClient: atClient);

  // ── Skills ────────────────────────────────────────────────────────────────
  final skillRegistry = SkillRegistry(atClient: atClient);
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

  // ── Automation ────────────────────────────────────────────────────────────
  final notificationManager = NotificationManager(atClient: atClient);
  // Note: AtPlatformService provides CRUD helpers used by individual services.
  // Kept here for future direct use (Phase 3+).
  // ignore: unused_local_variable
  final atPlatformService =
      AtPlatformService(atClient: atClient, namespace: kNamespace);

  final orchestrator = Orchestrator(
    atClient: atClient,
    llmRouter: llmRouter,
    policyEngine: policyEngine,
    memoryService: memoryService,
    auditService: auditService,
    hitlManager: hitlManager,
    skillRunner: skillRunner,
    mcpClient: mcpClient,
  );

  final scheduler = TaskScheduler(
    atClient: atClient,
    policyEngine: policyEngine,
    hitlManager: hitlManager,
    auditService: auditService,
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

  log.info('SafeClaw agent is running. Listening for commands via atPlatform.');
  log.info('Owner atSign: @owner (replace with your actual owner atSign)');

  // Keep process alive — gateway handles all work via notification subscriptions
  await Future.delayed(Duration(days: 365 * 10));
}
