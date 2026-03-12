/// Gateway — AtRpc server that is the secure entry point to the agent.
///
/// Architecture:
///   - Implements an AtRpc server on @agent's atSign
///   - allowList controls which atSigns can send commands:
///       @owner (direct Flutter app / CLI)
///       @bridge_* (messaging bridge relays)
///   - Zero open ports: connects OUTBOUND to atPlatform and listens on
///     the encrypted notification channel
///   - Rate limiting per sender (in-memory, resets on restart)
///   - All approved requests are forwarded to the Orchestrator
///   - All responses stream back via AtRpc to the originating atSign
///
/// AtRpc domain namespace: 'safeclaw'
/// AtRpc key pattern delivered to @owner:
///   @owner:safeclaw.rpc_.*@agent
///
/// Multi-instance horizontal scaling:
///   Use ServiceFactoryWithNoOpSyncService() + unique hive paths per instance,
///   OR use the immutable mutex race pattern (see AtPlatformService).

import 'dart:async';
import 'dart:convert';
import 'package:at_client/at_client.dart';
import 'package:logging/logging.dart';

import '../core/orchestrator.dart';
import '../core/policy_engine.dart';
import '../services/audit_service.dart';
import 'gateway_callbacks.dart';

class Gateway {
  final AtClient atClient;
  final Orchestrator orchestrator;
  final PolicyEngine policyEngine;
  final AuditService auditService;

  // Allow list: atSigns permitted to send commands.
  // Replace @owner with your actual owner atSign.
  // Add @bridge_whatsapp etc. when Phase 6 bridges are deployed.
  static const Set<String> _defaultAllowList = {
    '@owner',
    '@bridge_whatsapp',
    '@bridge_telegram',
    '@bridge_discord',
    '@bridge_slack',
  };

  late AtRpc _rpc;
  final Logger _log = Logger('Gateway');
  bool _running = false;

  Gateway({
    required this.atClient,
    required this.orchestrator,
    required this.policyEngine,
    required this.auditService,
  });

  /// Start the AtRpc server. This connects outbound to the atPlatform
  /// and subscribes to encrypted notification channels — no open ports.
  Future<void> start() async {
    if (_running) return;

    final namespace = atClient.getPreferences()!.namespace!;

    final callbacks = GatewayCallbacks(
      orchestrator: orchestrator,
      policyEngine: policyEngine,
      auditService: auditService,
    );

    // AtRpc server — listens for incoming RPC requests on the notification
    // channel. allowList enforces that only approved atSigns can invoke.
    _rpc = AtRpc(
      atClient: atClient,
      baseNameSpace: namespace,
      domainNameSpace: 'safeclaw',
      callbacks: callbacks,
      allowList: _defaultAllowList,
    );

    _rpc.start();
    _running = true;

    _log.info(
      'Gateway started on ${atClient.getCurrentAtSign()} '
      'namespace=$namespace domainNameSpace=safeclaw '
      'allowList=${_defaultAllowList.join(', ')}',
    );
  }

  /// Stop the AtRpc server gracefully.
  Future<void> stop() async {
    if (!_running) return;
    // AtRpc has no stop() method — the notification subscriptions wind down
    // naturally when the process exits or when AtClient disconnects.
    _running = false;
    _log.info('Gateway stopped');
  }
}
