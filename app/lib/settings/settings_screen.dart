/// SettingsScreen — configures agent atSign, LLM settings, and privacy preferences.
///
/// Settings are stored in SharedPreferences locally AND synced to an AtKey
/// on the owner's atServer (settings.app.pembrook@<owner>) so they survive
/// app reinstalls and sync across the owner's devices automatically.

import 'dart:convert';

import 'package:at_client/at_client.dart';
import 'package:at_client_flutter/at_client_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/navigation_drawer.dart';

import '../services/app_settings.dart';
import '../services/rpc_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _agentAtSignCtrl = TextEditingController(text: '@agent');
  double _privacyThreshold = 0.7;
  bool _localOnly = false;
  bool _streamingEnabled = true;
  double _fontScale = 1.0;

  static const String _namespace = 'pembrook';
  static const String _atKeyName = 'settings.app';

  /// Returns the AtClient if authenticated, or null.
  AtClient? get _atClient {
    try {
      return AtClientManager.getInstance().atClient;
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    // Read current font scale from the live AppSettings provider.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {
          _fontScale = context.read<AppSettings>().fontScale;
        });
      }
    });
    _loadPrefs();
  }

  @override
  void dispose() {
    _agentAtSignCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    // 1. Load from SharedPreferences as the fast/offline baseline.
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _agentAtSignCtrl.text = prefs.getString('agentAtSign') ?? '@agent';
      _privacyThreshold = prefs.getDouble('privacyThreshold') ?? 0.7;
      _localOnly = prefs.getBool('localOnly') ?? false;
      _streamingEnabled = prefs.getBool('streamingEnabled') ?? true;
    });

    // 2. Try to override from AtKey (survives reinstall; syncs across devices).
    final client = _atClient;
    if (client == null) return;
    try {
      final key = AtKey()
        ..key = _atKeyName
        ..namespace = _namespace;
      final atValue = await client.get(
        key,
        getRequestOptions: GetRequestOptions()..useRemoteAtServer = true,
      );
      if (atValue.value != null) {
        final data =
            jsonDecode(atValue.value as String) as Map<String, dynamic>;
        setState(() {
          _agentAtSignCtrl.text =
              data['agentAtSign'] as String? ?? _agentAtSignCtrl.text;
          _privacyThreshold = (data['privacyThreshold'] as num?)?.toDouble() ??
              _privacyThreshold;
          _localOnly = data['localOnly'] as bool? ?? _localOnly;
          _streamingEnabled =
              data['streamingEnabled'] as bool? ?? _streamingEnabled;
        });
        // Keep SharedPreferences in sync with AtKey values.
        await prefs.setString('agentAtSign', _agentAtSignCtrl.text);
        await prefs.setDouble('privacyThreshold', _privacyThreshold);
        await prefs.setBool('localOnly', _localOnly);
        await prefs.setBool('streamingEnabled', _streamingEnabled);
      }
    } catch (_) {
      // AtKey not available yet (e.g. first run) — SharedPreferences values stand.
    }
  }

  Future<void> _save() async {
    // 1. Persist to SharedPreferences immediately (offline-safe).
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agentAtSign', _agentAtSignCtrl.text.trim());
    await prefs.setDouble('privacyThreshold', _privacyThreshold);
    await prefs.setBool('localOnly', _localOnly);
    await prefs.setBool('streamingEnabled', _streamingEnabled);

    // 2. Sync to AtKey on owner's atServer (survives reinstall; cross-device).
    final client = _atClient;
    if (client != null) {
      try {
        final key = AtKey()
          ..key = _atKeyName
          ..namespace = _namespace
          ..metadata =
              (Metadata()..ttr = -1); // no time-to-refresh; always read live
        await client.put(
          key,
          jsonEncode({
            'agentAtSign': _agentAtSignCtrl.text.trim(),
            'privacyThreshold': _privacyThreshold,
            'localOnly': _localOnly,
            'streamingEnabled': _streamingEnabled,
            'savedAt': DateTime.now().toUtc().toIso8601String(),
          }),
          putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
        );
      } catch (_) {
        // AtKey write failure is non-fatal; SharedPreferences still saved.
      }
    }

    // 3. Notify RpcService so it recreates the AtRpcClient immediately.
    if (mounted) {
      await context
          .read<RpcService>()
          .updateAgentAtSign(_agentAtSignCtrl.text.trim());
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings saved')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 600;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      drawer: wide ? null : const AppNavigationDrawer(),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Agent ────────────────────────────────────────────
          _SectionHeader('Agent'),
          TextFormField(
            controller: _agentAtSignCtrl,
            decoration: const InputDecoration(
              labelText: 'Agent atSign',
              hintText: '@agent',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.smart_toy),
            ),
          ),
          const SizedBox(height: 24),

          // ── Privacy ──────────────────────────────────────────
          _SectionHeader('Privacy'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Privacy threshold'),
            subtitle: Text(
                'Queries with privacy score ≥ ${(_privacyThreshold * 100).toInt()}% '
                'go to local Ollama only'),
          ),
          Slider(
            value: _privacyThreshold,
            min: 0.0,
            max: 1.0,
            divisions: 10,
            label: '${(_privacyThreshold * 100).toInt()}%',
            onChanged: (v) => setState(() => _privacyThreshold = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Local LLM only'),
            subtitle: const Text('Never send queries to external LLMs'),
            value: _localOnly,
            onChanged: (v) => setState(() => _localOnly = v),
          ),
          const SizedBox(height: 16),

          // ── UI ───────────────────────────────────────────────
          _SectionHeader('Interface'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Theme'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.light,
                    icon: Icon(Icons.light_mode_outlined),
                    label: Text('Light'),
                  ),
                  ButtonSegment(
                    value: ThemeMode.system,
                    icon: Icon(Icons.brightness_auto_outlined),
                    label: Text('Auto'),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    icon: Icon(Icons.dark_mode_outlined),
                    label: Text('Dark'),
                  ),
                ],
                selected: {context.watch<AppSettings>().themeMode},
                onSelectionChanged: (s) =>
                    context.read<AppSettings>().setThemeMode(s.first),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Streaming responses'),
            subtitle: const Text('Show tokens as they arrive'),
            value: _streamingEnabled,
            onChanged: (v) => setState(() => _streamingEnabled = v),
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Font size'),
            subtitle: Text(
              _fontScale == 1.0
                  ? 'Normal (100%)'
                  : '${(_fontScale * 100).round()}%',
            ),
          ),
          Slider(
            value: _fontScale,
            min: 0.8,
            max: 1.6,
            divisions: 8,
            label: '${(_fontScale * 100).round()}%',
            onChanged: (v) {
              setState(() => _fontScale = v);
              context.read<AppSettings>().setFontScale(v);
            },
          ),
          const SizedBox(height: 24),

          // ── Access & Integrations ───────────────────────────
          const _SectionHeader('Access & Integrations'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.policy_outlined),
            title: const Text('Policy Rules'),
            subtitle: const Text('Manage allow/deny rules for agent actions'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/policy'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.hub_outlined),
            title: const Text('Bridges'),
            subtitle:
                const Text('Configure WhatsApp, Telegram, Discord, Slack'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/bridges'),
          ),
          const SizedBox(height: 16),

          // ── Account ──────────────────────────────────────────
          _SectionHeader('Account'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('Sign out', style: TextStyle(color: Colors.red)),
            onTap: _signOut,
          ),
        ],
      ),
    );
  }

  Future<void> _signOut() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
            'You will be signed out. Your keys remain on this device '
            'so you can sign back in at any time.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    // Reset in-memory RPC session state only.
    // Keys are intentionally kept in the keychain so the user can sign
    // back in without re-importing their .atKeys file.
    // ignore: use_build_context_synchronously
    context.read<RpcService>().signOut();
    // ignore: use_build_context_synchronously
    context.go('/auth');
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 1.2,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}
