/// init_config.dart — First-run configuration writer for the SafeClaw agent.
///
/// Run from the `agent/` directory:
///   dart run bin/init_config.dart \
///     --atsign @myagent \
///     --key-file /path/to/@myagent_key.atKeys \
///     --owner @myowner \
///     [--allowed-users @myowner,@mybridges] \
///     [--bridges-atsign @mybridges] \
///     [--ollama-model llama3.2] \
///     [--local-only false]
///
/// Writes the following AtKeys to @myagent's atServer (namespace: safeclaw):
///   settings.owner_atsign     → the owner atSign string
///   settings.allowed_users    → JSON array of permitted sender atSigns
///   settings.llm_config       → JSON object with LLM defaults
///
/// These are self-atKeys (sharedBy = @myagent, sharedWith = @myagent),
/// readable only by the agent process itself.
///
/// Safe to re-run: existing values are overwritten with the new arguments.

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:at_client/at_client.dart';
import 'package:at_cli_commons/at_cli_commons.dart';
import 'package:logging/logging.dart';

const String kNamespace = 'safeclaw';

void main(List<String> args) async {
  // ── Logging ──────────────────────────────────────────────────────────────
  hierarchicalLoggingEnabled = true;
  Logger.root.level = Level.WARNING;
  Logger.root.onRecord.listen((r) {
    stderr.writeln('[${r.level.name}] ${r.loggerName}: ${r.message}');
  });

  // ── Argument parsing ─────────────────────────────────────────────────────
  final parser = ArgParser()
    ..addOption('atsign',
        abbr: 'a', mandatory: true, help: 'Agent atSign (e.g. @myagent)')
    ..addOption('key-file',
        abbr: 'k', mandatory: true, help: 'Path to agent .atKeys file')
    ..addOption('owner',
        abbr: 'o',
        mandatory: true,
        help: 'Owner atSign — the Flutter app / CLI atSign (e.g. @myowner)')
    ..addOption('allowed-users',
        help: 'Comma-separated atSigns permitted to send commands '
            '(default: just --owner). Example: @myowner,@mybridges')
    ..addOption('bridges-atsign',
        help: 'Additional bridge relay atSign to add to the allowList '
            '(shorthand for including in --allowed-users)')
    ..addOption('ollama-model',
        defaultsTo: 'llama3.2', help: 'Default Ollama model name')
    ..addOption('ollama-url',
        defaultsTo: 'http://localhost:11434', help: 'Ollama server base URL')
    ..addFlag('local-only',
        defaultsTo: false,
        help: 'If true, never call cloud LLM APIs; Ollama only')
    ..addFlag('verbose', abbr: 'v', defaultsTo: false, help: 'Verbose logging')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help');

  late final ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } catch (e) {
    stderr.writeln('Error: $e\n');
    stderr.writeln(parser.usage);
    exit(1);
  }

  if (parsed['help'] as bool) {
    stdout.writeln(
        'SafeClaw init_config — write first-run AtKeys to the agent atServer\n');
    stdout.writeln(parser.usage);
    exit(0);
  }

  if (parsed['verbose'] as bool) {
    Logger.root.level = Level.INFO;
  }

  final agentAtSign = (parsed['atsign'] as String).trim();
  final keyFile = (parsed['key-file'] as String).trim();
  final ownerAtSign = (parsed['owner'] as String).trim();
  final ollamaModel = parsed['ollama-model'] as String;
  final ollamaUrl = parsed['ollama-url'] as String;
  final localOnly = parsed['local-only'] as bool;

  // Build allowList: owner + optional bridges + optional extra users.
  final allowSet = <String>{ownerAtSign};

  final bridgesAtSign = parsed['bridges-atsign'] as String?;
  if (bridgesAtSign != null && bridgesAtSign.isNotEmpty) {
    allowSet.add(bridgesAtSign.trim());
  }

  final allowedUsersRaw = parsed['allowed-users'] as String?;
  if (allowedUsersRaw != null && allowedUsersRaw.isNotEmpty) {
    allowSet.addAll(
      allowedUsersRaw
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty),
    );
  }

  // ── Validate inputs ──────────────────────────────────────────────────────
  if (!agentAtSign.startsWith('@')) {
    stderr.writeln('Error: --atsign must start with @');
    exit(1);
  }
  if (!ownerAtSign.startsWith('@')) {
    stderr.writeln('Error: --owner must start with @');
    exit(1);
  }
  if (!File(keyFile).existsSync()) {
    stderr.writeln('Error: key file not found: $keyFile');
    exit(1);
  }

  stdout.writeln('');
  stdout.writeln('SafeClaw init_config');
  stdout.writeln('════════════════════');
  stdout.writeln('  Agent atSign  : $agentAtSign');
  stdout.writeln('  Owner atSign  : $ownerAtSign');
  stdout.writeln('  AllowList     : ${allowSet.toList()..sort()}');
  stdout.writeln('  Ollama model  : $ollamaModel');
  stdout.writeln('  Ollama URL    : $ollamaUrl');
  stdout.writeln('  Local only    : $localOnly');
  stdout.writeln('');
  stdout.writeln('Writing AtKeys to $agentAtSign\'s atServer...');
  stdout.writeln('');

  // ── Authenticate ─────────────────────────────────────────────────────────
  final storageDir = Directory.systemTemp.createTempSync('safeclaw_init_');
  try {
    // CLIBase needs --atsign, --key-file, --storage-dir, --namespace.
    final cliArgs = [
      '--atsign',
      agentAtSign,
      '--key-file',
      keyFile,
      '--storage-dir',
      storageDir.path,
      '--namespace',
      kNamespace,
    ];

    final cliBase =
        await CLIBase.fromCommandLineArgs(cliArgs, namespace: kNamespace);
    await cliBase.init();
    final atClient = cliBase.atClient;

    stdout.writeln('Authenticated as ${atClient.getCurrentAtSign()}');

    // ── Write AtKeys ─────────────────────────────────────────────────────

    // 1. Owner atSign
    await _putSelfKey(atClient, 'settings.owner_atsign', ownerAtSign);
    stdout.writeln('  ✓ settings.owner_atsign = $ownerAtSign');

    // 2. AllowList (JSON array)
    final allowJson = jsonEncode(allowSet.toList()..sort());
    await _putSelfKey(atClient, 'settings.allowed_users', allowJson);
    stdout.writeln('  ✓ settings.allowed_users = $allowJson');

    // 3. LLM config
    final llmConfig = jsonEncode({
      'model': ollamaModel,
      'ollamaUrl': ollamaUrl,
      'localOnly': localOnly,
      'maxTokens': 4096,
      'temperature': 0.7,
    });
    await _putSelfKey(atClient, 'settings.llm_config', llmConfig);
    stdout.writeln('  ✓ settings.llm_config = $llmConfig');

    stdout.writeln('');
    stdout.writeln('Done. All AtKeys written successfully.');
    stdout.writeln('');
    stdout.writeln('Next steps:');
    stdout.writeln('  • Start the agent:  docker compose up');
    stdout.writeln('  • Open the Flutter app and authenticate as $ownerAtSign');
    stdout.writeln('  • The app will connect to $agentAtSign automatically.');
    stdout.writeln('');
  } finally {
    await storageDir.delete(recursive: true);
  }
}

/// Write a self AtKey (sharedBy = agent, sharedWith = agent).
Future<void> _putSelfKey(
    AtClient atClient, String keyName, String value) async {
  final agentAtSign = atClient.getCurrentAtSign()!;
  final atKey = AtKey()
    ..key = keyName
    ..namespace = kNamespace
    ..sharedBy = agentAtSign
    ..metadata = (Metadata()..isPublic = false);
  await atClient.put(atKey, value);
}
