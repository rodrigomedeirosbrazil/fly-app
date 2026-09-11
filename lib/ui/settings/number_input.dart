import 'package:flutter/services.dart';

/// The keyboard and the input filter every numeric settings field uses.
///
/// `TextInputType.number` alone maps to iOS's `numberPad`, which has **no
/// decimal separator at all** -- four of these fields are decimal (per-cell
/// voltages, capacity in Ah, the BMS reference), so on an iPhone the pilot
/// could not type `3,15`. `decimal: true` is what puts the separator on the
/// key row.
///
/// The filter is deliberately an allow-list of digits and both separators
/// rather than a fixed-width mask: these fields have different lengths
/// (`3,15` V, `18` Ah, `140` °C) and a mask would have to decide each one's
/// shape in advance. It restricts the alphabet, not the format --
/// `parseSetting` is what judges the format, and it reports a field it cannot
/// read instead of substituting zero.
///
/// Neither is a guarantee: a pasted string, a hardware keyboard or `1.2.3`
/// still reach the controller's text. That is why the parse has to stay
/// honest.
const TextInputType kSettingsKeyboard =
    TextInputType.numberWithOptions(decimal: true);

final List<TextInputFormatter> kSettingsFormatters = [
  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
];
