/// ChatScreen — the main SafeClaw conversation UI.
///
/// Sends messages to @agent via RpcService.call() and renders the response.
/// Subscribes to RpcService.streamChunks for incremental token rendering
/// (streaming mode from the agent).
///
/// Navigation drawer:
///   Home (chat), History, Audit Log, Skills, HITL Approvals, Settings.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../services/rpc_service.dart';

class _Message {
  final String text;
  final bool isUser;
  final DateTime timestamp;

  _Message({
    required this.text,
    required this.isUser,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<_Message> _messages = [];
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final Uuid _uuid = const Uuid();
  late final String _conversationId;

  bool _isLoading = false;
  String _streamBuffer = '';
  StreamSubscription<String>? _streamSub;

  @override
  void initState() {
    super.initState();
    _conversationId = _uuid.v4();
    _messages.add(_Message(
      text: 'Hello! I\'m your SafeClaw AI assistant. All our communication is '
          'end-to-end encrypted via the atPlatform. How can I help you today?',
      isUser: false,
    ));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _streamSub?.cancel();
    _streamSub = context.read<RpcService>().streamChunks.listen((chunk) {
      setState(() => _streamBuffer += chunk);
      _scrollToBottom();
    });
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _streamSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // On wide screens (desktop/tablet) the AppShell NavigationRail handles
    // navigation — no drawer needed.  On narrow screens keep the drawer.
    final wide = MediaQuery.of(context).size.width >= 600;
    return Scaffold(
      appBar: AppBar(
        title: const Text('SafeClaw'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_comment),
            tooltip: 'New conversation',
            onPressed: _newConversation,
          ),
        ],
      ),
      drawer: wide ? null : _buildDrawer(context),
      body: Column(
        children: [
          // ── Agent config warning ───────────────────────────
          Consumer<RpcService>(
            builder: (context, rpc, _) {
              if (rpc.agentAtSign == '@agent') {
                return MaterialBanner(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  content: const Text(
                    'Agent atSign not configured. '
                    'Go to Settings and set your agent atSign.',
                  ),
                  leading:
                      const Icon(Icons.warning_amber, color: Colors.orange),
                  actions: [
                    TextButton(
                      onPressed: () => context.go('/settings'),
                      child: const Text('Settings'),
                    ),
                  ],
                );
              }
              return const SizedBox.shrink();
            },
          ),
          Expanded(child: _buildMessages()),
          if (_streamBuffer.isNotEmpty) _StreamingBubble(text: _streamBuffer),
          _buildInput(),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  //  MESSAGES LIST
  // ──────────────────────────────────────────────────────────

  Widget _buildMessages() {
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final msg = _messages[index];
        return _ChatBubble(message: msg);
      },
    );
  }

  // ──────────────────────────────────────────────────────────
  //  INPUT ROW
  // ──────────────────────────────────────────────────────────

  Widget _buildInput() {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputCtrl,
              maxLines: null,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                hintText: 'Message SafeClaw…',
                border: InputBorder.none,
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 8),
          _isLoading
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton.filled(
                  icon: const Icon(Icons.send),
                  onPressed: _send,
                ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  //  SEND
  // ──────────────────────────────────────────────────────────

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _isLoading) return;

    _inputCtrl.clear();
    setState(() {
      _messages.add(_Message(
        text: text,
        isUser: true,
        timestamp: DateTime.now(),
      ));
      _isLoading = true;
      _streamBuffer = '';
    });
    _scrollToBottom();

    final rpcService = context.read<RpcService>();
    final result = await rpcService.call(
      command: text,
      conversationId: _conversationId,
      payload: {'message': text},
    );

    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _streamBuffer = '';
      _messages.add(_Message(
        text: result.success
            ? result.response
            : '⚠️ ${result.error ?? "Unknown error"}',
        isUser: false,
        timestamp: DateTime.now(),
      ));
    });
    _scrollToBottom();
  }

  void _newConversation() {
    setState(() {
      _messages.clear();
      _messages.add(_Message(
        text: 'New conversation started.',
        isUser: false,
      ));
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ──────────────────────────────────────────────────────────
  //  DRAWER
  // ──────────────────────────────────────────────────────────

  Widget _buildDrawer(BuildContext context) {
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
                Text('SafeClaw',
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
          _DrawerItem(Icons.chat, 'Chat', '/home', context),
          _DrawerItem(Icons.article, 'Audit Log', '/audit', context),
          _DrawerItem(Icons.extension, 'Skills', '/skills', context),
          _DrawerItem(Icons.pending_actions, 'Approvals', '/hitl', context),
          const Divider(),
          _DrawerItem(Icons.settings, 'Settings', '/settings', context),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────

Widget _DrawerItem(
    IconData icon, String label, String route, BuildContext context) {
  return ListTile(
    leading: Icon(icon),
    title: Text(label),
    onTap: () {
      Navigator.pop(context);
      context.go(route);
    },
  );
}

// ──────────────────────────────────────────────────────────────────────────────

class _ChatBubble extends StatelessWidget {
  final _Message message;

  const _ChatBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: isUser
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          message.text,
          style: TextStyle(
            color: isUser
                ? Theme.of(context).colorScheme.onPrimary
                : Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

class _StreamingBubble extends StatelessWidget {
  final String text;

  const _StreamingBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: Theme.of(context).colorScheme.primary, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(text)),
            const SizedBox(width: 8),
            const SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
