import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../services/location_service.dart';
import 'app_prefs.dart';

enum CheckInStatus { done, current, pending }

class TripCheckIn {
  TripCheckIn({required this.label, required this.fraction, this.reachedAt});

  final String label;

  /// Where on the route this checkpoint sits, 0..1.
  final double fraction;
  DateTime? reachedAt;
}

/// The trip started from Safe Route ("Start Safe Trip").
///
/// While active it follows your GPS along the chosen route, works out how
/// far is left and when you'll arrive, ticks off checkpoints, warns you if
/// you go well off the route, and finishes when you reach the destination.
class TripState extends ChangeNotifier {
  TripState(this._prefs);

  final AppPrefs _prefs;
  final _distance = const Distance();

  /// A position further than this from the route counts as off-route.
  static const offRouteMetres = 150.0;

  /// Within this of the end counts as arrived.
  static const arrivedMetres = 60.0;

  bool active = false;
  bool arrived = false;
  bool offRoute = false;

  String destinationName = '';
  List<LatLng> route = const [];
  double totalMetres = 0;
  double plannedSeconds = 0;
  int? safetyScore;
  bool walking = true;

  DateTime? startedAt;
  LatLng? position;
  double progressMetres = 0;
  List<TripCheckIn> checkIns = [];

  StreamSubscription<Position>? _sub;
  List<double> _cumulative = const [];
  int _nearestIndex = 0;

  Duration get elapsed =>
      startedAt == null ? Duration.zero : DateTime.now().difference(startedAt!);

  double get remainingMetres => math.max(0, totalMetres - progressMetres);

  double get fractionDone => totalMetres <= 0 ? 0 : progressMetres / totalMetres;

  /// Time left at the planned pace for the remaining distance.
  Duration get eta {
    if (totalMetres <= 0) return Duration.zero;
    final seconds = plannedSeconds * (remainingMetres / totalMetres);
    return Duration(seconds: seconds.round());
  }

  CheckInStatus statusOf(TripCheckIn c) {
    if (c.reachedAt != null) return CheckInStatus.done;
    final next = checkIns.firstWhere(
      (x) => x.reachedAt == null,
      orElse: () => checkIns.last,
    );
    return identical(next, c) ? CheckInStatus.current : CheckInStatus.pending;
  }

  Future<String?> start({
    required String destinationName,
    required List<LatLng> route,
    required double distanceMetres,
    required double durationSeconds,
    required bool walking,
    int? safetyScore,
  }) async {
    if (route.length < 2) return 'This route has no path to follow.';

    final problem = await LocationService.ensurePermission();
    if (problem != null) return problem;

    await _sub?.cancel();

    this.destinationName = destinationName;
    this.route = List.unmodifiable(route);
    this.walking = walking;
    this.safetyScore = safetyScore;
    plannedSeconds = durationSeconds;

    final cumulative = <double>[0];
    for (var i = 1; i < route.length; i++) {
      cumulative.add(cumulative.last + _distance.distance(route[i - 1], route[i]));
    }
    _cumulative = cumulative;
    totalMetres = cumulative.last > 0 ? cumulative.last : distanceMetres;

    active = true;
    arrived = false;
    offRoute = false;
    startedAt = DateTime.now();
    progressMetres = 0;
    _nearestIndex = 0;
    position = route.first;

    checkIns = [
      TripCheckIn(label: 'Start', fraction: 0, reachedAt: startedAt),
      TripCheckIn(label: 'One third of the way', fraction: 1 / 3),
      TripCheckIn(label: 'Two thirds of the way', fraction: 2 / 3),
      TripCheckIn(label: destinationName, fraction: 1),
    ];

    _sub = LocationService.positionStream().listen(_onPosition);
    notifyListeners();
    return null;
  }

  void _onPosition(Position p) {
    if (!active) return;

    final here = LatLng(p.latitude, p.longitude);
    position = here;

    // Look a little behind and well ahead of the last match, so a route
    // that loops back near itself doesn't make progress jump around.
    final from = math.max(0, _nearestIndex - 5);
    final to = math.min(route.length - 1, _nearestIndex + 200);
    var best = _nearestIndex;
    var bestMetres = double.infinity;

    for (var i = from; i <= to; i++) {
      final d = _distance.distance(here, route[i]);
      if (d < bestMetres) {
        bestMetres = d;
        best = i;
      }
    }

    _nearestIndex = math.max(_nearestIndex, best);
    progressMetres = _cumulative[_nearestIndex];

    final wasOffRoute = offRoute;
    offRoute = bestMetres > offRouteMetres;
    if (offRoute && !wasOffRoute) {
      _prefs.notify(
        type: 'warning',
        title: 'You left your safe route',
        message: 'You are about ${bestMetres.round()} m from the planned route '
            'to $destinationName.',
      );
    }

    for (final c in checkIns) {
      if (c.reachedAt == null && fractionDone >= c.fraction - 0.02) {
        c.reachedAt = DateTime.now();
      }
    }

    if (_distance.distance(here, route.last) <= arrivedMetres) {
      _finish(arrivedSafely: true);
      return;
    }

    notifyListeners();
  }

  Future<void> end() => _finish(arrivedSafely: false);

  Future<void> _finish({required bool arrivedSafely}) async {
    await _sub?.cancel();
    _sub = null;

    if (arrivedSafely) {
      arrived = true;
      progressMetres = totalMetres;
      for (final c in checkIns) {
        c.reachedAt ??= DateTime.now();
      }
      await _prefs.recordSafeTrip();
      await _prefs.notify(
        type: 'success',
        title: 'Safe trip completed',
        message: 'You reached $destinationName safely.',
      );
    }

    active = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
