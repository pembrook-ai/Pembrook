/// ChatHistoryScreen — browse, load, and delete past conversation sessions.
///
/// Returns a [ConversationSummary] via [Navigator.pop] when the user taps a
/// session — [ChatScreen] then calls [_loadConversation] to restore it.
///
/// Pull-to-refresh fetches the latest conversations from the remote atServer
/// (falls back to local cache if offline).
/// Swipe-to-dismiss or the delete icon removes a session permanently.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/data_service.dart';
import '../services/rpc_service.dart';

class ChatHistoryScreen extends StatefulWidget {
  const ChatHistoryScreen({super.key});

  @override
  State<ChatHistoryScreen> createState() => _ChatHistoryScreenState();
}

class _ChatHistoryScreenState extends State<ChatHistoryScreen> {
  bool _selectMode = false;
  final Set<String> _selected = {};

  void _toggleSelectMode() {
    setState(() {
      _selectMode = !_selectMode;
      if (!_selectMode) _selected.clear();
    });
  }

  void _toggleItem(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  void _selectAll(List<ConversationSummary> convs) {
    setState(() {
      if (_selected.length == convs.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(convs.map((c) => c.id));
      }
    });
  }

  Future<void> _deleteSelected(ConversationStore store) async {
    if (_selected.isEmpty) return;
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete conversations?'),
        content: Text(
          'Delete $count conversation${count == 1 ? '' : 's'}? '
          'This removes them from your local history. '
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
      await store.deleteMany(_selected);
      setState(() {
        _selected.clear();
        _selectMode = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ConversationStore>(
      builder: (context, store, _) {
        final convs = store.conversations;
        final allSelected =
            convs.isNotEmpty && _selected.length == convs.length;

        return Scaffold(
          appBar: AppBar(
            title: _selectMode
                ? Text('${_selected.length} selected')
                : const Text('Conversation History'),
            leading: _selectMode
                ? IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Cancel',
                    onPressed: _toggleSelectMode,
                  )
                : null,
            actions: [
              if (_selectMode) ...[
                IconButton(
                  icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
                  tooltip: allSelected ? 'Deselect All' : 'Select All',
                  onPressed: () => _selectAll(convs),
                ),
                IconButton(
                  icon: const Icon(Icons.delete),
                  tooltip: 'Delete Selected',
                  onPressed:
                      _selected.isEmpty ? null : () => _deleteSelected(store),
                ),
              ] else ...[
                if (convs.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.checklist),
                    tooltip: 'Select',
                    onPressed: _toggleSelectMode,
                  ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh',
                  onPressed: () => store.load(),
                ),
              ],
            ],
          ),
          body: convs.isEmpty
              ? Center(
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
                )
              : RefreshIndicator(
                  onRefresh: store.load,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: convs.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final conv = convs[index];
                      final isSelected = _selected.contains(conv.id);
                      return Consumer<RpcService>(
                        builder: (context, rpc, _) => _ConversationTile(
                          summary: conv,
                          isUnread: rpc.unreadConvIds.contains(conv.id),
                          selectMode: _selectMode,
                          isSelected: isSelected,
                          onTap: _selectMode
                              ? () => _toggleItem(conv.id)
                              : () {
                                  rpc.markConvRead(conv.id);
                                  context.pop(conv);
                                },
                          onLongPress: () {
                            if (!_selectMode) {
                              _toggleSelectMode();
                              _toggleItem(conv.id);
                            }
                          },
                          onDelete: () => _confirmDelete(context, store, conv),
                        ),
                      );
                    },
                  ),
                ),
        );
      },
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
  final bool isUnread;
  final bool selectMode;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;

  const _ConversationTile({
    required this.summary,
    required this.isUnread,
    required this.selectMode,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final dateStr = _formatDate(summary.createdAt);
    final msgCount = summary.messageCount;

    return Dismissible(
      key: Key(summary.id),
      direction:
          selectMode ? DismissDirection.none : DismissDirection.endToStart,
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
        tileColor: isSelected
            ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.35)
            : isUnread
                ? Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withOpacity(0.18)
                : null,
        leading: selectMode
            ? Checkbox(
                value: isSelected,
                onChanged: (_) => onTap(),
              )
            : Badge(
                isLabelVisible: isUnread,
                child: CircleAvatar(
                  backgroundColor:
                      Theme.of(context).colorScheme.primaryContainer,
                  child: Icon(
                    Icons.chat_bubble_outline,
                    size: 20,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
        title: Text(
          summary.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: isUnread ? const TextStyle(fontWeight: FontWeight.bold) : null,
        ),
        subtitle: Text(
          '$dateStr · $msgCount message${msgCount == 1 ? '' : 's'}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: selectMode
            ? null
            : IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete',
                onPressed: onDelete,
              ),
        onTap: onTap,
        onLongPress: onLongPress,
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
