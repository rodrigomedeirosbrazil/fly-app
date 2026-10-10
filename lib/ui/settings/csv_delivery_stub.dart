import 'dart:typed_data';

bool canShareCsvFile(String name, Uint8List bytes) => false;

Future<void> shareCsvFile(String name, Uint8List bytes) =>
    throw UnsupportedError('web only');

void saveCsvFile(String name, Uint8List bytes) =>
    throw UnsupportedError('web only');

bool openCsvFile(String name, Uint8List bytes) =>
    throw UnsupportedError('web only');
