/// AuthScreen — atSign onboarding and login.
///
/// Supports all four at_client_flutter auth workflows (per ATPLATFORM_GUIDELINES.md):
///   1. Login from Keychain  → returning user, keys already on this device
///   2. Activate new atSign  → first-time registration via Registrar (CRAM, no QR code)
///   3. APKAM enrollment     → app-level key management for a new device
///   4. Import .atKeys file  → cross-device key transfer via exported key file
///
/// NOTE: QR code activation is NOT supported — it belongs to the deprecated
///   at_onboarding_flutter package. Use the Registrar (CRAM) flow instead.
///
/// After successful auth:
///   - AtClientManager.setCurrentAtSign() is called.
///   - RpcService is initialised with the authenticated AtClient.
///   - Route pushed to /home.

import 'dart:io';

import 'package:at_auth/at_auth.dart';
import 'package:at_client_flutter/at_client_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../services/data_service.dart';
import '../services/rpc_service.dart';

// Keep enum/class available for any other references.
export 'walkthrough.dart' show AuthWorkflow;

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  static const String _namespace = 'pembrook';
  static const _rootDomain = AtRootDomain.atsignDomain;

  List<String> _keychainAtSigns = [];
  String? _selectedAtSign;
  bool _loading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadKeychainAtSigns();
  }

  Future<void> _loadKeychainAtSigns() async {
    final storage = KeychainStorage();
    final atSigns = await storage.getAllAtsigns();
    if (mounted) {
      setState(() {
        _keychainAtSigns = atSigns;
        _selectedAtSign = atSigns.isNotEmpty ? atSigns.first : null;
      });
    }
  }

  void _setLoading(bool v) {
    if (mounted) setState(() => _loading = v);
  }

  void _setError(String? v) {
    if (mounted) setState(() => _errorMessage = v);
  }

  // ══════════════════════════════════════════════════════
  //  Keychain login (returning user)
  // ══════════════════════════════════════════════════════

  Future<void> _keychainFlow() async {
    final atSign = _selectedAtSign;
    if (atSign == null) return;

    _setLoading(true);
    _setError(null);
    try {
      final request = AtAuthRequest(
        atSign,
        rootDomain: _rootDomain,
        atKeysIo: KeychainAtKeysIo(),
      );

      if (!mounted) return;
      // ignore: use_build_context_synchronously
      final response = await PkamDialog.show(context,
          request: request, backupKeys: [KeychainAtKeysIo()]);
      if (response == null || !response.isSuccessful) return;

      await _finishAuth(response);
    } catch (e) {
      _setError('Login error: $e');
    } finally {
      _setLoading(false);
    }
  }

  // ══════════════════════════════════════════════════════
  //  Registrar CRAM (activate a brand-new atSign)
  // ══════════════════════════════════════════════════════

  Future<void> _registrarFlow() async {
    _setLoading(true);
    _setError(null);
    try {
      if (!mounted) return;
      // ignore: use_build_context_synchronously
      final authRequest = await AtSignSelectionDialog.show(context);
      if (authRequest == null) return;

      final request = AtOnboardingRequest(
        authRequest.atSign,
        rootDomain: authRequest.rootDomain,
        atKeysIo: KeychainAtKeysIo(),
      );

      if (!mounted) return;
      // ignore: use_build_context_synchronously
      final cramKey = await RegistrarCramDialog.show(
        context,
        request,
        registrar: RegistrarService(
          registrarUrl: 'my.atsign.com',
          apiKey: 'at_prod_1dcbe8e7-0672-4ff0-ab2b-53d8f4aebfc2',
        ),
      );
      if (cramKey == null) return;

      if (!mounted) return;
      // ignore: use_build_context_synchronously
      final response =
          await CramDialog.show(context, request: request, cramKey: cramKey);
      if (response == null || !response.isSuccessful) return;

      await _finishAuth(response);
    } catch (e) {
      _setError('Activation error: $e');
    } finally {
      _setLoading(false);
    }
  }

  // ══════════════════════════════════════════════════════
  //  .atKeys file
  // ══════════════════════════════════════════════════════

  Future<void> _atKeysFileFlow() async {
    _setLoading(true);
    _setError(null);
    try {
      if (!mounted) return;
      // ignore: use_build_context_synchronously
      final fileAtKeysIo = await AtKeysFileDialog.show(context);
      if (fileAtKeysIo == null) return;

      final filepath = fileAtKeysIo.filePath!('');
      final parts = filepath.split(Platform.pathSeparator).last;
      final atSign = parts.split('_').first;

      final request = AtAuthRequest(
        atSign,
        rootDomain: _rootDomain,
        atKeysIo: fileAtKeysIo,
      );

      if (!mounted) return;
      // ignore: use_build_context_synchronously
      final response = await PkamDialog.show(context,
          request: request, backupKeys: [KeychainAtKeysIo()]);
      if (response == null || !response.isSuccessful) return;

      await _finishAuth(response);
    } catch (e) {
      _setError('Import error: $e');
    } finally {
      _setLoading(false);
    }
  }

  // ══════════════════════════════════════════════════════
  //  APKAM
  // ══════════════════════════════════════════════════════

  Future<void> _apkamFlow() async {
    _setLoading(true);
    _setError(null);
    try {
      if (!mounted) return;
      // ignore: use_build_context_synchronously
      final authRequest = await AtSignSelectionDialog.show(context);
      if (authRequest == null) return;

      if (!mounted) return;
      // ignore: use_build_context_synchronously
      final enroll = await ApkamActivationDialog.show(
        context,
        atSign: authRequest.atSign,
        rootDomain: authRequest.rootDomain,
        appName: 'pembrook',
        deviceName: 'phone',
        namespaces: {'pembrook': 'rw'},
      );
      if (enroll == null || enroll.atAuthKeys == null) return;

      final request = AtAuthRequest(
        authRequest.atSign,
        rootDomain: authRequest.rootDomain,
        atAuthKeys: enroll.atAuthKeys,
      );

      if (!mounted) return;
      // ignore: use_build_context_synchronously
      final response = await PkamDialog.show(context,
          request: request, backupKeys: [KeychainAtKeysIo()]);
      if (response == null || !response.isSuccessful) return;

      await _finishAuth(response);
    } catch (e) {
      _setError('APKAM error: $e');
    } finally {
      _setLoading(false);
    }
  }

  // ══════════════════════════════════════════════════════
  //  COMMON: finish authentication
  // ══════════════════════════════════════════════════════

  Future<void> _finishAuth(AuthResponse response) async {
    // Each launch gets its own unique subdirectory under the system temp folder.
    // This means multiple app instances never share a Hive lock, and the OS
    // cleans up the temp data automatically on reboot.
    final tmp = await getTemporaryDirectory();
    final instanceId = DateTime.now().millisecondsSinceEpoch;
    final storageDir =
        Directory('${tmp.path}/pembrook_${response.atSign}_$instanceId');
    await storageDir.create(recursive: true);

    final pref = AtClientPreference()
      ..rootDomain = _rootDomain.rootDomain
      ..namespace = _namespace
      ..hiveStoragePath = storageDir.path
      ..commitLogPath = storageDir.path
      ..isLocalStoreRequired = true;

    await AtClientManager.getInstance().setCurrentAtSign(
      response.atSign,
      _namespace,
      pref,
      enrollmentId: response.enrollmentId,
      atChops: response.atChops,
      atLookUp: response.atLookUp,
    );

    if (!mounted) return;
    final atClient = AtClientManager.getInstance().atClient;
    // ignore: use_build_context_synchronously
    await context.read<RpcService>().initialise(atClient);

    // Navigate immediately — the chat screen is usable as soon as the RPC
    // client is ready.  DataService (audit, HITL, skills) and ConversationStore
    // both make multiple remote-server calls that can take several seconds;
    // running them in the background means the user is never stuck staring at
    // the auth spinner waiting for data they may not immediately need.
    if (!mounted) return;
    // Capture provider references before go() tears down the auth route.
    // ignore: use_build_context_synchronously
    final dataService = context.read<DataService>();
    // ignore: use_build_context_synchronously
    final convStore = context.read<ConversationStore>();
    // ignore: use_build_context_synchronously
    context.go('/home');

    // Background init — providers notifyListeners() as each finishes so the
    // UI updates automatically once the data arrives.
    dataService.initialise(atClient).ignore();
    convStore.initialise(atClient).ignore();
  }

  // ══════════════════════════════════════════════════════
  //  Build
  // ══════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Icon(
                Icons.security,
                size: 80,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'Pembrook',
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Your private AI agent — end-to-end encrypted.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const Spacer(),

              // ── Error banner ─────────────────────────────────────────────
              if (_errorMessage != null) ...[
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // ── Loading indicator ─────────────────────────────────────────
              if (_loading) ...[
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 12),
              ],

              // ── 1. Login from Keychain ─────────────────────────────────
              if (_keychainAtSigns.isEmpty)
                _AuthButton(
                  icon: Icons.lock_open,
                  label: 'Login from Keychain',
                  subtitle: 'No atSigns found on this device',
                  enabled: false,
                  onTap: () {},
                )
              else
                Card(
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        Icon(Icons.lock_open,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 16),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            value: _selectedAtSign,
                            decoration: const InputDecoration(
                              labelText: 'Login from Keychain',
                              border: InputBorder.none,
                              isDense: true,
                            ),
                            items: _keychainAtSigns
                                .map((s) => DropdownMenuItem(
                                      value: s,
                                      child: Text(s),
                                    ))
                                .toList(),
                            onChanged: _loading
                                ? null
                                : (v) => setState(() => _selectedAtSign = v),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _loading ? null : _keychainFlow,
                          child: const Text('Login'),
                        ),
                      ],
                    ),
                  ),
                ),

              const SizedBox(height: 12),

              // ── 2. Activate new atSign ───────────────────────────────────
              _AuthButton(
                icon: Icons.person_add,
                label: 'Activate new atSign',
                subtitle: 'First-time setup via my.atsign.com',
                enabled: !_loading,
                onTap: _registrarFlow,
              ),
              const SizedBox(height: 12),

              // ── 3. APKAM enrolment ───────────────────────────────────────
              _AuthButton(
                icon: Icons.phonelink_setup,
                label: 'APKAM — new device enrolment',
                subtitle: 'Approve this device from another authorised device',
                enabled: !_loading,
                onTap: _apkamFlow,
              ),
              const SizedBox(height: 12),

              // ── 4. Import .atKeys file ───────────────────────────────────
              _AuthButton(
                icon: Icons.upload_file,
                label: 'Import .atKeys file',
                subtitle: 'Use an exported key file backup',
                enabled: !_loading,
                onTap: _atKeysFileFlow,
              ),

              const Spacer(),

              Text(
                'If you need an Atsign.\nGet one at my.atsign.com',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuthButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  const _AuthButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        enabled: enabled,
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: enabled ? onTap : null,
      ),
    );
  }
}
