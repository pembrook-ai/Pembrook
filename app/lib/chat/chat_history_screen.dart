/// ChatHistoryScreen — browse, load, and delete past conversation sessions.
///
/// Returns a [ConversationSummary] via [Navigator.pop] when the user taps a
/// session — [ChatScreen] then calls [_loadConversation] to restore it.
///
/// Pull-to-refresh reloads from SharedPreferences.
/// Swipe-to-dismiss or the delete icon removes a session permanently.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/data_service.dart';

class ChatHistoryScreen extends StatelessWidget {
  const ChatHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Conversation History'),
        actions: [
          Consumer<ConversationStore>(
            builder: (context, store, _) => IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: () => store.load(),
            ),
          ),
        ],
      ),
      body: Consumer<ConversationStore>(
        builder: (context, store, _) {
          final convs = store.conversations;

          if (convs.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.chat_bubble_outline,
                    size: 64,
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No past conversations.',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text('Start chatting to build your history.'),
                ],
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: store.load,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: convs.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final conv = convs[index];
                return _ConversationTile(
                  summary: conv,
                  onTap: () => context.pop(conv),
                  onDelete: () => _confirmDelete(context, store, conv),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    ConversationStore store,
    ConversationSummary conv,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete conversation?'),
        content: Text(
          '"${conv.title}" will be removed from your local history. '
          'The agent\'s memory is not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await store.delete(conv.id);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _ConversationTile extends StatelessWidget {
  final ConversationSummary summary;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _ConversationTile({
    required this.summary,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final dateStr = _formatDate(summary.createdAt);
    final msgCount = summary.messageCount;

    return Dismissible(
      key: Key(summary.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        color: Theme.of(context).colorScheme.errorContainer,
        padding: const EdgeInsets.only(right: 24),
        child: Icon(
          Icons.delete_outline,
          color: Theme.of(context).colorScheme.onErrorContainer,
        ),
      ),
      confirmDismiss: (_) async {
        onDelete();
        return false; // let onDelete handle it (with confirmation)
      },
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Icon(
            Icons.chat_bubble_outline,
            size: 20,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
        title: Text(
          summary.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '$dateStr · $msgCount message${msgCount == 1 ? '' : 's'}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete',
          onPressed: onDelete,
        ),
        onTap: onTap,
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'Today ${DateFormat.jm().format(dt)}';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return DateFormat.EEEE().format(dt);
    return DateFormat.yMMMd().format(dt);
  }
}
