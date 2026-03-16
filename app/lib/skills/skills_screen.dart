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
    const _networkSkills = {'email', 'calendar', 'web_search'};
    var requiresNetwork = false;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Register Skill'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: idCtrl,
                    onChanged: (v) {
                      final id = v.trim().toLowerCase();
                      if (_networkSkills.contains(id)) {
                        setState(() => requiresNetwork = true);
                      }
                    },
                    decoration: const InputDecoration(
                      labelText: 'Skill ID',
                      hintText: 'e.g. email',
                      helperText:
                          'Short name only — maps to pembrook-skill-<id>:latest',
                      prefixIcon: Icon(Icons.extension),
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Required';
                      final id = v.trim();
                      if (id.contains(':')) {
                        return 'Enter the short ID only (e.g. "email"), not the full image name';
                      }
                      if (RegExp(r'[^a-zA-Z0-9_\-]').hasMatch(id)) {
                        return 'Only letters, numbers, hyphens and underscores allowed';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: atSignCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Skill atSign',
                      hintText: 'e.g. @myservices',
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
                  const SizedBox(height: 4),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Requires network access'),
                    subtitle:
                        const Text('Enable for email, calendar, web_search'),
                    value: requiresNetwork,
                    onChanged: (v) => setState(() => requiresNetwork = v),
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
      ),
    );

    if (result == true && context.mounted) {
      final skill = SkillData(
        skillId: idCtrl.text.trim(),
        skillAtSign: atSignCtrl.text.trim(),
        description: descCtrl.text.trim(),
        version:
            versionCtrl.text.trim().isEmpty ? '1.0.0' : versionCtrl.text.trim(),
        requiresNetwork: requiresNetwork,
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
              IconButton(
                icon: const Icon(Icons.tune),
                tooltip: 'Configure',
                onPressed: () => _showConfigSheet(context, ds),
              ),
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

  // ── Known config fields per skill ID ──────────────────────
  static const _knownFields = <String, List<_ConfigField>>{
    'email': [
      _ConfigField('smtpHost', 'SMTP Host', 'smtp.gmail.com', false),
      _ConfigField('smtpPort', 'SMTP Port', '587', false),
      _ConfigField('smtpUser', 'SMTP Username', 'you@example.com', false),
      _ConfigField('smtpPassword', 'SMTP Password', '', true),
      _ConfigField('fromAddress', 'From Address', 'you@example.com', false),
      _ConfigField('imapHost', 'IMAP Host', 'imap.gmail.com', false),
      _ConfigField('imapPort', 'IMAP Port', '993', false),
      _ConfigField('imapUser', 'IMAP Username', 'you@example.com', false),
      _ConfigField('imapPassword', 'IMAP Password', '', true),
    ],
    'calendar': [
      _ConfigField('accessToken', 'Google OAuth2 Access Token', '', true),
      _ConfigField('calendarId', 'Calendar ID', 'primary', false),
    ],
    'web_search': [
      _ConfigField('searchApiUrl', 'SearXNG Base URL',
          'https://searx.example.com', false),
      _ConfigField('braveApiKey', 'Brave API Key', '', true),
    ],
  };

  Future<void> _showConfigSheet(BuildContext context, DataService ds) async {
    final fields = _knownFields[skill.skillId];
    final controllers = <String, TextEditingController>{};

    // Populate from existing config.
    if (fields != null) {
      for (final f in fields) {
        controllers[f.key] =
            TextEditingController(text: skill.config[f.key] ?? '');
      }
    } else {
      // Generic: display existing key-value pairs.
      for (final entry in skill.config.entries) {
        controllers[entry.key] = TextEditingController(text: entry.value);
      }
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.tune),
                    const SizedBox(width: 10),
                    Text(
                      'Configure "${skill.skillId}"',
                      style: Theme.of(ctx).textTheme.titleLarge,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Credentials are stored encrypted on your atServer '
                  'and injected into the skill at invocation time. '
                  'They are never logged.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 20),
                if (fields != null)
                  ...fields.map(
                    (f) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: TextField(
                        controller: controllers[f.key],
                        obscureText: f.secret,
                        decoration: InputDecoration(
                          labelText: f.label,
                          hintText: f.hint,
                          border: const OutlineInputBorder(),
                          suffixIcon:
                              f.secret ? const Icon(Icons.lock_outline) : null,
                        ),
                      ),
                    ),
                  )
                else ...[
                  Text(
                    'No predefined fields for skill "${skill.skillId}". '
                    'Credentials will be passed as-is from the payload.',
                    style: Theme.of(ctx).textTheme.bodyMedium,
                  ),
                ],
                const SizedBox(height: 8),
                FilledButton.icon(
                  icon: const Icon(Icons.save),
                  label: const Text('Save'),
                  onPressed: () async {
                    final newConfig = <String, String>{};
                    for (final entry in controllers.entries) {
                      if (entry.value.text.isNotEmpty) {
                        newConfig[entry.key] = entry.value.text;
                      }
                    }
                    final updated = skill.copyWith(config: newConfig);
                    await ds.saveSkill(updated);
                    if (ctx.mounted) {
                      await SkillsScreen._syncSkillToAgent(ctx, updated);
                    }
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content:
                                Text('Config saved for "${skill.skillId}".')),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );

    for (final c in controllers.values) {
      c.dispose();
    }
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
// ─────────────────────────────────────────────────────────────────────────────

/// Describes a single named config field for a skill.
class _ConfigField {
  final String key;
  final String label;
  final String hint;
  final bool secret;

  const _ConfigField(this.key, this.label, this.hint, this.secret);
}
