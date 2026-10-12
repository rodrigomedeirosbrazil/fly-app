// Numbers as a Brazilian pilot writes them: `50,8 V`, `5.830 rpm`.

String decimal(double v, int digits) =>
    v.toStringAsFixed(digits).replaceAll('.', ',');

String grouped(int v) {
  final digits = v.abs().toString();
  final out = StringBuffer(v < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write('.');
    out.write(digits[i]);
  }
  return out.toString();
}

/// `mm:ss`, and minutes keep counting past 60 rather than rolling over — a
/// paramotor flight is measured in minutes and an hour hand would be one
/// more thing to read.
String clock(Duration d) => '${d.inMinutes.toString().padLeft(2, '0')}:'
    '${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// `h:mm:ss`, for counters that run to hundreds of hours.
String hours(Duration d) => '${d.inHours}:'
    '${(d.inMinutes % 60).toString().padLeft(2, '0')}:'
    '${(d.inSeconds % 60).toString().padLeft(2, '0')}';
