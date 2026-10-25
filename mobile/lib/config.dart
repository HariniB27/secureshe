import 'package:flutter/foundation.dart';

/// One place for the backend address, so every screen talks to the same
/// server. The backend (run.py) defaults to port 5050 too.
///
/// Defaults:
///   * Android emulator -> http://10.0.2.2:5050 (the emulator's name for
///     your laptop)
///   * iOS simulator, desktop, web -> http://127.0.0.1:5050
///
/// To use a real phone or a different server, pass it when running:
///   flutter run --dart-define=API_BASE_URL=http://192.168.1.20:5050
/// (see README.md for the full list).
class ApiConfig {
  static const String _override = String.fromEnvironment('API_BASE_URL');

  static String get baseUrl {
    if (_override.isNotEmpty) return _override;

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:5050';
    }

    return 'http://127.0.0.1:5050';
  }

  static String get safetyUrl => '$baseUrl/api/safety';
}

/// OpenStreetMap and the free routing/search services ask every app to
/// identify itself.
class MapConfig {
  static const String userAgentPackageName = 'com.secureshe.mobile';

  static const String tileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  static const Map<String, String> httpHeaders = {
    'User-Agent': 'SecureShe/1.0 (com.secureshe.mobile)',
  };
}
