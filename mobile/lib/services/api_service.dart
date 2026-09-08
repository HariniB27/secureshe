import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Thin wrapper around the SecureShe backend API.
///
/// Change [baseUrl] to point at whichever backend you're demoing against
/// (local dev server, a teammate's machine, staging, etc).
class ApiService {
  static const String baseUrl = 'http://127.0.0.1:5000';

  static const _storage = FlutterSecureStorage();
  static const _accessTokenKey = 'access_token';
  static const _refreshTokenKey = 'refresh_token';

  static Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await _storage.write(key: _accessTokenKey, value: accessToken);
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
  }

  static Future<String?> getAccessToken() => _storage.read(key: _accessTokenKey);

  static Future<String?> getRefreshToken() => _storage.read(key: _refreshTokenKey);

  static Future<void> clearTokens() async {
    await _storage.delete(key: _accessTokenKey);
    await _storage.delete(key: _refreshTokenKey);
  }

  /// POST /api/auth/register
  static Future<http.Response> register({
    required String name,
    required String email,
    required String password,
    required String phone,
  }) {
    return http.post(
      Uri.parse('$baseUrl/api/auth/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': name,
        'email': email,
        'password': password,
        'phone': phone,
      }),
    );
  }

  /// POST /api/auth/login — saves the returned tokens on success.
  static Future<http.Response> login({
    required String email,
    required String password,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      await saveTokens(
        accessToken: data['access_token'] as String,
        refreshToken: data['refresh_token'] as String,
      );
    }

    return response;
  }

  /// POST /api/auth/refresh — exchanges the stored refresh token for a new
  /// access token and persists it. Returns whether it succeeded.
  static Future<bool> refreshAccessToken() async {
    final refreshToken = await getRefreshToken();
    if (refreshToken == null) return false;

    final response = await http.post(
      Uri.parse('$baseUrl/api/auth/refresh'),
      headers: {'Authorization': 'Bearer $refreshToken'},
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      await _storage.write(
        key: _accessTokenKey,
        value: data['access_token'] as String,
      );
      return true;
    }

    return false;
  }

  /// Runs [request] with the current access token, and if it comes back 401
  /// (expired token), refreshes once via /api/auth/refresh and retries [request]
  /// with the new access token. Use like:
  ///
  ///   ApiService.authedRequest((token) => http.get(
  ///     Uri.parse('${ApiService.baseUrl}/api/complaints/status/$id'),
  ///     headers: {'Authorization': 'Bearer $token'},
  ///   ));
  static Future<http.Response> authedRequest(
    Future<http.Response> Function(String accessToken) request,
  ) async {
    final accessToken = await getAccessToken();
    var response = await request(accessToken ?? '');

    if (response.statusCode == 401) {
      final refreshed = await refreshAccessToken();
      if (refreshed) {
        final newAccessToken = await getAccessToken();
        response = await request(newAccessToken ?? '');
      }
    }

    return response;
  }
}
