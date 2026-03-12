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
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => context.read<DataService>().refresh(),
          ),
        ],
      ),
      body: Consumer<DataService>(
        builder: (context, ds, _) {
          if (ds.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (ds.auditEntries.isEmpty) {
            return const Center(child: Text('No audit entries yet.'));
          }
          return ListView.separated(
            itemCount: ds.auditEntries.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = ds.auditEntries[index];
              final decision = entry.policyDecision;
              final color = decision == 'allowed'
                  ? Colors.green
                  : decision == 'denied'
                      ? Colors.red
                      : Colors.orange;
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: color.withOpacity(0.15),
                  child: Icon(
                    decision == 'allowed'
                        ? Icons.check
                        : decision == 'denied'
                            ? Icons.block
                            : Icons.warning,
                    color: color,
                    size: 20,
                  ),
                ),
                title: Text(entry.actionType,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${entry.initiatorAtSign}  ·  '
                    '${DateFormat('MMM d, HH:mm').format(entry.timestamp.toLocal())}'),
                trailing: entry.notes != null
                    ? const Icon(Icons.info_outline, size: 20)
                    : null,
                onTap: entry.notes != null
                    ? () => showDialog(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: Text(entry.actionType),
                            content: Text(entry.notes!),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Close'),
                              )
                            ],
                          ),
                        )
                    : null,
              );
            },
          );
        },
      ),
    );
  }
}
