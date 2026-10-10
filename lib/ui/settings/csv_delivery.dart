/// Hands a downloaded log to the browser. Web only; native builds share
/// through `share_csv.dart` and never call these.
///
/// Each of these has to run inside the tap that asked for it: browsers only
/// share, download or open a tab during a recent user gesture, and the BLE
/// download that produced the bytes outlasts that window.
library;

export 'csv_delivery_stub.dart'
    if (dart.library.js_interop) 'csv_delivery_web.dart';
