import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config.dart';

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
  static String get baseUrl => ApiConfig.safetyUrl;

  static const Duration _timeout = Duration(seconds: 12);

  Future<SafetyScore> fetchScore(LatLng point) async {
    final uri = Uri.parse(
      '$baseUrl/score'
      '?lat=${point.latitude}'
      '&lng=${point.longitude}',
    );

    final response = await http.get(uri).timeout(_timeout);

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
    ).timeout(_timeout);

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

    final response = await http.get(uri).timeout(_timeout);

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

  /// Scores whole routes on crime, road type and lighting.
  /// [routes] are lists of evenly spaced points along each route.
  Future<RouteCheckResult> checkRoutes({
    required List<List<LatLng>> routes,
    required List<double> distancesMetres,
  }) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/route-check'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'hour': DateTime.now().hour,
            'routes': [
              for (var i = 0; i < routes.length; i++)
                {
                  'points': [
                    for (final p in routes[i]) [p.latitude, p.longitude],
                  ],
                  'distance_m': distancesMetres[i],
                },
            ],
          }),
        )
        // Road data can take a few seconds the first time.
        .timeout(const Duration(seconds: 40));

    if (response.statusCode != 200) {
      throw Exception('Route check failed: ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    return RouteCheckResult(
      night: data['night'] == true,
      environmentChecked: data['environment_checked'] == true,
      routes: (data['results'] as List)
          .map((r) => RouteSafety.fromJson(Map<String, dynamic>.from(r as Map)))
          .toList(),
    );
  }

  /// Recent complaint locations for the live map layer.
  ///
  /// Pass the [LiveReportsPage.serverTime] from the previous call as
  /// [since] to get only the reports added after it.
  Future<LiveReportsPage> fetchLiveReports({String? since}) async {
    final params = <String, String>{};
    if (since != null) params['since'] = since;

    final uri = Uri.parse('$baseUrl/live-reports')
        .replace(queryParameters: params.isEmpty ? null : params);

    final response = await http.get(uri).timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('Live reports failed: ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    return LiveReportsPage(
      reports: (data['features'] as List? ?? [])
          .map((f) => LiveReport.fromFeature(Map<String, dynamic>.from(f as Map)))
          .toList(),
      serverTime: data['server_time'] as String?,
    );
  }

  /// One point per district from the historical crime dataset.
  Future<List<DistrictCrime>> fetchDistrictCrime() async {
    final response = await http
        .get(Uri.parse('$baseUrl/historical-crime-points'))
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('Historical crime data failed: ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    return (data['features'] as List? ?? [])
        .map((f) => DistrictCrime.fromFeature(Map<String, dynamic>.from(f as Map)))
        .toList();
  }
}

class LiveReportsPage {
  final List<LiveReport> reports;
  final String? serverTime;

  LiveReportsPage({required this.reports, required this.serverTime});
}

/// A complaint location as the public map sees it: rounded position and
/// time only, no description or identity.
class LiveReport {
  final int id;
  final LatLng point;
  final DateTime? reportedAt;

  LiveReport({required this.id, required this.point, required this.reportedAt});

  factory LiveReport.fromFeature(Map<String, dynamic> feature) {
    final coords = (feature['geometry'] as Map)['coordinates'] as List;
    final props = Map<String, dynamic>.from(feature['properties'] as Map);
    final reported = props['reported_at'] as String?;

    return LiveReport(
      id: (props['id'] as num).toInt(),
      point: LatLng(
        (coords[1] as num).toDouble(),
        (coords[0] as num).toDouble(),
      ),
      reportedAt: reported == null ? null : DateTime.tryParse(reported),
    );
  }

  Duration? get age =>
      reportedAt == null ? null : DateTime.now().toUtc().difference(reportedAt!);
}

class DistrictCrime {
  final String district;
  final String state;
  final int year;
  final int totalCrimes;

  /// 0..1 relative to the worst district in the dataset.
  final double intensity;
  final LatLng point;

  DistrictCrime({
    required this.district,
    required this.state,
    required this.year,
    required this.totalCrimes,
    required this.intensity,
    required this.point,
  });

  factory DistrictCrime.fromFeature(Map<String, dynamic> feature) {
    final coords = (feature['geometry'] as Map)['coordinates'] as List;
    final props = Map<String, dynamic>.from(feature['properties'] as Map);

    return DistrictCrime(
      district: props['district'] as String? ?? '',
      state: props['state'] as String? ?? '',
      year: (props['year'] as num?)?.toInt() ?? 0,
      totalCrimes: (props['total_crimes'] as num?)?.toInt() ?? 0,
      intensity: (props['intensity'] as num?)?.toDouble() ?? 0,
      point: LatLng(
        (coords[1] as num).toDouble(),
        (coords[0] as num).toDouble(),
      ),
    );
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

class RouteCheckResult {
  RouteCheckResult({
    required this.night,
    required this.environmentChecked,
    required this.routes,
  });

  final bool night;

  /// False when road/lighting data couldn't be fetched; scores are then
  /// based on crime data only.
  final bool environmentChecked;
  final List<RouteSafety> routes;
}

class RouteSafety {
  RouteSafety({
    required this.score,
    required this.lowestCrimeScore,
    required this.warnings,
    this.mainRoadPct,
    this.isolatedPct,
    this.litPct,
  });

  final int score;
  final int lowestCrimeScore;
  final List<String> warnings;
  final int? mainRoadPct;
  final int? isolatedPct;
  final int? litPct;

  factory RouteSafety.fromJson(Map<String, dynamic> json) {
    return RouteSafety(
      score: (json['score'] as num).toInt(),
      lowestCrimeScore:
          (json['lowest_crime_score'] as num?)?.toInt() ?? 100,
      warnings: [
        for (final w in (json['warnings'] as List? ?? const [])) w.toString(),
      ],
      mainRoadPct: (json['main_road_pct'] as num?)?.toInt(),
      isolatedPct: (json['isolated_pct'] as num?)?.toInt(),
      litPct: (json['lit_pct'] as num?)?.toInt(),
    );
  }
}
