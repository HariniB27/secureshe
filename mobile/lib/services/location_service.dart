import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class LocationService {
  /// Asks for location access if needed.
  ///
  /// Returns null when location is usable, otherwise a short message to show
  /// the user. Screens should keep working without location.
  static Future<String?> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'Location is turned off on this device.';
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      return 'Location permission was denied.';
    }

    if (permission == LocationPermission.deniedForever) {
      return 'Location permission is blocked. Turn it on in Settings.';
    }

    return null;
  }

  /// A position as fast as possible, so the map doesn't sit waiting for a
  /// precise GPS lock: the phone's last known position first (instant), then
  /// a quick medium-accuracy fix. The live stream sharpens it afterwards.
  ///
  /// Returns null if nothing arrives within [timeLimit].
  static Future<Position?> quickFix({
    Duration timeLimit = const Duration(seconds: 8),
  }) async {
    if (!kIsWeb) {
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) return last;
      } catch (_) {}
    }

    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: timeLimit,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// Live position updates, sent whenever you move about 10 metres.
  static Stream<Position> positionStream() {
    return Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    );
  }
}
