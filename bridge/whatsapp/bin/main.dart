/// WhatsApp Bridge — skeleton for Phase 2.
///
/// Full implementation: Phase 2 of the SafeClaw roadmap.
///
/// FLOW (to be implemented):
///   1. Start Shelf HTTP server on 127.0.0.1:8080 (local only).
///   2. Verify webhook token from WhatsApp Cloud API.
///   3. Parse inbound message (text, media, voice).
///   4. Authenticate sender against @owner's allowList AtKey.
///   5. Forward message to @agent via AtRpc call.
///   6. Receive @agent response.
///   7. POST to WhatsApp Cloud API to send reply.
///
/// See: https://developers.facebook.com/docs/whatsapp/cloud-api

import 'dart:io';
import 'package:at_cli_commons/at_cli_commons.dart';
import 'package:at_client/at_client.dart';
import 'package:logging/logging.dart';

void main(List<String> args) async {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    stderr.writeln(
      '[${record.level.name}] ${record.loggerName}: ${record.message}',
    );
  });

  final log = Logger('SafeClawBridgeWhatsApp');
  log.info('WhatsApp bridge — Phase 2 (not yet implemented)');

  // TODO Phase 2:
  //   - CLIBase.fromCommandLineArgs(args) for @bridge_whatsapp auth
  //   - Shelf server setup
  //   - AtRpc client to @agent
}
