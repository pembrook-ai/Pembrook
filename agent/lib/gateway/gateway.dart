/// Gateway — AtRpc server that is the secure entry point to the agent.
///
/// Architecture:
///   - Implements an AtRpc server on @agent's atSign
///   - allowList controls which atSigns can send commands:
///       @owner (direct Flutter app / CLI)
///       @bridges (messaging bridge relay atSign — all bridges share one)
///       Any additional atSigns stored in `settings.allowed_users.safeclaw`
///   - Zero open ports: connects OUTBOUND to atPlatform and listens on
///     the encrypted notification channel
///   - Rate limiting per sender (in-memory, resets on restart)
///   - All approved requests are forwarded to the Orchestrator
///   - All responses stream back via AtRpc to the originating atSign
///   - allowList is refreshed every 5 minutes from AtKey + env var fallback
///
/// AtRpc domain namespace: 'safeclaw'
/// AtRpc key pattern delivered to @owner:
///   @owner:safeclaw.rpc_.*@agent
///
/// AllowList persistence:
///   AtKey: settings.allowed_users.safeclaw@agent  →  JSON array of atSigns
///   Env var fallback: ALLOWED_USERS=@owner,@bridges (comma-separated)
///   Owner atSign from: settings.owner_atsign.safeclaw@agent OR OWNER_AT_SIGN env var
///
/// Multi-instance horizontal scaling:
///   Use ServiceFactoryWithNoOpSyncService() + unique hive paths per instance,
///   OR use the immutable mutex race pattern (see AtPlatformService).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:at_client/at_client.dart';
import 'package:logging/logging.dart';

import '../core/orchestrator.dart';
import '../core/policy_engine.dart';
import '../services/audit_service.dart';
import 'gateway_callbacks.dart';

/// AtKey name for the JSON array of permitted atSigns.
const String _kAllowedUsersKey = 'settings.allowed_users';

/// AtKey name for the owner atSign.
const String _kOwnerAtSignKey = 'settings.owner_atsign';

/// How often to re-read the allowList from the atServer.
const Duration _kAllowListRefreshInterval = Duration(minutes: 5);

class Gateway {
  final AtClient atClient;
  final Orchestrator orchestrator;
  final PolicyEngine policyEngine;
  final AuditService auditService;

  /// Live, mutable allowList.  AtRpc holds a reference to this exact Set
  /// object, so mutations made by the refresh timer are visible immediately
  /// without restarting the AtRpc server.
  final Set<String> _allowList = {};

  late AtRpc _rpc;
  Timer? _allowListRefreshTimer;
  final Logger _log = Logger('Gateway');
  bool _running = false;

  Gateway({
    required this.atClient,
    required this.orchestrator,
    required this.policyEngine,
    required this.auditService,
  });

  // ── AllowList helpers ─────────────────────────────────────────────────────

  /// Read the allowList from AtKeys (falling back to env vars) and mutate
  /// [_allowList] in-place so the AtRpc server picks up the change.
  Future<void> _refreshAllowList() async {
    final agentAtSign = atClient.getCurrentAtSign()!;
    final updated = <String>{};

    // 1. Owner atSign from AtKey, then env var, then literal placeholder.
    try {
      final ownerKey = AtKey()
        ..key = _kOwnerAtSignKey
        ..namespace = 'safeclaw'
        ..sharedBy = agentAtSign;
      final ownerValue = await atClient.get(ownerKey);
      final ownerAtSign = ownerValue.value as String?;
      if (ownerAtSign != null && ownerAtSign.isNotEmpty) {
        updated.add(ownerAtSign.trim());
      }
    } catch (_) {
      // AtKey may not exist on first boot — fall through to env var.
    }

    final envOwner = Platform.environment['OWNER_AT_SIGN'] ?? '';
    if (envOwner.isNotEmpty) updated.add(envOwner.trim());

    // 2. Additional allowed users from AtKey (JSON array).
    try {
      final allowedKey = AtKey()
        ..key = _kAllowedUsersKey
        ..namespace = 'safeclaw'
        ..sharedBy = agentAtSign;
      final allowedValue = await atClient.get(allowedKey);
      final raw = allowedValue.value as String?;
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        updated.addAll(list.map((e) => (e as String).trim()));
      }
    } catch (_) {
      // Not yet written — fall through.
    }

    // 3. Env-var fallback: ALLOWED_USERS=@owner,@bridges
    final envUsers = Platform.environment['ALLOWED_USERS'] ?? '';
    if (envUsers.isNotEmpty) {
      updated.addAll(
        envUsers.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty),
      );
    }

    // 4. Mutate in-place so AtRpc sees the update without recreation.
    if (updated.isNotEmpty) {
      _allowList
        ..clear()
        ..addAll(updated);
      _log.info('AllowList refreshed: ${_allowList.toList()..sort()}');
    } else {
      _log.warning(
        'AllowList is empty after refresh — no atSigns can send commands. '
        'Set OWNER_AT_SIGN env var or write the settings.owner_atsign AtKey.',
      );
    }
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Start the AtRpc server. This connects outbound to the atPlatform
  /// and subscribes to encrypted notification channels — no open ports.
  Future<void> start() async {
    if (_running) return;

    // Load allowList before starting AtRpc so the first request is filtered.
    await _refreshAllowList();

    // Schedule periodic refresh — mutates _allowList in-place.
    _allowListRefreshTimer = Timer.periodic(
      _kAllowListRefreshInterval,
      (_) => _refreshAllowList(),
    );

    final namespace = atClient.getPreferences()!.namespace!;

    final callbacks = GatewayCallbacks(
      orchestrator: orchestrator,
      policyEngine: policyEngine,
      auditService: auditService,
    );

    // AtRpc server — listens for incoming RPC requests on the notification
    // channel. allowList enforces that only approved atSigns can invoke.
    // NOTE: _allowList is passed by reference — live mutations are picked up.
    _rpc = AtRpc(
      atClient: atClient,
      baseNameSpace: namespace,
      domainNameSpace: 'safeclaw',
      callbacks: callbacks,
      allowList: _allowList,
    );

    _rpc.start();
    _running = true;

    _log.info(
      'Gateway started on ${atClient.getCurrentAtSign()} '
      'namespace=$namespace domainNameSpace=safeclaw '
      'allowList=${_allowList.toList()..sort()}',
    );
  }

  /// Stop the AtRpc server gracefully.
  Future<void> stop() async {
    if (!_running) return;
    _allowListRefreshTimer?.cancel();
    _allowListRefreshTimer = null;
    // AtRpc has no stop() method — the notification subscriptions wind down
    // naturally when the process exits or when AtClient disconnects.
    _running = false;
    _log.info('Gateway stopped');
  }
}
