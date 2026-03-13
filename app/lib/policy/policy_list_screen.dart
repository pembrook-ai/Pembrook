/// PolicyListScreen — browse, create, and manage SafeClaw policy rules.
///
/// Policies are stored as AtKeys on @owner's atServer and shared with @agent:
///   Key: `policy.$policyId.safeclaw@<ownerAtSign>` sharedWith `@agent`
///   Value: JSON-encoded Policy object (see agent/lib/models/policy.dart)
///
/// The @agent PolicyEngine reads these keys to evaluate every action.
///
/// Usage:
///   - Tap the + FAB to create a new policy.
///   - Tap a policy card to open PolicyEditorScreen.
///   - Long-press a card (or use the trash icon) to delete.

import 'dart:convert';

import 'package:at_client/at_client.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'policy_editor_screen.dart';

class PolicyListScreen extends StatefulWidget {
  const PolicyListScreen({super.key});

  @override
  State<PolicyListScreen> createState() => _PolicyListScreenState();
}

class _PolicyListScreenState extends State<PolicyListScreen> {
  static const String _namespace = 'safeclaw';

  List<PolicySummary> _policies = [];
  bool _loading = true;
  String? _error;

  AtClient? get _atClient {
    try {
      return AtClientManager.getInstance().atClient;
    } catch (_) {
      return null;
    }
  }

  String get _ownerAtSign => _atClient?.getCurrentAtSign() ?? '@owner';

  @override
  void initState() {
    super.initState();
    _loadPolicies();
  }

  // ────────────────────────────────────────────────────────────────────────
  //  DATA
  // ────────────────────────────────────────────────────────────────────────

  Future<void> _loadPolicies() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final client = _atClient;
    if (client == null) {
      setState(() {
        _loading = false;
        _error = 'Not authenticated';
      });
      return;
    }

    try {
      // Scan for all policy keys owned by @owner
      final keys = await client.getAtKeys(
        regex: 'policy\\..+\\.$_namespace',
        sharedBy: _ownerAtSign,
      );

      final List<PolicySummary> loaded = [];
      for (final key in keys) {
        try {
          final result = await client.get(
            key,
            getRequestOptions: GetRequestOptions()..useRemoteAtServer = true,
          );
          final rawJson = result.value as String?;
          if (rawJson == null || rawJson.isEmpty) continue;
          final json = jsonDecode(rawJson) as Map<String, dynamic>;
          loaded.add(PolicySummary.fromJson(json, key.toString()));
        } catch (_) {
          continue;
        }
      }

      // Sort by priority ascending
      loaded.sort((a, b) => a.priority.compareTo(b.priority));

      setState(() {
        _policies = loaded;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _deletePolicy(PolicySummary policy) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete policy?'),
        content: Text(
          '"${policy.policyId}" has ${policy.ruleCount} rule(s). '
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final client = _atClient;
    if (client == null) return;

    try {
      final key = (AtKey.shared(
        'policy.${policy.policyId}',
        namespace: _namespace,
        sharedBy: _ownerAtSign,
      )..sharedWith('@agent'))
          .build();
      await client.delete(key);
      await _loadPolicies();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted "${policy.policyId}"')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  //  NAVIGATION
  // ────────────────────────────────────────────────────────────────────────

  Future<void> _openEditor({PolicySummary? existing}) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PolicyEditorScreen(policyId: existing?.policyId),
      ),
    );
    if (result == true) {
      await _loadPolicies();
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  //  BUILD
  // ────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Policy Rules'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loadPolicies,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('New Policy'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: _loadPolicies,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (_policies.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.policy_outlined,
              size: 72,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            const SizedBox(height: 16),
            const Text('No policies yet.'),
            const SizedBox(height: 8),
            const Text(
              'Tap + to create your first rule.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadPolicies,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
        itemCount: _policies.length,
        itemBuilder: (context, i) => _PolicyCard(
          policy: _policies[i],
          onTap: () => _openEditor(existing: _policies[i]),
          onDelete: () => _deletePolicy(_policies[i]),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
//  POLICY CARD
// ──────────────────────────────────────────────────────────────────────────────

class _PolicyCard extends StatelessWidget {
  final PolicySummary policy;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _PolicyCard({
    required this.policy,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor:
              _typeColor(policy.policyType, cs).withValues(alpha: 0.15),
          child: Icon(
            _typeIcon(policy.policyType),
            size: 20,
            color: _typeColor(policy.policyType, cs),
          ),
        ),
        title: Text(
          policy.policyId,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${policy.policyType.toUpperCase()} • '
          'Priority ${policy.priority} • '
          '${policy.ruleCount} rule${policy.ruleCount == 1 ? '' : 's'}'
          '\nUpdated ${_fmt(policy.updatedAt)}',
        ),
        isThreeLine: true,
        trailing: IconButton(
          icon: Icon(Icons.delete_outline, color: cs.error),
          tooltip: 'Delete',
          onPressed: onDelete,
        ),
      ),
    );
  }

  static IconData _typeIcon(String type) => switch (type) {
        'identity' => Icons.fingerprint,
        'capability' => Icons.toggle_on_outlined,
        'temporal' => Icons.access_time,
        'risk' => Icons.warning_amber_outlined,
        'dataFlow' => Icons.privacy_tip_outlined,
        'rateLimit' => Icons.speed,
        _ => Icons.policy_outlined,
      };

  static Color _typeColor(String type, ColorScheme cs) => switch (type) {
        'identity' => cs.primary,
        'capability' => cs.secondary,
        'temporal' => cs.tertiary,
        'risk' => Colors.orange,
        'dataFlow' => Colors.purple,
        'rateLimit' => Colors.teal,
        _ => cs.outline,
      };

  static String _fmt(DateTime? dt) {
    if (dt == null) return '—';
    return DateFormat('d MMM y').format(dt.toLocal());
  }
}

// ──────────────────────────────────────────────────────────────────────────────
//  POLICY SUMMARY  (lightweight read model for list view)
// ──────────────────────────────────────────────────────────────────────────────

class PolicySummary {
  final String policyId;
  final String policyType;
  final int priority;
  final int ruleCount;
  final DateTime? updatedAt;
  final String rawJson;

  const PolicySummary({
    required this.policyId,
    required this.policyType,
    required this.priority,
    required this.ruleCount,
    this.updatedAt,
    required this.rawJson,
  });

  factory PolicySummary.fromJson(Map<String, dynamic> json, String keyStr) {
    final rules = (json['rules'] as List?)?.length ?? 0;
    return PolicySummary(
      policyId: json['policyId'] as String? ?? keyStr,
      policyType: json['policyType'] as String? ?? 'identity',
      priority: json['priority'] as int? ?? 100,
      ruleCount: rules,
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
      rawJson: jsonEncode(json),
    );
  }
}
