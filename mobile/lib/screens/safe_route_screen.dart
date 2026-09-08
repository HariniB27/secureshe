import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

class SafeRouteScreen extends StatefulWidget {
  const SafeRouteScreen({super.key});

  @override
  State<SafeRouteScreen> createState() => _SafeRouteScreenState();
}

class _SafeRouteScreenState extends State<SafeRouteScreen> {
  mapbox.MapboxMap? _map;

  geo.Position? _userPosition;

  final TextEditingController _destinationController =
      TextEditingController();

  bool _loadingLocation = true;
  bool _searching = false;

  String? _error;

  String? _destinationName;

  double? _routeDistanceKm;
  double? _routeDurationMinutes;

  List<List<double>> _routeCoordinates = [];

  static const String accessToken =
      String.fromEnvironment('ACCESS_TOKEN');

  @override
  void initState() {
    super.initState();
    _getCurrentLocation();
  }

  @override
  void dispose() {
    _destinationController.dispose();
    super.dispose();
  }

  // ============================================================
  // MAP CREATED
  // ============================================================

  void _onMapCreated(mapbox.MapboxMap map) {
    _map = map;

    _moveToUserLocation();
  }

  // ============================================================
  // GET USER LOCATION
  // ============================================================

  Future<void> _getCurrentLocation() async {
    try {
      setState(() {
        _loadingLocation = true;
        _error = null;
      });

      final serviceEnabled =
          await geo.Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        throw Exception(
          'Location services are disabled.',
        );
      }

      geo.LocationPermission permission =
          await geo.Geolocator.checkPermission();

      if (permission == geo.LocationPermission.denied) {
        permission =
            await geo.Geolocator.requestPermission();
      }

      if (permission == geo.LocationPermission.denied) {
        throw Exception(
          'Location permission was denied.',
        );
      }

      if (permission ==
          geo.LocationPermission.deniedForever) {
        throw Exception(
          'Location permission is permanently denied.',
        );
      }

      final position =
          await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );

      if (!mounted) return;

      setState(() {
        _userPosition = position;
        _loadingLocation = false;
      });

