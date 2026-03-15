/// PolicyEditorScreen — create or edit a single Pembrook policy.
///
/// A Policy is stored as JSON in the AtKey:
///   `policy.$policyId.pembrook@<ownerAtSign>` sharedWith `@agent`
///
/// The screen lets the owner:
///   - Set policyId, type, and priority
///   - Add, edit, and delete individual PolicyRule objects
///   - Preview the raw JSON before saving
///   - Save → atClient.put() to @agent

import 'dart:convert';

import 'package:at_client/at_client.dart';
import 'package:flutter/material.dart';

// Policy types must match agent/lib/models/policy.dart PolicyType enum values.
const _policyTypes = [
  'identity',
  'capability',
  'temporal',
  'risk',
  'dataFlow',
  'rateLimit',
];

const _ruleActions = ['allow', 'deny', 'escalate'];

// ──────────────────────────────────────────────────────────────────────────────

class PolicyEditorScreen extends StatefulWidget {
  /// If [policyId] is provided, the existing policy is loaded for editing.
  /// If null, a blank new policy is created.
  final String? policyId;

  const PolicyEditorScreen({super.key, this.policyId});

  @override
  State<PolicyEditorScreen> createState() => _PolicyEditorScreenState();
}

class _PolicyEditorScreenState extends State<PolicyEditorScreen> {
  static const String _namespace = 'pembrook';

  final _formKey = GlobalKey<FormState>();

  // Policy-level fields
  final _policyIdCtrl = TextEditingController();
  String _policyType = _policyTypes.first;
  final _priorityCtrl = TextEditingController(text: '100');

  // Rules list
  final List<_RuleForm> _rules = [];

  bool _loading = false;
  bool _saving = false;
  bool _showJson = false;
  String? _saveError;

