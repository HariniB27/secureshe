import 'dart:convert';

import 'package:http/http.dart' as http;

class RouteOption {
  final List<List<double>> coordinates;
  final double distance;
  final double duration;

  double crimeRisk;

  RouteOption({
    required this.coordinates,
    required this.distance,
    required this.duration,
    this.crimeRisk = 0,
  });

  double get distanceKm => distance / 1000;

  double get durationMinutes => duration / 60;
}

class DirectionsService {
  static const String accessToken =
      String.fromEnvironment('ACCESS_TOKEN');

  Future<List<RouteOption>> getRoutes({
    required double startLongitude,
    required double startLatitude,
    required double destinationLongitude,
    required double destinationLatitude,
  }) async {
    if (accessToken.isEmpty) {
      throw Exception(
        'Mapbox ACCESS_TOKEN is missing.',
      );
    }

    final coordinates =
        '$startLongitude,$startLatitude;'
        '$destinationLongitude,$destinationLatitude';

    final uri = Uri.parse(
      'https://api.mapbox.com/directions/v5/'
      'mapbox/driving/$coordinates'
      '?alternatives=true'
      '&geometries=geojson'
      '&overview=full'
      '&access_token=$accessToken',
    );

    final response = await http.get(uri);

    if (response.statusCode != 200) {
      throw Exception(
        'Directions API failed: ${response.statusCode}',
      );
    }

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    if (data['code'] != 'Ok') {
      throw Exception(
        data['message'] ??
            'Unable to calculate routes.',
      );
    }

    final routes =
        data['routes'] as List<dynamic>? ?? [];

    if (routes.isEmpty) {
      throw Exception(
        'No routes were found.',
      );
    }

    return routes.map((route) {
      final geometry =
          route['geometry'] as Map<String, dynamic>;

      final rawCoordinates =
          geometry['coordinates'] as List<dynamic>;

      final coordinates =
          rawCoordinates.map<List<double>>((point) {
        return [
          (point[0] as num).toDouble(),
          (point[1] as num).toDouble(),
        ];
      }).toList();

      return RouteOption(
        coordinates: coordinates,
        distance:
            (route['distance'] as num).toDouble(),
        duration:
            (route['duration'] as num).toDouble(),
      );
    }).toList();
  }
}