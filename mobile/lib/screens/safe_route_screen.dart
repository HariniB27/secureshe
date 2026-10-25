import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../services/live_reports_feed.dart';
import '../services/location_service.dart';
import '../services/routing_service.dart';
import '../services/safety_api_service.dart';
import '../widgets/map_widgets.dart';

/// Search a destination, get walking or driving routes, and see which one
/// passes through safer areas.
///
/// Each route is checked against the safety API at points along the way.
/// While a route is on screen, new live reports near it trigger a warning and
/// the routes are re-checked, so the "Safest" pick stays current.
class SafeRouteScreen extends StatefulWidget {
  const SafeRouteScreen({super.key});

  @override
  State<SafeRouteScreen> createState() => _SafeRouteScreenState();
}

class _SafeRouteScreenState extends State<SafeRouteScreen>
    with WidgetsBindingObserver {
  static const _indiaCenter = LatLng(22.5, 79.0);

  /// Points sampled per route when checking safety.
  static const _samplesPerRoute = 20;

  /// A new report this close to your route triggers a warning.
  static const _routeAlertMetres = 300.0;

  final _mapController = MapController();
  final _routing = RoutingService();
  final _safety = SafetyApiService();
  final _feed = LiveReportsFeed();
  final _distance = const Distance();
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  StreamSubscription<Position>? _positionSub;
  Timer? _searchDebounce;
  bool _mapReady = false;

  LatLng? _me;
  LatLng? _customStart;
  String? _locationProblem;

  TravelMode _mode = TravelMode.walk;
  List<PlaceResult> _suggestions = [];
  PlaceResult? _destination;

  List<RouteOption> _routes = [];
  int _selected = 0;
  bool _loadingRoutes = false;
  bool _scoring = false;
  String? _error;

  LatLng? get _start => _customStart ?? _me;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _feed.addListener(_onFeedChanged);
    _feed.start();
    _startLocation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSub?.cancel();
    _searchDebounce?.cancel();
    _feed.removeListener(_onFeedChanged);
    _feed.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _mapController.dispose();
    super.dispose();
  }

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
  // Location
  // ------------------------------------------------------------------

  Future<void> _startLocation() async {
    final problem = await LocationService.ensurePermission();
    if (!mounted) return;

    if (problem != null) {
      setState(() => _locationProblem =
          '$problem Long-press the map to choose a start point.');
      return;
    }

    setState(() => _locationProblem = null);
    await _positionSub?.cancel();
    _positionSub = LocationService.positionStream().listen(_onPosition);

    // Quick first position so you don't wait for a precise GPS lock.
    final quick = await LocationService.quickFix();
    if (!mounted) return;

    if (quick != null) {
      if (_me == null) _onPosition(quick);
    } else if (_me == null) {
      setState(() => _locationProblem =
          'Still looking for your location. Long-press the map to choose a start point.');
    }
  }

  void _onPosition(Position position) {
    if (!mounted) return;
    final firstFix = _me == null;
    final here = LatLng(position.latitude, position.longitude);
    setState(() {
      _me = here;
      _locationProblem = null;
    });
    if (firstFix && _mapReady && _routes.isEmpty) {
      _mapController.move(here, 15);
    }
  }

  // ------------------------------------------------------------------
  // Search
  // ------------------------------------------------------------------

  void _onQueryChanged(String text) {
    _searchDebounce?.cancel();

    if (text.trim().length < 3) {
      setState(() => _suggestions = []);
      return;
    }

    // Wait until typing pauses. The free search server allows about one
    // request per second.
    _searchDebounce = Timer(const Duration(milliseconds: 700), () async {
      try {
        final results =
            await _routing.searchPlaces(text.trim(), near: _start);
        if (!mounted || _searchController.text.trim() != text.trim()) return;
        setState(() => _suggestions = results);
      } catch (e) {
        debugPrint('Place search failed: $e');
      }
    });
  }

  Future<void> _chooseDestination(PlaceResult place) async {
    _searchFocus.unfocus();
    _searchController.text = place.name;

    setState(() {
      _destination = place;
      _suggestions = [];
    });

    await _findRoutes();
  }

  // ------------------------------------------------------------------
  // Routes
  // ------------------------------------------------------------------

  Future<void> _findRoutes() async {
    final start = _start;
    final destination = _destination;
    if (destination == null) return;

    if (start == null) {
      setState(() => _error = _locationProblem ??
          'Still finding your location. You can long-press the map to set a start point.');
      return;
    }

    setState(() {
      _loadingRoutes = true;
      _error = null;
      _routes = [];
    });

    try {
      final routes =
          await _routing.getRoutes(start, destination.point, _mode);
      if (!mounted) return;

      if (routes.isEmpty) throw Exception('No route found between these places.');

      setState(() {
        // At most 3 options, which also keeps the safety check under the
        // backend's 200-point limit.
        _routes = routes.take(3).toList();
        _selected = 0;
        _loadingRoutes = false;
      });

      _fitRoutes();
      await _scoreRoutes();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingRoutes = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  /// Checks every route at evenly spaced points and picks the safest one.
  Future<void> _scoreRoutes() async {
    if (_routes.isEmpty || _scoring) return;
    setState(() => _scoring = true);

    final samples = <List<LatLng>>[
      for (final route in _routes) _sample(route.points, _samplesPerRoute),
    ];

    try {
      final results = await _safety.fetchScoresBatch(
        samples.expand((s) => s).toList(),
      );
      if (!mounted) return;

      var offset = 0;
      for (var i = 0; i < _routes.length; i++) {
        final scores = results
            .sublist(offset, offset + samples[i].length)
            .map((r) => r.score)
            .toList();
        offset += samples[i].length;

        _routes[i].averageScore =
            (scores.reduce((a, b) => a + b) / scores.length).round();
        _routes[i].lowestScore = scores.reduce(math.min);
      }

      // Pre-select the safest route.
      setState(() => _selected = _safestIndex ?? 0);
    } catch (e) {
      debugPrint('Route safety check failed: $e');
      if (mounted) {
        _snack('Could not check route safety. Showing routes without scores.');
      }
    } finally {
      if (mounted) setState(() => _scoring = false);
    }
  }

  List<LatLng> _sample(List<LatLng> points, int count) {
    if (points.length <= count) return points;
    final step = (points.length - 1) / (count - 1);
    return [for (var i = 0; i < count; i++) points[(i * step).round()]];
  }

  void _fitRoutes() {
    if (!_mapReady || _routes.isEmpty) return;
    final all = _routes.expand((r) => r.points).toList();
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(all),
        padding: const EdgeInsets.fromLTRB(40, 200, 40, 220),
      ),
    );
  }

  /// Highest average safety. Routes within 2 points of each other count as
  /// equally safe, and the quicker one wins.
  int? get _safestIndex {
    if (_routes.isEmpty || _routes.any((r) => r.averageScore == null)) {
      return null;
    }

    var best = 0;
    for (var i = 1; i < _routes.length; i++) {
      final diff = _routes[i].averageScore! - _routes[best].averageScore!;
      final quicker =
          _routes[i].durationSeconds < _routes[best].durationSeconds;
      if (diff > 2 || (diff.abs() <= 2 && quicker)) best = i;
    }
    return best;
  }

  int get _fastestIndex {
    var best = 0;
    for (var i = 1; i < _routes.length; i++) {
      if (_routes[i].durationSeconds < _routes[best].durationSeconds) best = i;
    }
    return best;
  }

  // ------------------------------------------------------------------
  // Live reports along the route
  // ------------------------------------------------------------------

  void _onFeedChanged() {
    if (!mounted) return;
    setState(() {});

    final fresh = _feed.latestNew;
    if (fresh.isEmpty || _routes.isEmpty) return;

    final route = _routes[_selected];
    final nearRoute = fresh.any(
      (report) => route.points.any(
        (p) => _distance.distance(p, report.point) <= _routeAlertMetres,
      ),
    );

    if (nearRoute) {
      _snack('A new incident was reported near your route. Re-checking…',
          danger: true);
      _scoreRoutes();
    }
  }

  void _snack(String message, {bool danger = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
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
    final me = _me;
    final start = _start;
    final destination = _destination;

    return Scaffold(
      appBar: AppBar(title: const Text('Safe Route')),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _indiaCenter,
              initialZoom: 4.6,
              minZoom: 3,
              maxZoom: 18,
              onMapReady: () {
                _mapReady = true;
                final here = _me;
                if (here != null) _mapController.move(here, 15);
              },
              onTap: (_, __) => _searchFocus.unfocus(),
              onLongPress: (_, point) {
                setState(() => _customStart = point);
                _snack('Start point set. Tap “Use my location” to undo.');
                if (_destination != null) _findRoutes();
              },
            ),
            children: [
              osmTileLayer(),
              PolylineLayer(polylines: _polylines()),
              MarkerLayer(
                markers: [
                  for (final report in _feed.reports)
                    Marker(
                      point: report.point,
                      width: 22,
                      height: 22,
                      child: LiveReportBubble(
                        count: 1,
                        hasRecent: report.age != null && report.age!.inMinutes < 60,
                      ),
                    ),
                  if (_customStart != null)
                    Marker(
                      point: _customStart!,
                      width: 36,
                      height: 36,
                      alignment: Alignment.topCenter,
                      child: const Icon(Icons.trip_origin,
                          color: Colors.green, size: 30),
                    ),
                  if (destination != null)
                    Marker(
                      point: destination.point,
                      width: 40,
                      height: 40,
                      alignment: Alignment.topCenter,
                      child: const Icon(Icons.location_on,
                          color: Colors.red, size: 40),
                    ),
                  if (me != null) userLocationMarker(me),
                ],
              ),
              osmAttribution(),
            ],
          ),

          // Search panel
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  _searchPanel(start),
                  if (_suggestions.isNotEmpty) _suggestionList(),
                  if (_suggestions.isEmpty) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: LiveStatusPill(
                        lastUpdated: _feed.lastUpdated,
                        error: _feed.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Route choices / errors
          if (_error != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 16,
              child: Card(
                color: Colors.red.shade50,
                child: ListTile(
                  leading: const Icon(Icons.error_outline, color: Colors.red),
                  title: Text(_error!),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _error = null),
                  ),
                ),
              ),
            )
          else if (_loadingRoutes)
            const Positioned(
              left: 12,
              right: 12,
              bottom: 16,
              child: Card(
                child: ListTile(
                  leading: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  title: Text('Finding routes…'),
                ),
              ),
            )
          else if (_routes.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 12,
              child: _routeCards(),
            ),
        ],
      ),
    );
  }

  List<Polyline> _polylines() {
    if (_routes.isEmpty) return const [];

    final lines = <Polyline>[];

    // Other options first (grey), so the chosen one is drawn on top.
    for (var i = 0; i < _routes.length; i++) {
      if (i == _selected) continue;
      lines.add(Polyline(
        points: _routes[i].points,
        strokeWidth: 5,
        color: Colors.grey.withValues(alpha: 0.7),
      ));
    }

    final chosen = _routes[_selected];
    final color = chosen.averageScore == null
        ? Colors.blue
        : scoreColor(chosen.averageScore!);

    lines.add(Polyline(
      points: chosen.points,
      strokeWidth: 7,
      color: color,
      borderStrokeWidth: 2,
      borderColor: Colors.white,
    ));

    return lines;
  }

  Widget _searchPanel(LatLng? start) {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(16),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  _customStart != null ? Icons.trip_origin : Icons.my_location,
                  color: Colors.green,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _customStart != null
                        ? 'From: chosen point on map'
                        : start != null
                            ? 'From: your location'
                            : (_locationProblem ?? 'Finding your location…'),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                if (_customStart != null)
                  TextButton(
                    onPressed: () {
                      setState(() => _customStart = null);
                      if (_destination != null) _findRoutes();
                    },
                    child: const Text('Use my location'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              textInputAction: TextInputAction.search,
              onChanged: _onQueryChanged,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.location_on, color: Colors.red),
                hintText: 'Where are you going?',
                isDense: true,
                filled: true,
                fillColor: Colors.grey.shade100,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _suggestions = [];
                            _destination = null;
                            _routes = [];
                          });
                        },
                      ),
              ),
            ),
            const SizedBox(height: 8),
            SegmentedButton<TravelMode>(
              segments: const [
                ButtonSegment(
                  value: TravelMode.walk,
                  icon: Icon(Icons.directions_walk),
                  label: Text('Walk'),
                ),
                ButtonSegment(
                  value: TravelMode.drive,
                  icon: Icon(Icons.directions_car),
                  label: Text('Drive'),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (selection) {
                setState(() => _mode = selection.first);
                if (_destination != null) _findRoutes();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _suggestionList() {
    return Card(
      margin: const EdgeInsets.only(top: 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 260),
        child: ListView.separated(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: _suggestions.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final place = _suggestions[i];
            return ListTile(
              dense: true,
              leading: const Icon(Icons.place_outlined),
              title: Text(place.name),
              subtitle: Text(
                place.detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _chooseDestination(place),
            );
          },
        ),
      ),
    );
  }

  Widget _routeCards() {
    final safest = _safestIndex;
    final fastest = _fastestIndex;

    return SizedBox(
      height: 150,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _routes.length,
        itemBuilder: (_, i) {
          final route = _routes[i];
          final selected = i == _selected;
          final score = route.averageScore;

          return GestureDetector(
            onTap: () => setState(() => _selected = i),
            child: Container(
              width: 230,
              margin: const EdgeInsets.only(right: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: selected
                      ? (score == null ? Colors.blue : scoreColor(score))
                      : Colors.transparent,
                  width: 3,
                ),
                boxShadow: const [
                  BoxShadow(blurRadius: 8, color: Colors.black26),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    children: [
                      if (safest == i) _tag('Safest', Colors.green.shade700),
                      if (fastest == i) _tag('Fastest', Colors.blue.shade700),
                      if (safest != i && fastest != i)
                        _tag('Option ${i + 1}', Colors.grey.shade700),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${route.durationMinutes.round()} min · '
                    '${route.distanceKm.toStringAsFixed(1)} km',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (score == null)
                    Text(
                      _scoring ? 'Checking safety…' : 'Safety not checked',
                      style: TextStyle(color: Colors.grey.shade700),
                    )
                  else ...[
                    Row(
                      children: [
                        Icon(Icons.shield, size: 18, color: scoreColor(score)),
                        const SizedBox(width: 6),
                        Text(
                          'Safety $score/100 · ${scoreLabel(score)}',
                          style: TextStyle(
                            color: scoreColor(score),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    if (route.lowestScore != null &&
                        route.lowestScore! < 40)
                      Text(
                        'Passes a high-risk stretch (${route.lowestScore})',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.red.shade700,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _tag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
