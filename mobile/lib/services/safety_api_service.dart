import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class CrimeSpot {
  final int id;
  final double latitude;
  final double longitude;
  final double distanceKm;
  final double weight;

  CrimeSpot({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.distanceKm,
    required this.weight,
  });

  factory CrimeSpot.fromJson(Map<String, dynamic> json) {
    return CrimeSpot(
      id: (json['id'] as num).toInt(),
      latitude: (json['lat'] as num).toDouble(),
      longitude: (json['lng'] as num).toDouble(),
      distanceKm: (json['distance_km'] as num).toDouble(),
      weight: (json['weight'] as num).toDouble(),
    );
  }
}

class SafetyScore {
  final LatLng point;
  final int score;
  final String band;
  final int liveReportCount;
  final double liveRisk;
  final double historicalRisk;
  final List<CrimeSpot> nearbyCrimeSpots;

  SafetyScore({
    required this.point,
    required this.score,
    required this.band,
    required this.liveReportCount,
    required this.liveRisk,
    required this.historicalRisk,
    required this.nearbyCrimeSpots,
  });

  factory SafetyScore.fromJson(Map<String, dynamic> json) {
    final spots = (json['nearby_crime_spots'] as List? ?? []);

    return SafetyScore(
      point: LatLng(
        (json['lat'] as num).toDouble(),
        (json['lng'] as num).toDouble(),
      ),

      score: (json['safety_score'] as num).toInt(),

      band: json['band'] as String,

      liveReportCount:
          (json['live_report_count'] as num?)?.toInt() ?? 0,

      liveRisk:
          (json['live_risk'] as num?)?.toDouble() ?? 0.0,

      historicalRisk:
          (json['historical_risk'] as num?)?.toDouble() ?? 0.0,

      nearbyCrimeSpots: spots
          .map(
            (spot) => CrimeSpot.fromJson(
              Map<String, dynamic>.from(spot as Map),
            ),
          )
          .toList(),
    );
  }
}

class SafetyApiService {
  static const String baseUrl =
      'http://127.0.0.1:5000/api/safety';

  Future<SafetyScore> fetchScore(LatLng point) async {
    final uri = Uri.parse(
      '$baseUrl/score'
      '?lat=${point.latitude}'
      '&lng=${point.longitude}',
    );

    final response = await http.get(uri);

    if (response.statusCode != 200) {
      throw Exception(
        'Safety API failed: '
        '${response.statusCode} '
        '${response.body}',
      );
    }

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    return SafetyScore.fromJson(data);
  }

  Future<List<SafetyScore>> fetchScoresBatch(
    List<LatLng> points,
  ) async {
    final response = await http.post(
      Uri.parse('$baseUrl/scores/batch'),
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'points': points
            .map(
              (point) => {
                'lat': point.latitude,
                'lng': point.longitude,
              },
            )
            .toList(),
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Safety batch API failed: '
        '${response.statusCode} '
        '${response.body}',
      );
    }

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    return (data['results'] as List)
        .map(
          (item) => SafetyScore.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList();
  }

  Future<List<CrimeMapPoint>> fetchHeatmap({
    required String district,
    String state = '',
  }) async {
    final queryParameters = <String, String>{
      'district': district,
    };

    if (state.isNotEmpty) {
      queryParameters['state'] = state;
    }

    final uri = Uri.parse(
      '$baseUrl/heatmap',
    ).replace(
      queryParameters: queryParameters,
    );

    final response = await http.get(uri);

    if (response.statusCode != 200) {
      throw Exception(
        'Heatmap API failed: '
        '${response.statusCode} '
        '${response.body}',
      );
    }

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    final points = (data['points'] as List? ?? []);

    return points
        .map(
          (item) => CrimeMapPoint.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList();
  }
}

class CrimeMapPoint {
  final double latitude;
  final double longitude;
  final double weight;
  final int year;
  final int totalCrimes;

  CrimeMapPoint({
    required this.latitude,
    required this.longitude,
    required this.weight,
    required this.year,
    required this.totalCrimes,
  });

  factory CrimeMapPoint.fromJson(Map<String, dynamic> json) {
    return CrimeMapPoint(
      latitude: (json['lat'] as num).toDouble(),
      longitude: (json['lng'] as num).toDouble(),
      weight: (json['weight'] as num).toDouble(),
      year: (json['year'] as num).toInt(),
      totalCrimes: (json['total_crimes'] as num).toInt(),
    );
  }
}