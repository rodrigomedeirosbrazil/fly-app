import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fly_app/protocol/line_assembler.dart';

List<int> bytes(String s) => ascii.encode(s);

void main() {
  test('a single complete notification yields one line', () {
    final a = LineAssembler();
    expect(a.add(bytes('hello\r\n')), ['hello']);
  });

  test('a line split across notifications is reassembled', () {
    final a = LineAssembler();
    expect(a.add(bytes(r'$XCTOD,87,')), isEmpty);
    expect(a.add(bytes('91,ARMED\r\n')), [r'$XCTOD,87,91,ARMED']);
  });

  test('two lines in one notification yield both, in order', () {
    final a = LineAssembler();
    expect(a.add(bytes('one\r\ntwo\r\n')), ['one', 'two']);
  });

  test('a partial tail is held for the next notification', () {
    final a = LineAssembler();
    expect(a.add(bytes('one\r\npar')), ['one']);
    expect(a.add(bytes('tial\r\n')), ['partial']);
  });

  test('bare LF without CR is accepted', () {
    final a = LineAssembler();
    expect(a.add(bytes('hello\n')), ['hello']);
  });

  test('a stream with no terminator is discarded rather than grown forever', () {
    final a = LineAssembler(maxBufferChars: 16);
    for (var i = 0; i < 10; i++) {
      expect(a.add(bytes('0123456789')), isEmpty);
    }
    // The buffer was dropped, so a line that arrives afterwards is clean.
    expect(a.add(bytes('clean\r\n')), ['clean']);
  });
}
