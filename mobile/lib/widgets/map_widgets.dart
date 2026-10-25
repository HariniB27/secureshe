import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../config.dart';
import '../theme.dart';

/// Map tiles that match the theme. Both use the regular OpenStreetMap tiles
/// (free, no key). In dark mode the tiles are colour-inverted on the phone,
/// so the map goes dark without depending on a paid dark-tile service.
/// (CARTO's dark tiles now need an API key, which showed "API KEY REQUIRED".)
TileLayer themedTileLayer(BuildContext context) {
  return TileLayer(
    urlTemplate: MapConfig.tileUrl,
    userAgentPackageName: MapConfig.userAgentPackageName,
    tileBuilder: context.ss.isDark ? darkModeTileBuilder : null,
  );
}

/// OpenStreetMap base layer. Free, no API key.
TileLayer osmTileLayer() {
  return TileLayer(
    urlTemplate: MapConfig.tileUrl,
    userAgentPackageName: MapConfig.userAgentPackageName,
  );
}

/// Credit line the map data and tiles require.
Widget mapAttribution(BuildContext context) {
  return const RichAttributionWidget(
    alignment: AttributionAlignment.bottomLeft,
    attributions: [TextSourceAttribution('OpenStreetMap contributors')],
  );
}

Widget osmAttribution() {
  return const RichAttributionWidget(
    attributions: [TextSourceAttribution('OpenStreetMap contributors')],
  );
}

/// The pink pulsing "you are here" dot from the design.
Marker userLocationMarker(LatLng point) {
  return Marker(
    point: point,
    width: 36,
    height: 36,
    child: const _PulsingDot(),
  );
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 14 + 22 * _c.value,
            height: 14 + 22 * _c.value,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primary.withValues(alpha: 0.3 * (1 - _c.value)),
            ),
          ),
          child!,
        ],
      ),
      child: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: AppColors.primary,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: [
            BoxShadow(color: AppColors.primary.withValues(alpha: 0.6), blurRadius: 8),
          ],
        ),
      ),
    );
  }
}

/// Pale circle showing how accurate the GPS fix is.
CircleMarker userAccuracyCircle(LatLng point, double accuracyMetres) {
  return CircleMarker(
    point: point,
    radius: accuracyMetres.clamp(5, 200).toDouble(),
    useRadiusInMeter: true,
    color: AppColors.primary.withValues(alpha: 0.08),
    borderColor: AppColors.primary.withValues(alpha: 0.3),
    borderStrokeWidth: 1,
  );
}

enum ZoneLevel { safe, moderate, unsafe }

Color zoneColor(ZoneLevel level) => switch (level) {
      ZoneLevel.safe => AppColors.success,
      ZoneLevel.moderate => AppColors.warning,
      ZoneLevel.unsafe => AppColors.destructive,
    };

/// Glowing dot marker from the design (MapMarker.tsx), with an optional
/// count for clusters.
class ZoneMarker extends StatelessWidget {
  const ZoneMarker({super.key, required this.level, this.size = 16, this.count, this.fresh = false});

  final ZoneLevel level;
  final double size;
  final int? count;

  /// Reported in the last hour: pulses.
  final bool fresh;

  @override
  Widget build(BuildContext context) {
    final color = zoneColor(level);
    final dot = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 12)],
      ),
      child: count != null && count! > 1
          ? Text(
              count! > 99 ? '99+' : '$count',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            )
          : null,
    );
    if (!fresh) return Center(child: dot);
    return Center(child: _Ping(color: color, size: size, child: dot));
  }
}

class _Ping extends StatefulWidget {
  const _Ping({required this.color, required this.size, required this.child});

  final Color color;
  final double size;
  final Widget child;

  @override
  State<_Ping> createState() => _PingState();
}

class _PingState extends State<_Ping> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Transform.scale(
            scale: 1 + _c.value,
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: 0.6 * (1 - _c.value)),
              ),
            ),
          ),
          child!,
        ],
      ),
      child: widget.child,
    );
  }
}

/// Colour for a 0–100 safety score.
Color scoreColor(int score) {
  if (score >= 70) return AppColors.success;
  if (score >= 40) return AppColors.warning;
  return AppColors.destructive;
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
      ? Color.lerp(AppColors.success, AppColors.warning, t * 2)!
      : Color.lerp(AppColors.warning, AppColors.destructive, (t - 0.5) * 2)!;
}

/// Short "2 h ago" style age.
String formatAge(Duration? age) {
  if (age == null) return 'recently';
  if (age.inMinutes < 1) return 'just now';
  if (age.inMinutes < 60) return '${age.inMinutes}m ago';
  if (age.inHours < 24) return '${age.inHours}h ago';
  return '${age.inDays}d ago';
}

/// "● Live" pill. Shows "Reconnecting…" when the feed is down.
class LiveBadge extends StatefulWidget {
  const LiveBadge({super.key, this.lastUpdated, this.error, this.compact = false});

  final DateTime? lastUpdated;
  final String? error;
  final bool compact;

  @override
  State<LiveBadge> createState() => _LiveBadgeState();
}

class _LiveBadgeState extends State<LiveBadge> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final offline = widget.error != null;
    final color = offline ? AppColors.warning : AppColors.success;

    String text;
    if (offline) {
      text = widget.compact ? 'Offline' : widget.error!;
    } else if (widget.compact || widget.lastUpdated == null) {
      text = 'Live';
    } else {
      final s = DateTime.now().difference(widget.lastUpdated!).inSeconds;
      text = s < 15 ? 'Live' : 'Live · ${s < 60 ? '${s}s' : '${s ~/ 60}m'} ago';
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: widget.compact ? 8 : 12, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            offline ? Icons.cloud_off_rounded : Icons.sensors_rounded,
            size: widget.compact ? 10 : 12,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: widget.compact ? 9 : 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
