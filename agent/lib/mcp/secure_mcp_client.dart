/// SecureMcpClient — call MCP server tools via AtRpc (zero open ports).
///
/// DESIGN:
///   - All MCP server communication goes through the atNetwork.
///   - Each MCP server has its own atSign (@mcp_home, @mcp_db, @mcp_browser).
///   - The client sends an RPC call to the server's atSign on domain
///     "pembrook.mcp" and waits for the response.
///   - Before calling, the PolicyEngine checks the tool invocation.
///   - After calling, the AuditService logs the result.
///
/// MCP request envelope (sent as AtRpc payload):
///   {
///     "jsonrpc": "2.0",
///     "method": "tools/call",
///     "params": {
///       "name": "<toolName>",
///       "arguments": {...}
///     },
///     "id": "<requestId>"
///   }
///
/// MCP response envelope:
///   {
///     "jsonrpc": "2.0",
///     "result": { "content": [...] },
///     "id": "<requestId>"
///   }
///
/// `listTools(mcpAtSign)` sends a `tools/list` request and returns the
/// server's tool definitions, enabling the orchestrator to browse
/// available tools at runtime.

import 'dart:async';
import 'dart:convert';
import 'package:at_client/at_client.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../models/audit_entry.dart';
import '../models/policy.dart';
import '../core/policy_engine.dart';
import '../core/hitl_manager.dart';
import '../services/audit_service.dart';

class McpCallResult {
  final bool success;
  final List<Map<String, dynamic>> content;
  final String? error;

  const McpCallResult({
    required this.success,
    this.content = const [],
    this.error,
  });
}

class SecureMcpClient {
  final AtClient atClient;
  final PolicyEngine policyEngine;
  final HitlManager hitlManager;
  final AuditService auditService;
  final Logger _log = Logger('SecureMcpClient');
  final Uuid _uuid = const Uuid();

  static const String _namespace = 'pembrook';
  static const String _mcpDomain = 'pembrook.mcp';

  SecureMcpClient({
    required this.atClient,
    required this.policyEngine,
    required this.hitlManager,
    required this.auditService,
  });

  // ──────────────────────────────────────────────────────────
  //  TOOL CALL
  // ──────────────────────────────────────────────────────────

  /// Call [toolName] on the MCP server at [mcpAtSign].
  ///
  /// [initiatorAtSign] is the originator of the request (for audit/policy).
  Future<McpCallResult> callTool({
    required String mcpAtSign,
    required String toolName,
    required Map<String, dynamic> arguments,
    required String initiatorAtSign,
    String? conversationId,
  }) async {
    // ── Policy check ─────────────────────────────────────────
    final policyReq = PolicyCheckRequest(
      initiatorAtSign: initiatorAtSign,
      targetResource: 'mcp:$mcpAtSign:$toolName',
      actionType: 'mcp.toolCall',
      payload: arguments,
      conversationId: conversationId ?? '',
    );
    final decision = await policyEngine.checkPolicy(policyReq);

    if (decision.isDenied) {
      await _audit(
        actionType: 'mcp.toolCall.$toolName',
        initiatorAtSign: initiatorAtSign,
        mcpServer: mcpAtSign,
        policyDecision: 'denied',
        notes: decision.reason,
      );
      return McpCallResult(
        success: false,
        error: decision.reason ?? 'Policy denied',
      );
    }

    // ── HITL if escalation required ──────────────────────────
    if (decision.requiresHitl) {
      final hitlReq = HitlRequest(
        actionId: 'mcp_${toolName}_${DateTime.now().millisecondsSinceEpoch}',
        actionType: 'mcp.toolCall',
        description:
            'MCP tool "$toolName" on $mcpAtSign requested by $initiatorAtSign',
        payload: arguments,
        requesterAtSign: initiatorAtSign,
      );
      final hitlDecision = await hitlManager.requestApproval(hitlReq);
      if (!hitlDecision.approved) {
        await _audit(
          actionType: 'mcp.toolCall.$toolName',
          initiatorAtSign: initiatorAtSign,
          mcpServer: mcpAtSign,
          policyDecision: 'denied',
          notes: 'HITL denied: ${hitlDecision.reason ?? ""}',
        );
        return McpCallResult(
          success: false,
          error: 'HITL approval denied: ${hitlDecision.reason ?? ""}',
        );
      }
    }

    // ── RPC call via atNetwork ───────────────────────────────
    final requestId = _uuid.v4();
    final envelope = {
      'jsonrpc': '2.0',
      'method': 'tools/call',
      'params': {'name': toolName, 'arguments': arguments},
      'id': requestId,
    };

    _log.info('MCP call: $mcpAtSign/$toolName (req=$requestId)');

    McpCallResult callResult;
    try {
      // Send request as notification; subscribe for response.
      // The MCP server listens on "pembrook.mcp.request" and responds on
      // "pembrook.mcp.response.<requestId>".
      final responseKey = 'mcp.response.$requestId';
      final responseFuture =
          _waitForResponse(responseKey, timeout: const Duration(seconds: 30));

      final requestKey = (AtKey.shared(
        'mcp.request.$requestId',
        namespace: _namespace,
        sharedBy: atClient.getCurrentAtSign() ?? '',
      )..sharedWith(mcpAtSign))
          .build()
        ..metadata = (Metadata()
          ..ttl = 30000 // 30 s
          ..ttr = -1);

      await atClient.notificationService.notify(
        NotificationParams.forUpdate(
          requestKey,
          value: jsonEncode(envelope),
        ),
      );

      final responseJson = await responseFuture;
      if (responseJson == null) {
        callResult = const McpCallResult(
            success: false, error: 'MCP response timed out');
      } else {
        final response = jsonDecode(responseJson) as Map<String, dynamic>;
        if (response.containsKey('error')) {
          callResult = McpCallResult(
            success: false,
            error: (response['error'] as Map<String, dynamic>)['message']
                as String?,
          );
        } else {
          final result = response['result'] as Map<String, dynamic>;
          final content = (result['content'] as List<dynamic>?)
                  ?.map((e) => e as Map<String, dynamic>)
                  .toList() ??
              [];
          callResult = McpCallResult(success: true, content: content);
        }
      }
    } catch (e) {
      _log.severe('MCP call error: $e');
      callResult = McpCallResult(success: false, error: 'RPC error: $e');
    }

    // ── Audit ─────────────────────────────────────────────────
    await _audit(
      actionType: 'mcp.toolCall.$toolName',
      initiatorAtSign: initiatorAtSign,
      mcpServer: mcpAtSign,
      policyDecision: callResult.success ? 'allowed' : 'denied',
      notes: callResult.error,
    );

    return callResult;
  }

