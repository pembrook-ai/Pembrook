import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/rpc_service.dart';

/// Shared navigation drawer for mobile screens.
/// Shows all top-level routes and a sign-out option.
class AppNavigationDrawer extends StatelessWidget {
  const AppNavigationDrawer({super.key});

  Future<void> _signOut(BuildContext context) async {
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
    if (confirm != true || !context.mounted) return;
    // ignore: use_build_context_synchronously
    context.read<RpcService>().signOut();
    // ignore: use_build_context_synchronously
    if (context.mounted) context.go('/auth');
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: ListView(
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Icon(Icons.security,
                    size: 40,
                    color: Theme.of(context).colorScheme.onPrimaryContainer),
                const SizedBox(height: 8),
                Text('Pembrook',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.bold,
                        )),
                Text('Secure AI Agent',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onPrimaryContainer,
                        )),
              ],
            ),
          ),
          _DrawerItem(Icons.chat, 'Chat', '/home'),
          _DrawerItem(Icons.history, 'History', '/history'),
          _DrawerItem(Icons.article, 'Audit Log', '/audit'),
          _DrawerItem(Icons.extension, 'Skills', '/skills'),
          _DrawerItem(Icons.pending_actions, 'Approvals', '/hitl'),
          _DrawerItem(Icons.link, 'Bridges', '/bridges'),
          _DrawerItem(Icons.policy, 'Policies', '/policy'),
          const Divider(),
          _DrawerItem(Icons.settings, 'Settings', '/settings'),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('Sign out', style: TextStyle(color: Colors.red)),
            onTap: () {
              Navigator.pop(context);
              _signOut(context);
            },
          ),
        ],
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String route;

  const _DrawerItem(this.icon, this.label, this.route);

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      onTap: () {
        Navigator.pop(context);
        context.go(route);
      },
    );
  }
}
