import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One entry on the Notifications screen.
class AppNotification {
  AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.message,
    required this.time,
    this.read = false,
  });

  final String id;

  /// danger, warning, info or success (sets the colour).
  final String type;
  final String title;
  final String message;
  final DateTime time;
  bool read;

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'title': title,
        'message': message,
        'time': time.toIso8601String(),
        'read': read,
      };

  factory AppNotification.fromJson(Map<String, dynamic> json) => AppNotification(
        id: json['id'] as String,
        type: json['type'] as String? ?? 'info',
        title: json['title'] as String? ?? '',
        message: json['message'] as String? ?? '',
        time: DateTime.tryParse(json['time'] as String? ?? '') ?? DateTime.now(),
        read: json['read'] as bool? ?? false,
      );
}

/// Settings and small bits of history kept on this phone only.
///
/// Things that need the server (profile, reports, contacts) live in
/// AuthState and the API services instead.
class AppPrefs extends ChangeNotifier {
  static const _kTheme = 'pref_theme_dark';
  static const _kNotifications = 'pref_notifications';
  static const _kBiometric = 'pref_biometric_lock';
  static const _kAnonymous = 'pref_anonymous_reports';
  static const _kShareLocation = 'pref_share_location';
  static const _kSosLocation = 'pref_sos_location';
  static const _kStealth = 'pref_stealth';
  static const _kCrashReports = 'pref_crash_reports';
  static const _kMarketing = 'pref_marketing';
  static const _kTrips = 'stat_safe_trips';
  static const _kSosCount = 'stat_sos_alerts';
  static const _kNotificationLog = 'notification_log';
  static const _kPersonalExtras = 'personal_extras';

  SharedPreferences? _prefs;

  bool darkMode = true;
  bool notificationsOn = true;
  bool biometricLock = false;
  bool anonymousReports = false;
  bool shareLocationWithCircle = true;
  bool liveLocationOnSos = true;
  bool stealthMode = false;
  bool crashReports = true;
  bool marketingEmails = false;

  int safeTrips = 0;
  int sosAlerts = 0;

  List<AppNotification> notifications = [];

  /// Personal details the server doesn't store (date of birth, gender,
  /// city, blood type, allergies, medical notes). Kept on this phone only.
  Map<String, String> personalExtras = {};

  ThemeMode get themeMode => darkMode ? ThemeMode.dark : ThemeMode.light;

  int get unreadCount => notifications.where((n) => !n.read).length;

  Future<void> load() async {
    final p = _prefs = await SharedPreferences.getInstance();

    darkMode = p.getBool(_kTheme) ?? true;
    notificationsOn = p.getBool(_kNotifications) ?? true;
    biometricLock = p.getBool(_kBiometric) ?? false;
    anonymousReports = p.getBool(_kAnonymous) ?? false;
    shareLocationWithCircle = p.getBool(_kShareLocation) ?? true;
    liveLocationOnSos = p.getBool(_kSosLocation) ?? true;
    stealthMode = p.getBool(_kStealth) ?? false;
    crashReports = p.getBool(_kCrashReports) ?? true;
    marketingEmails = p.getBool(_kMarketing) ?? false;
    safeTrips = p.getInt(_kTrips) ?? 0;
    sosAlerts = p.getInt(_kSosCount) ?? 0;

    try {
      final raw = p.getString(_kNotificationLog);
      if (raw != null) {
        notifications = (jsonDecode(raw) as List)
            .map((e) => AppNotification.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      }
    } catch (_) {
      notifications = [];
    }

    try {
      final raw = p.getString(_kPersonalExtras);
      if (raw != null) {
        personalExtras = Map<String, String>.from(jsonDecode(raw) as Map);
      }
    } catch (_) {
      personalExtras = {};
    }

    notifyListeners();
  }

  Future<void> _setBool(String key, bool value) async {
    await _prefs?.setBool(key, value);
    notifyListeners();
  }

  Future<void> toggleTheme() {
    darkMode = !darkMode;
    return _setBool(_kTheme, darkMode);
  }

  Future<void> setNotifications(bool v) {
    notificationsOn = v;
    return _setBool(_kNotifications, v);
  }

  Future<void> setBiometricLock(bool v) {
    biometricLock = v;
    return _setBool(_kBiometric, v);
  }

  Future<void> setAnonymousReports(bool v) {
    anonymousReports = v;
    return _setBool(_kAnonymous, v);
  }

  Future<void> setShareLocation(bool v) {
    shareLocationWithCircle = v;
    return _setBool(_kShareLocation, v);
  }

  Future<void> setSosLocation(bool v) {
    liveLocationOnSos = v;
    return _setBool(_kSosLocation, v);
  }

  Future<void> setStealth(bool v) {
    stealthMode = v;
    return _setBool(_kStealth, v);
  }

  Future<void> setCrashReports(bool v) {
    crashReports = v;
    return _setBool(_kCrashReports, v);
  }

  Future<void> setMarketing(bool v) {
    marketingEmails = v;
    return _setBool(_kMarketing, v);
  }

  Future<void> recordSafeTrip() async {
    safeTrips++;
    await _prefs?.setInt(_kTrips, safeTrips);
    notifyListeners();
  }

  Future<void> recordSos() async {
    sosAlerts++;
    await _prefs?.setInt(_kSosCount, sosAlerts);
    notifyListeners();
  }

  Future<void> savePersonalExtras(Map<String, String> extras) async {
    personalExtras = Map.of(extras);
    await _prefs?.setString(_kPersonalExtras, jsonEncode(personalExtras));
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Notification log
  // ------------------------------------------------------------------

  /// Adds a notification (newest first, last 50 kept). Ignored when
  /// notifications are switched off in Profile.
  Future<void> notify({
    required String type,
    required String title,
    required String message,
  }) async {
    if (!notificationsOn) return;

    notifications.insert(
      0,
      AppNotification(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        type: type,
        title: title,
        message: message,
        time: DateTime.now(),
      ),
    );
    if (notifications.length > 50) notifications = notifications.sublist(0, 50);
    await _saveNotifications();
  }

  Future<void> markAllRead() async {
    for (final n in notifications) {
      n.read = true;
    }
    await _saveNotifications();
  }

  Future<void> dismiss(String id) async {
    notifications.removeWhere((n) => n.id == id);
    await _saveNotifications();
  }

  Future<void> clearAccountData() async {
    notifications = [];
    personalExtras = {};
    safeTrips = 0;
    sosAlerts = 0;
    await _prefs?.remove(_kNotificationLog);
    await _prefs?.remove(_kPersonalExtras);
    await _prefs?.remove(_kTrips);
    await _prefs?.remove(_kSosCount);
    notifyListeners();
  }

  Future<void> _saveNotifications() async {
    await _prefs?.setString(
      _kNotificationLog,
      jsonEncode(notifications.map((n) => n.toJson()).toList()),
    );
    notifyListeners();
  }
}
