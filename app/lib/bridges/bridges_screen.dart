/// BridgesScreen — configure messaging bridge tokens and secrets.
///
/// Stores bridge configuration as encrypted AtKeys on @owner, shared with
/// @agent, so the agent can supply credentials to bridge processes at startup:
///
///   `bridge.$platform.config.safeclaw@<ownerAtSign>` sharedWith `@agent`
///
/// Each bridge value is a JSON object with platform-specific fields.
/// The bridge processes read these via @agent at startup (or can use
/// the values injected as environment variables by the deployment script).
///
/// Platforms:
///   whatsapp  — token, appSecret, phoneNumberId
///   telegram  — botToken
///   discord   — botToken
///   slack     — botToken, signingSecret

import 'dart:convert';

import 'package:at_client/at_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ──────────────────────────────────────────────────────────────────────────────
//  MODEL
// ──────────────────────────────────────────────────────────────────────────────

class _BridgeDef {
  final String id;
  final String name;
  final IconData icon;
  final Color color;
  final List<_Field> fields;

  const _BridgeDef({
    required this.id,
    required this.name,
    required this.icon,
    required this.color,
    required this.fields,
  });
}

class _Field {
  final String key;
  final String label;
  final String hint;
  final bool secret;

  const _Field({
    required this.key,
    required this.label,
    required this.hint,
    this.secret = false,
  });
}

const _bridges = [
  _BridgeDef(
    id: 'whatsapp',
    name: 'WhatsApp',
    icon: Icons.chat_bubble_outline,
    color: Color(0xFF25D366),
    fields: [
      _Field(
        key: 'token',
        label: 'Cloud API Access Token',
        hint: 'EAAe...',
        secret: true,
      ),
      _Field(
        key: 'appSecret',
        label: 'App Secret (HMAC verification)',
        hint: 'hex string from Meta Developer portal',
        secret: true,
      ),
      _Field(
        key: 'phoneNumberId',
        label: 'Phone Number ID',
        hint: '1236547890',
      ),
    ],
  ),
  _BridgeDef(
    id: 'telegram',
    name: 'Telegram',
    icon: Icons.send_outlined,
    color: Color(0xFF229ED9),
    fields: [
      _Field(
        key: 'botToken',
        label: 'Bot Token',
        hint: '1234567890:AABBcc…  (from @BotFather)',
        secret: true,
      ),
    ],
  ),
  _BridgeDef(
    id: 'discord',
    name: 'Discord',
    icon: Icons.headset_mic_outlined,
    color: Color(0xFF5865F2),
    fields: [
      _Field(
        key: 'botToken',
        label: 'Bot Token',
        hint: 'MTA0NjA…  (Discord Developer Portal → Bot)',
        secret: true,
      ),
    ],
  ),
  _BridgeDef(
    id: 'slack',
    name: 'Slack',
    icon: Icons.workspaces_outlined,
    color: Color(0xFF4A154B),
    fields: [
      _Field(
        key: 'botToken',
        label: 'Bot OAuth Token',
        hint: 'xoxb-…',
        secret: true,
      ),
      _Field(
        key: 'signingSecret',
        label: 'Signing Secret',
        hint: 'From Slack App → Basic Information',
        secret: true,
      ),
    ],
  ),
];

// ──────────────────────────────────────────────────────────────────────────────
//  SCREEN
// ──────────────────────────────────────────────────────────────────────────────

class BridgesScreen extends StatelessWidget {
  const BridgesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bridges')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // Info banner
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Bridge tokens are stored as encrypted AtKeys and shared '
                      'with @agent. They are never sent in plaintext.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          ..._bridges.map(
            (b) => _BridgeCard(bridge: b),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
//  BRIDGE CARD
// ──────────────────────────────────────────────────────────────────────────────

class _BridgeCard extends StatefulWidget {
  final _BridgeDef bridge;

  const _BridgeCard({required this.bridge});

  @override
  State<_BridgeCard> createState() => _BridgeCardState();
}

class _BridgeCardState extends State<_BridgeCard> {
  static const String _namespace = 'safeclaw';

  late final Map<String, TextEditingController> _controllers;
  bool _expanded = false;
  bool _saving = false;
  bool _loading = true;
  bool _configured = false; // true if a non-empty config exists in AtKey

  AtClient? get _atClient {
    try {
      return AtClientManager.getInstance().atClient;
    } catch (_) {
      return null;
    }
  }

