/// SafeClaw Flutter App — entry point.
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
///   /home       → ChatScreen (main chat UI)
///   /history    → HistoryScreen (conversations)
///   /audit      → AuditScreen (audit log viewer)
///   /settings   → SettingsScreen (preferences + policy)
///   /skills     → SkillsScreen (installed skills)
///   /hitl       → HitlScreen (pending HITL approvals)
///   /policy     → PolicyListScreen (policy rule manager)
///   /bridges    → BridgesScreen (messaging bridge config)
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'auth/auth_screen.dart';
import 'bridges/bridges_screen.dart';
import 'chat/chat_screen.dart';
import 'audit/audit_screen.dart';
import 'policy/policy_list_screen.dart';
import 'settings/settings_screen.dart';
import 'skills/skills_screen.dart';
import 'hitl/hitl_screen.dart';
import 'services/rpc_service.dart';
import 'services/data_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SafeClawApp());
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
  ],
);

class SafeClawApp extends StatelessWidget {
  const SafeClawApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => RpcService()),
        ChangeNotifierProvider(create: (_) => DataService()),
      ],
      child: MaterialApp.router(
        title: 'SafeClaw',
        debugShowCheckedModeBanner: false,
        routerConfig: _router,
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
              'SafeClaw',
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
