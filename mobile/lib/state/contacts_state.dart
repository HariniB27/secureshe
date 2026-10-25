import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_service.dart';

class TrustedContact {
  TrustedContact({required this.id, required this.name, required this.phone});

  final int id;
  final String name;
  final String phone;

  /// "Best Friend" -> "BF", "Mom" -> "MO"
  String get initials {
    final parts = name.trim().split(RegExp(r'\s+'))..removeWhere((p) => p.isEmpty);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      final word = parts.first.toUpperCase();
      return word.length >= 2 ? word.substring(0, 2) : word;
    }
    return (parts.first[0] + parts[1][0]).toUpperCase();
  }

  /// A stable colour per contact, from the design's palette.
  Color get color {
    const palette = [
      Color(0xFFFF1493),
      Color(0xFF6C5CE7),
      Color(0xFFFFBE0B),
      Color(0xFF28C76F),
      Color(0xFFA78BFA),
    ];
    return palette[id.abs() % palette.length];
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone_number': phone};

  factory TrustedContact.fromJson(Map<String, dynamic> json) => TrustedContact(
        id: (json['id'] as num).toInt(),
        name: json['name'] as String? ?? '',
        phone: json['phone_number'] as String? ?? '',
      );
}

/// Trusted circle, from Sreshta's /api/sos/contacts.
///
/// Every successful load is cached on the phone, so the SOS screen can
/// still text your contacts with no internet (Sreshta's offline fallback,
/// reads the same cache key).
class ContactsState extends ChangeNotifier {
  /// Same key sos_service.dart reads for offline SMS.
  static const cachedNumbersKey = 'cached_trusted_contacts';
  static const _cachedListKey = 'cached_trusted_contacts_full';

  /// The backend allows up to 5 trusted contacts.
  static const maxContacts = 5;

  List<TrustedContact> contacts = [];
  bool loading = false;
  String? error;

  Future<void> loadCached() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cachedListKey);
      if (raw == null) return;
      contacts = (jsonDecode(raw) as List)
          .map((e) => TrustedContact.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> refresh() async {
    loading = true;
    error = null;
    notifyListeners();

    try {
      final response = await ApiService.listContacts();
      if (response.statusCode == 200) {
        contacts = (jsonDecode(response.body) as List)
            .map((e) => TrustedContact.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        await _cache();
      } else {
        error = 'Could not load your circle (${response.statusCode}).';
      }
    } catch (_) {
      error = 'Offline. Showing your last saved circle.';
    }

    loading = false;
    notifyListeners();
  }

  /// Returns null on success, otherwise a message to show.
  Future<String?> add(String name, String phone) async {
    try {
      final response = await ApiService.addContact(name: name, phone: phone);
      if (response.statusCode == 201) {
        await refresh();
        return null;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['error'] as String? ?? 'Could not add this contact.';
    } catch (_) {
      return 'Cannot reach the server. Check your connection and try again.';
    }
  }

  Future<String?> remove(TrustedContact contact) async {
    try {
      final response = await ApiService.deleteContact(contact.id);
      if (response.statusCode == 200) {
        await refresh();
        return null;
      }
      return 'Could not remove ${contact.name}.';
    } catch (_) {
      return 'Cannot reach the server. Check your connection and try again.';
    }
  }

  Future<void> clear() async {
    contacts = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cachedListKey);
    await prefs.remove(cachedNumbersKey);
    notifyListeners();
  }

  Future<void> _cache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _cachedListKey,
      jsonEncode(contacts.map((c) => c.toJson()).toList()),
    );
    await prefs.setStringList(
      cachedNumbersKey,
      contacts.map((c) => c.phone).toList(),
    );
  }
}
