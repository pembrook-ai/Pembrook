/// AuthScreen — atSign onboarding and login.
///
/// Supports all four at_client_flutter auth workflows:
///   1. QR Code / CRAM      → first-time activation on new device
///   2. .atKeys file upload → cross-device key transfer
///   3. APKAM activation    → app-level key management (recommended)
///   4. PKAM (legacy)       → direct private key authentication
///
/// After successful auth:
///   - AtClientManager.setCurrentAtSign() is called.
///   - RpcService is initialised with the authenticated AtClient.
///   - Route pushed to /home.

import 'package:at_client_flutter/at_client_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../services/rpc_service.dart';
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
                'SafeClaw',
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

              // ── Auth workflow buttons ────────────────────────────────────
              _AuthButton(
                icon: Icons.phonelink_setup,
                label: 'Activate with QR Code',
                subtitle: 'First-time setup on a new device',
                onTap: () => _startAuth(context, AuthWorkflow.qrCode),
              ),
              const SizedBox(height: 12),
              _AuthButton(
                icon: Icons.upload_file,
                label: 'Upload .atKeys file',
                subtitle: 'Use an exported key file',
                onTap: () => _startAuth(context, AuthWorkflow.atKeysFile),
              ),
              const SizedBox(height: 12),
              _AuthButton(
                icon: Icons.vpn_key,
                label: 'APKAM Activation',
                subtitle: 'App-level key management (recommended)',
                onTap: () => _startAuth(context, AuthWorkflow.apkam),
              ),
              const SizedBox(height: 12),
              _AuthButton(
                icon: Icons.key,
                label: 'PKAM (Legacy)',
                subtitle: 'Direct private key authentication',
                onTap: () => _startAuth(context, AuthWorkflow.pkam),
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
