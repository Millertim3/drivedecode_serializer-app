// lib/ui/theme.dart
//
// A bench tool, not a consumer app. The palette is dark because these run in
// workshops under overhead light next to a pile of adapters, and the type is
// larger than a desktop default because the number on the success screen gets
// read onto a physical label from arm's length.

import 'package:flutter/material.dart';

const kBrand = Color(0xFF2F81F7);
const kGood = Color(0xFF3FB950);
const kWarn = Color(0xFFD29922);
const kBad = Color(0xFFF85149);

ThemeData benchTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: kBrand,
    brightness: Brightness.dark,
  ).copyWith(
    surface: const Color(0xFF0D1117),
    error: kBad,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFF0D1117),
    cardTheme: CardThemeData(
      color: const Color(0xFF161B22),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0xFF30363D)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(160, 48),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(120, 48)),
    ),
  );
}

/// The monospace stack for serials, tags and log lines.
///
/// Named per platform rather than left to the default: a proportional font
/// turns 'MTS00001043' into something an operator has to squint at, and the
/// whole point of the success screen is that the number is unambiguous.
const kMono = TextStyle(fontFamily: 'Menlo', fontFamilyFallback: [
  'Consolas',
  'Courier New',
  'monospace',
]);
