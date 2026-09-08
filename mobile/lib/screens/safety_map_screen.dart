import 'package:flutter/material.dart';

import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geolocator/geolocator.dart';

import '../services/safety_api_service.dart';


class SafetyMapScreen extends StatefulWidget {
  const SafetyMapScreen({super.key});

  @override
  State<SafetyMapScreen> createState() =>
      _SafetyMapScreenState();
}


class _SafetyMapScreenState extends State<SafetyMapScreen> {

  

  final SafetyApiService _safetyApi =
      SafetyApiService();

  LatLng? _currentLocation;

  int _safetyScore = 0;

  String _band = 'unknown';

  int _liveReportCount = 0;

  double _liveRisk = 0.0;

  Set<Marker> _markers = {};

  Set<Circle> _circles = {};

  bool _loading = true;


  static const LatLng _defaultLocation =
      LatLng(12.9716, 77.5946);


  @override
  void initState() {
    super.initState();

    _initializeMap();
  }


  Future<void> _initializeMap() async {

    await _getCurrentLocation();

    _currentLocation ??= _defaultLocation;

    await _loadSafetyData();

    if (mounted) {

      setState(() {
        _loading = false;
      });
    }
  }


  Future<void> _getCurrentLocation() async {

    try {

      bool serviceEnabled =
          await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {

        return;
      }


      LocationPermission permission =
          await Geolocator.checkPermission();


      if (permission ==
          LocationPermission.denied) {

        permission =
            await Geolocator.requestPermission();
      }


      if (permission ==
              LocationPermission.denied ||
          permission ==
              LocationPermission.deniedForever) {

        return;
      }


      final position =
          await Geolocator.getCurrentPosition();


      _currentLocation = LatLng(
        position.latitude,
        position.longitude,
      );

    } catch (e) {

      debugPrint(
        'Location error: $e',
      );
    }
  }


  Future<void> _loadSafetyData() async {

    if (_currentLocation == null) {
      return;
    }


    try {

      final result =
          await _safetyApi.fetchScore(
        _currentLocation!,
      );


      final markers =
          <Marker>{};


      /*
       * Current user location.
       */

      markers.add(
        Marker(
          markerId:
              const MarkerId('current_location'),

          position:
              _currentLocation!,

          infoWindow:
              const InfoWindow(
            title: 'Your location',
          ),
        ),
      );


      /*
       * ACTUAL CRIME SPOTS
       *
       * These come from Complaint.latitude
       * and Complaint.longitude in the
       * backend database.
       */

      for (final crime
          in result.nearbyCrimeSpots) {

        markers.add(
          Marker(
            markerId:
                MarkerId(
              'crime_${crime.id}',
            ),

            position: LatLng(
              crime.latitude,
              crime.longitude,
            ),

            icon:
                BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueRed,
            ),

            infoWindow:
                InfoWindow(
              title: 'Reported crime spot',

              snippet:
                  '${crime.distanceKm.toStringAsFixed(2)} km away',
            ),
          ),
        );
      }


      Color zoneColor;

      switch (result.band) {

        case 'green':
          zoneColor =
              Colors.green.withValues(alpha: 0.25);
          break;

        case 'yellow':
          zoneColor =
              Colors.amber.withValues(alpha: 0.25);
          break;

        case 'red':
          zoneColor =
              Colors.red.withValues(alpha: 0.25);
          break;

        default:
          zoneColor =
              Colors.grey.withValues(alpha: 0.2);
      }


      final circles = <Circle>{

        Circle(
          circleId:
              const CircleId('safety_zone'),

          center:
              _currentLocation!,

          radius: 500,

          fillColor:
              zoneColor,

          strokeWidth: 1,

          strokeColor:
              zoneColor,
        ),
      };


      if (mounted) {

        setState(() {

          _safetyScore =
              result.score;

          _band =
              result.band;

          _liveReportCount =
              result.liveReportCount;

          _liveRisk =
              result.liveRisk;

          _markers =
              markers;

          _circles =
              circles;
        });
      }

    } catch (e) {

      debugPrint(
        'Safety API error: $e',
      );
    }
  }


  Color _scoreColor() {

    switch (_band) {

      case 'green':
        return Colors.green;

      case 'yellow':
        return Colors.orange;

      case 'red':
        return Colors.red;

      default:
        return Colors.grey;
    }
  }


  @override
  Widget build(
    BuildContext context,
  ) {

    final location =
        _currentLocation ??
        _defaultLocation;


    return Scaffold(

      appBar: AppBar(
        title:
            const Text('Safety Map'),
      ),


      body: Stack(

        children: [

          GoogleMap(

            initialCameraPosition:
                CameraPosition(
              target: location,
              zoom: 14,
            ),

            
            myLocationEnabled:
                true,

            myLocationButtonEnabled:
                true,

            zoomControlsEnabled:
                false,

            markers:
                _markers,

            circles:
                _circles,
          ),


          /*
           * Loading indicator.
           */

          if (_loading)

            const Positioned(
              top: 20,
              right: 20,

              child:
                  Card(
                child:
                    Padding(
                  padding:
                      EdgeInsets.all(10),

                  child:
                      CircularProgressIndicator(),
                ),
              ),
            ),


          /*
           * Safety information card.
           */

          Positioned(

            left: 16,
            right: 16,
            bottom: 20,

            child: Card(

              elevation: 6,

              child: Padding(

                padding:
                    const EdgeInsets.all(16),

                child: Column(

                  crossAxisAlignment:
                      CrossAxisAlignment.start,

                  children: [

                    Row(

                      children: [

                        Icon(
                          Icons.shield,
                          color:
                              _scoreColor(),
                        ),

                        const SizedBox(
                          width: 8,
                        ),

                        const Text(
                          'Safety Score',
                          style:
                              TextStyle(
                            fontSize: 18,
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),

                        const Spacer(),

                        Text(
                          '$_safetyScore/100',

                          style:
                              TextStyle(
                            fontSize: 22,
                            fontWeight:
                                FontWeight.bold,
                            color:
                                _scoreColor(),
                          ),
                        ),
                      ],
                    ),


                    const SizedBox(
                      height: 8,
                    ),


                    Text(
                      'Risk level: ${_band.toUpperCase()}',
                    ),


                    const SizedBox(
                      height: 4,
                    ),


                    Text(
                      'Nearby reported crime spots: '
                      '$_liveReportCount',
                    ),


                    const SizedBox(
                      height: 4,
                    ),


                    Text(
                      'Live risk: '
                      '${_liveRisk.toStringAsFixed(3)}',
                    ),


                    const SizedBox(
                      height: 10,
                    ),


                    SizedBox(

                      width:
                          double.infinity,

                      child:
                          ElevatedButton.icon(

                        onPressed:
                            _loadSafetyData,

                        icon:
                            const Icon(
                          Icons.refresh,
                        ),

                        label:
                            const Text(
                          'Refresh Safety Data',
                        ),
                      ),
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
}