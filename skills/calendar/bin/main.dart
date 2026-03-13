/// Calendar skill — STDIN/STDOUT JSON line protocol entry point.
///
/// The SandboxManager sends:
///   {"command": "run", "payload": {...}, "requestId": "..."}
///
/// This skill reads one JSON line, processes it, and writes:
///   {"status": "ok", "result": {...}, "requestId": "..."}
///   OR
///   {"status": "error", "error": "...", "requestId": "..."}
///
/// Supported actions (payload.action):
///   list_events   — list calendar events in a time range
///   create_event  — create a new event
///   delete_event  — delete an event by ID
///
/// OAuth access token is injected by the agent from AtKey
/// skill.calendar.token.safeclaw@skill_calendar — never stored in container.
///
/// Common payload fields:
///   accessToken  : String  — Google OAuth2 access token
///   calendarId   : String? — target calendar (default 'primary')
///
/// list_events fields:
///   start        : String? — ISO-8601 datetime (default: now)
///   end          : String? — ISO-8601 datetime (default: 7 days from now)
///   maxResults   : int?    — max events to return (default 10)
///
/// create_event fields:
///   title        : String
///   start        : String  — ISO-8601 datetime
///   end          : String  — ISO-8601 datetime
///   description  : String?
///   attendees    : List<String>? — email addresses
///   timeZone     : String? — IANA time zone (default 'UTC')
///
/// delete_event fields:
///   eventId      : String
///
/// NOTE: This skill requires HTTPS egress to www.googleapis.com.
/// It will not function inside a Docker sandbox with --network=none.

import 'dart:convert';
import 'dart:io';

import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

final _log = Logger('calendar_skill');

void main() async {
  Logger.root.level = Level.WARNING;
  Logger.root.onRecord.listen(
    (r) => stderr.writeln('[${r.level}] ${r.message}'),
  );

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
  final action = payload['action'] as String? ?? 'list_events';

  switch (action) {
    case 'list_events':
      return _listEvents(payload);
    case 'create_event':
      return _createEvent(payload);
    case 'delete_event':
      return _deleteEvent(payload);
    default:
      throw ArgumentError('Unknown calendar action: $action');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  AUTH
// ─────────────────────────────────────────────────────────────────────────────

/// Build a googleapis-authenticated HTTP client from a raw access token.
http.Client _authClient(String accessToken) {
  final credentials = AccessCredentials(
    AccessToken(
      'Bearer',
      accessToken,
      // Assume the token is valid for at least 1 hour from now.
      // The agent is responsible for refreshing tokens before injecting them.
      DateTime.now().toUtc().add(const Duration(hours: 1)),
    ),
    null, // no refresh token — agent handles refresh via AtKey rotation
    [gcal.CalendarApi.calendarScope],
  );
  return authenticatedClient(http.Client(), credentials);
}

/// Extract and validate the access token; return a [CalendarApi] instance.
gcal.CalendarApi _buildApi(Map<String, dynamic> p) {
  final token = _required(p, 'accessToken') as String;
  return gcal.CalendarApi(_authClient(token));
}

// ─────────────────────────────────────────────────────────────────────────────
//  LIST EVENTS
// ─────────────────────────────────────────────────────────────────────────────

Future<Map<String, dynamic>> _listEvents(Map<String, dynamic> p) async {
  final api = _buildApi(p);
  final calendarId = (p['calendarId'] as String?) ?? 'primary';
  final now = DateTime.now().toUtc();
  final timeMin =
      p['start'] != null ? DateTime.parse(p['start'] as String).toUtc() : now;
  final timeMax = p['end'] != null
      ? DateTime.parse(p['end'] as String).toUtc()
      : now.add(const Duration(days: 7));
  final maxResults = (p['maxResults'] as int?) ?? 10;

  final events = await api.events.list(
    calendarId,
    timeMin: timeMin,
    timeMax: timeMax,
    singleEvents: true,
    orderBy: 'startTime',
    maxResults: maxResults,
  );

  final items = (events.items ?? []).map((e) {
    final startDt = e.start?.dateTime ?? e.start?.date;
    final endDt = e.end?.dateTime ?? e.end?.date;
    return {
      'id': e.id,
      'title': e.summary ?? '(no title)',
      'description': e.description,
      'start': startDt?.toIso8601String(),
      'end': endDt?.toIso8601String(),
      'location': e.location,
      'attendees': (e.attendees ?? []).map((a) => a.email).toList(),
      'status': e.status,
      'htmlLink': e.htmlLink,
    };
  }).toList();

  return {
    'calendarId': calendarId,
    'events': items,
    'count': items.length,
    'rangeStart': timeMin.toIso8601String(),
    'rangeEnd': timeMax.toIso8601String(),
  };
}

// ─────────────────────────────────────────────────────────────────────────────
//  CREATE EVENT
// ─────────────────────────────────────────────────────────────────────────────

Future<Map<String, dynamic>> _createEvent(Map<String, dynamic> p) async {
  final api = _buildApi(p);
  final calendarId = (p['calendarId'] as String?) ?? 'primary';
  final title = _required(p, 'title') as String;
  final start = DateTime.parse(_required(p, 'start') as String).toUtc();
  final end = DateTime.parse(_required(p, 'end') as String).toUtc();
  final description = p['description'] as String?;
  final timeZone = (p['timeZone'] as String?) ?? 'UTC';

  final attendeeEmails =
      (p['attendees'] as List<dynamic>?)?.cast<String>() ?? [];

  final event = gcal.Event()
    ..summary = title
    ..description = description
    ..start = (gcal.EventDateTime()
      ..dateTime = start
      ..timeZone = timeZone)
    ..end = (gcal.EventDateTime()
      ..dateTime = end
      ..timeZone = timeZone)
    ..attendees = attendeeEmails
        .map((email) => gcal.EventAttendee()..email = email)
        .toList();

  final created = await api.events.insert(event, calendarId);

  return {
    'created': true,
    'eventId': created.id,
    'title': created.summary,
    'start': created.start?.dateTime?.toIso8601String(),
    'end': created.end?.dateTime?.toIso8601String(),
    'htmlLink': created.htmlLink,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
//  DELETE EVENT
// ─────────────────────────────────────────────────────────────────────────────

Future<Map<String, dynamic>> _deleteEvent(Map<String, dynamic> p) async {
  final api = _buildApi(p);
  final calendarId = (p['calendarId'] as String?) ?? 'primary';
  final eventId = _required(p, 'eventId') as String;

  await api.events.delete(calendarId, eventId);

  return {'deleted': true, 'eventId': eventId};
}

// ─────────────────────────────────────────────────────────────────────────────
//  HELPERS
// ─────────────────────────────────────────────────────────────────────────────

Object _required(Map<String, dynamic> payload, String key) {
  final v = payload[key];
  if (v == null) throw ArgumentError('Missing required payload field: "$key"');
  return v;
}
