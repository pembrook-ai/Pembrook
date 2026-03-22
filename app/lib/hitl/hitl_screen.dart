/// HitlScreen — displays pending HITL approval requests.
///
/// @owner can approve or deny each action before the agent executes it.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/data_service.dart';
import '../widgets/navigation_drawer.dart';

class HitlScreen extends StatelessWidget {
  const HitlScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 600;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pending Approvals'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => context.read<DataService>().refresh(),
          ),
        ],
      ),
      drawer: wide ? null : const AppNavigationDrawer(),
      body: Consumer<DataService>(
        builder: (context, ds, _) {
          if (ds.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (ds.pendingHitl.isEmpty) {
            return const Center(child: Text('No pending approvals.'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: ds.pendingHitl.length,
            itemBuilder: (context, index) {
              final item = ds.pendingHitl[index];
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.pending_actions,
                              color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              item.actionType,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(item.description),
                      const SizedBox(height: 4),
                      Text(
                        'Requested: ${DateFormat('MMM d, HH:mm').format(item.requestedAt.toLocal())}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          OutlinedButton.icon(
                            icon: const Icon(Icons.close, color: Colors.red),
                            label: const Text('Deny',
                                style: TextStyle(color: Colors.red)),
                            onPressed: () =>
                                ds.approveHitl(item.actionId, approved: false),
                          ),
                          const SizedBox(width: 12),
                          FilledButton.icon(
                            icon: const Icon(Icons.check),
                            label: const Text('Approve'),
                            onPressed: () =>
                                ds.approveHitl(item.actionId, approved: true),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
