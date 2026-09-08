// lib/screens/trusted_contacts_screen.dart
//
// WHERE THIS GOES: lib/screens/trusted_contacts_screen.dart
// (alongside Harini's other screens — login_screen.dart, complaint_screen.dart, etc.)
//
// Wired against the ACTUAL ApiService (lib/services/api_service.dart) and
// AuthState (lib/state/auth_state.dart) Harini already built — uses
// ApiService.baseUrl and ApiService.authedRequest(), which auto-retries once
// via /api/auth/refresh if the access token has expired. No manual JWT
// handling needed here.
//
// ADD THIS PACKAGE to pubspec.yaml if not already present:
//   shared_preferences: ^2.2.0
// Then run: flutter pub get (from inside the mobile/ folder)
//
// ALSO ADD a route for this screen in main.dart, e.g.:
//   '/trusted-circle': (context) => const TrustedContactsScreen(),
// and a way to navigate to it (a button on the home/placeholder screen, or
// from the SOS screen) — there's no existing route or link to it yet.

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../services/api_service.dart';

// Shared cache key — sos_screen.dart reads this same key for the offline
// fallback path, so don't rename it without updating both files.
const String CACHED_CONTACTS_KEY = "cached_trusted_contacts";

class TrustedContactsScreen extends StatefulWidget {
  const TrustedContactsScreen({super.key});

  @override
  State<TrustedContactsScreen> createState() => _TrustedContactsScreenState();
}

class _TrustedContactsScreenState extends State<TrustedContactsScreen> {
  List<Map<String, dynamic>> _contacts = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    setState(() { _loading = true; _error = null; });
    try {
      final response = await ApiService.authedRequest((token) => http.get(
        Uri.parse("${ApiService.baseUrl}/api/sos/contacts"),
        headers: {"Authorization": "Bearer $token"},
      ));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        final contacts = data.cast<Map<String, dynamic>>();
        setState(() {
          _contacts = contacts;
          _loading = false;
        });
        await _cacheContactsLocally(contacts);
      } else {
        setState(() { _error = "Failed to load contacts (${response.statusCode})"; _loading = false; });
      }
    } catch (e) {
      setState(() { _error = "Error: $e"; _loading = false; });
    }
  }

  // ---------------------------------------------------------------------
  // Saves just the phone numbers to local device storage, so sos_screen.dart
  // can send offline SMS even with zero internet connection (it can't reach
  // the server to ask "who are my contacts" at that point, so it needs a
  // copy already sitting on the device from the last time this screen
  // loaded successfully online).
  // ---------------------------------------------------------------------
  Future<void> _cacheContactsLocally(List<Map<String, dynamic>> contacts) async {
    final prefs = await SharedPreferences.getInstance();
    final numbers = contacts.map((c) => c["phone_number"].toString()).toList();
    await prefs.setStringList(CACHED_CONTACTS_KEY, numbers);
  }

  Future<void> _addContact(String name, String phone) async {
    try {
      final response = await ApiService.authedRequest((token) => http.post(
        Uri.parse("${ApiService.baseUrl}/api/sos/contacts"),
        headers: {
          "Authorization": "Bearer $token",
          "Content-Type": "application/json",
        },
        body: jsonEncode({"name": name, "phone_number": phone}),
      ));
      if (response.statusCode == 201) {
        _loadContacts();
      } else {
        final body = jsonDecode(response.body);
        _showSnack(body["error"] ?? "Failed to add contact");
      }
    } catch (e) {
      _showSnack("Error: $e");
    }
  }

  Future<void> _deleteContact(int id) async {
    try {
      final response = await ApiService.authedRequest((token) => http.delete(
        Uri.parse("${ApiService.baseUrl}/api/sos/contacts/$id"),
        headers: {"Authorization": "Bearer $token"},
      ));
      if (response.statusCode == 200) {
        _loadContacts();
      } else {
        _showSnack("Failed to delete contact");
      }
    } catch (e) {
      _showSnack("Error: $e");
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showAddDialog() {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Add Trusted Contact"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: "Name"),
            ),
            TextField(
              controller: phoneController,
              decoration: const InputDecoration(
                labelText: "Phone (e.g. +919876543210)",
              ),
              keyboardType: TextInputType.phone,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _addContact(nameController.text.trim(), phoneController.text.trim());
            },
            child: const Text("Add"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Trusted Circle")),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : ListView.builder(
                  itemCount: _contacts.length,
                  itemBuilder: (ctx, i) {
                    final c = _contacts[i];
                    return ListTile(
                      leading: const Icon(Icons.person),
                      title: Text(c["name"]),
                      subtitle: Text(c["phone_number"]),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => _deleteContact(c["id"]),
                      ),
                    );
                  },
                ),
      floatingActionButton: _contacts.length >= 5
          ? null // max 5 reached, hide the add button
          : FloatingActionButton(
              onPressed: _showAddDialog,
              child: const Icon(Icons.add),
            ),
    );
  }
}
