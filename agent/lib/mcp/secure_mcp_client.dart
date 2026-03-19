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
        arguments: arguments,
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
          arguments: arguments,
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
      // Send request as notification; poll for put()-based response.
      // The MCP server listens on "pembrook.mcp.request" and responds by
      // writing to "mcp.response.<requestId>" via put().
      final responseKeyName = 'mcp.response.$requestId';

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

      final responseJson = await _waitForResponse(
        responseKeyName,
        mcpAtSign,
        timeout: const Duration(seconds: 30),
      );
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
      arguments: arguments,
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
      final responseKeyName = 'mcp.response.$requestId';

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

      final rawResponse = await _waitForResponse(
        responseKeyName,
        mcpAtSign,
        timeout: const Duration(seconds: 30),
      );
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

  /// Poll for the response key written by the MCP server via `put()`.
  ///
  /// The MCP server writes the response as a shared key:
  ///   `@agent:mcp.response.<id>.pembrook@mcpserver`
  /// We poll with `get()` since `notify()` relay is unreliable across atServers.
  Future<String?> _waitForResponse(
    String responseKeyName,
    String mcpAtSign, {
    required Duration timeout,
  }) async {
    final myAtSign = atClient.getCurrentAtSign() ?? '';
    final deadline = DateTime.now().add(timeout);
    const pollInterval = Duration(milliseconds: 500);
    var attempt = 0;

    // Construct the key exactly the same way the MCP server creates it
    // (AtKey.shared + namespace), so the SDK generates identical lookup
    // commands.
    final atKey = (AtKey.shared(
      responseKeyName,
      namespace: _namespace,
      sharedBy: mcpAtSign,
    )..sharedWith(myAtSign))
        .build();

    _log.info('Polling for response key: ${atKey.toString()} '
        '(key=${atKey.key}, ns=${atKey.namespace}, '
        'sharedBy=${atKey.sharedBy}, sharedWith=${atKey.sharedWith})');

    while (DateTime.now().isBefore(deadline)) {
      attempt++;
      try {
        // Force remote lookup — the agent runs with --never-sync so the
        // locally-cached Hive store will never see keys written by the
        // MCP server.  The remote atServer has the key immediately after
        // the MCP server's put() completes.
        final result = await atClient.get(
          atKey,
          getRequestOptions: GetRequestOptions()..useRemoteAtServer = true,
        );
        if (result.value != null && result.value.toString().isNotEmpty) {
          _log.info('Got response on attempt $attempt for $responseKeyName');
          // Clean up the response key on the remote server after reading it.
          try {
            await atClient.delete(atKey);
          } catch (_) {}
          return result.value.toString();
        }
      } on AtKeyNotFoundException catch (_) {
        // Key not yet available — keep polling
      } on KeyNotFoundException catch (_) {
        // Key not yet available — keep polling
      } catch (e) {
        // Log every error at INFO on first few attempts for debugging
        if (attempt <= 3) {
          _log.info('Poll attempt $attempt for $responseKeyName: '
              '${e.runtimeType}: $e');
        }
      }
      await Future.delayed(pollInterval);
    }
    _log.warning(
        'Polling timed out after $attempt attempts for $responseKeyName');
    return null;
  }

  Future<void> _audit({
    required String actionType,
    required String initiatorAtSign,
    required String mcpServer,
    required String policyDecision,
    Map<String, dynamic>? arguments,
    String? notes,
  }) async {
    // Extract the URL from tool arguments when present so it appears in the
    // audit log (matches how fetch_webpage records targetResource).
    final url = arguments?['url'] as String?;
    final targetResource =
        url != null && url.isNotEmpty ? url : 'mcp:$mcpServer';

    // Build a human-readable summary of the arguments for notes.
    final argSummary = arguments != null && arguments.isNotEmpty
        ? arguments.entries.map((e) {
            final v = e.value.toString();
            return '${e.key}=${v.length > 120 ? '${v.substring(0, 120)}…' : v}';
          }).join(', ')
        : null;

    // Combine arg summary with any existing notes (e.g. error message).
    final combinedNotes = [
      if (argSummary != null) argSummary,
      if (notes != null) notes,
    ].join(' | ');

    await auditService.log(AuditEntry(
      timestamp: DateTime.now().toUtc(),
      actionType: actionType,
      initiatorAtSign: initiatorAtSign,
      targetResource: targetResource,
      policyDecision: policyDecision,
      mcpServer: mcpServer,
      notes: combinedNotes.isNotEmpty ? combinedNotes : null,
    ));
  }
}
