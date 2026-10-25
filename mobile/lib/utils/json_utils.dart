import 'dart:convert';

import 'package:http/http.dart' as http;

/// Decodes a JSON object, or returns null when [body] isn't one (an HTML
/// error page, an empty body, a proxy message...). Never throws.
Map<String, dynamic>? tryDecodeMap(String body) {
  try {
    final value = jsonDecode(body);
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
  } catch (_) {}
  return null;
}

/// Decodes a JSON array, or returns null when [body] isn't one. Never throws.
List<dynamic>? tryDecodeList(String body) {
  try {
    final value = jsonDecode(body);
    if (value is List) return value;
  } catch (_) {}
  return null;
}

/// True when this 401 came from the login-token check (Flask-JWT-Extended
/// answers `{"msg": "..."}`), as opposed to our own "wrong password"
/// answers, which use `error` or `verified`.
bool isSessionExpiredResponse(http.Response response) {
  if (response.statusCode != 401) return false;
  final data = tryDecodeMap(response.body);
  return data != null && data.containsKey('msg') && !data.containsKey('error');
}

/// A message safe to show for a failed response: the server's own `error`
/// when it sent one, otherwise a plain description of what went wrong.
String errorMessage(http.Response response, {String fallback = 'Something went wrong. Try again.'}) {
  if (isSessionExpiredResponse(response)) {
    return 'Your session expired. Please sign in again.';
  }
  final data = tryDecodeMap(response.body);
  final error = data?['error'];
  if (error is String && error.isNotEmpty) return error;
  if (response.statusCode >= 500) return 'Server error, try again.';
  return fallback;
}
