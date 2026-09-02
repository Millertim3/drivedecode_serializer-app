// lib/api/settings.dart
//
// Bench configuration: where the Worker is and what token to present.
//
// The admin token is a BENCH credential, not a shipped one. It is not in
// source, not in the repository, and not compiled into the binary — it is
// typed once on the machine that does the programming and kept in
// shared_preferences. If a bench laptop is lost, this is the thing to rotate,
// and rotating it costs one `wrangler secret put` and one dialog.
//
// The --dart-define overrides exist so a CI build or a second bench can be
// provisioned without a human opening the dialog. They win over stored values,
// mirroring drivedecode-app's Config.

import 'package:shared_preferences/shared_preferences.dart';

class BenchSettings {
  const BenchSettings({required this.baseUrl, required this.adminToken});

  final String baseUrl;
  final String adminToken;

  static const _defaultBaseUrl =
      String.fromEnvironment('API_BASE_URL', defaultValue: 'https://api.millerobd.com');
  static const _definedToken = String.fromEnvironment('ADMIN_BENCH_TOKEN');

  static const _urlKey = 'bench.base_url';
  static const _tokenKey = 'bench.admin_token';

  bool get configured => baseUrl.isNotEmpty && adminToken.isNotEmpty;

  static Future<BenchSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return BenchSettings(
      baseUrl: (prefs.getString(_urlKey) ?? _defaultBaseUrl).trim(),
      adminToken:
          (_definedToken.isNotEmpty ? _definedToken : prefs.getString(_tokenKey) ?? '')
              .trim(),
    );
  }

  static Future<void> save({
    required String baseUrl,
    required String adminToken,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    // Trailing slashes are the classic paste artefact and would turn every
    // path into a double-slashed URL that the Worker's route match rejects.
    await prefs.setString(_urlKey, baseUrl.trim().replaceAll(RegExp(r'/+$'), ''));
    await prefs.setString(_tokenKey, adminToken.trim());
  }
}
