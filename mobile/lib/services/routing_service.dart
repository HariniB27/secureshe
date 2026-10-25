import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config.dart';

enum TravelMode { walk, drive }

class PlaceResult {
  PlaceResult({
    required this.name,
    required this.detail,
    required this.point,
    this.distanceKm,
  });

  final String name;
  final String detail;
  final LatLng point;

  /// How far it is from where you are, when your location is known.
  final double? distanceKm;
}

/// What the routing server sent back for one trip.
class RouteSearchResult {
  RouteSearchResult({
    required this.routes,
    required this.snappedStart,
    required this.snappedEnd,
    required this.endSnapMetres,
  });

  final List<RouteOption> routes;

  /// The nearest walkable/drivable points to your start and destination.
  /// Every route goes between these two points.
  final LatLng snappedStart;
  final LatLng snappedEnd;

  /// Gap between the destination you picked and where the road/path ends,
  /// e.g. a place in the middle of a park or a campus.
  final double endSnapMetres;
}

class RouteOption {
  RouteOption({
    required this.points,
    required this.distanceMetres,
    required this.durationSeconds,
  });

  final List<LatLng> points;
  final double distanceMetres;
  final double durationSeconds;

  /// Filled in after the route is checked against the safety API.
  int? averageScore;
  int? lowestScore;

  /// From /route-check: share of the route on main roads, on isolated
  /// tracks/paths, and tagged as lit. Null if road data wasn't available.
  int? mainRoadPct;
  int? isolatedPct;
  int? litPct;
  List<String> warnings = const [];

  /// True for a walking option that follows the main roads (built from the
  /// driving route), offered because the walking router's own pick can go
  /// through fields and back paths.
  bool viaMainRoads = false;

  double get distanceKm => distanceMetres / 1000;
  double get durationMinutes => durationSeconds / 60;
}

/// Free OpenStreetMap services, no API key:
///   * Nominatim for searching places
///   * OSRM (routing.openstreetmap.de) for walking and driving routes
///
/// Both are community servers meant for light use. Fine for development and
/// demos; for a public launch, host your own or use a paid provider.
class RoutingService {
  static const _timeout = Duration(seconds: 15);

  /// Searches places, nearest first.
  ///
  /// When your location is known it first searches only within about 50 km
  /// of you, so a common name (a mall, a college) doesn't jump to another
  /// city. Only if nothing is found nearby does it search everywhere.
  Future<List<PlaceResult>> searchPlaces(String query, {LatLng? near}) async {
    if (near != null) {
      final nearby = await _nominatim(query, near: near, bounded: true);
      if (nearby.isNotEmpty) return nearby;
    }

    return _nominatim(query, near: near, bounded: false);
  }

  Future<List<PlaceResult>> _nominatim(
    String query, {
    LatLng? near,
    required bool bounded,
  }) async {
    final params = <String, String>{
      'q': query,
      'format': 'jsonv2',
      'limit': '8',
      'accept-language': 'en',
    };

    if (near != null) {
      const pad = 0.45; // about 50 km
      params['viewbox'] = '${near.longitude - pad},${near.latitude + pad},'
          '${near.longitude + pad},${near.latitude - pad}';
      if (bounded) params['bounded'] = '1';
    }

    final uri = Uri.https('nominatim.openstreetmap.org', '/search', params);
    final response =
        await http.get(uri, headers: MapConfig.httpHeaders).timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('Place search failed (${response.statusCode}).');
    }

    const distance = Distance();
    final results = (jsonDecode(response.body) as List<dynamic>).map((item) {
      final map = Map<String, dynamic>.from(item as Map);
      final full = map['display_name'] as String? ?? '';
      final name = (map['name'] as String?)?.trim();
      final point = LatLng(
        double.parse(map['lat'] as String),
        double.parse(map['lon'] as String),
      );

      return PlaceResult(
        name: (name == null || name.isEmpty) ? full.split(',').first : name,
        detail: full,
        point: point,
        distanceKm: near == null ? null : distance.distance(near, point) / 1000,
      );
    }).toList();

    if (near != null) {
      results.sort((a, b) => a.distanceKm!.compareTo(b.distanceKm!));
    }

