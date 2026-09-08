import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Thin wrapper around the SecureShe backend API.
///
/// Change [baseUrl] to point at whichever backend you're demoing against
/// (local dev server, a teammate's machine, staging, etc).
class ApiService {
  static const String baseUrl = 'http://127.0.0.1:5050';

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

  /// POST /api/complaints/submit — multipart, with an optional evidence file
  /// (photo or audio) and optional location. [locationSource] should be
  /// 'gps' or 'manual' when [lat]/[lng] are provided. Retries once via
  /// /api/auth/refresh on a 401.
  static Future<http.Response> submitComplaint({
    required String description,
    Uint8List? evidenceBytes,
    String? evidenceFilename,
    double? lat,
    double? lng,
    String? locationSource,
  }) {
    return authedRequest((token) async {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/api/complaints/submit'),
      )
        ..headers['Authorization'] = 'Bearer $token'
        ..fields['description'] = description;

      if (lat != null && lng != null) {
        request.fields['lat'] = lat.toString();
        request.fields['lng'] = lng.toString();
        if (locationSource != null) {
          request.fields['location_source'] = locationSource;
        }
      }

      if (evidenceBytes != null) {
        request.files.add(
          http.MultipartFile.fromBytes(
            'evidence',
            evidenceBytes,
            filename: evidenceFilename ?? 'evidence',
          ),
        );
      }

      final streamedResponse = await request.send();
      return http.Response.fromStream(streamedResponse);
    });
  }

  /// POST /api/auth/verify-password — re-checks the current user's password
  /// without issuing a new token. Retries once via /api/auth/refresh on a 401.
  static Future<http.Response> verifyPassword(String password) {
    return authedRequest((token) {
      return http.post(
        Uri.parse('$baseUrl/api/auth/verify-password'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'password': password}),
      );
    });
  }

  /// GET /api/safety/score?lat=&lng= — public, no auth required.
  static Future<http.Response> getSafetyScore({
    required double lat,
    required double lng,
  }) {
    return http.get(
      Uri.parse('$baseUrl/api/safety/score?lat=$lat&lng=$lng'),
    );
  }

  /// POST /api/safety/scores/batch — public, no auth required. Scores up to
  /// 200 {lat, lng} points in one request; used to paint many map markers
  /// without one HTTP call per marker.
  static Future<http.Response> getSafetyScoresBatch(
    List<({double lat, double lng})> points,
  ) {
    return http.post(
      Uri.parse('$baseUrl/api/safety/scores/batch'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'points': points.map((p) => {'lat': p.lat, 'lng': p.lng}).toList(),
      }),
    );
  }
}
