import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Available UI languages. Adding one = add an ARB file + a row here +
// support its Locale in LocaleController.all.
enum AppLang {
  en(Locale('en'), 'English'),
  ar(Locale('ar'), 'العربية'),
  ru(Locale('ru'), 'Русский');

  const AppLang(this.locale, this.label);
  final Locale locale;
  final String label;

  static AppLang fromCode(String? code) => AppLang.values.firstWhere(
    (l) => l.locale.languageCode == code,
    orElse: () => AppLang.en,
  );
}

class LocaleController extends AsyncNotifier<AppLang> {
  static const _kKey = 'app_language';

  @override
  Future<AppLang> build() async {
    final prefs = await SharedPreferences.getInstance();
    return AppLang.fromCode(prefs.getString(_kKey));
  }

  Future<void> set(AppLang next) async {
    state = AsyncData(next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKey, next.locale.languageCode);
  }
}

final localeControllerProvider =
    AsyncNotifierProvider<LocaleController, AppLang>(LocaleController.new);
