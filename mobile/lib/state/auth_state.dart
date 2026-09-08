import 'dart:convert';

import 'package:flutter/foundation.dart';

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
    final refreshed = await ApiService.refreshAccessToken();
    _isLoggedIn = refreshed;
    if (!refreshed) {
      await ApiService.clearTokens();
    }
    notifyListeners();
    return _isLoggedIn;
  }

  /// Logs in via POST /api/auth/login. Returns null on success, or an error
  /// message from the backend on failure.
  Future<String?> login({required String email, required String password}) async {
    final response = await ApiService.login(email: email, password: password);
    debugPrint('LOGIN STATUS: ${response.statusCode}');
    debugPrint('LOGIN BODY: ${response.body}');
    
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final user = data['user'] as Map<String, dynamic>;
      _userName = user['name'] as String?;
      _userEmail = user['email'] as String?;
      _isLoggedIn = true;
      notifyListeners();
      return null;
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['error'] as String? ?? 'Login failed';
  }

  Future<void> logout() async {
    await ApiService.clearTokens();
    _isLoggedIn = false;
    _userName = null;
    _userEmail = null;
    notifyListeners();
  }
}