  // ──────────────────────────────────────────────────────────
  //  LIST TOOLS
  // ──────────────────────────────────────────────────────────

  /// Query [mcpAtSign] for its available tools.
  ///
  /// Sends a JSON-RPC 2.0 `tools/list` request and returns the tool
  /// definitions, or an empty list if the server is unreachable.
  Future<List<Map<String, dynamic>>> listTools(String mcpAtSign) async {
    final requestId = _uuid.v4();
    final envelope = {
      'jsonrpc': '2.0',
      'method': 'tools/list',
      'params': {},
      'id': requestId,
    };

    _log.info('MCP tools/list: $mcpAtSign (req=$requestId)');

    try {
      final responseKey = 'mcp.response.$requestId';
      final responseFuture =
          _waitForResponse(responseKey, timeout: const Duration(seconds: 30));

      final requestKey = (AtKey.shared(
        'mcp.request.$requestId',
        namespace: _namespace,
        sharedBy: atClient.getCurrentAtSign() ?? '',
      )..sharedWith(mcpAtSign))
          .build()
        ..metadata = (Metadata()
          ..ttl = 30000
          ..ttr = -1);

      await atClient.notificationService.notify(
        NotificationParams.forUpdate(
          requestKey,
          value: jsonEncode(envelope),
        ),
      );

      final rawResponse = await responseFuture;
      if (rawResponse == null) {
        _log.warning('listTools timed out for $mcpAtSign');
        return [];
      }

      final decoded = jsonDecode(rawResponse) as Map<String, dynamic>;
      final result = decoded['result'] as Map<String, dynamic>?;
      final tools = result?['tools'] as List<dynamic>? ?? [];
      return tools.cast<Map<String, dynamic>>();
    } catch (e) {
      _log.warning('listTools error for $mcpAtSign: $e');
      return [];
    }
  }

  // ──────────────────────────────────────────────────────────
  //  HELPERS
  // ──────────────────────────────────────────────────────────

  /// Subscribe and wait for a single response notification.
  Future<String?> _waitForResponse(String keyPattern,
      {required Duration timeout}) async {
    final completer = Completer<String?>();
    final subscription = atClient.notificationService
        .subscribe(regex: keyPattern, shouldDecrypt: true)
        .listen((notification) {
      if (!completer.isCompleted && notification.value != null) {
        completer.complete(notification.value);
      }
    });

    Future.delayed(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });

    final result = await completer.future;
    await subscription.cancel();
    return result;
  }

  Future<void> _audit({
    required String actionType,
    required String initiatorAtSign,
    required String mcpServer,
    required String policyDecision,
    String? notes,
  }) async {
    await auditService.log(AuditEntry(
      timestamp: DateTime.now().toUtc(),
      actionType: actionType,
      initiatorAtSign: initiatorAtSign,
      targetResource: 'mcp:$mcpServer',
      policyDecision: policyDecision,
      mcpServer: mcpServer,
      notes: notes,
    ));
  }
}
