/// MAC addresses on the wire and on screen.
///
/// The firmware stores them as `String` in Settings and sends them as **six
/// raw bytes** in the `Bms` and `System` config groups, converting with
/// `macStringToBytes` / `macBytesToString`. This is the Dart side of that
/// conversion.
///
/// **All zero means unset**, which is what `""` means in Settings. That is a
/// protocol rule, not a display choice: a controller with no BMS configured
/// answers `CFG_GET` with six zero bytes, and rendering them as
/// `00:00:00:00:00:00` would show the pilot an address that does not exist.
library;

const List<int> kUnsetMac = [0, 0, 0, 0, 0, 0];

bool isUnsetMac(List<int> bytes) =>
    bytes.length == 6 && bytes.every((b) => b == 0);

/// The printable form, or null when there is no address to print.
String? formatMac(List<int> bytes) {
  if (bytes.length != 6 || isUnsetMac(bytes)) return null;
  return bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
}

final RegExp _macPattern = RegExp(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$');

/// Six bytes, or null when [text] is not exactly six colon-separated hex
/// pairs.
///
/// The same pattern the portal's own form uses. The firmware's
/// `macStringToBytes` would read a shorter string as a partial address, so
/// being stricter here is what stops a half-typed MAC from being written.
List<int>? parseMac(String text) {
  final trimmed = text.trim();
  if (!_macPattern.hasMatch(trimmed)) return null;
  return trimmed.split(':').map((p) => int.parse(p, radix: 16)).toList();
}
