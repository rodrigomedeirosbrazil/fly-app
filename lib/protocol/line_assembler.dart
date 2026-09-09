import 'dart:convert';

/// Reassembles `\n`-terminated ASCII lines out of BLE notification chunks.
///
/// The controller sends one whole line per notification, but that only holds
/// while the negotiated MTU is larger than the line. Buffering here means the
/// parser never has to care how the transport chopped the stream.
class LineAssembler {
  LineAssembler({this.maxBufferChars = 512});

  /// Above this, the buffer is discarded. A peer that never sends a terminator
  /// must not be able to grow this without bound.
  final int maxBufferChars;

  String _buffer = '';

  /// Feeds one notification payload. Returns the complete lines it closed, in
  /// arrival order, with any trailing CR stripped.
  List<String> add(List<int> chunk) {
    _buffer += ascii.decode(chunk, allowInvalid: true);

    final lines = <String>[];
    while (true) {
      final i = _buffer.indexOf('\n');
      if (i < 0) break;
      lines.add(_buffer.substring(0, i).trimRight());
      _buffer = _buffer.substring(i + 1);
    }

    if (_buffer.length > maxBufferChars) _buffer = '';
    return lines;
  }

  /// Drops any partial line. Call on disconnect so a reconnect does not splice
  /// the tail of the old session onto the head of the new one.
  void reset() => _buffer = '';
}
