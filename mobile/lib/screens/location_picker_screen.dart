import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../theme.dart';
import '../widgets/map_widgets.dart';
import '../widgets/ss_ui.dart';

/// Lets the user pick a location by panning the map under a fixed center
/// pin (the standard "drag the map, not the pin" pattern), then confirming.
/// Returns the chosen [LatLng] via Navigator.pop, or null if cancelled.
class LocationPickerScreen extends StatefulWidget {
  const LocationPickerScreen({super.key, this.initialCenter});

  final LatLng? initialCenter;

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  static const _fallbackCenter = LatLng(20.0, 0.0);
  static const _pinSize = 48.0;

  final _mapController = MapController();
  late LatLng _center = widget.initialCenter ?? _fallbackCenter;

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SSPage(
      header: GlassHeader(
        title: 'Set Location',
        subtitle: 'Drag the map so the pin marks where it happened',
        onBack: () => Navigator.of(context).pop(),
      ),
      safeBottom: false,
      body: Stack(
        alignment: Alignment.center,
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _center,
              initialZoom: widget.initialCenter != null ? 15.0 : 2.0,
              onPositionChanged: (camera, hasGesture) {
                _center = camera.center;
              },
            ),
            children: [
              themedTileLayer(context),
              mapAttribution(context),
            ],
          ),
          // Fixed pin at screen center; the map pans underneath it. Offset
          // upward so the icon's visual tip (its bottom point), not its
          // center, lands exactly on the map's center point.
          Transform.translate(
            offset: const Offset(0, -_pinSize / 2),
            child: const IgnorePointer(
              child: Icon(Icons.location_on_rounded, color: AppColors.primary, size: _pinSize),
            ),
          ),
          Positioned(
            bottom: 24 + MediaQuery.of(context).padding.bottom,
            left: 24,
            right: 24,
            child: GradientButton(
              label: 'Confirm Location',
              icon: Icons.check_rounded,
              onPressed: () => Navigator.of(context).pop(_center),
            ),
          ),
        ],
      ),
    );
  }
}
