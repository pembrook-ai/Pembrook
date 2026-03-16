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

import 'package:flutter/material.dart';

import 'walkthrough.dart';

class AuthScreen extends StatelessWidget {
  const AuthScreen({super.key});

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

              // ── Auth workflow buttons (per ATPLATFORM_GUIDELINES.md) ────
              // 1. Returning user — keys already stored on this device.
              _AuthButton(
                icon: Icons.lock_open,
                label: 'Login from Keychain',
                subtitle: 'Use an atSign already on this device',
                onTap: () => _startAuth(context, AuthWorkflow.keychain),
              ),
              const SizedBox(height: 12),
              // 2. First-time activation of a brand-new atSign via registrar.
              _AuthButton(
                icon: Icons.person_add,
                label: 'Activate new atSign',
                subtitle: 'First-time setup via my.atsign.com',
                onTap: () => _startAuth(context, AuthWorkflow.registrar),
              ),
              const SizedBox(height: 12),
              // 3. Enrol this app on a new device (requires approval on
              //    an already-authorised device).
              _AuthButton(
                icon: Icons.phonelink_setup,
                label: 'APKAM — new device enrolment',
                subtitle: 'Approve this device from another authorised device',
                onTap: () => _startAuth(context, AuthWorkflow.apkam),
              ),
              const SizedBox(height: 12),
              // 4. Import a previously exported .atKeys backup file.
              _AuthButton(
                icon: Icons.upload_file,
                label: 'Import .atKeys file',
                subtitle: 'Use an exported key file backup',
                onTap: () => _startAuth(context, AuthWorkflow.atKeysFile),
              ),

              const Spacer(),

              // ── atSign info ──────────────────────────────────────────────
              Text(
                'You need a provisioned @owner atSign.\nGet one free at my.atsign.com',
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

  void _startAuth(BuildContext context, AuthWorkflow workflow) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AuthWalkthrough(workflow: workflow),
      ),
    );
  }
}

class _AuthButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  const _AuthButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
