/// Pembrook Flutter App — entry point.
///
/// Architecture:
///   - All backend communication via AtRpc calls to @agent's atSign.
///   - No open ports. No server URLs. No direct network calls.
///   - User preferences, audit log, and conversation history are
///     all AtKeys — read/written via the at_client SDK.
///
/// Authentication (at_client_flutter):
///   - First run: full onboarding via AtOnboarding or AtKeysFileDialog.
///   - Subsequent runs: auto-login via stored keys in platform keychain.
///
/// Routing (go_router):
///   /           → SplashScreen (checks auth state)
///   /auth       → AuthScreen (onboarding / key upload)
///   /home       → ChatScreen (main chat UI)           ┐
///   /audit      → AuditScreen (audit log viewer)      │ wrapped in
///   /settings   → SettingsScreen (preferences)        │ ShellRoute →
///   /skills     → SkillsScreen (installed skills)     │ AppShell
///   /hitl       → HitlScreen (pending HITL approvals) │ (NavigationRail
///   /policy     → PolicyListScreen (policy manager)   │  on desktop,
///   /bridges    → BridgesScreen (bridge config)       ┘  Drawer on mobile)
///
/// Desktop navigation:
///   AppShell shows a persistent NavigationRail (width ≥ 600) so users
///   can move between sections without a physical/gesture back button.
///   On narrow screens the existing hamburger Drawer is used instead.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'auth/auth_screen.dart';
import 'bridges/bridges_screen.dart';
import 'chat/chat_screen.dart';
import 'chat/chat_history_screen.dart';
import 'audit/audit_screen.dart';
import 'policy/policy_list_screen.dart';
import 'settings/settings_screen.dart';
import 'skills/skills_screen.dart';
import 'hitl/hitl_screen.dart';
import 'services/app_settings.dart';
import 'services/rpc_service.dart';
import 'services/data_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PembrookApp());
}

final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const SplashScreen(),
    ),
    GoRoute(
      path: '/auth',
      builder: (context, state) => const AuthScreen(),
    ),
    // ── Main app shell — persistent NavigationRail on desktop ─────────────
    ShellRoute(
      builder: (context, state, child) =>
          AppShell(location: state.uri.path, child: child),
      routes: [
        GoRoute(
          path: '/home',
          builder: (context, state) => const ChatScreen(),
        ),
        GoRoute(
          path: '/audit',
          builder: (context, state) => const AuditScreen(),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const SettingsScreen(),
        ),
        GoRoute(
          path: '/skills',
          builder: (context, state) => const SkillsScreen(),
        ),
        GoRoute(
          path: '/hitl',
          builder: (context, state) => const HitlScreen(),
        ),
        GoRoute(
          path: '/policy',
          builder: (context, state) => const PolicyListScreen(),
        ),
        GoRoute(
          path: '/bridges',
          builder: (context, state) => const BridgesScreen(),
        ),
        GoRoute(
          path: '/history',
          builder: (context, state) => const ChatHistoryScreen(),
        ),
      ],
    ),
  ],
);

// ─────────────────────────────────────────────────────────────────────────────
// AppShell — persistent navigation wrapper.
//
// Wide screens (≥ 600 px):
//   Renders a NavigationRail on the left so the user can always switch
//   between sections without needing a physical or gesture back button.
//   The child (current route) fills the remaining width.
//
// Narrow screens (< 600 px):
//   Returns the child unchanged.  ChatScreen provides a Drawer; other
//   screens rely on the OS back button / gesture (mobile).
// ─────────────────────────────────────────────────────────────────────────────

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  // Ordered list of top-level destinations shown in the NavigationRail.
  static const _dests = [
    (
      icon: Icons.chat_outlined,
      activeIcon: Icons.chat,
      label: 'Chat',
      route: '/home'
    ),
    (
      icon: Icons.article_outlined,
      activeIcon: Icons.article,
      label: 'Audit',
      route: '/audit'
    ),
    (
      icon: Icons.extension_outlined,
      activeIcon: Icons.extension,
      label: 'Skills',
      route: '/skills'
    ),
    (
      icon: Icons.pending_actions_outlined,
      activeIcon: Icons.pending_actions,
      label: 'Approvals',
      route: '/hitl'
    ),
    (
      icon: Icons.settings_outlined,
      activeIcon: Icons.settings,
      label: 'Settings',
      route: '/settings'
    ),
  ];

  int get _selectedIndex {
    // /policy and /bridges are accessed from Settings — highlight Settings.
    if (location.startsWith('/policy') || location.startsWith('/bridges')) {
      return 4;
    }
    for (var i = 0; i < _dests.length; i++) {
      if (location.startsWith(_dests[i].route)) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 600;
    if (!wide) return child;

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _selectedIndex,
            labelType: NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Icon(
                Icons.security,
                size: 32,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            destinations: _dests
                .map((d) => NavigationRailDestination(
                      icon: Icon(d.icon),
                      selectedIcon: Icon(d.activeIcon),
                      label: Text(d.label),
                    ))
                .toList(),
            onDestinationSelected: (i) => context.go(_dests[i].route),
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class PembrookApp extends StatelessWidget {
  const PembrookApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppSettings()),
        ChangeNotifierProvider(create: (_) => RpcService()),
        ChangeNotifierProvider(create: (_) => DataService()),
        ChangeNotifierProvider(create: (_) => ConversationStore()),
      ],
      child: MaterialApp.router(
        title: 'Pembrook',
        debugShowCheckedModeBanner: false,
        routerConfig: _router,
        builder: (context, child) {
          final scale = context.watch<AppSettings>().fontScale;
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
            ),
            child: child!,
          );
        },
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1B5E20), // deep green — "claw"
            brightness: Brightness.light,
          ),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1B5E20),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: ThemeMode.system,
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// SplashScreen — checks authentication and redirects accordingly.
// ──────────────────────────────────────────────────────────────────────────────

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    final rpcService = context.read<RpcService>();
    if (rpcService.isAuthenticated) {
      context.go('/home');
    } else {
      context.go('/auth');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.security,
              size: 72,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'Pembrook',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
