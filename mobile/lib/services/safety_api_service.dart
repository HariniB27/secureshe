import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:google_maps_flutter/google_maps_flutter.dart';


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
  final List<CrimeSpot> nearbyCrimeSpots;

  SafetyScore({
    required this.point,
    required this.score,
    required this.band,
    required this.liveReportCount,
    required this.liveRisk,
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
      nearbyCrimeSpots: spots
          .map(
            (spot) => CrimeSpot.fromJson(
              spot as Map<String, dynamic>,
            ),
          )
          .toList(),
    );
  }
}


class SafetyApiService {

  /*
   * IMPORTANT:
   *
   * This URL depends on where Flutter is running.
   *
   * Android emulator:
   *     http://127.0.0.1:5000/api/safety
   *
   * iOS simulator / Mac:
   *     http://127.0.0.1:5000/api/safety
   *
   * Physical phone:
   *     use your Mac's local IP address.
   */

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
            item as Map<String, dynamic>,
          ),
        )
        .toList();
  }
}