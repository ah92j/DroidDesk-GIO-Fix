import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// A GitHub release newer than the installed app.
class AppRelease {
  final String tag;
  final String version;
  final String title;
  final String notes;
  final String pageUrl;
  final String apkUrl;
  final int apkSize;

  const AppRelease({
    required this.tag,
    required this.version,
    required this.title,
    required this.notes,
    required this.pageUrl,
    required this.apkUrl,
    required this.apkSize,
  });
}

/// Checks GitHub Releases for a newer DroidDesk build.
class UpdateService {
  static const repo = 'ah92j/DroidDesk-GIO-Fix';
  // Test builds can point at a local mock: --dart-define=DROIDDESK_UPDATE_URL=http://...
  static const _latestUrl = String.fromEnvironment(
    'DROIDDESK_UPDATE_URL',
    defaultValue: 'https://api.github.com/repos/$repo/releases/latest',
  );
  static const _lastCheckKey = 'update_last_check';
  static const _skippedTagKey = 'update_skipped_tag';
  static const checkInterval = Duration(hours: 6);

  /// Returns a newer release, or null.
  ///
  /// Automatic checks run at most every [checkInterval] and respect "Skip this version";
  /// [manual] checks always hit the network and report errors by throwing.
  static Future<AppRelease?> check({
    required String installedVersion,
    bool manual = false,
    bool force = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (!manual && !force) {
      final last = prefs.getInt(_lastCheckKey) ?? 0;
      final elapsed = DateTime.now().millisecondsSinceEpoch - last;
      if (elapsed < checkInterval.inMilliseconds) return null;
    }

    final Map<String, dynamic> json;
    try {
      json = await _fetchLatest();
    } catch (error) {
      if (manual) rethrow;
      return null;
    }
    await prefs.setInt(_lastCheckKey, DateTime.now().millisecondsSinceEpoch);

    final tag = json['tag_name']?.toString() ?? '';
    if (tag.isEmpty || json['draft'] == true || json['prerelease'] == true) return null;
    if (!isNewer(tag, installedVersion)) return null;
    if (!manual && prefs.getString(_skippedTagKey) == tag) return null;

    final assets = (json['assets'] as List? ?? const []).cast<Map>();
    final apk = assets.where(
      (asset) => asset['name'].toString().toLowerCase().endsWith('.apk'),
    );
    if (apk.isEmpty) return null;

    return AppRelease(
      tag: tag,
      version: _clean(tag),
      title: json['name']?.toString() ?? tag,
      notes: (json['body']?.toString() ?? '').trim(),
      pageUrl: json['html_url']?.toString() ?? 'https://github.com/$repo/releases',
      apkUrl: apk.first['browser_download_url'].toString(),
      apkSize: (apk.first['size'] as num?)?.toInt() ?? 0,
    );
  }

  static Future<void> skip(String tag) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_skippedTagKey, tag);
  }

  static Future<Map<String, dynamic>> _fetchLatest() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(_latestUrl));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'DroidDesk-Updater');
      final response = await request.close().timeout(const Duration(seconds: 15));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw HttpException('GitHub returned ${response.statusCode}');
      }
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  /// "v1.2.0" → "1.2.0"; drops a "-suffix" and "+build".
  static String _clean(String version) =>
      version.trim().replaceFirst(RegExp(r'^[vV]'), '').split(RegExp(r'[-+ ]')).first;

  /// True when [candidate] is a higher semantic version than [current].
  static bool isNewer(String candidate, String current) {
    List<int> parts(String v) =>
        _clean(v).split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final a = parts(candidate);
    final b = parts(current);
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}
