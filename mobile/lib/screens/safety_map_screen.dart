import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../services/live_reports_feed.dart';
import '../services/location_service.dart';
import '../services/safety_api_service.dart';
import '../utils/map_clustering.dart';
import '../widgets/map_widgets.dart';

/// Real-time crime map on OpenStreetMap.
///
/// * Live layer: recent complaints, checked every 10 seconds. New ones
///   appear without reloading, and you get a warning if one lands within
///   1 km of you.
/// * District layer: background risk from the historical crime dataset.
/// * Your position follows you as you move, and the "safety here" score
///   updates when you've moved about 150 m or a new report comes in nearby.
/// * Tap anywhere to check the safety score of that spot.
class SafetyMapScreen extends StatefulWidget {
  const SafetyMapScreen({super.key});

  @override
  State<SafetyMapScreen> createState() => _SafetyMapScreenState();
}

class _SafetyMapScreenState extends State<SafetyMapScreen>
    with WidgetsBindingObserver {
  static const _indiaCenter = LatLng(22.5, 79.0);
  static const _indiaZoom = 4.6;
  static const _focusedZoom = 14.5;

  /// A new report closer than this triggers a warning.
  static const _alertRadiusMetres = 1000.0;

  /// Re-check "safety here" after moving this far.
  static const _rescoreDistanceMetres = 150.0;

  final _mapController = MapController();
  final _api = SafetyApiService();
  final _feed = LiveReportsFeed();
  final _distance = const Distance();

  StreamSubscription<Position>? _positionSub;
  bool _mapReady = false;

  // You
  LatLng? _me;
  double _myAccuracy = 0;
  bool _following = true;
  String? _locationProblem;

  // Safety where you are
  SafetyScore? _hereScore;
  LatLng? _hereScoredAt;
  bool _scoringHere = false;

  // Tapped spot
  LatLng? _picked;
  SafetyScore? _pickedScore;
  bool _scoringPicked = false;

  // Layers
  bool _showLive = true;
  bool _showDistricts = true;
  List<DistrictCrime> _districts = [];
  List<PointCluster<LiveReport>> _liveClusters = [];
  int _clusterZoom = _indiaZoom.round();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _feed.addListener(_onFeedChanged);
    _feed.start();
    _loadDistricts();
    _startLocation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSub?.cancel();
    _feed.removeListener(_onFeedChanged);
    _feed.dispose();
    _mapController.dispose();
    super.dispose();
  }

  // Stop polling and GPS while the app is in the background, to save
  // battery and data. Pick up again when it comes back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _feed.start();
      _positionSub?.resume();
    } else if (state == AppLifecycleState.paused) {
      _feed.stop();
      _positionSub?.pause();
    }
  }

  // ------------------------------------------------------------------
  // Data
  // ------------------------------------------------------------------

  Future<void> _loadDistricts() async {
    try {
      final districts = await _api.fetchDistrictCrime();
      if (!mounted) return;
      setState(() => _districts = districts);
    } catch (e) {
      debugPrint('District data failed: $e');
    }
  }

  void _onFeedChanged() {
    if (!mounted) return;

    setState(_recluster);

    final me = _me;
    final fresh = _feed.latestNew;
    if (fresh.isEmpty) return;

    final nearby = me == null
        ? const <LiveReport>[]
        : fresh
            .where((r) => _distance.distance(me, r.point) <= _alertRadiusMetres)
            .toList();

    if (nearby.isNotEmpty) {
      final closest = nearby
          .map((r) => _distance.distance(me!, r.point))
          .reduce(math.min);

      _showAlert(
        'New report about ${(closest / 1000).toStringAsFixed(1)} km from you',
        danger: true,
      );

      // Your score is out of date now.
      _scoreHere(force: true);
    } else {
      _showAlert(
        fresh.length == 1
            ? '1 new report on the map'
            : '${fresh.length} new reports on the map',
      );
    }

    // Refresh the tapped spot too if it's near a new report.
    final picked = _picked;
    if (picked != null &&
        fresh.any((r) => _distance.distance(picked, r.point) <= 2000)) {
      _scorePicked(picked);
    }
  }

  void _recluster() {
    _liveClusters = clusterPoints<LiveReport>(
      _feed.reports,
      (r) => r.point,
      _clusterZoom.toDouble(),
    );
  }

  // ------------------------------------------------------------------
  // Location
  // ------------------------------------------------------------------

  Future<void> _startLocation() async {
    final problem = await LocationService.ensurePermission();
    if (!mounted) return;

    if (problem != null) {
      setState(() => _locationProblem = problem);
      return;
    }

    setState(() => _locationProblem = null);

    // Start the live stream, and in parallel grab a quick first position so
    // the map jumps to you straight away.
    await _positionSub?.cancel();
    _positionSub = LocationService.positionStream().listen(
      _onPosition,
      onError: (Object e) {
        if (!mounted) return;
        setState(() => _locationProblem = 'Lost GPS signal. Retrying…');
      },
    );

    final quick = await LocationService.quickFix();
    if (!mounted) return;

    if (quick != null) {
      if (_me == null) _onPosition(quick);
    } else if (_me == null) {
      setState(() => _locationProblem =
          'Still looking for your location. On a simulator, set one in '
          'Features → Location.');
    }
  }

  void _onPosition(Position position) {
    if (!mounted) return;

    final firstFix = _me == null;
    final here = LatLng(position.latitude, position.longitude);

    setState(() {
      _me = here;
      _myAccuracy = position.accuracy;
      _locationProblem = null;
    });

    if (_mapReady && (firstFix || _following)) {
      _mapController.move(
        here,
        firstFix ? _focusedZoom : _mapController.camera.zoom,
      );
    }

    _scoreHere();
  }

  Future<void> _scoreHere({bool force = false}) async {
    final me = _me;
    if (me == null || _scoringHere) return;

    final last = _hereScoredAt;
    if (!force &&
        last != null &&
        _distance.distance(last, me) < _rescoreDistanceMetres) {
      return;
    }

    _scoringHere = true;
    try {
      final score = await _api.fetchScore(me);
      if (!mounted) return;
      setState(() {
        _hereScore = score;
        _hereScoredAt = me;
      });
    } catch (e) {
      debugPrint('Score for current location failed: $e');
    } finally {
      _scoringHere = false;
    }
  }

  void _recenter() {
    final me = _me;

    if (me == null) {
      _startLocation();
      if (_locationProblem != null) _showAlert(_locationProblem!);
      return;
    }

    setState(() => _following = true);
    _mapController.move(me, math.max(_mapController.camera.zoom, 14));
  }

  // ------------------------------------------------------------------
  // Map interaction
  // ------------------------------------------------------------------

  void _onCameraChanged(MapCamera camera, bool hasGesture) {
    final stopFollowing = hasGesture && _following;
    final zoom = camera.zoom.round();
    final zoomChanged = zoom != _clusterZoom;

    if (!stopFollowing && !zoomChanged) return;

    // The map can report camera changes while it is building, so update
    // our state just after instead of during.
    Future.microtask(() {
      if (!mounted) return;
      setState(() {
        // Dragging the map stops it from following you.
        if (stopFollowing) _following = false;
        if (zoomChanged) {
          _clusterZoom = zoom;
          _recluster();
        }
      });
    });
  }

  Future<void> _scorePicked(LatLng point) async {
    setState(() {
      _picked = point;
      _scoringPicked = true;
    });

    try {
      final score = await _api.fetchScore(point);
      if (!mounted || _picked != point) return;
      setState(() => _pickedScore = score);
    } catch (e) {
      if (!mounted) return;
      _showAlert('Could not get a safety score for that spot.');
    } finally {
      if (mounted && _picked == point) {
        setState(() => _scoringPicked = false);
      }
    }
  }

  void _onClusterTap(PointCluster<LiveReport> cluster) {
    if (cluster.count > 1) {
      _mapController.move(
        cluster.center,
        math.min(_mapController.camera.zoom + 2, 18),
      );
      return;
    }

    final report = cluster.items.first;
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: ListTile(
          leading: Icon(Icons.warning_rounded, color: liveReportColor(1)),
          title: Text('Reported ${formatAge(report.age)}'),
          subtitle: const Text(
            'Approximate area (within about 100 m). Details are private.',
          ),
        ),
      ),
    );
  }

  void _showAlert(String message, {bool danger = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                danger ? Icons.warning_amber_rounded : Icons.info_outline,
                color: Colors.white,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(message)),
            ],
          ),
          backgroundColor: danger ? Colors.red.shade700 : null,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  // ------------------------------------------------------------------
  // Build
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Safety Map'),
        actions: [
          IconButton(
            tooltip: 'Safe route',
            icon: const Icon(Icons.alt_route),
            onPressed: () => Navigator.of(context).pushNamed('/safe-route'),
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _indiaCenter,
              initialZoom: _indiaZoom,
              minZoom: 3,
              maxZoom: 18,
              onMapReady: () {
                _mapReady = true;
                final me = _me;
                if (me != null) _mapController.move(me, _focusedZoom);
              },
              onPositionChanged: _onCameraChanged,
              onTap: (_, point) => _scorePicked(point),
            ),
            children: [
              osmTileLayer(),
              if (_showDistricts) CircleLayer(circles: _districtCircles()),
              if (_me != null)
                CircleLayer(circles: [userAccuracyCircle(_me!, _myAccuracy)]),
              if (_showLive) MarkerLayer(markers: _liveMarkers()),
              MarkerLayer(
                markers: [
                  if (_picked != null)
                    Marker(
                      point: _picked!,
                      width: 40,
                      height: 40,
                      alignment: Alignment.topCenter,
                      child: const Icon(
                        Icons.location_on,
                        size: 40,
                        color: Colors.deepPurple,
                      ),
                    ),
                  if (_me != null) userLocationMarker(_me!),
                ],
              ),
              osmAttribution(),
            ],
          ),

          // Top: safety where you are, live status, layer toggles.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _hereBanner(),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      LiveStatusPill(
                        lastUpdated: _feed.lastUpdated,
                        error: _feed.error,
                      ),
                      _layerChip(
                        'Live reports',
                        _showLive,
                        (v) => setState(() => _showLive = v),
                      ),
                      _layerChip(
                        'District data',
                        _showDistricts,
                        (v) => setState(() => _showDistricts = v),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Bottom right: follow me.
          Positioned(
            right: 16,
            bottom: _picked != null ? 200 : 24,
            child: FloatingActionButton(
              heroTag: 'map-recenter',
              tooltip: 'Follow my location',
              onPressed: _recenter,
              child: Icon(
                _following && _me != null
                    ? Icons.my_location
                    : Icons.location_searching,
              ),
            ),
          ),

          // Bottom: tapped spot, or the legend.
          Positioned(
            left: 12,
            right: _picked != null ? 12 : null,
            bottom: 16,
            child: _picked != null ? _pickedCard() : _legend(),
          ),
        ],
      ),
    );
  }

  List<CircleMarker> _districtCircles() {
    return _districts.map((d) {
      final color = districtColor(d.intensity);
      return CircleMarker(
        point: d.point,
        // Bigger and redder for districts with more recorded crime.
        radius: 4000 + 16000 * math.sqrt(d.intensity),
        useRadiusInMeter: true,
        color: color.withValues(alpha: 0.18),
        borderColor: color.withValues(alpha: 0.45),
        borderStrokeWidth: 1,
      );
    }).toList();
  }

  List<Marker> _liveMarkers() {
    return _liveClusters.map((cluster) {
      final size = cluster.count >= 5 ? 44.0 : (cluster.count >= 2 ? 38.0 : 30.0);
      final hasRecent = cluster.items.any(
        (r) => r.age != null && r.age!.inMinutes < 60,
      );

      return Marker(
        point: cluster.center,
        width: size,
        height: size,
        child: GestureDetector(
          onTap: () => _onClusterTap(cluster),
          child: LiveReportBubble(count: cluster.count, hasRecent: hasRecent),
        ),
      );
    }).toList();
  }

  Widget _hereBanner() {
    final score = _hereScore;

    String title;
    String subtitle;
    Color color;
    IconData icon;

    if (_locationProblem != null) {
      title = 'Location unavailable';
      subtitle = '$_locationProblem Tap the map to check any spot.';
      color = Colors.grey.shade700;
      icon = Icons.location_off;
    } else if (score == null) {
      title = 'Finding your location…';
      subtitle = 'Your safety score will appear here.';
      color = Colors.blueGrey;
      icon = Icons.gps_not_fixed;
    } else {
      title = 'Safety here: ${score.score}/100 · ${scoreLabel(score.score)}';
      subtitle = score.liveReportCount == 0
          ? 'No recent reports within 2 km'
          : '${score.liveReportCount} recent report'
              '${score.liveReportCount == 1 ? '' : 's'} within 2 km';
      color = scoreColor(score.score);
      icon = Icons.shield;
    }

    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(14),
      color: Colors.white,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _locationProblem != null ? _startLocation : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: color,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(subtitle, style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _layerChip(String label, bool selected, ValueChanged<bool> onChanged) {
    return FilterChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: onChanged,
      visualDensity: VisualDensity.compact,
      backgroundColor: Colors.white,
      elevation: 2,
    );
  }

  Widget _pickedCard() {
    final score = _pickedScore;

    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
        child: Row(
          children: [
            if (_scoringPicked && score == null)
              const SizedBox(
                width: 48,
                height: 48,
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else if (score != null)
              CircleAvatar(
                radius: 26,
                backgroundColor: scoreColor(score.score),
                child: Text(
                  '${score.score}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ),
            const SizedBox(width: 14),
            Expanded(
              child: score == null
                  ? const Text('Checking this spot…')
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          scoreLabel(score.score),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: scoreColor(score.score),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${score.liveReportCount} recent report'
                          '${score.liveReportCount == 1 ? '' : 's'} within 2 km',
                          style: const TextStyle(fontSize: 13),
                        ),
                        Text(
                          'District risk: '
                          '${(score.historicalRisk * 100).round()}%',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ],
                    ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                _picked = null;
                _pickedScore = null;
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _legend() {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_showLive) ...[
              const Text(
                'Recent reports',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
              _legendRow(liveReportColor(1), '1 report'),
              _legendRow(liveReportColor(2), '2–4 reports'),
              _legendRow(liveReportColor(5), '5+ reports'),
              _legendRow(
                Colors.white,
                'Glow = last hour',
                border: liveReportColor(1),
              ),
            ],
            if (_showLive && _showDistricts) const SizedBox(height: 6),
            if (_showDistricts) ...[
              const Text(
                'District crime (dataset)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
              _legendRow(districtColor(0), 'Low'),
              _legendRow(districtColor(0.5), 'Medium'),
              _legendRow(districtColor(1), 'High'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _legendRow(Color color, String label, {Color? border}) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: border == null ? null : Border.all(color: border, width: 2),
            ),
          ),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}
