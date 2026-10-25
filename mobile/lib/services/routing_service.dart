import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config.dart';

enum TravelMode { walk, drive }

class PlaceResult {
  PlaceResult({required this.name, required this.detail, required this.point});

  final String name;
  final String detail;
  final LatLng point;
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

  Future<List<PlaceResult>> searchPlaces(String query, {LatLng? near}) async {
    final params = <String, String>{
      'q': query,
      'format': 'jsonv2',
      'limit': '6',
      'accept-language': 'en',
    };

    // Prefer results around you, without excluding places further away.
    if (near != null) {
      const pad = 0.5;
      params['viewbox'] = '${near.longitude - pad},${near.latitude + pad},'
          '${near.longitude + pad},${near.latitude - pad}';
    }

    final uri = Uri.https('nominatim.openstreetmap.org', '/search', params);
    final response =
        await http.get(uri, headers: MapConfig.httpHeaders).timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('Place search failed (${response.statusCode}).');
    }

    final results = jsonDecode(response.body) as List<dynamic>;

    return results.map((item) {
      final map = Map<String, dynamic>.from(item as Map);
      final full = map['display_name'] as String? ?? '';
      final name = (map['name'] as String?)?.trim();

      return PlaceResult(
        name: (name == null || name.isEmpty) ? full.split(',').first : name,
        detail: full,
        point: LatLng(
          double.parse(map['lat'] as String),
          double.parse(map['lon'] as String),
        ),
      );
    }).toList();
  }

  Future<List<RouteOption>> getRoutes(
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

    final routes = data['routes'] as List<dynamic>? ?? [];

    return routes.map((route) {
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
  }
}
