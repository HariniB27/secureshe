import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../services/api_service.dart';

/// App-wide auth/session state. Wrap the app in a `ChangeNotifierProvider<AuthState>`
/// (see main.dart) and read it with `context.watch<AuthState>()` / `context.read<AuthState>()`.
class AuthState extends ChangeNotifier {
  bool _isLoggedIn = false;
  String? _userName;
  String? _userEmail;

  bool get isLoggedIn => _isLoggedIn;
  String? get userName => _userName;
  String? get userEmail => _userEmail;

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

    try {
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200) {
        final user = data['user'] as Map<String, dynamic>;
        _userName = user['name'] as String?;
        _userEmail = user['email'] as String?;
        _isLoggedIn = true;
        notifyListeners();
        return null;
      }

      return data['error'] as String? ?? 'Login failed';
    } catch (_) {
      // The server responded, but not with the JSON we expect (e.g. a 500
      // with an HTML error page) — surface a generic message instead of
      // leaving the caller's loading state stuck on an uncaught exception.
      return 'Something went wrong (server returned ${response.statusCode}). Please try again.';
    }
  }

  Future<void> logout() async {
    await ApiService.clearTokens();
    _isLoggedIn = false;
    _userName = null;
    _userEmail = null;
    notifyListeners();
  }
}
