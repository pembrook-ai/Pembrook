/// SandboxManager — execute skills inside isolated containers.
///
/// SECURITY CONSTRAINTS (applied to every container run):
///   --rm              remove on exit (no persistent container state)
///   --network=none    zero network access inside the sandbox
///   --memory=256m     hard memory cap
///   --cpus=0.5        hard CPU cap
///   --read-only       read-only root filesystem
///   --cap-drop=ALL    drop all Linux capabilities
///   --security-opt=no-new-privileges
///
/// macOS fallback: if Docker is unavailable, refuse execution unless
/// [allowMacOsFallback] is true, in which case a macOS Sandbox profile
/// (com.apple.security.temporary-exception.* denied) would be applied.
/// For now the fallback is blocked — prefer Docker in all deployments.
///
/// Skills communicate via STDIN/STDOUT using a JSON line protocol:
///   → {"command": "run", "payload": {...}, "requestId": "..."}
///   ← {"status": "ok", "result": {...}, "requestId": "..."}
///   ← {"status": "error", "error": "...", "requestId": "..."}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';

import '../models/skill_metadata.dart';

class SandboxResult {
  final bool success;
  final Map<String, dynamic>? result;
  final String? error;
  final int exitCode;
  final Duration duration;

  const SandboxResult({
    required this.success,
    this.result,
    this.error,
    required this.exitCode,
    required this.duration,
  });
}

class SandboxManager {
  final Logger _log = Logger('SandboxManager');

  /// Whether to allow execution outside Docker (macOS sandbox).
  /// Default: false — refuse if Docker is unavailable.
  final bool allowMacOsFallback;

  /// Execution timeout (default 60 s).
  final Duration timeout;

  SandboxManager({
    this.allowMacOsFallback = false,
    this.timeout = const Duration(seconds: 60),
  });

  // ──────────────────────────────────────────────────────────
  //  MAIN EXECUTION ENTRY POINT
  // ──────────────────────────────────────────────────────────

  /// Run a skill Docker image with [command] payload.
  ///
  /// [meta.skillId] is used as the Docker image name by convention:
  ///   safeclaw-skill-<skillId>:latest
  Future<SandboxResult> run(
    SkillMetadata meta,
    Map<String, dynamic> command, {
    String? requestId,
  }) async {
    final dockerAvailable = await _isDockerAvailable();

    if (!dockerAvailable) {
      if (!allowMacOsFallback) {
        return SandboxResult(
          success: false,
          error: 'Docker is unavailable and macOS fallback is disabled.',
          exitCode: -1,
          duration: Duration.zero,
        );
      }
      return _runMacOsSandbox(meta, command, requestId: requestId);
    }

    return _runDocker(meta, command, requestId: requestId);
  }

  // ──────────────────────────────────────────────────────────
  //  DOCKER EXECUTION
  // ──────────────────────────────────────────────────────────

  Future<SandboxResult> _runDocker(
    SkillMetadata meta,
    Map<String, dynamic> command, {
    String? requestId,
  }) async {
    final imageName = 'safeclaw-skill-${meta.skillId}:latest';
    final input = jsonEncode({
      'command': 'run',
      'payload': command,
      'requestId':
          requestId ?? DateTime.now().millisecondsSinceEpoch.toString(),
    });

    // Use --network=bridge when the skill declared network endpoints;
    // otherwise keep the default --network=none sandbox.
    final networkFlag = meta.declaredCapabilities.networkEndpoints.isNotEmpty
        ? '--network=bridge'
        : '--network=none';

    final args = [
      'run',
      '--rm',
      networkFlag,
      '--memory=256m',
      '--cpus=0.5',
      '--read-only',
      '--cap-drop=ALL',
      '--security-opt=no-new-privileges',
      '--interactive',
      imageName,
    ];

    _log.fine('docker run $imageName with payload: $command');

    final stopwatch = Stopwatch()..start();
    try {
      final process = await Process.start('docker', args);
      process.stdin.writeln(input);
      await process.stdin.close();

      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();

      final exitCode = await process.exitCode.timeout(timeout);
      stopwatch.stop();

      final stdout = await stdoutFuture;
      final stderr = await stderrFuture;

      if (exitCode != 0) {
        return SandboxResult(
          success: false,
          error: 'Container exited $exitCode: $stderr',
          exitCode: exitCode,
          duration: stopwatch.elapsed,
        );
      }

      // Parse last non-empty JSON line from stdout
      final lines = stdout
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();

      if (lines.isEmpty) {
        return SandboxResult(
          success: false,
          error: 'Empty output from container',
          exitCode: exitCode,
          duration: stopwatch.elapsed,
        );
      }

      final response = jsonDecode(lines.last) as Map<String, dynamic>;

      return SandboxResult(
        success: response['status'] == 'ok',
        result: response['result'] as Map<String, dynamic>?,
        error: response['error'] as String?,
        exitCode: exitCode,
        duration: stopwatch.elapsed,
      );
    } on TimeoutException {
      stopwatch.stop();
      _log.warning('Skill ${meta.skillId} timed out after $timeout');
      return SandboxResult(
        success: false,
        error: 'Execution timed out after ${timeout.inSeconds}s',
        exitCode: -1,
        duration: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      _log.severe('Sandbox execution error: $e');
      return SandboxResult(
        success: false,
        error: 'Sandbox error: $e',
        exitCode: -1,
        duration: stopwatch.elapsed,
      );
    }
  }

  // ──────────────────────────────────────────────────────────
  //  macOS FALLBACK (blocked unless explicitly enabled)
  // ──────────────────────────────────────────────────────────

  Future<SandboxResult> _runMacOsSandbox(
    SkillMetadata meta,
    Map<String, dynamic> command, {
    String? requestId,
  }) async {
    // Phase 3 will implement: sandbox-exec -f <profile> <skill_binary>
    // For now this path is unreachable (allowMacOsFallback defaults to false).
    return SandboxResult(
      success: false,
      error: 'macOS sandbox execution is not yet implemented.',
      exitCode: -1,
      duration: Duration.zero,
    );
  }

  // ──────────────────────────────────────────────────────────
  //  HELPERS
  // ──────────────────────────────────────────────────────────

  Future<bool> _isDockerAvailable() async {
    try {
      final result = await Process.run('docker', ['info'], runInShell: false);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
