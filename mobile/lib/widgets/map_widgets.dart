import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../config.dart';

/// OpenStreetMap base layer. Free, no API key.
TileLayer osmTileLayer() {
  return TileLayer(
    urlTemplate: MapConfig.tileUrl,
    userAgentPackageName: MapConfig.userAgentPackageName,
  );
}

/// Credit line OpenStreetMap requires on every map.
Widget osmAttribution() {
  return const RichAttributionWidget(
    attributions: [TextSourceAttribution('OpenStreetMap contributors')],
  );
}

/// Blue "you are here" dot.
Marker userLocationMarker(LatLng point) {
  return Marker(
    point: point,
    width: 24,
    height: 24,
    child: Container(
      decoration: BoxDecoration(
        color: Colors.blue,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)],
      ),
    ),
  );
}

/// Pale circle showing how accurate the GPS fix is.
CircleMarker userAccuracyCircle(LatLng point, double accuracyMetres) {
  return CircleMarker(
    point: point,
    radius: accuracyMetres.clamp(5, 200).toDouble(),
    useRadiusInMeter: true,
    color: Colors.blue.withValues(alpha: 0.12),
    borderColor: Colors.blue.withValues(alpha: 0.35),
    borderStrokeWidth: 1,
  );
}

/// Colour for a group of live reports. Matches the legend.
Color liveReportColor(int count) {
  if (count >= 5) return Colors.red.shade600;
  if (count >= 2) return Colors.orange.shade700;
  return Colors.amber.shade700;
}

/// Colour for a 0–100 safety score.
Color scoreColor(int score) {
  if (score >= 70) return Colors.green.shade600;
  if (score >= 40) return Colors.orange.shade700;
  return Colors.red.shade600;
}

String scoreLabel(int score) {
  if (score >= 70) return 'Safer';
  if (score >= 40) return 'Be alert';
  return 'High risk';
}

/// Colour for the historical district layer, green (low) to red (high).
Color districtColor(double intensity) {
  final double t = intensity.clamp(0.0, 1.0).toDouble();
  return t < 0.5
      ? Color.lerp(Colors.green, Colors.yellow.shade700, t * 2)!
      : Color.lerp(Colors.yellow.shade700, Colors.red, (t - 0.5) * 2)!;
}

/// A bubble for one or more live reports.
class LiveReportBubble extends StatelessWidget {
  const LiveReportBubble({
    super.key,
    required this.count,
    required this.hasRecent,
  });

  final int count;

  /// True if any report in the bubble is under an hour old.
  final bool hasRecent;

  @override
  Widget build(BuildContext context) {
    final color = liveReportColor(count);

    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: hasRecent ? Colors.white : Colors.white70,
          width: hasRecent ? 3 : 2,
        ),
        boxShadow: [
          BoxShadow(
            blurRadius: hasRecent ? 10 : 4,
            spreadRadius: hasRecent ? 2 : 0,
            color: color.withValues(alpha: 0.6),
          ),
        ],
      ),
      child: count > 1
          ? Text(
              count > 99 ? '99+' : '$count',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            )
          : const Icon(Icons.warning_rounded, color: Colors.white, size: 16),
    );
  }
}

/// "Live · updated 12s ago" pill. Refreshes its own text so the map
/// underneath doesn't have to rebuild every second.
class LiveStatusPill extends StatefulWidget {
  const LiveStatusPill({super.key, this.lastUpdated, this.error});

  final DateTime? lastUpdated;
  final String? error;

  @override
  State<LiveStatusPill> createState() => _LiveStatusPillState();
}

class _LiveStatusPillState extends State<LiveStatusPill> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _ago(DateTime time) {
    final seconds = DateTime.now().difference(time).inSeconds;
    if (seconds < 10) return 'just now';
    if (seconds < 60) return '${seconds}s ago';
    return '${seconds ~/ 60} min ago';
  }

  @override
  Widget build(BuildContext context) {
    final offline = widget.error != null;
    final updated = widget.lastUpdated;

    final text = offline
        ? widget.error!
        : updated == null
            ? 'Connecting…'
            : 'Live · updated ${_ago(updated)}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.circle,
            size: 9,
            color: offline ? Colors.orange : Colors.green,
          ),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

/// Short "2 h ago" style age.
String formatAge(Duration? age) {
  if (age == null) return 'recently';
  if (age.inMinutes < 1) return 'just now';
  if (age.inMinutes < 60) return '${age.inMinutes} min ago';
  if (age.inHours < 24) return '${age.inHours} h ago';
  return '${age.inDays} days ago';
}
