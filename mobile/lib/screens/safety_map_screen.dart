import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;

class SafetyMapScreen extends StatefulWidget {
  const SafetyMapScreen({super.key});

  @override
  State<SafetyMapScreen> createState() => _SafetyMapScreenState();
}

class _SafetyMapScreenState extends State<SafetyMapScreen> {
  mb.MapboxMap? _mapboxMap;
  geo.Position? _userPosition;

  // ============================================================
  // API
  // ============================================================

  static const String apiUrl =
      'http://127.0.0.1:5000/api/safety/historical-crime-points';

  // ============================================================
  // MAPBOX IDS
  // ============================================================

  static const String sourceId = 'crime-source';

  static const String clusterLayerId = 'crime-clusters';

  static const String clusterCountLayerId = 'crime-cluster-count';

  static const String individualLayerId = 'individual-crimes';

  // ============================================================
  // STATE
  // ============================================================

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
  }

  // ============================================================
  // MAP CREATED
  // ============================================================

  void _onMapCreated(mb.MapboxMap mapboxMap) {
    _mapboxMap = mapboxMap;
  }

  // ============================================================
  // STYLE LOADED
  // ============================================================

  Future<void> _onStyleLoaded(mb.StyleLoadedEventData eventData) async {
    try {
      // 1. Load crime data FIRST.
      await _loadCrimePoints();

      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = null;
      });

      // 2. Then try to find the user's location.
      // If location fails, the crime map still remains visible.
      try {
        await _getUserLocation();
      } catch (e) {
        debugPrint('Location error: $e');
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  // ============================================================
  // GET USER LOCATION
  // ============================================================

  Future<void> _getUserLocation() async {
    final serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      throw Exception('Location services are disabled.');
    }

    geo.LocationPermission permission = await geo.Geolocator.checkPermission();

    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
    }

    if (permission == geo.LocationPermission.denied) {
      throw Exception('Location permission was denied.');
    }

    if (permission == geo.LocationPermission.deniedForever) {
      throw Exception('Location permission is permanently denied.');
    }

    final position =
        await geo.Geolocator.getCurrentPosition(
          locationSettings: const geo.LocationSettings(
            accuracy: geo.LocationAccuracy.high,
          ),
        ).timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            throw Exception('Could not get your location within 10 seconds.');
          },
        );

    if (!mounted) return;

    setState(() {
      _userPosition = position;
    });

    // Move Mapbox camera to the user's location.
    await _mapboxMap?.setCamera(
      mb.CameraOptions(
        center: mb.Point(
          coordinates: mb.Position(position.longitude, position.latitude),
        ),
        zoom: 14.0,
      ),
    );
  }

  // ============================================================
  // LOAD CRIME DATA
  // ============================================================

  Future<void> _loadCrimePoints() async {
    if (_mapboxMap == null) {
      throw Exception('Mapbox map is not initialized.');
    }

    final response = await http.get(Uri.parse(apiUrl));

    if (response.statusCode != 200) {
      throw Exception('Crime API failed: ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    final features = data['features'] as List<dynamic>? ?? [];

    if (features.isEmpty) {
      throw Exception('No crime locations were returned by the API.');
    }

    final featureCollection = jsonEncode(data);

    // ------------------------------------------------------------
    // SOURCE
    // ------------------------------------------------------------

    final source = mb.GeoJsonSource(
      id: sourceId,
      data: featureCollection,

      // Enable Mapbox clustering.
      cluster: true,

      // Distance at which points are grouped.
      clusterRadius: 60,

      // After zoom 14, show individual points.
      clusterMaxZoom: 14,
    );

    await _mapboxMap!.style.addSource(source);

    // ------------------------------------------------------------
    // LAYERS
    // ------------------------------------------------------------

    await _addClusterLayer();

    await _addClusterCountLayer();

    await _addIndividualCrimeLayer();
  }

  // ============================================================
  // CLUSTER CIRCLES
  // ============================================================

  Future<void> _addClusterLayer() async {
    final layer = mb.CircleLayer(id: clusterLayerId, sourceId: sourceId);

    // Only clustered points.
    layer.filter = ['has', 'point_count'];

    // Make the cluster size depend on number of crimes.
    layer.circleRadius = 20.0;

    // RED
    layer.circleColor = Colors.red.toARGB32();

    // White outline.
    layer.circleStrokeWidth = 2.0;

    layer.circleStrokeColor = Colors.white.toARGB32();

    await _mapboxMap!.style.addLayer(layer);
  }

  // ============================================================
  // CLUSTER COUNT
  // ============================================================

  Future<void> _addClusterCountLayer() async {
    final layer = mb.SymbolLayer(id: clusterCountLayerId, sourceId: sourceId);

    // Only clustered points.
    layer.filter = ['has', 'point_count'];

    // Display number of crimes/points in cluster.
    layer.textField = '{point_count_abbreviated}';

    layer.textSize = 14.0;

    layer.textColor = Colors.white.toARGB32();

    layer.textIgnorePlacement = true;

    layer.textAllowOverlap = true;

    await _mapboxMap!.style.addLayer(layer);
  }

  // ============================================================
  // INDIVIDUAL CRIME POINTS
  // ============================================================

  Future<void> _addIndividualCrimeLayer() async {
    final layer = mb.CircleLayer(id: individualLayerId, sourceId: sourceId);

    // Show only non-clustered points.
    layer.filter = [
      '!',
      ['has', 'point_count'],
    ];

    // Individual crime spot size.
    layer.circleRadius = 7.0;

    // Orange individual crime point.
    layer.circleColor = Colors.orange.toARGB32();

    layer.circleStrokeWidth = 1.5;

    layer.circleStrokeColor = Colors.white.toARGB32();

    await _mapboxMap!.style.addLayer(layer);
  }

  // ============================================================
  // MOVE TO USER LOCATION
  // ============================================================

  Future<void> _goToMyLocation() async {
    try {
      await _getUserLocation();
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SecureShe Crime Map')),

      body: Stack(
        children: [
          // ------------------------------------------------------
          // MAP
          // ------------------------------------------------------

          mb.MapWidget(
            viewport: mb.CameraViewportState(
              center: mb.Point(coordinates: mb.Position(77.5946, 12.9716)),
              zoom: 5.0,
            ),

            onMapCreated: _onMapCreated,

            onStyleLoadedListener: _onStyleLoaded,
          ),

          // ------------------------------------------------------
          // LOADING
          // ------------------------------------------------------
          if (_loading)
            const Center(
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),

                      SizedBox(width: 12),

                      Text('Loading crime map...'),
                    ],
                  ),
                ),
              ),
            ),

          // ------------------------------------------------------
          // ERROR
          // ------------------------------------------------------
          if (_error != null)
            Center(
              child: Card(
                margin: const EdgeInsets.all(24),

                child: Padding(
                  padding: const EdgeInsets.all(20),

                  child: Column(
                    mainAxisSize: MainAxisSize.min,

                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: Colors.red,
                        size: 40,
                      ),

                      const SizedBox(height: 12),

                      const Text(
                        'Unable to load crime map',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),

                      const SizedBox(height: 8),

                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.red),
                      ),

                      const SizedBox(height: 16),

                      ElevatedButton(
                        onPressed: () async {
                          setState(() {
                            _loading = true;
                            _error = null;
                          });

                          try {
                            await _loadCrimePoints();

                            if (!mounted) return;

                            setState(() {
                              _loading = false;
                            });

                            try {
                              await _getUserLocation();
                            } catch (e) {
                              debugPrint('Location error: $e');
                            }
                          } catch (e) {
                            if (!mounted) return;

                            setState(() {
                              _loading = false;
                              _error = e.toString();
                            });
                          }
                        },
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ------------------------------------------------------
          // MY LOCATION BUTTON
          // ------------------------------------------------------
          Positioned(
            right: 16,
            bottom: 180,
            child: FloatingActionButton(
              heroTag: 'my-location',
              onPressed: _goToMyLocation,
              child: const Icon(Icons.my_location),
            ),
          ),

          // ------------------------------------------------------
          // LEGEND
          // ------------------------------------------------------
          Positioned(left: 16, bottom: 16, child: _buildLegend()),
        ],
      ),
    );
  }

  // ============================================================
  // LEGEND
  // ============================================================

  Widget _buildLegend() {
    return Card(
      elevation: 5,

      child: Padding(
        padding: const EdgeInsets.all(12),

        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,

          children: [
            const Text(
              'Crime Density',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),

            const SizedBox(height: 8),

            _legendItem(Colors.green, 'Low', '1 location'),

            _legendItem(Colors.yellow, 'Medium', '2–4 locations'),

            _legendItem(Colors.orange, 'High', '5–9 locations'),

            _legendItem(Colors.red, 'Very High', '10+ locations'),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // LEGEND ITEM
  // ============================================================

  Widget _legendItem(Color color, String title, String description) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),

      child: Row(
        mainAxisSize: MainAxisSize.min,

        children: [
          Container(
            width: 14,
            height: 14,

            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),

          const SizedBox(width: 8),

          Text('$title — $description'),
        ],
      ),
    );
  }
}