  String get _ownerAtSign =>
      _atClient?.getCurrentAtSign() ?? '@owner';

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final f in widget.bridge.fields)
        f.key: TextEditingController(),
    };
    _loadConfig();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ────────────────────────────────────────────────────────────────────────
  //  ATKEY HELPERS
  // ────────────────────────────────────────────────────────────────────────

  AtKey _makeKey() =>
      (AtKey.shared(
        'bridge.${widget.bridge.id}.config',
        namespace: _namespace,
        sharedBy: _ownerAtSign,
      )..sharedWith('@agent'))
          .build()
        ..metadata = (Metadata()..ttr = -1);

  Future<void> _loadConfig() async {
    setState(() => _loading = true);
    final client = _atClient;
    if (client == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final result = await client.get(
        _makeKey(),
        getRequestOptions: GetRequestOptions()..useRemoteAtServer = true,
      );
      final raw = result.value as String?;
      if (raw != null && raw.isNotEmpty) {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        for (final f in widget.bridge.fields) {
          _controllers[f.key]?.text = json[f.key] as String? ?? '';
        }
        // Configured = at least one non-empty field
        _configured =
            json.values.any((v) => v is String && v.isNotEmpty);
      }
    } catch (_) {
      // Key doesn't exist yet — that's fine
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _saveConfig() async {
    setState(() => _saving = true);
    final client = _atClient;
    if (client == null) {
      setState(() => _saving = false);
      return;
    }
    final json = {
      for (final f in widget.bridge.fields)
        f.key: _controllers[f.key]!.text.trim(),
    };
    try {
      await client.put(
        _makeKey(),
        jsonEncode(json),
        putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
      );
      final anyFilled = json.values.any((v) => v.isNotEmpty);
      setState(() {
        _saving = false;
        _configured = anyFilled;
        _expanded = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('${widget.bridge.name} config saved')),
        );
      }
    } catch (e) {
      setState(() => _saving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    }
  }

  Future<void> _clearConfig() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Clear ${widget.bridge.name} config?'),
        content: const Text('This will delete the stored tokens.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor:
                    Theme.of(context).colorScheme.error),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final client = _atClient;
    if (client == null) return;
    try {
      await client.delete(_makeKey());
      for (final c in _controllers.values) {
        c.clear();
      }
      setState(() => _configured = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('${widget.bridge.name} tokens cleared')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Clear failed: $e')),
        );
      }
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  //  BUILD
  // ────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final b = widget.bridge;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.hardEdge,
      child: Column(
        children: [
          // ── Header row ───────────────────────────────────────
          ListTile(
            onTap: () => setState(() => _expanded = !_expanded),
            leading: CircleAvatar(
              backgroundColor: b.color.withValues(alpha: 0.15),
              child: Icon(b.icon, color: b.color, size: 20),
            ),
            title: Text(b.name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: _loading
                ? const Text('Loading…')
                : Text(
                    _configured ? 'Configured ✓' : 'Not configured',
                    style: TextStyle(
                      color: _configured
                          ? Colors.green.shade600
                          : cs.outline,
                    ),
                  ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_configured)
                  IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: 'Clear tokens',
                    visualDensity: VisualDensity.compact,
                    onPressed: _clearConfig,
                  ),
                Icon(
                  _expanded
                      ? Icons.expand_less
                      : Icons.expand_more,
                  color: cs.outline,
                ),
              ],
            ),
          ),

          // ── Expanded fields ──────────────────────────────────
          if (_expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  ...b.fields.map(
                    (f) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _SecretField(
                        controller: _controllers[f.key]!,
                        label: f.label,
                        hint: f.hint,
                        isSecret: f.secret,
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () =>
                            setState(() => _expanded = false),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _saving ? null : _saveConfig,
                        child: _saving
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Text('Save'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
//  SECRET FIELD (password toggle + copy button)
// ──────────────────────────────────────────────────────────────────────────────

class _SecretField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final bool isSecret;

  const _SecretField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.isSecret,
  });

  @override
  State<_SecretField> createState() => _SecretFieldState();
}

class _SecretFieldState extends State<_SecretField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      obscureText: widget.isSecret && _obscure,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        border: const OutlineInputBorder(),
        isDense: true,
        suffixIcon: widget.isSecret
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off,
                        size: 20),
                    tooltip: _obscure ? 'Show' : 'Hide',
                    onPressed: () =>
                        setState(() => _obscure = !_obscure),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 20),
                    tooltip: 'Copy',
                    onPressed: () {
                      Clipboard.setData(
                          ClipboardData(text: widget.controller.text));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Copied to clipboard')),
                      );
                    },
                  ),
                ],
              )
            : null,
      ),
    );
  }
}
