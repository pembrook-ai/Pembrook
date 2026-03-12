/// Data models for SafeClaw agent.
///
/// These models are serialized to/from JSON and stored as AtKey values.
/// All storage uses the 'safeclaw' namespace.

// ── Enums ─────────────────────────────────────────────────────────────────

/// Trust level of the source that created a piece of data.
/// CRITICAL: Data from untrusted sources can NEVER escalate to command authority.
enum TrustLevel {
  /// Directly from the owner via an authenticated atSign channel
  owner,

  /// From an installed, sandboxed skill with verified developer atSign
  verifiedSkill,

  /// From an unverified source (web results, forwarded messages, LLM output)
  unverifiedInput,

  /// From an external LLM (has no knowledge of user identity)
  externalLlm,
}

/// Intent classification result from the LLM router.
enum IntentType {
  chat,
  task,
  automation,
  skillInvocation,
  mcpToolCall,
  multiStepPlan,
  unknown,
}

// ── Conversation ───────────────────────────────────────────────────────────

/// A single message in a conversation.
///
/// AtKey: conversation.$conversationId.safeclaw@owner (app-side)
///         conversation.$conversationId.safeclaw@agent (agent-side)
class ConversationMessage {
  final String id;
  final String role; // 'user' | 'assistant' | 'system'
  final String content;
  final DateTime timestamp;
  final TrustLevel trustLevel;
  final String sourceAtSign;

  ConversationMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
    required this.trustLevel,
    required this.sourceAtSign,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'content': content,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'trustLevel': trustLevel.name,
        'sourceAtSign': sourceAtSign,
      };

  factory ConversationMessage.fromJson(Map<String, dynamic> json) =>
      ConversationMessage(
        id: json['id'] as String,
        role: json['role'] as String,
        content: json['content'] as String,
        timestamp:
            DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
        trustLevel: TrustLevel.values
            .byName((json['trustLevel'] as String? ?? 'unverifiedInput')),
        sourceAtSign: json['sourceAtSign'] as String,
      );
}

/// A conversation — list of messages with a shared conversationId.
class Conversation {
  final String id;
  final List<ConversationMessage> messages;
  final DateTime createdAt;
  final DateTime updatedAt;

  Conversation({
    required this.id,
    required this.messages,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'messages': messages.map((m) => m.toJson()).toList(),
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: json['id'] as String,
        messages: (json['messages'] as List<dynamic>? ?? [])
            .map((m) => ConversationMessage.fromJson(m as Map<String, dynamic>))
            .toList(),
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch(json['updatedAt'] as int),
      );
}

// ── LLM Settings ──────────────────────────────────────────────────────────

/// LLM configuration stored as AtKey: settings.llm.safeclaw@agent
class LlmSettings {
  final String localModel; // e.g. 'llama3.2', 'mistral', 'phi-3'
  final String externalProvider; // 'claude' | 'openai' | 'google' | 'none'
  final double privacyThreshold; // 0.0 (always external) to 1.0 (always local)
  final bool localOnly; // override: never call external LLMs

  const LlmSettings({
    this.localModel = 'llama3.2',
    this.externalProvider = 'none',
    this.privacyThreshold = 0.7,
    this.localOnly = false,
  });

  Map<String, dynamic> toJson() => {
        'localModel': localModel,
        'externalProvider': externalProvider,
        'privacyThreshold': privacyThreshold,
        'localOnly': localOnly,
      };

  factory LlmSettings.fromJson(Map<String, dynamic> json) => LlmSettings(
        localModel: json['localModel'] as String? ?? 'llama3.2',
        externalProvider: json['externalProvider'] as String? ?? 'none',
        privacyThreshold: (json['privacyThreshold'] as num?)?.toDouble() ?? 0.7,
        localOnly: json['localOnly'] as bool? ?? false,
      );
}