  // ────────────────────────────────────────────────────────────────────────
  //  LIFECYCLE
  // ────────────────────────────────────────────────────────────────────────

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
    if (widget.policyId != null) {
      _policyIdCtrl.text = widget.policyId!;
      _loadExisting();
    } else {
      // Start with one blank rule for convenience
      _rules.add(_RuleForm());
    }
  }

  @override
  void dispose() {
    _policyIdCtrl.dispose();
    _priorityCtrl.dispose();
    for (final r in _rules) {
      r.dispose();
    }
    super.dispose();
  }

  // ────────────────────────────────────────────────────────────────────────
  //  LOAD EXISTING POLICY
  // ────────────────────────────────────────────────────────────────────────

  Future<void> _loadExisting() async {
    setState(() => _loading = true);
    final client = _atClient;
    if (client == null) {
      setState(() => _loading = false);
      return;
    }

    try {
      final key = (AtKey.shared(
        'policy.${widget.policyId!}',
        namespace: _namespace,
        sharedBy: _ownerAtSign,
      )..sharedWith('@agent'))
          .build();

      final result = await client.get(
        key,
        getRequestOptions: GetRequestOptions()..useRemoteAtServer = true,
      );
      final rawJson = result.value as String?;
      if (rawJson != null && rawJson.isNotEmpty) {
        final json = jsonDecode(rawJson) as Map<String, dynamic>;
        _populateFromJson(json);
      }
    } catch (_) {
      // Key may not exist if policyId was typed wrong; that's fine.
    } finally {
      setState(() => _loading = false);
    }
  }

  void _populateFromJson(Map<String, dynamic> json) {
    _policyIdCtrl.text = json['policyId'] as String? ?? widget.policyId ?? '';
    _policyType = json['policyType'] as String? ?? _policyTypes.first;
    _priorityCtrl.text = (json['priority'] as int? ?? 100).toString();

    final rulesJson = (json['rules'] as List<dynamic>?) ?? [];
    setState(() {
      _rules.clear();
      for (final r in rulesJson) {
        _rules.add(_RuleForm.fromJson(r as Map<String, dynamic>));
      }
      if (_rules.isEmpty) _rules.add(_RuleForm());
    });
  }

  // ────────────────────────────────────────────────────────────────────────
  //  BUILD JSON
  // ────────────────────────────────────────────────────────────────────────

  Map<String, dynamic> _toJson() => {
        'policyId': _policyIdCtrl.text.trim(),
        'policyType': _policyType,
        'rules': _rules.map((r) => r.toJson()).toList(),
        'priority': int.tryParse(_priorityCtrl.text.trim()) ?? 100,
        'createdBy': _ownerAtSign,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      };

  // ────────────────────────────────────────────────────────────────────────
  //  SAVE
  // ────────────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    _formKey.currentState!.save();

    setState(() {
      _saving = true;
      _saveError = null;
    });

    final client = _atClient;
    if (client == null) {
      setState(() {
        _saving = false;
        _saveError = 'Not authenticated';
      });
      return;
    }

    final policyId = _policyIdCtrl.text.trim();
    if (policyId.isEmpty) {
      setState(() {
        _saving = false;
        _saveError = 'Policy ID must not be empty.';
      });
      return;
    }

    try {
      final key = (AtKey.shared(
        'policy.$policyId',
        namespace: _namespace,
        sharedBy: _ownerAtSign,
      )..sharedWith('@agent'))
          .build()
        ..metadata = (Metadata()..ttr = -1);

      await client.put(
        key,
        jsonEncode(_toJson()),
        putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
      );

      setState(() => _saving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Policy "$policyId" saved')),
        );
        Navigator.of(context).pop(true); // true = list should refresh
      }
    } catch (e) {
      setState(() {
        _saving = false;
        _saveError = e.toString();
      });
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  //  BUILD
  // ────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.policyId == null ? 'New Policy' : 'Edit Policy'),
        actions: [
          IconButton(
            icon: Icon(_showJson ? Icons.list_alt : Icons.code),
            tooltip: _showJson ? 'Form view' : 'JSON preview',
            onPressed: () => setState(() => _showJson = !_showJson),
          ),
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _showJson
              ? _JsonPreview(jsonMap: _toJson())
              : _FormBody(
                  formKey: _formKey,
                  policyIdCtrl: _policyIdCtrl,
                  policyType: _policyType,
                  onTypeChanged: (t) => setState(() => _policyType = t),
                  priorityCtrl: _priorityCtrl,
                  rules: _rules,
                  onAddRule: () => setState(() => _rules.add(_RuleForm())),
                  onRemoveRule: (i) => setState(() {
                    _rules[i].dispose();
                    _rules.removeAt(i);
                  }),
                  onRulesChanged: () => setState(() {}),
                  saveError: _saveError,
                ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
//  FORM BODY
// ──────────────────────────────────────────────────────────────────────────────

class _FormBody extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController policyIdCtrl;
  final String policyType;
  final ValueChanged<String> onTypeChanged;
  final TextEditingController priorityCtrl;
  final List<_RuleForm> rules;
  final VoidCallback onAddRule;
  final void Function(int index) onRemoveRule;
  final VoidCallback onRulesChanged;
  final String? saveError;

  const _FormBody({
    required this.formKey,
    required this.policyIdCtrl,
    required this.policyType,
    required this.onTypeChanged,
    required this.priorityCtrl,
    required this.rules,
    required this.onAddRule,
    required this.onRemoveRule,
    required this.onRulesChanged,
    this.saveError,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Form(
      key: formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Policy metadata ──────────────────────────────────
          const _SectionHeader('Policy'),
          TextFormField(
            controller: policyIdCtrl,
            decoration: const InputDecoration(
              labelText: 'Policy ID',
              hintText: 'e.g. block_external_skills',
              border: OutlineInputBorder(),
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Required' : null,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _policyTypes.contains(policyType)
                ? policyType
                : _policyTypes.first,
            decoration: const InputDecoration(
              labelText: 'Policy Type',
              border: OutlineInputBorder(),
            ),
            items: _policyTypes
                .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                .toList(),
            onChanged: (v) {
              if (v != null) onTypeChanged(v);
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: priorityCtrl,
            decoration: const InputDecoration(
              labelText: 'Priority',
              hintText: '100',
              helperText: 'Lower values are evaluated first',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            validator: (v) =>
                int.tryParse(v ?? '') == null ? 'Must be a number' : null,
          ),
          const SizedBox(height: 24),

          // ── Rules ────────────────────────────────────────────
          Row(
            children: [
              const Expanded(child: _SectionHeader('Rules')),
              TextButton.icon(
                onPressed: onAddRule,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Rule'),
              ),
            ],
          ),
          if (rules.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No rules — tap "Add Rule" to begin.',
                style: TextStyle(color: cs.outline),
              ),
            ),
          ...rules.asMap().entries.map(
                (e) => _RuleCard(
                  key: ObjectKey(e.value),
                  index: e.key,
                  rule: e.value,
                  onRemove: () => onRemoveRule(e.key),
                  onChanged: onRulesChanged,
                ),
              ),

          // ── Error ────────────────────────────────────────────
          if (saveError != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.error, color: cs.onErrorContainer, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      saveError!,
                      style: TextStyle(color: cs.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
//  RULE CARD
// ──────────────────────────────────────────────────────────────────────────────

class _RuleCard extends StatefulWidget {
  final int index;
  final _RuleForm rule;
  final VoidCallback onRemove;
  final VoidCallback onChanged;

  const _RuleCard({
    super.key,
    required this.index,
    required this.rule,
    required this.onRemove,
    required this.onChanged,
  });

  @override
  State<_RuleCard> createState() => _RuleCardState();
}

class _RuleCardState extends State<_RuleCard> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rule = widget.rule;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                Text(
                  'Rule ${widget.index + 1}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.delete_outline, color: cs.error, size: 20),
                  tooltip: 'Remove rule',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onRemove,
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Rule ID
            TextFormField(
              controller: rule.idCtrl,
              decoration: const InputDecoration(
                labelText: 'Rule ID',
                hintText: 'e.g. deny_unknown_skills',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 8),

            // Description
            TextFormField(
              controller: rule.descCtrl,
              decoration: const InputDecoration(
                labelText: 'Description',
                hintText: 'Human-readable explanation of this rule',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),

            // Action dropdown
            DropdownButtonFormField<String>(
              value: _ruleActions.contains(rule.action)
                  ? rule.action
                  : _ruleActions.first,
              decoration: const InputDecoration(
                labelText: 'Action',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: _ruleActions
                  .map((a) => DropdownMenuItem(value: a, child: Text(a)))
                  .toList(),
              onChanged: (v) {
                if (v != null) {
                  setState(() => rule.action = v);
                  widget.onChanged();
                }
              },
            ),
            const SizedBox(height: 8),

            // Condition JSON
            TextFormField(
              controller: rule.conditionCtrl,
              decoration: const InputDecoration(
                labelText: 'Condition (JSON)',
                hintText: '{"actionType": "skill.invoke"}',
                helperText: 'Leave {} for a catch-all rule',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              maxLines: 3,
              validator: (v) {
                if (v == null || v.trim().isEmpty) return null;
                try {
                  jsonDecode(v);
                  return null;
                } catch (_) {
                  return 'Invalid JSON';
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
//  JSON PREVIEW
// ──────────────────────────────────────────────────────────────────────────────

class _JsonPreview extends StatelessWidget {
  final Map<String, dynamic> jsonMap;

  const _JsonPreview({required this.jsonMap});

  @override
  Widget build(BuildContext context) {
    final pretty = const JsonEncoder.withIndent('  ').convert(jsonMap);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        pretty,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.5,
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
//  RULE FORM (mutable state for each rule in the editor)
// ──────────────────────────────────────────────────────────────────────────────

class _RuleForm {
  final TextEditingController idCtrl;
  final TextEditingController descCtrl;
  final TextEditingController conditionCtrl;
  String action;

  _RuleForm({
    String id = '',
    String description = '',
    this.action = 'deny',
    String condition = '{}',
  })  : idCtrl = TextEditingController(text: id),
        descCtrl = TextEditingController(text: description),
        conditionCtrl = TextEditingController(text: condition);

  factory _RuleForm.fromJson(Map<String, dynamic> json) {
    return _RuleForm(
      id: json['ruleId'] as String? ?? '',
      description: json['description'] as String? ?? '',
      action: json['action'] as String? ?? 'deny',
      condition: jsonEncode(json['condition'] ?? {}),
    );
  }

  Map<String, dynamic> toJson() {
    dynamic conditionValue;
    try {
      conditionValue = jsonDecode(conditionCtrl.text.trim());
    } catch (_) {
      conditionValue = <String, dynamic>{};
    }
    return {
      'ruleId': idCtrl.text.trim(),
      'description': descCtrl.text.trim(),
      'action': action,
      'condition': conditionValue,
    };
  }

  void dispose() {
    idCtrl.dispose();
    descCtrl.dispose();
    conditionCtrl.dispose();
  }
}

// ──────────────────────────────────────────────────────────────────────────────
//  SHARED WIDGET
// ──────────────────────────────────────────────────────────────────────────────

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
