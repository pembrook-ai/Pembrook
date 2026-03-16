/// MemoryService — all conversation history and context, stored as AtKeys.
///
/// CRITICAL: Nothing is stored in local files. Every piece of memory is an
/// AtKey that automatically syncs across all of the owner's devices via
/// the atPlatform sync service.
///
/// Key patterns (namespace: pembrook):
///   conversation.$convId.pembrook@agent     — full conversation (TTL 90 days)
///   context.user_preferences.pembrook@agent — owner preferences
///   context.user_profile.pembrook@agent     — personal info (owner-managed)
///   summary.$period.pembrook@agent          — compressed summaries
///
/// Source tagging (SECURITY CRITICAL):
///   Every memory entry includes:
///     sourceAtSign: who created it
///     trustLevel:   owner | verifiedSkill | unverifiedInput | externalLlm
///   Memory from untrusted sources (web results, external LLM) is stored with
///   trustLevel='unverifiedInput' and CANNOT escalate to command authority.
///   This prevents delayed multi-turn memory poisoning attacks.

import 'dart:convert';
import 'package:at_client/at_client.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../models/conversation.dart';
import 'llm_router.dart';

/// TTL for full conversation history: 90 days in milliseconds
const int kConversationTtlMs = 90 * 24 * 60 * 60 * 1000;

/// TTL for memory summaries: 1 year in milliseconds
const int kSummaryTtlMs = 365 * 24 * 60 * 60 * 1000;

class MemoryService {
  final AtClient atClient;

  /// Optional LlmRouter for summarizing old conversations (Phase 2).
  /// Wire this in via the constructor; if null, summarization is skipped.
  final LlmRouter? llmRouter;

  final Logger _log = Logger('MemoryService');
  final Uuid _uuid = const Uuid();

  MemoryService({required this.atClient, this.llmRouter});

  // ── Conversation ──────────────────────────────────────────────────────────

  /// Load a conversation by ID from the agent's atServer.
  ///
  /// Returns null if the conversation does not exist.
  Future<Conversation?> loadConversation(String conversationId) async {
    try {
      final key = AtKey()
        ..key = 'conversation.$conversationId'
        ..namespace = 'pembrook';

      final atValue = await atClient.get(
        key,
        getRequestOptions: GetRequestOptions()..useRemoteAtServer = true,
      );

      if (atValue.value == null) return null;
      return Conversation.fromJson(
          jsonDecode(atValue.value as String) as Map<String, dynamic>);
    } catch (e) {
      _log.fine('Conversation $conversationId not found (new): $e');
      return null;
    }
  }

