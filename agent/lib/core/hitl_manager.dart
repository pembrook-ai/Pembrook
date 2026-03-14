/// HitlManager — Human-In-The-Loop approval manager.
///
/// When PolicyEngine flags an action as requiring HITL, the HitlManager:
///   1. Stores the pending action as an AtKey on @agent
///   2. Sends an approval request to @owner via atPlatform notification
///   3. Waits for the owner's response (approve/deny)
///   4. If timeout reached with no response → DENY (fail-closed design)
///
/// This is a critical security property: the agent CANNOT auto-approve its
/// own actions. Owner approval is cryptographically signed by @owner's atSign.
///
/// HITL pending AtKey: hitl.pending.$actionId.safeclaw@agent  (TTL: 5 min)
/// HITL response AtKey: @owner:hitl.response.$actionId.safeclaw@agent
///
/// Notification to owner:
///   Key: hitl.request.$actionId.safeclaw@owner (sharedWith @owner)
///   Value: HitlRequest JSON

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:at_client/at_client.dart';
import 'package:logging/logging.dart';

import '../models/policy.dart';

class HitlManager {
  final AtClient atClient;
  final Logger _log = Logger('HitlManager');

  /// Resolved at construction from OWNER_AT_SIGN env var (set by docker-compose).
  final String _ownerAtSign;

  // Default HITL timeout — after this, action is DENIED (fail-closed)
  static const Duration _defaultTimeout = Duration(minutes: 5);

  HitlManager({required this.atClient})
      : _ownerAtSign = Platform.environment['OWNER_AT_SIGN'] ?? '@owner';

  /// Request owner approval for a high-risk action.
  ///
  /// Returns a [HitlDecision] after the owner responds or timeout.
  /// On timeout → HitlDecision(approved: false) — fail-closed.
  Future<HitlDecision> requestApproval(HitlRequest request) async {
    _log.info('Requesting HITL approval for actionType=${request.actionType} '
        'actionId=${request.actionId}');

    // ── 1. Store pending state as AtKey ───────────────────────────────────
    // TTL: 5 minutes — auto-cleaned if not responded to
    final pendingKey = AtKey()
      ..key = 'hitl.pending.${request.actionId}'
      ..namespace = 'safeclaw'
      ..metadata = (Metadata()..ttl = 300000 // 5 minutes in ms
          );

    await atClient.put(
      pendingKey,
      jsonEncode(request.toJson()),
      putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
    );

    // ── 2. Notify owner via encrypted notification ─────────────────────
    final notifKey = AtKey()
      ..key = 'hitl.request.${request.actionId}'
      ..namespace = 'safeclaw'
      ..sharedWith = _ownerAtSign
      ..metadata = (Metadata()
            ..ttl = 300000
            ..ttr = -1 // notify immediately
          );

    await atClient.notificationService.notify(
      NotificationParams.forUpdate(
        notifKey,
        value: jsonEncode(request.toJson()),
      ),
    );

    _log.info('HITL notification sent to $_ownerAtSign — waiting up to '
        '${request.timeoutSeconds}s for response');

    // ── 3. Wait for owner response ─────────────────────────────────────
    final completer = Completer<HitlDecision>();
    final timeout = Duration(seconds: request.timeoutSeconds);

    // Subscribe to the response notification from @owner
    final subscription = atClient.notificationService
        .subscribe(
      regex: 'hitl\\.response\\.${request.actionId}',
      shouldDecrypt: true,
    )
        .listen((notification) {
      if (completer.isCompleted) return;

      // Verify the response came from the owner
      if (notification.from != _ownerAtSign) {
        _log.warning('HITL response from unexpected sender '
            '${notification.from} — ignoring');
        return;
      }

      try {
        final responseData =
            jsonDecode(notification.value ?? '{}') as Map<String, dynamic>;
        final approved = responseData['decision'] == 'approve';
        _log.info('Received HITL response for ${request.actionId}: '
            '${approved ? "APPROVED" : "DENIED"} by $_ownerAtSign');
        completer.complete(HitlDecision(
          approved: approved,
          reason: responseData['reason'] as String?,
        ));
      } catch (e) {
        _log.warning('Failed to parse HITL response: $e');
      }
    });

    // ── 4. Timeout — fail-closed ─────────────────────────────────────────
    final timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        _log.warning(
            'HITL timeout for ${request.actionId} — action DENIED (fail-closed)');
        completer.complete(HitlDecision(
          approved: false,
          reason: 'Owner did not respond within ${request.timeoutSeconds}s '
              '— action denied by timeout (fail-closed)',
        ));
      }
    });

    final decision = await completer.future;

    // Cleanup
    timeoutTimer.cancel();
    await subscription.cancel();

    // Delete pending key (cleanup — it would expire via TTL anyway)
    try {
      await atClient.delete(pendingKey);
    } catch (_) {}

    return decision;
  }
}
