/// SkillsScreen — displays and manages installed skills.
///
/// Reads live data from DataService (which stores skill registrations as
/// AtKeys on @owner's atServer, sharedWith @agent).
///
/// Skills are ALSO synced to the agent via RpcService using the special
/// _sys.skill.* management commands so the agent can actually invoke them.
///
/// Features:
///   - Live list with trust-score bar
///   - FAB → Add Skill dialog (skillId, skillAtSign, description, version)
///   - Enable / disable toggle per skill  (re-syncs to agent)
///   - Delete (unregister) per skill      (removes from agent registry)
///   - Pull-to-refresh

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/data_service.dart';
import '../services/rpc_service.dart';

class SkillsScreen extends StatelessWidget {
  const SkillsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Installed Skills'),
        actions: [
          Consumer<DataService>(
            builder: (context, ds, _) => IconButton(
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
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddSkillDialog(context),
        tooltip: 'Register skill',
        child: const Icon(Icons.add),
      ),
      body: Consumer<DataService>(
        builder: (context, ds, _) {
          if (ds.loading && ds.skills.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (ds.skills.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.extension_off_outlined,
                      size: 64,
                      color: Theme.of(context).colorScheme.outlineVariant),
                  const SizedBox(height: 16),
                  Text(
                    'No skills registered.',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text('Tap + to add one.'),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () => ds.refresh(),
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
              itemCount: ds.skills.length,
              itemBuilder: (context, index) {
                final skill = ds.skills[index];
                return _SkillCard(skill: skill);
              },
            ),
          );
        },
      ),
    );
  }

  Future<void> _showAddSkillDialog(BuildContext context) async {
    final formKey = GlobalKey<FormState>();
    final idCtrl = TextEditingController();
    final atSignCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final versionCtrl = TextEditingController(text: '1.0.0');

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Register Skill'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: idCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Skill ID',
                    hintText: 'e.g. calendar',
                    prefixIcon: Icon(Icons.extension),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: atSignCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Skill atSign',
                    hintText: 'e.g. @skill_calendar',
                    prefixIcon: Icon(Icons.alternate_email),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: descCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    prefixIcon: Icon(Icons.notes),
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: versionCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Version',
                    prefixIcon: Icon(Icons.tag),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('Register'),
          ),
        ],
      ),
    );

    if (result == true && context.mounted) {
      final skill = SkillData(
        skillId: idCtrl.text.trim(),
        skillAtSign: atSignCtrl.text.trim(),
        description: descCtrl.text.trim(),
        version:
            versionCtrl.text.trim().isEmpty ? '1.0.0' : versionCtrl.text.trim(),
      );
      try {
        await context.read<DataService>().saveSkill(skill);
        // Sync to agent via RPC so the agent can actually invoke the skill.
        await _syncSkillToAgent(context, skill);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Skill "${skill.skillId}" registered.')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to register skill: $e')),
          );
        }
      }
    }
  }

  /// Send _sys.skill.install to the agent so it writes a SkillMetadata entry
  /// into its own registry.  The RPC is best-effort — if the agent is offline
  /// the local DataService entry is still saved and will be re-synced next time.
  static Future<void> _syncSkillToAgent(
      BuildContext context, SkillData skill) async {
    if (!context.mounted) return;
    final rpc = context.read<RpcService>();
    try {
      await rpc.call(
        command: '_sys.skill.install',
        conversationId: 'sys',
        payload: skill.toJson(),
      );
    } catch (_) {
      // Non-fatal: agent might be offline.
    }
  }

  /// Send _sys.skill.uninstall to the agent.  Best-effort.
  static Future<void> _removeSkillFromAgent(
      BuildContext context, String skillId) async {
    if (!context.mounted) return;
    final rpc = context.read<RpcService>();
    try {
      await rpc.call(
        command: '_sys.skill.uninstall',
        conversationId: 'sys',
        payload: {'skillId': skillId},
      );
    } catch (_) {
      // Non-fatal.
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _SkillCard extends StatelessWidget {
  final SkillData skill;
  const _SkillCard({required this.skill});

  @override
  Widget build(BuildContext context) {
    final ds = context.read<DataService>();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: skill.enabled
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Text(
              skill.skillId.isNotEmpty ? skill.skillId[0].toUpperCase() : '?',
              style: TextStyle(
                color: skill.enabled
                    ? Theme.of(context).colorScheme.onPrimaryContainer
                    : Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          title: Text(
            skill.skillId,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: skill.enabled ? null : Theme.of(context).disabledColor,
            ),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                skill.skillAtSign,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 12,
                ),
              ),
              if (skill.description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(skill.description),
                ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Text('Trust: ', style: TextStyle(fontSize: 12)),
                  _TrustBar(score: skill.trustScore),
                  Text(
                    ' ${(skill.trustScore * 100).toInt()}%',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const Spacer(),
                  Text(
                    'v${skill.version}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ],
          ),
          isThreeLine: true,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(
                value: skill.enabled,
                onChanged: (val) async {
                  final updated = skill.copyWith(enabled: val);
                  await ds.saveSkill(updated);
                  // Re-sync to agent (carrier of the 'enabled' flag).
                  if (context.mounted) {
                    await SkillsScreen._syncSkillToAgent(context, updated);
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remove skill',
                color: Theme.of(context).colorScheme.error,
                onPressed: () => _confirmDelete(context, ds),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, DataService ds) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Skill?'),
        content: Text(
          'Remove "${skill.skillId}" from the agent\'s skill registry? '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (ok == true && context.mounted) {
      try {
        await ds.removeSkill(skill.skillId);
        // Remove from agent registry too.
        if (context.mounted) {
          await SkillsScreen._removeSkillFromAgent(context, skill.skillId);
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Skill "${skill.skillId}" removed.')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to remove: $e')),
          );
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _TrustBar extends StatelessWidget {
  final double score;
  const _TrustBar({required this.score});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 60,
      height: 6,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: score,
          backgroundColor: Colors.grey.shade300,
          valueColor: AlwaysStoppedAnimation<Color>(
            score >= 0.8
                ? Colors.green
                : score >= 0.5
                    ? Colors.orange
                    : Colors.red,
          ),
        ),
      ),
    );
  }
}
