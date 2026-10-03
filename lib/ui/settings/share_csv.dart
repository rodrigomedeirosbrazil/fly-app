import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

/// Hands a downloaded log to the system share sheet — mail, WhatsApp, Files.
///
/// The only line in the log feature that touches the platform, kept out of
/// the screen so every widget test substitutes it. `fileNameOverrides` is
/// what makes the attachment carry the controller's name instead of a
/// generated one; a pilot sorting flights needs the date in the file name.
Future<void> shareCsv(String name, Uint8List bytes) async {
  await SharePlus.instance.share(ShareParams(
    files: [XFile.fromData(bytes, name: name, mimeType: 'text/csv')],
    fileNameOverrides: [name],
  ));
}
