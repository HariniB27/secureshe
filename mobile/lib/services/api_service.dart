import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

/// Thin wrapper around the SecureShe backend API.
///
/// The server address comes from [ApiConfig] (see lib/config.dart).
class ApiService {
  static String get baseUrl => ApiConfig.baseUrl;

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
    String? category,
    bool anonymous = false,
    List<({Uint8List bytes, String filename})> files = const [],
  }) {
    return authedRequest((token) async {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/api/complaints/submit'),
      )
        ..headers['Authorization'] = 'Bearer $token'
        ..fields['description'] = description
        ..fields['anonymous'] = anonymous ? 'true' : 'false';

      if (category != null) request.fields['category'] = category;

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

      // Up to 5 files, each sent as another "evidence" part.
      for (final file in files) {
        request.files.add(
          http.MultipartFile.fromBytes('evidence', file.bytes, filename: file.filename),
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

  // ------------------------------------------------------------------
  // Account (added for the redesign)
  // ------------------------------------------------------------------

  static Map<String, String> _jsonHeaders(String token) => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

  /// GET /api/auth/me — the signed-in user's profile.
  static Future<http.Response> getMe() => authedRequest(
        (token) => http.get(
          Uri.parse('$baseUrl/api/auth/me'),
          headers: _jsonHeaders(token),
        ),
      );

  /// PUT /api/auth/me — update name and/or phone.
  static Future<http.Response> updateMe({String? name, String? phone}) =>
      authedRequest(
        (token) => http.put(
          Uri.parse('$baseUrl/api/auth/me'),
          headers: _jsonHeaders(token),
          body: jsonEncode({
            if (name != null) 'name': name,
            if (phone != null) 'phone': phone,
          }),
        ),
      );

  /// POST /api/auth/change-password
  static Future<http.Response> changePassword({
    required String currentPassword,
    required String newPassword,
  }) =>
      authedRequest(
        (token) => http.post(
          Uri.parse('$baseUrl/api/auth/change-password'),
          headers: _jsonHeaders(token),
          body: jsonEncode({
            'current_password': currentPassword,
            'new_password': newPassword,
          }),
        ),
      );

  /// DELETE /api/auth/me — permanently deletes the account.
  static Future<http.Response> deleteAccount(String password) => authedRequest(
        (token) => http.delete(
          Uri.parse('$baseUrl/api/auth/me'),
          headers: _jsonHeaders(token),
          body: jsonEncode({'password': password}),
        ),
      );

  // ------------------------------------------------------------------
  // Reports
  // ------------------------------------------------------------------

  /// GET /api/complaints/mine — your own reports, newest first.
  static Future<http.Response> myComplaints() => authedRequest(
        (token) => http.get(
          Uri.parse('$baseUrl/api/complaints/mine'),
          headers: _jsonHeaders(token),
        ),
      );

  /// GET /api/complaints/status/<id> — one of your reports.
  static Future<http.Response> complaintStatus(String id) => authedRequest(
        (token) => http.get(
          Uri.parse('$baseUrl/api/complaints/status/$id'),
          headers: _jsonHeaders(token),
        ),
      );

  // ------------------------------------------------------------------
  // Trusted circle and SOS (Sreshta's /api/sos endpoints)
  // ------------------------------------------------------------------

  static Future<http.Response> listContacts() => authedRequest(
        (token) => http.get(
          Uri.parse('$baseUrl/api/sos/contacts'),
          headers: _jsonHeaders(token),
        ),
      );

  static Future<http.Response> addContact({
    required String name,
    required String phone,
  }) =>
      authedRequest(
        (token) => http.post(
          Uri.parse('$baseUrl/api/sos/contacts'),
          headers: _jsonHeaders(token),
          body: jsonEncode({'name': name, 'phone_number': phone}),
        ),
      );

  static Future<http.Response> deleteContact(int id) => authedRequest(
        (token) => http.delete(
          Uri.parse('$baseUrl/api/sos/contacts/$id'),
          headers: _jsonHeaders(token),
        ),
      );

  static Future<http.Response> triggerSos({
    required double latitude,
    required double longitude,
  }) =>
      authedRequest(
        (token) => http.post(
          Uri.parse('$baseUrl/api/sos/trigger'),
          headers: _jsonHeaders(token),
          body: jsonEncode({'latitude': latitude, 'longitude': longitude}),
        ),
      );

  // ------------------------------------------------------------------
  // Community flags
  // ------------------------------------------------------------------

  /// POST /api/safety/flags — kind is dark-street, harassment,
  /// suspicious or safe-zone.
  static Future<http.Response> addFlag({
    required String kind,
    required double lat,
    required double lng,
  }) =>
      authedRequest(
        (token) => http.post(
          Uri.parse('$baseUrl/api/safety/flags'),
          headers: _jsonHeaders(token),
          body: jsonEncode({'kind': kind, 'lat': lat, 'lng': lng}),
        ),
      );
}
