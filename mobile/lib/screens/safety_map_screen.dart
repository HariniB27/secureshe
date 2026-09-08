import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../services/api_service.dart';
import '../theme.dart';

/// Renders live safety scores from Janice's GET /api/safety/score and
/// POST /api/safety/scores/batch endpoints on an OpenStreetMap-backed map.
/// Tap anywhere on the map to score that point.
class SafetyMapScreen extends StatefulWidget {
  const SafetyMapScreen({super.key});

  @override
  State<SafetyMapScreen> createState() => _SafetyMapScreenState();
}

class _SafetyMapScreenState extends State<SafetyMapScreen> {
  static const _fallbackCenter = LatLng(20.0, 0.0);
  static const _fallbackZoom = 2.0;
  static const _focusedZoom = 14.0;

  final _mapController = MapController();

  LatLng? _currentPosition;
  LatLng? _selectedPosition;
  Map<String, dynamic>? _selectedScore;
  List<dynamic> _nearbyCrimeSpots = [];

  bool _isLoadingLocation = true;
  bool _isLoadingScore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initLocation();
  }

  Color _bandColor(String? band) {
    switch (band) {
      case 'green':
        return Colors.green;
      case 'yellow':
        return Colors.orange;
      case 'red':
        return Colors.red;
      default:
        return AppColors.navy;
    }
  }

  Future<void> _initLocation() async {
    setState(() {
      _isLoadingLocation = true;
      _error = null;
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          _error = 'Location services are off. Tap the map to check a safety score anywhere.';
          _isLoadingLocation = false;
        });
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        setState(() {
          _error = 'Location permission denied. Tap the map to check a safety score anywhere.';
          _isLoadingLocation = false;
        });
        return;
      }

      final position = await Geolocator.getCurrentPosition();
      final here = LatLng(position.latitude, position.longitude);

      if (!mounted) return;
      setState(() {
        _currentPosition = here;
        _isLoadingLocation = false;
      });

      _mapController.move(here, _focusedZoom);
      await _queryScore(here);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not get your location: $e';
        _isLoadingLocation = false;
      });
    }
  }

  Future<void> _queryScore(LatLng point) async {
    setState(() {
      _isLoadingScore = true;
      _error = null;
    });

    try {
      final response = await ApiService.getSafetyScore(lat: point.latitude, lng: point.longitude);

      if (!mounted) return;

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200) {
        setState(() {
          _selectedPosition = point;
          _selectedScore = data;
          _nearbyCrimeSpots = data['nearby_crime_spots'] as List<dynamic>? ?? [];
        });
      } else {
        setState(() => _error = data['error'] as String? ?? 'Could not load safety score');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Cannot reach the server. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _isLoadingScore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final score = _selectedScore;

    return Scaffold(
      appBar: AppBar(title: const Text('Safety Map')),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentPosition ?? _fallbackCenter,
              initialZoom: _currentPosition != null ? _focusedZoom : _fallbackZoom,
              onTap: (tapPosition, point) => _queryScore(point),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.secureshe.mobile',
              ),
              MarkerLayer(
                markers: [
                  if (_currentPosition != null)
                    Marker(
                      point: _currentPosition!,
                      width: 24,
                      height: 24,
                      child: const Icon(Icons.my_location, color: Colors.blue),
                    ),
                  for (final spot in _nearbyCrimeSpots)
                    Marker(
                      point: LatLng(
                        (spot as Map<String, dynamic>)['lat'] as double,
                        spot['lng'] as double,
                      ),
                      width: 16,
                      height: 16,
                      child: const Icon(Icons.circle, color: Colors.red, size: 12),
                    ),
                  if (_selectedPosition != null)
                    Marker(
                      point: _selectedPosition!,
                      width: 36,
                      height: 36,
                      child: Icon(
                        Icons.location_on,
                        color: _bandColor(score?['band'] as String?),
                        size: 36,
                      ),
                    ),
                ],
              ),
            ],
          ),
          if (_isLoadingLocation)
            const Center(child: CircularProgressIndicator()),
          if (_isLoadingScore)
            const Positioned(top: 16, left: 0, right: 0, child: Center(child: CircularProgressIndicator())),
          if (_error != null)
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: Material(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!, style: const TextStyle(color: Colors.red)),
                ),
              ),
            ),
          if (score != null)
            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.circle, color: _bandColor(score['band'] as String?), size: 14),
                          const SizedBox(width: 8),
                          Text(
                            'Safety score: ${score['safety_score']}',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text('${score['live_report_count']} nearby report(s) considered'),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _initLocation,
        tooltip: 'Use my location',
        child: const Icon(Icons.my_location),
      ),
    );
  }
}
