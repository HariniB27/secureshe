// lib/screens/sos_screen.dart
//
// WHERE THIS GOES: lib/screens/sos_screen.dart
//
// Wired against the ACTUAL ApiService Harini built — uses ApiService.baseUrl
// and ApiService.authedRequest() (auto-retries once via /api/auth/refresh on
// an expired token).
//
// ALSO ADD a route for this screen in main.dart, replacing the current
// placeholder:
//   '/sos': (context) => const SosScreen(),
// (main.dart currently has '/sos': (context) => const PlaceholderScreen(...) )
//
// PACKAGES YOU NEED TO ADD to pubspec.yaml under dependencies:
//   geolocator: ^13.0.0
//   telephony: ^0.2.0          # sends real SMS from the device — works with NO internet
//   connectivity_plus: ^6.0.0  # detects online vs offline
//   shared_preferences: ^2.2.0 # caches trusted contacts for offline access
// (http is already a dependency, since api_service.dart uses it)
//
// Then run (from inside the mobile/ folder): flutter pub get
//
// ANDROID PERMISSIONS — add these inside <manifest> in
// android/app/src/main/AndroidManifest.xml (above <application>):
//   <uses-permission android:name="android.permission.SEND_SMS"/>
//   <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
//   <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
//
// IMPORTANT REALITY CHECK: the SEND_SMS permission and the `telephony`
// package only work on Android, and only on a real device or an emulator
// with a working SIM/radio — SMS cannot be sent from most emulators or
// from iOS. For your demo, use a real Android phone for the offline part,
// or clearly say "designed, not demoed live" if you only have an emulator.
//
// NOTE: the zone-alert / proactive feature has been deliberately left out
// of this file for now — add it back once Janice's safety-zone endpoint
// is ready and you've given me its exact route + response shape.

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:telephony/telephony.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

// Must match the same key used in trusted_contacts_screen.dart — that
// screen is what actually populates this cache whenever it successfully
// loads contacts from the server.
const String CACHED_CONTACTS_KEY = "cached_trusted_contacts";

class SosScreen extends StatefulWidget {
  const SosScreen({super.key});

  @override
  State<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends State<SosScreen> {
  bool _sending = false;
  String _statusText = "";

  Future<Position> _getCurrentLocation() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
  }

  Future<bool> _isOnline() async {
    final result = await Connectivity().checkConnectivity();
    return result != ConnectivityResult.none;
  }

  // ---------------------------------------------------------------------
  // MAIN SOS ACTION — decides online vs offline path automatically.
  // ---------------------------------------------------------------------
  Future<void> _handleSosPressed() async {
    setState(() { _sending = true; _statusText = "Getting your location..."; });

    Position position;
    try {
      position = await _getCurrentLocation();
    } catch (e) {
      setState(() { _sending = false; _statusText = "Could not get location: $e"; });
      return;
    }

    final online = await _isOnline();

    if (online) {
      await _sendOnlineSos(position);
    } else {
      await _sendOfflineSms(position);
    }
  }

  // ---------------------------------------------------------------------
  // ONLINE PATH — calls the Flask /api/sos/trigger endpoint (Twilio).
  // Currently expected to hit Twilio's trial-account template restriction
  // (documented separately) and fall through to the offline SMS path below
  // — that's the intended behavior for today's demo, not a bug.
  // ---------------------------------------------------------------------
  Future<void> _sendOnlineSos(Position position) async {
    setState(() { _statusText = "Sending SOS via server..."; });
    try {
      final response = await ApiService.authedRequest((token) => http.post(
        Uri.parse("${ApiService.baseUrl}/api/sos/trigger"),
        headers: {
          "Authorization": "Bearer $token",
          "Content-Type": "application/json",
        },
        body: jsonEncode({
          "latitude": position.latitude,
          "longitude": position.longitude,
        }),
      ));
      if (response.statusCode == 200) {
        setState(() { _sending = false; _statusText = "SOS sent to your trusted contacts."; });
      } else {
        // Server reachable but failed (e.g. Twilio error, no contacts) —
        // fall back to direct device SMS so the alert still goes out.
        setState(() { _statusText = "Server SOS failed, trying direct SMS..."; });
        await _sendOfflineSms(position);
      }
    } catch (e) {
      // Network dropped mid-request — fall back to direct SMS.
      setState(() { _statusText = "Network error, trying direct SMS..."; });
      await _sendOfflineSms(position);
    }
  }

  // ---------------------------------------------------------------------
  // OFFLINE / FALLBACK PATH — sends SMS directly from the phone's SIM,
  // no internet required at all. Reads the trusted contacts list from
  // local storage, since we can't call the backend here — that cache is
  // written by trusted_contacts_screen.dart every time it successfully
  // loads contacts from the server, so it's available even with no signal
  // (as long as the contacts screen has been opened online at least once).
  // ---------------------------------------------------------------------
  Future<void> _sendOfflineSms(Position position) async {
    final telephony = Telephony.instance;
    final bool? permissionsGranted = await telephony.requestSmsPermissions;

    if (permissionsGranted != true) {
      setState(() { _sending = false; _statusText = "SMS permission denied — cannot send offline alert."; });
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final cachedContactNumbers = prefs.getStringList(CACHED_CONTACTS_KEY) ?? [];

    if (cachedContactNumbers.isEmpty) {
      setState(() { _sending = false; _statusText = "No cached contacts available offline. Open Trusted Circle once while online first."; });
      return;
    }

    final mapsLink = "https://www.google.com/maps?q=${position.latitude},${position.longitude}";
    final message = "SOS ALERT (offline mode): I need help. My location: $mapsLink";

    for (final number in cachedContactNumbers) {
      await telephony.sendSms(to: number, message: message);
    }

    setState(() { _sending = false; _statusText = "SOS sent directly via SMS (offline mode)."; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("SOS")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: _sending ? null : _handleSosPressed,
              child: Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _sending ? Colors.grey : Colors.red,
                ),
                child: Center(
                  child: _sending
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text(
                          "SOS",
                          style: TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.bold),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(_statusText, textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}
