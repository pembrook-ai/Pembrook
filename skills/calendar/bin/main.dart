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
/// It then exits 0.

import 'dart:convert';
import 'dart:io';

void main() async {
  final line = await stdin.first;
  final input = jsonDecode(utf8.decode(line)) as Map<String, dynamic>;
  final requestId = input['requestId'] as String? ?? '';
  final payload = input['payload'] as Map<String, dynamic>? ?? {};

  try {
    final result = await _handleCommand(payload);
    stdout.writeln(
      jsonEncode({'status': 'ok', 'result': result, 'requestId': requestId}),
    );
  } catch (e) {
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

Future<Map<String, dynamic>> _handleCommand(
  Map<String, dynamic> payload,
) async {
  final action = payload['action'] as String? ?? 'list_events';

  switch (action) {
    case 'list_events':
      // Phase 3: implement Google Calendar API call using OAuth token
      // passed securely via payload (never stored in container).
      return {
        'events': [],
        'message': 'Calendar skill — Phase 3 (not yet implemented)',
      };

    case 'create_event':
      return {
        'eventId': null,
        'message': 'Calendar skill — Phase 3 (not yet implemented)',
      };

    default:
      throw ArgumentError('Unknown calendar action: $action');
  }
}