  /// Save a new exchange (user message + assistant response) to the conversation.
  ///
  /// Creates the conversation if it doesn't exist.
  /// Appends the new messages while preserving history.
  Future<void> saveExchange({
    required String conversationId,
    required String userMessage,
    required String assistantMessage,
    required String sourceAtSign,
    required TrustLevel trustLevel,
  }) async {
    // Load existing conversation or create new
    var conversation = await loadConversation(conversationId);
    conversation ??= Conversation(
      id: conversationId,
      messages: [],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final now = DateTime.now();

    // Append new messages
    final updatedMessages = [
      ...conversation.messages,
      ConversationMessage(
        id: _uuid.v4(),
        role: 'user',
        content: userMessage,
        timestamp: now,
        trustLevel: trustLevel,
        sourceAtSign: sourceAtSign,
      ),
      ConversationMessage(
        id: _uuid.v4(),
        role: 'assistant',
        content: assistantMessage,
        timestamp: now.add(const Duration(milliseconds: 1)),
        trustLevel: TrustLevel.owner, // agent's own responses are trusted
        sourceAtSign: atClient.getCurrentAtSign() ?? '@agent',
      ),
    ];

    final updated = Conversation(
      id: conversationId,
      messages: updatedMessages,
      createdAt: conversation.createdAt,
      updatedAt: now,
    );

    await _saveConversation(updated);
  }

  /// Write a conversation AtKey to the atServer.
  Future<void> _saveConversation(Conversation conversation) async {
    final key = AtKey()
      ..key = 'conversation.${conversation.id}'
      ..namespace = 'pembrook'
      ..metadata = (Metadata()
        ..ttl = kConversationTtlMs
        ..ttr = -1);

    await atClient.put(
      key,
      jsonEncode(conversation.toJson()),
      putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
    );
    _log.fine('Saved conversation ${conversation.id} '
        '(${conversation.messages.length} messages)');
  }

  // ── User Preferences ──────────────────────────────────────────────────────

  /// Load owner preferences from AtKey.
  Future<Map<String, dynamic>> loadUserPreferences() async {
    try {
      final key = AtKey()
        ..key = 'context.user_preferences'
        ..namespace = 'pembrook';
      final atValue = await atClient.get(
        key,
        getRequestOptions: GetRequestOptions()..useRemoteAtServer = true,
      );
      if (atValue.value == null) return {};
      return jsonDecode(atValue.value as String) as Map<String, dynamic>;
    } catch (e) {
      _log.fine('No user preferences found: $e');
      return {};
    }
  }

  /// Save owner preferences.
  Future<void> saveUserPreferences(Map<String, dynamic> preferences) async {
    final key = AtKey()
      ..key = 'context.user_preferences'
      ..namespace = 'pembrook';
    await atClient.put(
      key,
      jsonEncode(preferences),
      putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
    );
  }

  // ── Summaries (Phase 2: Memory Maintenance) ───────────────────────────────

  /// Summarize old conversations to keep context windows manageable.
  ///
  /// Called periodically by [HeartbeatEngine].
  /// Conversations older than [olderThan] AND longer than
  /// [maxMessagesBeforeSummarize] are compressed:
  ///   1. Trusted messages are sent to the local LLM for summarization.
  ///   2. The summary is stored as `memory.summary.$id.pembrook@agent`.
  ///   3. The conversation is trimmed to the summary + last 5 messages.
  Future<void> summarizeOldConversations({
    Duration olderThan = const Duration(days: 7),
    int maxMessagesBeforeSummarize = 50,
  }) async {
    if (llmRouter == null) {
      _log.fine('summarizeOldConversations: no LlmRouter wired, skipping');
      return;
    }

    _log.info('Memory maintenance: scanning conversations for summarization');

    List<String> keys;
    try {
      keys = await atClient.getKeys(regex: r'conversation\.');
    } catch (e) {
      _log.warning('Failed to list conversation keys: $e');
      return;
    }

    final cutoff = DateTime.now().subtract(olderThan);
    int summarized = 0;

    for (final keyStr in keys) {
      try {
        final atKey = AtKey.fromString(keyStr);
        final atValue = await atClient.get(
          atKey,
          getRequestOptions: GetRequestOptions()..useRemoteAtServer = true,
        );
        if (atValue.value == null) continue;

        final conv = Conversation.fromJson(
            jsonDecode(atValue.value as String) as Map<String, dynamic>);

        // Only summarize conversations old enough with enough messages.
        if (conv.updatedAt.isAfter(cutoff)) continue;
        if (conv.messages.length < maxMessagesBeforeSummarize) continue;

        // Build transcript from trusted messages only (prevents memory poisoning).
        final trustedMsgs = conv.messages
            .where((m) =>
                m.trustLevel == TrustLevel.owner ||
                m.trustLevel == TrustLevel.verifiedSkill)
            .toList();
        if (trustedMsgs.isEmpty) continue;

        final transcript = trustedMsgs
            .map((m) =>
                '${m.role == 'assistant' ? 'Assistant' : 'User'}: ${m.content}')
            .join('\n');

        // Summarize locally — always privacy-score 1.0 to force local LLM.
        final summary = await llmRouter!.generateResponse(
          query: transcript,
          conversationHistory: [],
          privacyScore: 1.0,
          systemOverride: 'Summarize the following conversation concisely. '
              'Preserve all key facts, decisions, preferences, and action items. '
              'Omit pleasantries. Output plain prose, not bullet points.',
        );

        // Persist the summary as a separate AtKey for the app audit view.
        final summaryKey = AtKey()
          ..key = 'memory.summary.${conv.id}'
          ..namespace = 'pembrook'
          ..metadata = (Metadata()
            ..ttl = kSummaryTtlMs
            ..ttr = -1);
        await atClient.put(
          summaryKey,
          jsonEncode({
            'conversationId': conv.id,
            'summarizedAt': DateTime.now().toUtc().toIso8601String(),
            'originalMessageCount': conv.messages.length,
            'summary': summary,
          }),
          putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
        );

        // Trim conversation: system summary marker + last 5 messages.
        final last5 = conv.messages.reversed.take(5).toList().reversed.toList();
        final trimmed = [
          ConversationMessage(
            id: _uuid.v4(),
            role: 'system',
            content:
                '[Summary of ${conv.messages.length - 5} earlier messages]: '
                '$summary',
            timestamp: DateTime.now(),
            trustLevel: TrustLevel.verifiedSkill,
            sourceAtSign: atClient.getCurrentAtSign() ?? '@agent',
          ),
          ...last5,
        ];

        final trimmedConv = Conversation(
          id: conv.id,
          messages: trimmed,
          createdAt: conv.createdAt,
          updatedAt: conv.updatedAt,
        );
        await _saveConversation(trimmedConv);

        summarized++;
        _log.info('Summarized conversation ${conv.id} '
            '(${conv.messages.length} → ${trimmed.length} messages)');
      } catch (e) {
        _log.warning('Failed to summarize conversation: $e');
      }
    }

    if (summarized > 0) {
      _log.info(
          'Memory maintenance complete: $summarized conversation(s) summarized');
    }
  }

  // ── Skill State (Phase 3) ─────────────────────────────────────────────────

  /// Load persistent state for a skill.
  /// Key: skill_state.$skillId.pembrook@agent
  Future<Map<String, dynamic>> loadSkillState(String skillId) async {
    try {
      final key = AtKey()
        ..key = 'skill_state.$skillId'
        ..namespace = 'pembrook';
      final atValue = await atClient.get(key);
      if (atValue.value == null) return {};
      return jsonDecode(atValue.value as String) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// Save persistent state for a skill.
  Future<void> saveSkillState(
      String skillId, Map<String, dynamic> state) async {
    final key = AtKey()
      ..key = 'skill_state.$skillId'
      ..namespace = 'pembrook';
    await atClient.put(
      key,
      jsonEncode(state),
      putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
    );
  }
}
