/// AuthWalkthrough — implements all four at_client_flutter auth flows.
///
/// SUPPORTED WORKFLOWS (AuthWorkflow enum):
///
///   keychain   → Login from Keychain (returning user, keys on this device)
///   registrar  → Activate new atSign via Registrar CRAM (no QR code)
///   atKeysFile → Import .atKeys backup file
///   apkam      → APKAM enrolment for a new device
///
/// After any successful auth:
///   1. AtClientManager.getInstance().setCurrentAtSign() is called.
///   2. RpcService.initialise(atClient) is called so the app can talk to @agent.
///   3. Navigation is pushed to /home.
///
/// Uses at_client_flutter 1.0.x static .show() dialog API.
/// QR code activation is NOT offered — see ATPLATFORM_GUIDELINES.md.

import 'dart:io';

import 'dart:io';

import 'package:at_auth/at_auth.dart';
import 'package:at_client_flutter/at_client_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../services/data_service.dart';

import '../services/rpc_service.dart';

enum AuthWorkflow { keychain, registrar, atKeysFile, apkam }

class AuthWalkthrough extends StatefulWidget {
  final AuthWorkflow workflow;

  const AuthWalkthrough({super.key, required this.workflow});

  @override
  State<AuthWalkthrough> createState() => _AuthWalkthroughState();
}

class _AuthWalkthroughState extends State<AuthWalkthrough> {
  bool _loading = false;
  String? _errorMessage;

  static const String _namespace = 'pembrook';
  static const _rootDomain = AtRootDomain.atsignDomain;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_workflowTitle()),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              if (_errorMessage != null) ...[
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onErrorContainer),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else
                ElevatedButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: Text('Start ${_workflowTitle()}'),
                  onPressed: _run,
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _workflowTitle() {
    switch (widget.workflow) {
      case AuthWorkflow.keychain:
        return 'Login from Keychain';
      case AuthWorkflow.registrar:
        return 'Activate new atSign';
      case AuthWorkflow.atKeysFile:
        return 'Import .atKeys File';
      case AuthWorkflow.apkam:
        return 'APKAM — New Device Enrolment';
    }
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      await _runWorkflow();
    } catch (e) {
      setState(() {
        _errorMessage = 'Authentication error: $e';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _runWorkflow() async {
    switch (widget.workflow) {
      case AuthWorkflow.keychain:
        await _keychainFlow();
        break;
      case AuthWorkflow.registrar:
        await _registrarFlow();
        break;
      case AuthWorkflow.atKeysFile:
        await _atKeysFileFlow();
        break;
      case AuthWorkflow.apkam:
        await _apkamFlow();
        break;
    }
  }

  // ══════════════════════════════════════════════════════
  //  Registrar CRAM (activate a brand-new atSign)
  //  Reference: ATPLATFORM_GUIDELINES.md workflow 2
  // ══════════════════════════════════════════════════════

  Future<void> _registrarFlow() async {
    if (!mounted) return;
    // Step 1: Let the user enter / select their atSign.
    final authRequest = await AtSignSelectionDialog.show(context);
    if (authRequest == null) return;

    final request = AtOnboardingRequest(
      authRequest.atSign,
      rootDomain: authRequest.rootDomain,
      atKeysIo: KeychainAtKeysIo(),
    );

    // Step 2: Fetch CRAM key from registrar.
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

    // Step 3: Perform CRAM onboarding.
    if (!mounted) return;
    // ignore: use_build_context_synchronously
    final response =
        await CramDialog.show(context, request: request, cramKey: cramKey);
    if (response == null || !response.isSuccessful) return;

    await _finishAuth(response);
  }

  // ══════════════════════════════════════════════════════
  //  .atKeys file
  // ══════════════════════════════════════════════════════

  Future<void> _atKeysFileFlow() async {
    if (!mounted) return;
    // Step 1: Let the user pick a .atKeys file.
    // ignore: use_build_context_synchronously
    final fileAtKeysIo = await AtKeysFileDialog.show(context);
    if (fileAtKeysIo == null) return;

    // Step 2: Extract atSign from the filename e.g. "@alice_key.atKeys".
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
  }

  // ══════════════════════════════════════════════════════
  //  APKAM
  // ══════════════════════════════════════════════════════

  Future<void> _apkamFlow() async {
    if (!mounted) return;
    final authRequest = await AtSignSelectionDialog.show(context);
    if (authRequest == null) return;

    if (!mounted) return;
    // Step 2: Start APKAM enrollment.
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

    // Step 3: Build auth request from enrollment keys and authenticate.
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
  }

  // ══════════════════════════════════════════════════════
  //  Keychain login (returning user)
  //  Reference: ATPLATFORM_GUIDELINES.md workflow 1
  // ══════════════════════════════════════════════════════

  Future<void> _keychainFlow() async {
    if (!mounted) return;
    final keychainStorage = KeychainStorage();
    final atSigns = await keychainStorage.getAllAtsigns();

    // ignore: use_build_context_synchronously
    final authRequest = await AtSignSelectionDialog.show(
      context,
      existingDomains: {
        for (final s in atSigns) s: _rootDomain,
      },
    );
    if (authRequest == null) return;

    final request = AtAuthRequest(
      authRequest.atSign,
      rootDomain: authRequest.rootDomain,
      atKeysIo: KeychainAtKeysIo(),
    );

    if (!mounted) return;
    // ignore: use_build_context_synchronously
    final response = await PkamDialog.show(context,
        request: request, backupKeys: [KeychainAtKeysIo()]);
    if (response == null || !response.isSuccessful) return;

    await _finishAuth(response);
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
    // ignore: use_build_context_synchronously
    await context.read<DataService>().initialise(atClient);
    // ignore: use_build_context_synchronously
    // Migrate conversation history from SharedPreferences → AtKey and load
    // the latest from the remote atServer so multi-device sync works.
    await context.read<ConversationStore>().initialise(atClient);
    // ignore: use_build_context_synchronously
    context.go('/home');
  }
}