    return results;
  }

  Future<RouteSearchResult> getRoutes(
    LatLng from,
    LatLng to,
    TravelMode mode,
  ) async {
    final server = mode == TravelMode.walk ? 'routed-foot' : 'routed-car';
    final coords = '${from.longitude},${from.latitude};'
        '${to.longitude},${to.latitude}';

    final uri = Uri.parse(
      'https://routing.openstreetmap.de/$server/route/v1/driving/$coords'
      '?alternatives=true&overview=full&geometries=geojson',
    );

    final response =
        await http.get(uri, headers: MapConfig.httpHeaders).timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('Route search failed (${response.statusCode}).');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    if (data['code'] != 'Ok') {
      throw Exception('No route found between these places.');
    }

    final waypoints = (data['waypoints'] as List<dynamic>? ?? [])
        .map((w) => Map<String, dynamic>.from(w as Map))
        .toList();

    LatLng waypointPoint(int i, LatLng fallback) {
      if (i >= waypoints.length) return fallback;
      final loc = waypoints[i]['location'] as List<dynamic>;
      return LatLng((loc[1] as num).toDouble(), (loc[0] as num).toDouble());
    }

    final routes = (data['routes'] as List<dynamic>? ?? []).map((route) {
      final r = Map<String, dynamic>.from(route as Map);
      final coordinates = (r['geometry'] as Map)['coordinates'] as List;

      return RouteOption(
        points: coordinates
            .map((c) => LatLng(
                  ((c as List)[1] as num).toDouble(),
                  (c[0] as num).toDouble(),
                ))
            .toList(),
        distanceMetres: (r['distance'] as num).toDouble(),
        durationSeconds: (r['duration'] as num).toDouble(),
      );
    }).toList();

    return RouteSearchResult(
      routes: routes,
      snappedStart: waypointPoint(0, from),
      snappedEnd: waypointPoint(1, to),
      endSnapMetres: waypoints.length > 1
          ? ((waypoints[1]['distance'] as num?)?.toDouble() ?? 0)
          : 0,
    );
  }

  /// Walking options: the walking router's own routes plus the driving
  /// routes walked on foot.
  ///
  /// The walking router picks the shortest path even if it's a lonely track
  /// across fields, and often returns just one route. Driving routes stay on
  /// proper roads, so they give a main-road alternative to compare against.
  Future<RouteSearchResult> getWalkingRoutes(LatLng from, LatLng to) async {
    final foot = await getRoutes(from, to, TravelMode.walk);

    RouteSearchResult? car;
    try {
      car = await getRoutes(from, to, TravelMode.drive);
    } catch (_) {
      // The walking routes alone are still usable.
    }

    final routes = <RouteOption>[...foot.routes];

    for (final route in car?.routes ?? const <RouteOption>[]) {
      // Driving routes can include one-way detours and roads closed to
      // walkers (expressways). Skip anything that is a big detour.
      final shortestFoot = foot.routes.isEmpty
          ? double.infinity
          : foot.routes.map((r) => r.distanceMetres).reduce(math.min);
      if (route.distanceMetres > shortestFoot * 1.6) continue;

      final walking = RouteOption(
        points: route.points,
        distanceMetres: route.distanceMetres,
        // About 4.5 km/h.
        durationSeconds: route.distanceMetres / 1.25,
      )..viaMainRoads = true;

      if (!routes.any((r) => _similar(r, walking))) routes.add(walking);
    }

    return RouteSearchResult(
      routes: routes,
      snappedStart: foot.snappedStart,
      snappedEnd: foot.snappedEnd,
      endSnapMetres: foot.endSnapMetres,
    );
  }

  /// Two routes are "the same" if most of one runs within 60 m of the other.
  static bool _similar(RouteOption a, RouteOption b) {
    const distance = Distance();
    final samples = _evenly(a.points, 15);
    final others = _evenly(b.points, 80);

    final close = samples.where((p) {
      return others.any((q) => distance.distance(p, q) < 60);
    }).length;

    return close >= samples.length * 0.85;
  }

  static List<LatLng> _evenly(List<LatLng> points, int count) {
    if (points.length <= count) return points;
    final step = (points.length - 1) / (count - 1);
    return [for (var i = 0; i < count; i++) points[(i * step).round()]];
  }
}
