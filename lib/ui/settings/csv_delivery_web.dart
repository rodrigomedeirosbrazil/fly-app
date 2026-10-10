import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

web.File _file(String name, Uint8List bytes) => web.File(
      [bytes.toJS].toJS,
      name,
      web.FilePropertyBag(type: 'text/csv'),
    );

/// Whether this browser can put a file in the system share sheet. False
/// where `navigator.canShare` does not exist at all, which is most desktop
/// browsers and possibly Bluefy.
bool canShareCsvFile(String name, Uint8List bytes) {
  try {
    return web.window.navigator
        .canShare(web.ShareData(files: [_file(name, bytes)].toJS));
  } catch (_) {
    return false;
  }
}

/// Opens the share sheet. A pilot closing it is not an error.
Future<void> shareCsvFile(String name, Uint8List bytes) async {
  try {
    await web.window.navigator
        .share(web.ShareData(files: [_file(name, bytes)].toJS))
        .toDart;
  } catch (e) {
    if (e.toString().contains('AbortError')) return;
    rethrow;
  }
}

/// A blob URL rather than the `data:` URL share_plus falls back to: it holds
/// a whole log without inflating it into a string, and it is what WebKit
/// hands to its download handling.
String _blobUrl(Uint8List bytes, String type) => web.URL.createObjectURL(
      web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: type)),
    );

void _revokeLater(String url) {
  // Not immediately: the download or the new tab reads it asynchronously.
  Timer(const Duration(minutes: 1), () => web.URL.revokeObjectURL(url));
}

/// Downloads the file under its controller name.
void saveCsvFile(String name, Uint8List bytes) {
  final url = _blobUrl(bytes, 'text/csv');
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = name
    ..style.display = 'none';
  web.document.body!.append(anchor);
  anchor.click();
  anchor.remove();
  _revokeLater(url);
}

/// Shows the file as text in a new tab, where it can be read or copied when
/// neither sharing nor downloading works. False when the browser refused to
/// open the tab.
bool openCsvFile(String name, Uint8List bytes) {
  // text/plain so the tab renders it instead of downloading it again.
  final url = _blobUrl(bytes, 'text/plain;charset=utf-8');
  final tab = web.window.open(url, '_blank');
  _revokeLater(url);
  return tab != null;
}
