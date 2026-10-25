import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../services/api_service.dart';
import '../utils/json_utils.dart';

/// App-wide auth/session state. Wrap the app in a `ChangeNotifierProvider<AuthState>`
/// (see main.dart) and read it with `context.watch<AuthState>()` / `context.read<AuthState>()`.
class AuthState extends ChangeNotifier {
  bool _isLoggedIn = false;
  String? _userName;
  String? _userEmail;
  String? _userPhone;
  DateTime? _joinedAt;
  int? _userId;

  bool get isLoggedIn => _isLoggedIn;
  String? get userName => _userName;
  String? get userEmail => _userEmail;
  String? get userPhone => _userPhone;
  DateTime? get joinedAt => _joinedAt;
  int? get userId => _userId;

  /// "Priya Sharma" -> "PS"
  String get initials {
    final parts = (_userName ?? '').trim().split(RegExp(r'\s+'))
      ..removeWhere((p) => p.isEmpty);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  /// Loads name, email and phone from GET /api/auth/me. Called after login
  /// and on startup, so the profile shows even after the app restarts.
  Future<void> loadProfile() async {
    try {
      final response = await ApiService.getMe();
      if (response.statusCode != 200) return;
      final data = tryDecodeMap(response.body);
      if (data == null) return;
      _applyUser(data);
      notifyListeners();
    } catch (_) {
      // Offline: keep whatever we already have.
    }
  }

  void _applyUser(Map<String, dynamic> user) {
    _userId = (user['id'] as num?)?.toInt() ?? _userId;
    _userName = user['name'] as String? ?? _userName;
    _userEmail = user['email'] as String? ?? _userEmail;
    _userPhone = user['phone'] as String? ?? _userPhone;
    final created = user['created_at'] as String?;
    if (created != null) _joinedAt = DateTime.tryParse(created);
  }

  /// Returns null on success, otherwise a message to show.
  Future<String?> updateProfile({String? name, String? phone}) async {
    try {
      final response = await ApiService.updateMe(name: name, phone: phone);
      final data = tryDecodeMap(response.body);
      if (response.statusCode != 200 || data == null) {
        return errorMessage(response, fallback: 'Could not save your changes.');
      }
      _applyUser(data);
      notifyListeners();
      return null;
    } catch (_) {
      return 'Cannot reach the server. Check your connection and try again.';
    }
  }

  /// Returns null on success, otherwise a message to show.
  Future<String?> changePassword(String current, String next) async {
    try {
      final response = await ApiService.changePassword(
        currentPassword: current,
        newPassword: next,
      );
      if (response.statusCode == 200) return null;
      return errorMessage(response, fallback: 'Could not change your password.');
    } catch (_) {
      return 'Cannot reach the server. Check your connection and try again.';
    }
  }

  /// Returns null on success (and signs out), otherwise a message to show.
  Future<String?> deleteAccount(String password) async {
    try {
      final response = await ApiService.deleteAccount(password);
      if (response.statusCode == 200) {
        await logout();
        return null;
      }
      return errorMessage(response, fallback: 'Could not delete your account.');
    } catch (_) {
      return 'Cannot reach the server. Check your connection and try again.';
    }
  }

  /// Reads persisted tokens on app startup. Returns true if there's an
  /// existing session, so the caller can skip straight to the home route
  /// instead of showing the login screen.
  ///
  /// A network failure here (backend unreachable) is treated the same as "no
  /// session" — falling back to the login screen — rather than leaving the
  /// caller's splash screen stuck waiting on a request that will never resolve.
  Future<bool> checkPersistedSession() async {
    final accessToken = await ApiService.getAccessToken();
    final refreshToken = await ApiService.getRefreshToken();

    if (accessToken == null || refreshToken == null) {
      _isLoggedIn = false;
      notifyListeners();
      return false;
    }

    // The access token may have expired while the app was closed — confirm
    // the session is still usable (and refresh it) rather than trusting it blindly.
    bool refreshed = false;
    try {
      refreshed = await ApiService.refreshAccessToken();
    } catch (_) {
      refreshed = false;
    }

    _isLoggedIn = refreshed;
    if (!refreshed) {
      await ApiService.clearTokens();
    } else {
      await loadProfile();
    }
    notifyListeners();
    return _isLoggedIn;
  }

  /// Logs in via POST /api/auth/login. Returns null on success, or a
  /// user-facing error message on failure — either the backend's own message
  /// (e.g. invalid credentials) or a distinct message when the request
  /// couldn't reach the server at all (no network / backend down).
  Future<String?> login({required String email, required String password}) async {
    http.Response response;
    try {
      response = await ApiService.login(email: email, password: password);
    } catch (_) {
      return 'Cannot reach the server. Check your connection and try again.';
    }

    // The body isn't always JSON (a 500 can come back as an HTML page), so
    // decoding is its own step and never throws.
    final data = tryDecodeMap(response.body);
    final user = data?['user'];

    if (response.statusCode == 200 && user is Map) {
      _applyUser(Map<String, dynamic>.from(user));
      _isLoggedIn = true;
      _sessionExpired = false;
      notifyListeners();
      // Fills in phone and join date, which login doesn't return.
      await loadProfile();
      return null;
    }

    return errorMessage(
      response,
      fallback: 'Something went wrong (server returned ${response.statusCode}). Please try again.',
    );
  }

  bool _sessionExpired = false;

  /// True after the server rejected our login token for good; the login
  /// screen shows a note once, then calls [clearSessionNotice].
  bool get sessionExpired => _sessionExpired;

  void clearSessionNotice() => _sessionExpired = false;

  /// Signs out because the session ended (not because the user asked to).
  Future<void> expireSession() async {
    _sessionExpired = true;
    await logout();
  }

  Future<void> logout() async {
    await ApiService.clearTokens();
    _isLoggedIn = false;
    _userName = null;
    _userEmail = null;
    _userPhone = null;
    _joinedAt = null;
    _userId = null;
    notifyListeners();
  }
}
