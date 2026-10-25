import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/app_prefs.dart';
import '../state/contacts_state.dart';
import '../state/trip_state.dart';
import '../theme.dart';
import '../widgets/map_widgets.dart';
import '../widgets/ss_components.dart';
import '../widgets/ss_ui.dart';

/// "Safe Trip Active": live map, ETA, distance left, check-ins, and quick
/// ways to share the trip or call for help.
class TripTrackingScreen extends StatefulWidget {
  const TripTrackingScreen({super.key});

  @override
  State<TripTrackingScreen> createState() => _TripTrackingScreenState();
}

class _TripTrackingScreenState extends State<TripTrackingScreen> {
  final _map = MapController();
  bool _mapReady = false;
  LatLng? _lastCentred;

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  void _follow(TripState trip) {
    final here = trip.position;
    if (!_mapReady || here == null || here == _lastCentred) return;
    _lastCentred = here;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _map.move(here, _map.camera.zoom);
    });
  }

  Future<void> _shareTrip(TripState trip) async {
    final contacts = context.read<ContactsState>().contacts;
    final shareLocation = context.read<AppPrefs>().shareLocationWithCircle;
    final here = trip.position;

    final buffer = StringBuffer(
      "I'm on my way to ${trip.destinationName} with SecureShe. "
      'ETA about ${formatDuration(trip.eta)}.',
    );
    if (shareLocation && here != null) {
      buffer.write(
        ' My location: https://www.google.com/maps?q=${here.latitude},${here.longitude}',
      );
    }

    // iOS uses "&body=", Android "?body=" after the recipients.
    final recipients = contacts.map((c) => c.phone).join(',');
    final separator = !kIsWeb && Platform.isIOS ? '&' : '?';
    final uri = Uri.parse(
      'sms:$recipients${separator}body=${Uri.encodeComponent(buffer.toString())}',
    );

    if (!await launchUrl(uri) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open your messages app.')),
      );
    }
  }

  Future<void> _confirmEnd(TripState trip) async {
    final end = await showSSSheet<bool>(
      context,
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetTitle(
            title: 'End trip?',
            subtitle: 'Tracking stops. You haven\'t reached your destination yet.',
          ),
          GradientButton(
            label: 'End Trip',
            variant: SSButtonVariant.danger,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
          const SizedBox(height: 10),
          GradientButton(
            label: 'Keep Tracking',
            variant: SSButtonVariant.outline,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
        ],
      ),
    );
    if (end == true) {
      await trip.end();
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final trip = context.watch<TripState>();
    final c = context.ss;

    if (!trip.active && !trip.arrived) {
      return SSPage(
        header: GlassHeader(title: 'Safe Trip', onBack: () => Navigator.of(context).pop()),
        body: Center(
          child: Text('No trip in progress.', style: TextStyle(color: c.mutedForeground)),
        ),
      );
    }

    _follow(trip);

    return SSPage(
      header: GlassHeader(
        title: trip.arrived ? 'You arrived safely' : 'Safe Trip Active',
        subtitle: trip.arrived
            ? trip.destinationName
            : trip.offRoute
                ? '● Off your planned route'
                : '● Tracking Live',
        subtitleColor: trip.offRoute ? AppColors.warning : AppColors.success,
        onBack: () => Navigator.of(context).pop(),
        trailing: SecondTicker(
          builder: (_) => TagPill(
            text: formatClock(trip.elapsed.inSeconds),
            color: AppColors.success,
            fontSize: 12,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        children: [
          // Map
          ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: SizedBox(
              height: 180,
              child: FlutterMap(
                mapController: _map,
                options: MapOptions(
                  initialCameraFit: CameraFit.bounds(
                    bounds: LatLngBounds.fromPoints(trip.route),
                    padding: const EdgeInsets.all(24),
                  ),
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
                  ),
                  onMapReady: () => _mapReady = true,
                ),
                children: [
                  themedTileLayer(context),
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: trip.route,
                        strokeWidth: 4,
                        color: AppColors.primary,
                        pattern: const StrokePattern.dashed(segments: [10, 5]),
                      ),
                    ],
                  ),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: trip.route.first,
                        width: 18,
                        height: 18,
                        child: const ZoneMarker(level: ZoneLevel.safe, size: 14),
                      ),
                      Marker(
                        point: trip.route.last,
                        width: 36,
                        height: 36,
                        alignment: Alignment.topCenter,
                        child: const Icon(Icons.location_on_rounded,
                            size: 36, color: AppColors.primary),
                      ),
                      if (trip.position != null) userLocationMarker(trip.position!),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Stats
          Row(
            children: [
              Expanded(
                child: StatTile(
                  icon: Icons.schedule_rounded,
                  label: 'ETA',
                  value: trip.arrived ? 'Arrived' : formatDuration(trip.eta),
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  icon: Icons.place_outlined,
                  label: 'Distance left',
                  value: formatDistance(trip.remainingMetres),
                  color: AppColors.warning,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  icon: Icons.shield_outlined,
                  label: 'Status',
                  value: trip.arrived
                      ? 'Safe'
                      : trip.offRoute
                          ? 'Off route'
                          : 'On track',
                  color: trip.offRoute ? AppColors.warning : AppColors.success,
                ),
              ),
            ],
          ),
          if (trip.safetyScore != null) ...[
            const SizedBox(height: 8),
            Text(
              'Route safety score: ${trip.safetyScore}/100',
              style: TextStyle(fontSize: 11, color: c.mutedForeground),
            ),
          ],
          const SizedBox(height: 20),

          // Check-ins
          Text(
            'Check-in Timeline',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.foreground),
          ),
          const SizedBox(height: 12),
          TimelineList(
            compact: true,
            entries: [
              for (final ci in trip.checkIns)
                TimelineEntry(
                  title: ci.label,
                  subtitle: ci.reachedAt == null
                      ? 'After ${formatDistance(trip.totalMetres * ci.fraction)}'
                      : _clock(ci.reachedAt!),
                  state: switch (trip.statusOf(ci)) {
                    CheckInStatus.done => TimelineState.done,
                    CheckInStatus.current => TimelineState.current,
                    CheckInStatus.pending => TimelineState.pending,
                  },
                ),
            ],
          ),
          const SizedBox(height: 20),

          _CircleCard(onShare: () => _shareTrip(trip)),
          const SizedBox(height: 20),

          GradientButton(
            label: 'Emergency Call (112)',
            icon: Icons.phone_rounded,
            variant: SSButtonVariant.outline,
            height: 52,
            fontSize: 14,
            onPressed: () => launchUrl(Uri(scheme: 'tel', path: '112')),
          ),
          const SizedBox(height: 10),
          if (trip.arrived)
            GradientButton(
              label: 'Done',
              variant: SSButtonVariant.success,
              height: 52,
              fontSize: 14,
              onPressed: () {
                trip.arrived = false;
                Navigator.of(context).pop();
              },
            )
          else
            GradientButton(
              label: 'End Trip',
              icon: Icons.error_outline_rounded,
              variant: SSButtonVariant.danger,
              height: 52,
              fontSize: 14,
              onPressed: () => _confirmEnd(trip),
            ),
        ],
      ),
    );
  }

  String _clock(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
  }
}

class _CircleCard extends StatelessWidget {
  const _CircleCard({required this.onShare});

  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final contacts = context.watch<ContactsState>().contacts;

    return SSCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Trusted Circle',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.foreground),
          ),
          const SizedBox(height: 10),
          if (contacts.isEmpty)
            Text(
              'Add trusted contacts in Circle to share your trip with them.',
              style: TextStyle(fontSize: 12, color: c.mutedForeground),
            )
          else ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final contact in contacts)
                  TagPill(text: contact.name, color: AppColors.primary),
              ],
            ),
            const SizedBox(height: 12),
            GradientButton(
              label: 'Share Trip by Text',
              icon: Icons.sms_outlined,
              height: 44,
              fontSize: 13,
              onPressed: onShare,
            ),
          ],
        ],
      ),
    );
  }
}
