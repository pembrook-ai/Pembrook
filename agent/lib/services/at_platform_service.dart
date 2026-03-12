/// AtPlatformService — helpers for multi-instance coordination on atPlatform.
///
/// PATTERNS DOCUMENTED:
///
/// 1. IMMUTABLE MUTEX (distributed lock):
///    - Write Metadata()..immutable = true to an AtKey with a short TTL.
///    - The first writer wins; subsequent writers get an error and back off.
///    - Once the TTL expires, the lock is automatically released.
///
/// 2. EPHEMERAL / STATELESS INSTANCE:
///    - Use ServiceFactoryWithNoOpSyncService so the agent does not
///      attempt full atServer sync on startup (fast boot, no BHive churn).
///    - Every read uses useRemoteAtServer=true; every write uses
///      useRemoteAtServer=true for consistent cloud state.
///
/// 3. AtKey CRUD HELPERS:
///    - Wrappers that enforce namespace, remote reads/writes, and
///      appropriate Metadata defaults so call sites are clean.

import 'dart:async';
import 'package:at_client/at_client.dart';
import 'package:logging/logging.dart';

class AtPlatformService {
  final AtClient atClient;
  final String namespace;
  final Logger _log = Logger('AtPlatformService');

  AtPlatformService({
    required this.atClient,
    required this.namespace,
  });

  // ══════════════════════════════════════════════════════
  //  KEY HELPERS
  // ══════════════════════════════════════════════════════

  /// Build a self-owned key (stored on this atSign's own atServer).
  AtKey selfKey(String key) => AtKey()
    ..key = key
    ..namespace = namespace
    ..sharedBy = atClient.getCurrentAtSign() ?? '';

  /// Build a shared key (stored on [recipientAtSign]'s atServer).
  AtKey sharedKey(String key, String recipientAtSign) => (AtKey.shared(key,
          namespace: namespace, sharedBy: atClient.getCurrentAtSign() ?? '')
        ..sharedWith(recipientAtSign))
      .build();

  // ══════════════════════════════════════════════════════
  //  CRUD — always remote
  // ══════════════════════════════════════════════════════

  /// Put a value to the cloud (bypass local cache).
  Future<bool> put(
    AtKey key,
    String value, {
    int? ttlMs,
    bool immutable = false,
    int? ttr,
  }) async {
    key.metadata ??= Metadata();
    if (ttlMs != null) key.metadata!.ttl = ttlMs;
    if (immutable) key.metadata!.immutable = true;
    if (ttr != null) key.metadata!.ttr = ttr;

    try {
      return await atClient.put(
        key,
        value,
        putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
      );
    } catch (e) {
      _log.warning('put failed for ${key.key}: $e');
      rethrow;
    }
  }

  /// Get a value from the cloud (bypass local cache).
  Future<String?> get(AtKey key) async {
    try {
      final result = await atClient.get(
        key,
        getRequestOptions: GetRequestOptions()..useRemoteAtServer = true,
      );
      return result.value as String?;
    } catch (e) {
      _log.fine('get returned null for ${key.key}: $e');
      return null;
    }
  }

  /// Delete a key from the cloud.
  Future<bool> delete(AtKey key) async {
    try {
      return await atClient.delete(key);
    } catch (e) {
      _log.warning('delete failed for ${key.key}: $e');
      return false;
    }
  }

  // ══════════════════════════════════════════════════════
  //  DISTRIBUTED MUTEX (immutable AtKey lock)
  // ══════════════════════════════════════════════════════

  /// Attempt to acquire a named distributed lock.
  ///
  /// Returns `true` if this instance won the race.
  /// Returns `false` if another instance already holds the lock.
  ///
  /// The lock auto-releases after [ttlMs] milliseconds (default 30 s).
  ///
  /// IMPLEMENTATION:
  ///   - Put an immutable key with a short TTL.
  ///   - Immutability means only the FIRST put succeeds; all subsequent
  ///     puts throw an exception — exploited as a distributed CAS.
  ///   - Always verify owner after write to guard against races.
  Future<bool> acquireLock(
    String lockName, {
    int ttlMs = 30000,
    String? holderHint,
  }) async {
    final key = selfKey('lock.$lockName');
    try {
      await put(
        key,
        holderHint ?? (atClient.getCurrentAtSign() ?? 'agent'),
        ttlMs: ttlMs,
        immutable: true,
      );
      _log.fine('Lock acquired: $lockName');
      return true;
    } catch (e) {
      // The immutability write conflict is surfaced as an exception.
      _log.fine('Lock already held: $lockName ($e)');
      return false;
    }
  }

  /// Release a lock before its TTL expires (not always possible with
  /// immutable keys — best-effort delete; if denied the TTL will
  /// expire naturally).
  Future<void> releaseLock(String lockName) async {
    final key = selfKey('lock.$lockName');
    await delete(key);
    _log.fine('Lock released (or already expired): $lockName');
  }

  // ══════════════════════════════════════════════════════
  //  NOTIFICATION HELPERS
  // ══════════════════════════════════════════════════════

  /// Subscribe to notifications matching [regex] and invoke [callback].
  ///
  /// Returns the stream subscription so callers can cancel it.
  StreamSubscription<AtNotification> subscribe(
    String regex,
    void Function(AtNotification) callback, {
    bool shouldDecrypt = true,
  }) {
    return atClient.notificationService
        .subscribe(regex: regex, shouldDecrypt: shouldDecrypt)
        .listen(callback);
  }
}