      await _moveToUserLocation();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loadingLocation = false;
        _error = e.toString();
      });
    }
  }

  // ============================================================
  // MOVE MAP TO USER
  // ============================================================

  Future<void> _moveToUserLocation() async {
    final position = _userPosition;
    final map = _map;

    if (position == null || map == null) {
      return;
    }

    await map.setCamera(
      mapbox.CameraOptions(
        center: mapbox.Point(
          coordinates: mapbox.Position(
            position.longitude,
            position.latitude,
          ),
        ),
        zoom: 15.0,
      ),
    );
  }

  // ============================================================
  // SEARCH DESTINATION
  // ============================================================

  Future<List<double>?> _searchDestination(
    String query,
  ) async {
    if (accessToken.isEmpty) {
      throw Exception(
        'Mapbox access token is missing.',
      );
    }

    final user = _userPosition;

    String proximity = '';

    if (user != null) {
      proximity =
          '&proximity=${user.longitude},${user.latitude}';
    }

    final url = Uri.parse(
      'https://api.mapbox.com/search/searchbox/v1/forward'
      '?q=${Uri.encodeComponent(query)}'
      '&limit=1'
      '&language=en'
      '$proximity'
      '&access_token=$accessToken',
    );

    final response = await http.get(url);

    if (response.statusCode != 200) {
      throw Exception(
        'Destination search failed: ${response.statusCode}',
      );
    }

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    final features =
        data['features'] as List<dynamic>?;

    if (features == null || features.isEmpty) {
      throw Exception(
        'Destination not found. Try entering a more specific place.',
      );
    }

    final feature =
        features.first as Map<String, dynamic>;

    final geometry =
        feature['geometry'] as Map<String, dynamic>;

    final coordinates =
        geometry['coordinates'] as List<dynamic>;

    final properties =
        feature['properties'] as Map<String, dynamic>?;

    String name = query;

    if (properties != null) {
      name =
          properties['name_preferred']?.toString() ??
              properties['name']?.toString() ??
              properties['full_address']?.toString() ??
              query;
    }

    _destinationName = name;

    return [
      (coordinates[0] as num).toDouble(),
      (coordinates[1] as num).toDouble(),
    ];
  }

  // ============================================================
  // GET ROUTE FROM MAPBOX DIRECTIONS
  // ============================================================

  Future<Map<String, dynamic>> _getRoute(
    List<double> destination,
  ) async {
    if (accessToken.isEmpty) {
      throw Exception(
        'Mapbox access token is missing.',
      );
    }

    final user = _userPosition;

    if (user == null) {
      throw Exception(
        'Current location is not available.',
      );
    }

    final origin =
        '${user.longitude},${user.latitude}';

    final destinationString =
        '${destination[0]},${destination[1]}';

    final coordinates =
        '$origin;$destinationString';

    final url = Uri.parse(
      'https://api.mapbox.com/directions/v5/mapbox/driving/'
      '$coordinates'
      '?alternatives=true'
      '&geometries=geojson'
      '&overview=full'
      '&steps=true'
      '&access_token=$accessToken',
    );

    final response = await http.get(url);

    if (response.statusCode != 200) {
      throw Exception(
        'Route request failed: ${response.statusCode}',
      );
    }

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    if (data['code'] != 'Ok') {
      throw Exception(
        'Mapbox could not find a route.',
      );
    }

    final routes =
        data['routes'] as List<dynamic>?;

    if (routes == null || routes.isEmpty) {
      throw Exception(
        'No route was found.',
      );
    }

    return routes.first as Map<String, dynamic>;
  }

  // ============================================================
  // FIND ROUTE
  // ============================================================

  Future<void> _findRoute() async {
    final query =
        _destinationController.text.trim();

    if (query.isEmpty) {
      _showMessage(
        'Please enter a destination.',
      );
      return;
    }

    if (_userPosition == null) {
      _showMessage(
        'Your current location is still being detected.',
      );
      return;
    }

    try {
      setState(() {
        _searching = true;
        _error = null;
      });

      // --------------------------------------------------------
      // STEP 1: SEARCH DESTINATION
      // --------------------------------------------------------

      final destination =
          await _searchDestination(query);

      if (destination == null) {
        throw Exception(
          'Could not find destination.',
        );
      }

      // --------------------------------------------------------
      // STEP 2: GET ROAD ROUTE
      // --------------------------------------------------------

      final route =
          await _getRoute(destination);

      // --------------------------------------------------------
      // STEP 3: READ DISTANCE
      // --------------------------------------------------------

      final distanceMeters =
          (route['distance'] as num).toDouble();

      final durationSeconds =
          (route['duration'] as num).toDouble();

      final geometry =
          route['geometry'] as Map<String, dynamic>;

      final coordinates =
          geometry['coordinates'] as List<dynamic>;

      final routePoints =
          coordinates.map<List<double>>((point) {
        final p = point as List<dynamic>;

        return [
          (p[0] as num).toDouble(),
          (p[1] as num).toDouble(),
        ];
      }).toList();

      if (!mounted) return;

      setState(() {
        _routeCoordinates = routePoints;

        _routeDistanceKm =
            distanceMeters / 1000.0;

        _routeDurationMinutes =
            durationSeconds / 60.0;

        _searching = false;
      });

      // --------------------------------------------------------
      // STEP 4: DRAW ROUTE
      // --------------------------------------------------------

      await _drawRoute();

      // --------------------------------------------------------
      // STEP 5: FIT MAP TO ROUTE
      // --------------------------------------------------------

      await _fitRouteToScreen();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _searching = false;
        _error = e.toString();
      });
    }
  }

  // ============================================================
  // DRAW ROUTE
  // ============================================================

  Future<void> _drawRoute() async {
    final map = _map;

    if (map == null || _routeCoordinates.isEmpty) {
      return;
    }

    const sourceId = 'safe-route-source';
    const layerId = 'safe-route-layer';

    try {
      await map.style.removeStyleLayer(layerId);
    } catch (_) {}

    try {
      await map.style.removeStyleSource(sourceId);
    } catch (_) {}

    final feature = {
      'type': 'Feature',
      'geometry': {
        'type': 'LineString',
        'coordinates': _routeCoordinates,
      },
      'properties': {},
    };

    final geoJson = {
      'type': 'FeatureCollection',
      'features': [feature],
    };

    final source = mapbox.GeoJsonSource(
      id: sourceId,
      data: jsonEncode(geoJson),
    );

    await map.style.addSource(source);

    final layer = mapbox.LineLayer(
      id: layerId,
      sourceId: sourceId,
    );

    layer.lineColor =
        Colors.green.toARGB32();

    layer.lineWidth = 6.0;

    layer.lineOpacity = 0.9;

    await map.style.addLayer(layer);
  }

  // ============================================================
  // FIT MAP TO ROUTE
  // ============================================================

  Future<void> _fitRouteToScreen() async {
    final map = _map;

    if (map == null || _routeCoordinates.isEmpty) {
      return;
    }

    double minLng = _routeCoordinates.first[0];
    double maxLng = _routeCoordinates.first[0];
    double minLat = _routeCoordinates.first[1];
    double maxLat = _routeCoordinates.first[1];

    for (final point in _routeCoordinates) {
      minLng = math.min(minLng, point[0]);
      maxLng = math.max(maxLng, point[0]);
      minLat = math.min(minLat, point[1]);
      maxLat = math.max(maxLat, point[1]);
    }

    final centerLng = (minLng + maxLng) / 2;
    final centerLat = (minLat + maxLat) / 2;

    final lngDifference = (maxLng - minLng).abs();
    final latDifference = (maxLat - minLat).abs();

    final largestDifference =
        math.max(lngDifference, latDifference);

    double zoom;

    if (largestDifference < 0.005) {
      zoom = 15.0;
    } else if (largestDifference < 0.01) {
      zoom = 14.0;
    } else if (largestDifference < 0.03) {
      zoom = 13.0;
    } else if (largestDifference < 0.06) {
      zoom = 12.0;
    } else if (largestDifference < 0.12) {
      zoom = 11.0;
    } else if (largestDifference < 0.25) {
      zoom = 10.0;
    } else {
      zoom = 9.0;
    }

    await map.setCamera(
      mapbox.CameraOptions(
        center: mapbox.Point(
          coordinates: mapbox.Position(
            centerLng,
            centerLat,
          ),
        ),
        zoom: zoom,
      ),
    );
  }

  // ============================================================
  // MESSAGE
  // ============================================================

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Safe Route',
          style: TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          // ----------------------------------------------------
          // MAP
          // ----------------------------------------------------

          mapbox.MapWidget(
            viewport: mapbox.CameraViewportState(
              center: mapbox.Point(
                coordinates: mapbox.Position(
                  77.5946,
                  12.9716,
                ),
              ),
              zoom: 5.0,
            ),
            onMapCreated: _onMapCreated,
          ),

          // ----------------------------------------------------
          // SEARCH PANEL
          // ----------------------------------------------------

          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                margin: const EdgeInsets.all(14),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius:
                      BorderRadius.circular(18),
                  boxShadow: const [
                    BoxShadow(
                      blurRadius: 15,
                      offset: Offset(0, 5),
                      color: Colors.black26,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // CURRENT LOCATION

                    Row(
                      children: [
                        const Icon(
                          Icons.my_location,
                          color: Colors.green,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _loadingLocation
                                ? 'Finding your location...'
                                : 'Your current location',
                            style: const TextStyle(
                              fontWeight:
                                  FontWeight.w500,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed:
                              _getCurrentLocation,
                          icon: const Icon(
                            Icons.refresh,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 10),

                    // DESTINATION

                    TextField(
                      controller:
                          _destinationController,
                      textInputAction:
                          TextInputAction.search,
                      onSubmitted: (_) =>
                          _findRoute(),
                      decoration: InputDecoration(
                        prefixIcon:
                            const Icon(
                          Icons.location_on,
                          color: Colors.red,
                        ),
                        hintText:
                            'Enter your destination',
                        filled: true,
                        fillColor:
                            Colors.grey.shade100,
                        border:
                            OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(
                            14,
                          ),
                          borderSide:
                              BorderSide.none,
                        ),
                      ),
                    ),

                    const SizedBox(height: 10),

                    // FIND ROUTE BUTTON

                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child:
                          ElevatedButton.icon(
                        onPressed:
                            _searching
                                ? null
                                : _findRoute,
                        icon: _searching
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color:
                                      Colors.white,
                                ),
                              )
                            : const Icon(
                                Icons.directions,
                              ),
                        label: Text(
                          _searching
                              ? 'Finding route...'
                              : 'Find Route',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ----------------------------------------------------
          // LOCATION BUTTON
          // ----------------------------------------------------

          Positioned(
            right: 16,
            bottom: 170,
            child: FloatingActionButton(
              heroTag:
                  'safeRouteLocation',
              onPressed:
                  _moveToUserLocation,
              child: const Icon(
                Icons.my_location,
              ),
            ),
          ),

          // ----------------------------------------------------
          // ROUTE INFORMATION
          // ----------------------------------------------------

          if (_routeDistanceKm != null)
            Positioned(
              left: 14,
              right: 14,
              bottom: 14,
              child: _buildRouteCard(),
            ),

          // ----------------------------------------------------
          // ERROR
          // ----------------------------------------------------

          if (_error != null)
            Positioned(
              left: 14,
              right: 14,
              bottom: 14,
              child: Card(
                child: Padding(
                  padding:
                      const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: Colors.red,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _error!,
                          style:
                              const TextStyle(
                            color: Colors.red,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          setState(() {
                            _error = null;
                          });
                        },
                        icon:
                            const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ----------------------------------------------------
          // LOCATION LOADING
          // ----------------------------------------------------

          if (_loadingLocation)
            const Center(
              child: Card(
                child: Padding(
                  padding:
                      EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  child: Row(
                    mainAxisSize:
                        MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child:
                            CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      ),
                      SizedBox(width: 12),
                      Text(
                        'Finding your location...',
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ============================================================
  // ROUTE CARD
  // ============================================================

  Widget _buildRouteCard() {
    final distance =
        _routeDistanceKm ?? 0;

    final duration =
        _routeDurationMinutes ?? 0;

    return Card(
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.circular(18),
      ),
      child: Padding(
        padding:
            const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 45,
                  height: 45,
                  decoration: BoxDecoration(
                    color: Colors.green.shade100,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.shield,
                    color:
                        Colors.green.shade700,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _destinationName ??
                        'Route',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight:
                          FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow:
                        TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 14),

            Row(
              children: [
                const Icon(
                  Icons.route,
                  size: 20,
                  color: Colors.green,
                ),
                const SizedBox(width: 8),
                Text(
                  '${distance.toStringAsFixed(1)} km',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 20),
                const Icon(
                  Icons.access_time,
                  size: 20,
                  color: Colors.blue,
                ),
                const SizedBox(width: 8),
                Text(
                  '${duration.round()} min',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            Row(
              children: [
                Icon(
                  Icons.shield,
                  size: 18,
                  color:
                      Colors.green.shade700,
                ),
                const SizedBox(width: 7),
                Text(
                  'Route found',
                  style: TextStyle(
                    color:
                        Colors.green.shade700,
                    fontWeight:
                        FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}