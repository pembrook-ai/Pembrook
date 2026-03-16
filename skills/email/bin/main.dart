/// Email skill — STDIN/STDOUT JSON line protocol entry point.
///
/// The SandboxManager sends:
///   {"command": "run", "payload": {...}, "requestId": "..."}
///
/// Supported actions (payload.action):
///   send_email  — send an email via SMTP
///   list_inbox  — list recent IMAP inbox messages
///   read_email  — fetch full body of a message by UID
///   delete_email — delete a message by UID (HITL required by policy)
///
/// All credentials are injected in the payload by the agent (read from AtKeys).
/// Nothing is persisted inside the container.
///
/// Send payload fields:
///   smtpHost     : String
///   smtpPort     : int    (default 587)
///   smtpUser     : String
///   smtpPassword : String
///   fromAddress  : String
///   to           : String | List<String>
///   cc           : String | List<String>?
///   subject      : String
///   body         : String
///   useSSL       : bool?  (default false; use STARTTLS on 587)
///
/// IMAP payload fields (shared by list_inbox, read_email, delete_email):
///   imapHost     : String
///   imapPort     : int    (default 993)
///   imapUser     : String
///   imapPassword : String
///   useSSL       : bool?  (default true for port 993)
///
/// list_inbox extra fields:
///   maxMessages  : int?   (default 20)
///
/// read_email / delete_email extra fields:
///   uid          : int
///
/// NOTE: This skill requires network access (SMTP/IMAP egress).
/// It will not function inside a Docker sandbox with --network=none.

import 'dart:convert';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:logging/logging.dart';
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';

final _log = Logger('email_skill');

void main() async {
  Logger.root.level = Level.WARNING;
  Logger.root.onRecord
      .listen((r) => stderr.writeln('[${r.level}] ${r.message}'));

  final line = await stdin.first;
  final input = jsonDecode(utf8.decode(line)) as Map<String, dynamic>;
  final requestId = input['requestId'] as String? ?? '';
  final payload = input['payload'] as Map<String, dynamic>? ?? {};

  try {
    final result = await _handleCommand(payload);
    stdout.writeln(
      jsonEncode({'status': 'ok', 'result': result, 'requestId': requestId}),
    );
  } catch (e, st) {
    _log.severe('Unhandled error', e, st);
    stdout.writeln(
      jsonEncode({
        'status': 'error',
        'error': e.toString(),
        'requestId': requestId,
      }),
    );
    exit(1);
  }
}

// ─────────────────────────────────────────────────────────────────────────────

