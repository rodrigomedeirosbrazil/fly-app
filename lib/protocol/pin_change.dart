/// The `PIN_CHANGE` (`0x28`) request and the rules the firmware applies to it.
///
/// `BleControl.cpp`'s handler requires the new PIN to be 4–8 characters and
/// compares the current one byte for byte against Settings. The PIN travels
/// as raw characters, one byte each, so anything outside printable ASCII
/// cannot be sent as the pilot typed it — `codeUnits` would emit UTF-16 units
/// the firmware reads as different bytes, and the pilot would be locked out
/// by a PIN they never typed.
library;

const int kPinMinLength = 4;
const int kPinMaxLength = 8;

enum PinProblem { tooShort, tooLong, notAscii, mismatch }

bool _isPrintableAscii(String s) =>
    s.codeUnits.every((c) => c >= 0x20 && c <= 0x7E);

/// Null when [next] is a PIN the firmware accepts and [confirm] repeats it.
///
/// Length first: a pilot who typed three characters twice needs to hear
/// about the length, not that two short PINs agree.
PinProblem? checkNewPin(String next, String confirm) {
  if (next.length < kPinMinLength) return PinProblem.tooShort;
  if (next.length > kPinMaxLength) return PinProblem.tooLong;
  if (!_isPrintableAscii(next)) return PinProblem.notAscii;
  if (next != confirm) return PinProblem.mismatch;
  return null;
}

bool isValidNewPin(String next) =>
    next.length >= kPinMinLength &&
    next.length <= kPinMaxLength &&
    _isPrintableAscii(next);

String pinProblemMessage(PinProblem p) => switch (p) {
      PinProblem.tooShort => 'O PIN precisa de pelo menos 4 caracteres',
      PinProblem.tooLong => 'O PIN pode ter no máximo 8 caracteres',
      PinProblem.notAscii => 'Use só letras sem acento, números e símbolos',
      PinProblem.mismatch => 'Os dois PINs novos não são iguais',
    };

/// `[curLen u8][cur…][newLen u8][new…]`.
///
/// Throws on a current PIN longer than any the firmware stores: the request
/// could never succeed, and at 22 characters or more it would overflow the
/// 32-byte queue slot and be dropped without a reply.
List<int> encodePinChange({required String current, required String next}) {
  if (current.length > kPinMaxLength) {
    throw ArgumentError.value(current.length, 'current', 'longer than any PIN');
  }
  return [
    current.length,
    ...current.codeUnits,
    next.length,
    ...next.codeUnits,
  ];
}
