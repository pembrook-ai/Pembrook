/// AuditScreen — displays the immutable audit log from @owner's atServer.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/data_service.dart';

class AuditScreen extends StatelessWidget {
  const AuditScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Audit Log'),
        actions: [
          Consumer<DataService>(
            builder: (context, ds, _) => ExcludeSemantics(
              child: IconButton(
                icon: ds.loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                tooltip: 'Refresh',
                onPressed: ds.loading ? null : () => ds.refresh(),
              ),
            ),
          ),
        ],
      ),
      body: Consumer<DataService>(
        builder: (context, ds, _) {
          if (ds.loading && ds.auditEntries.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (ds.auditEntries.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.receipt_long_outlined, size: 64, color: Theme.of(context).colorScheme.outlineVariant),
                  const SizedBox(height: 16),
                  Text('No audit entries yet.', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  const Text('Entries appear here after the agent processes requests.'),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () => ds.refresh(),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: ds.auditEntries.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) => _AuditCard(entry: ds.auditEntries[index]),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _AuditCard extends StatelessWidget {
  final AuditItem entry;
  const _AuditCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final decision = entry.policyDecision;
    final decisionColor = switch (decision) {
      'allowed' => Colors.green,
      'denied' => Colors.red,
      _ => Colors.orange,
    };
    final decisionIcon = switch (decision) {
      'allowed' => Icons.check_circle_outline,
      'denied' => Icons.cancel_outlined,
      _ => Icons.pending_outlined,
    };

    return InkWell(
      onTap: () => _showDetail(context, entry),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Decision icon ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 12),
              child: Icon(decisionIcon, color: decisionColor, size: 22),
            ),
            // ── Main content ───────────────────────────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title row + duration chip
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _formatActionType(entry.actionType),
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (entry.executionDurationMs != null)
                        _Chip(
                          label: '${entry.executionDurationMs} ms',
                          color: Theme.of(context).colorScheme.secondaryContainer,
                          textColor: Theme.of(context).colorScheme.onSecondaryContainer,
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  // Initiator + timestamp
                  Text(
                    '${entry.initiatorAtSign}  ·  '
                    '${DateFormat('MMM d, HH:mm:ss').format(entry.timestamp.toLocal())}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  // Target / skill / mcp line
                  if (_targetLine(entry) != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      _targetLine(entry)!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontFamily: 'monospace',
                          ),
                    ),
                  ],
                  // Command preview
                  if (entry.notes != null && entry.notes!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        entry.notes!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 2, left: 4),
              child: Icon(Icons.chevron_right, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  String _formatActionType(String raw) {
    if (raw.startsWith('mcp.toolCall.')) {
      return 'MCP: ${raw.substring(13)}';
    }
    if (raw == 'mcp.toolCall') return 'MCP Tool Call';
    if (raw.startsWith('task.run.')) {
      final taskId = raw.substring(9);
      final label = taskId.contains('_') ? taskId.split('_').first : taskId;
      return 'Task: $label';
    }
    if (raw.startsWith('skill.invoke.')) {
      return 'Skill: ${raw.substring(13)}';
    }
    if (raw == 'skill.invoke') return 'Skill Invocation';
    if (raw == 'tool.fetch_webpage') return 'Fetch Webpage';
    if (raw.startsWith('tool.')) return 'Tool: ${raw.substring(5)}';
    return raw;
  }

  String? _targetLine(AuditItem e) {
    if (e.skillId != null) return 'skill: ${e.skillId}';
    if (e.mcpServer != null) return 'mcp: ${e.mcpServer}';
    if (e.targetResource != null && e.targetResource != 'llm' && e.targetResource != e.actionType) {
      return e.targetResource;
    }
    return null;
  }

  void _showDetail(BuildContext context, AuditItem e) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.92,
        builder: (_, ctrl) => ListView(
          controller: ctrl,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          children: [
            Text(
              _formatActionType(e.actionType),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            _DetailRow(label: 'Decision', value: e.policyDecision.toUpperCase()),
            _DetailRow(label: 'Time', value: DateFormat('EEE d MMM yyyy HH:mm:ss').format(e.timestamp.toLocal())),
            _DetailRow(label: 'Initiator', value: e.initiatorAtSign),
            if (e.targetResource != null) _DetailRow(label: 'Target', value: e.targetResource!),
            if (e.skillId != null) _DetailRow(label: 'Skill', value: e.skillId!),
            if (e.mcpServer != null) _DetailRow(label: 'MCP Server', value: e.mcpServer!),
            if (e.executionDurationMs != null) _DetailRow(label: 'Duration', value: '${e.executionDurationMs} ms'),
            if (e.notes != null && e.notes!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'COMMAND PREVIEW',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      letterSpacing: 1,
                    ),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(e.notes!, style: Theme.of(context).textTheme.bodyMedium),
              ),
            ],
            if (e.inputHash != null || e.outputHash != null) ...[
              const SizedBox(height: 12),
              Text(
                'INTEGRITY HASHES',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      letterSpacing: 1,
                    ),
              ),
              const SizedBox(height: 6),
              if (e.inputHash != null) _HashRow(label: 'Input', hash: e.inputHash!),
              if (e.outputHash != null) _HashRow(label: 'Output', hash: e.outputHash!),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;
  const _Chip({required this.label, required this.color, required this.textColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: textColor, height: 1.4)),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    )),
          ),
          Expanded(
              child: SelectableText(value,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500))),
        ],
      ),
    );
  }
}

class _HashRow extends StatelessWidget {
  final String label;
  final String hash;
  const _HashRow({required this.label, required this.hash});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )),
          const SizedBox(height: 2),
          SelectableText(
            hash,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace', fontSize: 11),
          ),
        ],
      ),
    );
  }
}