Future<Map<String, dynamic>> _handleCommand(
  Map<String, dynamic> payload,
) async {
  final action = payload['action'] as String? ?? 'send_email';
  switch (action) {
    case 'send_email':
      return _sendEmail(payload);
    case 'list_inbox':
      return _listInbox(payload);
    case 'read_email':
      return _readEmail(payload);
    case 'delete_email':
      return _deleteEmail(payload);
    default:
      throw ArgumentError('Unknown action: $action');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SMTP — SEND
// ─────────────────────────────────────────────────────────────────────────────

Future<Map<String, dynamic>> _sendEmail(Map<String, dynamic> p) async {
  final smtpHost = _required(p, 'smtpHost') as String;
  final smtpPort = _parseInt(p['smtpPort'], 587);
  final smtpUser = _required(p, 'smtpUser') as String;
  final smtpPassword = _required(p, 'smtpPassword') as String;
  final fromAddress = _required(p, 'fromAddress') as String;
  final useSSL = _parseBool(p['useSSL'], smtpPort == 465);

  final toRaw = _required(p, 'to');
  final toList = toRaw is List ? toRaw.cast<String>() : [toRaw as String];

  final ccRaw = p['cc'];
  final ccList = ccRaw == null
      ? <String>[]
      : ccRaw is List
          ? ccRaw.cast<String>()
          : [ccRaw as String];

  final subject = _required(p, 'subject') as String;
  final body = _required(p, 'body') as String;

  final server = SmtpServer(
    smtpHost,
    port: smtpPort,
    username: smtpUser,
    password: smtpPassword,
    ssl: useSSL,
  );

  final message = Message()
    ..from = Address(fromAddress)
    ..recipients.addAll(toList.map(Address.new))
    ..ccRecipients.addAll(ccList.map(Address.new))
    ..subject = subject
    ..text = body;

  final report = await send(message, server);

  return {
    'sent': true,
    'to': toList,
    'subject': subject,
    'messageCount': toList.length,
    'report': report.toString(),
  };
}

// ─────────────────────────────────────────────────────────────────────────────
//  IMAP — LIST / READ / DELETE
// ─────────────────────────────────────────────────────────────────────────────

Future<ImapClient> _connectImap(Map<String, dynamic> p) async {
  final host = _required(p, 'imapHost') as String;
  final port = _parseInt(p['imapPort'], 993);
  final user = _required(p, 'imapUser') as String;
  final password = _required(p, 'imapPassword') as String;
  final useSSL = _parseBool(p['useSSL'], port == 993);

  final client = ImapClient(isLogEnabled: false);
  await client.connectToServer(host, port, isSecure: useSSL);
  await client.login(user, password);
  return client;
}

Future<Map<String, dynamic>> _listInbox(Map<String, dynamic> p) async {
  final maxMessages = _parseInt(p['maxMessages'], 20);
  final client = await _connectImap(p);

  try {
    await client.selectInbox();
    final fetchResult = await client.fetchRecentMessages(
      messageCount: maxMessages,
      criteria: 'ENVELOPE FLAGS',
    );

    final messages = fetchResult.messages.map((msg) {
      final from = msg.from?.map((a) => a.email).toList() ?? [];
      return {
        'uid': msg.uid,
        'subject': msg.decodeSubject() ?? '(no subject)',
        'from': from.isNotEmpty ? from.first : '',
        'date': msg.decodeDate()?.toIso8601String(),
        'isSeen': msg.isSeen,
        'isFlagged': msg.isFlagged,
      };
    }).toList();

    return {
      'inbox': messages,
      'count': messages.length,
    };
  } finally {
    await client.logout();
  }
}

Future<Map<String, dynamic>> _readEmail(Map<String, dynamic> p) async {
  final uid = _required(p, 'uid') as int;
  final client = await _connectImap(p);

  try {
    await client.selectInbox();

    final fetchResult =
        await client.uidFetchMessage(uid, 'BODY.PEEK[] ENVELOPE FLAGS');

    if (fetchResult.messages.isEmpty) {
      throw StateError('Message UID $uid not found');
    }

    final msg = fetchResult.messages.first;
    final plainText = msg.decodeTextPlainPart() ?? '';
    final htmlText = msg.decodeTextHtmlPart() ?? '';

    final from = msg.from?.map((a) => a.email).toList() ?? [];
    final to = msg.to?.map((a) => a.email).toList() ?? [];

    return {
      'uid': uid,
      'subject': msg.decodeSubject() ?? '(no subject)',
      'from': from.isNotEmpty ? from.first : '',
      'to': to,
      'date': msg.decodeDate()?.toIso8601String(),
      'bodyText': plainText,
      'bodyHtml': htmlText,
      'isSeen': msg.isSeen,
    };
  } finally {
    await client.logout();
  }
}

Future<Map<String, dynamic>> _deleteEmail(Map<String, dynamic> p) async {
  final uid = _parseInt(_required(p, 'uid'), -1);
  final client = await _connectImap(p);

  try {
    await client.selectInbox();
    await client.markDeleted(
      MessageSequence.fromId(uid, isUid: true),
    );
    await client.expunge();

    return {'deleted': true, 'uid': uid};
  } finally {
    await client.logout();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  HELPERS
// ─────────────────────────────────────────────────────────────────────────────

/// Assert a required payload field is present and return it.
Object _required(Map<String, dynamic> payload, String key) {
  final v = payload[key];
  if (v == null) throw ArgumentError('Missing required payload field: "$key"');
  return v;
}

/// Parse an int from either an int or a String value.
int _parseInt(dynamic v, int fallback) {
  if (v == null) return fallback;
  if (v is int) return v;
  if (v is double) return v.toInt();
  return int.tryParse(v.toString()) ?? fallback;
}

/// Parse a bool from either a bool or a String value.
bool _parseBool(dynamic v, bool fallback) {
  if (v == null) return fallback;
  if (v is bool) return v;
  return v.toString().toLowerCase() == 'true';
}
