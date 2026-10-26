import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telephony/telephony.dart';

import '../state/contacts_state.dart';
import 'api_service.dart';

class SosResult {
  SosResult({required this.sent, required this.message, this.viaSms = false});

  final bool sent;
  final String message;
  final bool viaSms;
}

/// Sreshta's SOS logic (originally sos_screen.dart), as a service the redesigned
/// SOS confirm screen can call:
///
///   1. Get your location.
///   2. Online: POST /api/sos/trigger (Twilio texts your circle).
///   3. Offline, or the server fails: text your circle straight from the
///      phone's SIM, using the contacts cached on the device.
///
/// Direct SMS only works on Android with a SIM (not iOS or most emulators).
class SosService {
  static Future<SosResult> send({void Function(String)? onStatus}) async {
    onStatus?.call('Getting your location…');

    Position position;
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
    } catch (e) {
      // Try the last known position before giving up.
      final last = await Geolocator.getLastKnownPosition();
      if (last == null) {
        return SosResult(sent: false, message: 'Could not get your location.');
      }
      position = last;
    }

    final connectivity = await Connectivity().checkConnectivity();
    // connectivity_plus 6.x returns a list. Offline = empty or only "none".
    final online = connectivity.isNotEmpty &&
        !connectivity.every((r) => r == ConnectivityResult.none);

    if (online) {
      onStatus?.call('Alerting your trusted circle…');
      try {
        // Don't leave someone waiting on a slow or hung server: after this,
        // fall back to texting from the SIM (Sreshta used 4 s on her phone;
        // 8 s leaves room for Twilio to text up to 5 contacts).
        final response = await ApiService.triggerSos(
          latitude: position.latitude,
          longitude: position.longitude,
        ).timeout(const Duration(seconds: 8));
        if (response.statusCode == 200) {
          return SosResult(
            sent: true,
            message: 'Your trusted circle was alerted with your location.',
          );
        }
        onStatus?.call('Server alert failed, texting directly…');
      } catch (_) {
        onStatus?.call('Network error, texting directly…');
      }
    }

    return _sendSms(position);
  }

  static Future<SosResult> _sendSms(Position position) async {
    // The telephony plugin only exists on Android. Say so plainly on iOS
    // instead of surfacing a MissingPluginException.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return SosResult(
        sent: false,
        message: 'Could not reach the server, and texting directly from the '
            'phone only works on Android. Call your contacts or emergency '
            'services directly.',
      );
    }

    try {
      final telephony = Telephony.instance;
      final granted = await telephony.requestSmsPermissions;
      if (granted != true) {
        return SosResult(
          sent: false,
          message: 'SMS permission denied, so the offline alert could not be sent.',
        );
      }

      final prefs = await SharedPreferences.getInstance();
      final numbers = prefs.getStringList(ContactsState.cachedNumbersKey) ?? [];

      if (numbers.isEmpty) {
        return SosResult(
          sent: false,
          message: 'No saved contacts on this phone. Open Circle once while '
              'online so they are available offline.',
        );
      }

      final link =
          'https://www.google.com/maps?q=${position.latitude},${position.longitude}';
      for (final number in numbers) {
        await telephony.sendSms(
          to: number,
          message: 'SOS ALERT: I need help. My location: $link',
        );
      }

      return SosResult(
        sent: true,
        viaSms: true,
        message: 'Texted ${numbers.length} contact${numbers.length == 1 ? '' : 's'} '
            'directly with your location.',
      );
    } catch (e) {
      return SosResult(sent: false, message: 'Could not send SMS: $e');
    }
  }
}
