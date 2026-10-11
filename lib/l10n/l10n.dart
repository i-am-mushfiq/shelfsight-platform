import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'bn.dart';

/// App language. English text is the key: `t('Start visit')` returns the Bangla
/// translation when Bangla is chosen, and the English text itself when a translation
/// is missing, so nothing ever shows blank.
///
/// Values in `{name}` placeholders are filled from [params]; numbers are written with
/// Bangla digits in Bangla. Names (products, shops) are left as they are.
enum AppLanguage { en, bn }

final ValueNotifier<AppLanguage> appLanguage = ValueNotifier(AppLanguage.en);

bool get isBangla => appLanguage.value == AppLanguage.bn;

String t(String english, [Map<String, Object?> params = const {}]) {
  var text = isBangla ? (bnStrings[english] ?? english) : english;
  for (final entry in params.entries) {
    final value = entry.value;
    text = text.replaceAll('{${entry.key}}', value is num ? num2(value) : '${value ?? ''}');
  }
  return text;
}

/// Translates text that came as data (a store type, a status) when a translation exists.
String tr(String? english) => english == null ? '' : t(english);

const _bnDigits = '০১২৩৪৫৬৭৮৯';

/// Digits in the current language (Bangla digits in Bangla).
String digits(String text) =>
    isBangla ? text.replaceAllMapped(RegExp(r'[0-9]'), (m) => _bnDigits[int.parse(m[0]!)]) : text;

/// A number written for the current language: whole numbers as they are, others to one decimal.
String num2(num value) => digits(value == value.roundToDouble() ? value.round().toString() : value.toStringAsFixed(1));

Future<File> _languageFile() async =>
    File('${(await getApplicationDocumentsDirectory()).path}/language.txt');

/// Restores the language chosen on this phone. Called once at start-up.
Future<void> loadLanguage() async {
  try {
    final file = await _languageFile();
    if (await file.exists()) {
      final saved = (await file.readAsString()).trim();
      appLanguage.value = saved == 'bn' ? AppLanguage.bn : AppLanguage.en;
    }
  } catch (_) {
    // No storage (tests) or unreadable file: keep English.
  }
}

Future<void> setLanguage(AppLanguage language) async {
  appLanguage.value = language;
  try {
    await (await _languageFile()).writeAsString(language.name);
  } catch (_) {
    // Not saved: it still applies until the app closes.
  }
}
