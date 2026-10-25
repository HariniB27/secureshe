import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../services/live_reports_feed.dart';
import '../services/location_service.dart';
import '../services/routing_service.dart';
import '../services/safety_api_service.dart';
import '../state/app_prefs.dart';
import '../state/shell_controller.dart';
import '../state/trip_state.dart';
import '../theme.dart';
import '../utils/map_clustering.dart';
import '../widgets/map_widgets.dart';
import '../widgets/ss_components.dart';
import '../widgets/ss_ui.dart';

enum _LayerMode { heat, safe, all }

/// What a tap on the map shows in the info card.
class _MapPick {
  _MapPick({required this.title, required this.subtitle, required this.color, this.point});

  final String title;
  final String subtitle;
  final Color color;
  final LatLng? point;
}

/// Safety Map from the design, built on the real-time crime map and Safe
/// Route:
///
/// * Community heat map: live reports (updated every 10 s, with a 1 hour /
///   24 hours / this week filter), community flags and district crime data.
/// * Safe route: search a destination, compare walking or driving routes on
///   reports, road type and lighting, then start a tracked Safe Trip.
/// * "+" adds a community flag at your location.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  static const _defaultCenter = LatLng(12.9165, 79.1325); // Vellore
  static const _endToleranceMetres = 75.0;
  static const _maxDetourFactor = 1.5;
  static const _showGapMetres = 40.0;
  static const _alertRadiusMetres = 1000.0;

  final _map = MapController();
  final _api = SafetyApiService();
  final _routing = RoutingService();
  final _feed = LiveReportsFeed();
  final _distance = const Distance();
  final _toController = TextEditingController();
  final _toFocus = FocusNode();

  ShellController? _shell;
  bool _visible = false;
  bool _mapReady = false;

  // You
  StreamSubscription<Position>? _positionSub;
  LatLng? _me;
  double _accuracy = 0;
  LatLng? _customStart;
  String? _locationProblem;
  String? _hereName;

  // Data layers
  List<DistrictCrime> _districts = [];
  List<CommunityFlag> _flags = [];
  List<PointCluster<LiveReport>> _clusters = [];
  int _clusterZoom = 13;
  int _windowHours = 24;
  _LayerMode _layerMode = _LayerMode.heat;

  // Route planning
  TravelMode _mode = TravelMode.walk;
  Timer? _searchDebounce;
  List<PlaceResult> _suggestions = [];
  PlaceResult? _destination;
  List<RouteOption> _routes = [];
  int _selected = 0;
  LatLng? _routeEnd;
  double _endGap = 0;
  int _routeRequest = 0;
  bool _loadingRoutes = false;
  bool _scoring = false;
  bool _night = false;
  bool _environmentChecked = true;
  String? _routeError;

  // UI
  bool _expanded = false;
  _MapPick? _pick;

  LatLng? get _start => _customStart ?? _me;
  bool get _routeSet => _routes.isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _feed.addListener(_onFeed);
    _feed.windowHours = _windowHours;
    _loadStatic();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shell = context.read<ShellController>();
    if (!identical(shell, _shell)) {
      _shell?.removeListener(_onShell);
      _shell = shell..addListener(_onShell);
      _onShell();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shell?.removeListener(_onShell);
    _positionSub?.cancel();
    _searchDebounce?.cancel();
    _feed.removeListener(_onFeed);
    _feed.dispose();
    _map.dispose();
    _toController.dispose();
    _toFocus.dispose();
    super.dispose();
  }

  // Only poll and track GPS while the Map tab is on screen.
  void _onShell() {
    final shell = _shell!;
    final visible = shell.tab == ShellTab.map;

    if (visible && !_visible) {
      _visible = true;
      _feed.start();
      _startLocation();
      _loadFlags();
    } else if (!visible && _visible) {
      _visible = false;
      _feed.stop();
      _positionSub?.pause();
    }

    if (visible) {
      final place = shell.takePendingDestination();
      final query = shell.takePendingQuery();
      if (place != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _chooseDestination(place));
      } else if (query != null && query.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _toController.text = query;
          _searchNow(query, autoPickFirst: true);
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_visible) return;
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

  Future<void> _loadStatic() async {
    try {
      final districts = await _api.fetchDistrictCrime();
      if (mounted) setState(() => _districts = districts);
    } catch (e) {
      debugPrint('District data failed: $e');
    }
  }

  Future<void> _loadFlags() async {
    try {
      final flags = await _api.fetchFlags(hours: _windowHours < 24 * 7 ? 24 * 7 : _windowHours);
      if (mounted) setState(() => _flags = flags);
    } catch (e) {
      debugPrint('Flags failed: $e');
    }
  }

  void _onFeed() {
    if (!mounted) return;
    setState(_recluster);

    final me = _me;
    final fresh = _feed.latestNew;
    if (fresh.isEmpty) return;

    if (me != null &&
        fresh.any((r) => _distance.distance(me, r.point) <= _alertRadiusMetres)) {
      context.read<AppPrefs>().notify(
            type: 'warning',
            title: 'Unsafe area nearby',
            message: 'A new incident was reported within 1 km of you.',
          );
      _snack('New incident reported within 1 km of you', danger: true);
    }

    if (_routeSet) {
      final route = _routes[_selected];
      final nearRoute = fresh.any(
        (r) => route.points.any((p) => _distance.distance(p, r.point) <= 300),
      );
      if (nearRoute) {
        _snack('A new incident was reported near your route. Re-checking…', danger: true);
        _scoreRoutes();
      }
    }
  }

  void _recluster() {
    _clusters = clusterPoints<LiveReport>(
      _feed.reports,
      (r) => r.point,
      _clusterZoom.toDouble(),
    );
  }

  Future<void> _setWindow(int hours) async {
    setState(() => _windowHours = hours);
    await _feed.setWindow(hours);
    _loadFlags();
  }

  // ------------------------------------------------------------------
  // Location
  // ------------------------------------------------------------------

  Future<void> _startLocation() async {
    if (_positionSub != null) {
      _positionSub!.resume();
      return;
    }

    final problem = await LocationService.ensurePermission();
    if (!mounted) return;
    if (problem != null) {
      setState(() => _locationProblem = problem);
      return;
    }

    _positionSub = LocationService.positionStream().listen(_onPosition);
    final quick = await LocationService.quickFix();
    if (quick != null && _me == null) _onPosition(quick);
  }

  void _onPosition(Position p) {
    if (!mounted) return;
    final first = _me == null;
    final here = LatLng(p.latitude, p.longitude);
    setState(() {
      _me = here;
      _accuracy = p.accuracy;
      _locationProblem = null;
    });
    if (first) {
      if (_mapReady && !_routeSet) _map.move(here, 14.5);
      _routing.placeName(here).then((name) {
        if (mounted && name != null) setState(() => _hereName = name);
      });
    }
  }

  void _recenter() {
    final target = _start;
    if (target == null) {
      _startLocation();
      if (_locationProblem != null) _snack(_locationProblem!);
      return;
    }
    if (!_mapReady) return;
    _map.move(target, math.max(_map.camera.zoom, 15));
  }

  void _onCamera(MapCamera camera, bool hasGesture) {
    final zoom = camera.zoom.round();
    if (zoom == _clusterZoom) return;
    Future.microtask(() {
      if (!mounted) return;
      setState(() {
        _clusterZoom = zoom;
        _recluster();
      });
    });
  }

  // ------------------------------------------------------------------
  // Destination search
  // ------------------------------------------------------------------

  void _onQueryChanged(String text) {
    _searchDebounce?.cancel();
    if (_destination != null && text != _destination!.name) _clearRoute(keepText: true);

    if (text.trim().length < 3) {
      setState(() => _suggestions = []);
      return;
    }
    // The free search server allows about one request per second.
    _searchDebounce = Timer(const Duration(milliseconds: 700), () => _searchNow(text));
  }

  Future<void> _searchNow(String text, {bool autoPickFirst = false}) async {
    try {
      final results = await _routing.searchPlaces(text.trim(), near: _start);
      if (!mounted || _toController.text.trim() != text.trim()) return;
      if (autoPickFirst && results.isNotEmpty) {
        _chooseDestination(results.first);
      } else {
        setState(() => _suggestions = results);
      }
    } catch (e) {
      debugPrint('Place search failed: $e');
    }
  }

  Future<void> _chooseDestination(PlaceResult place) async {
    _toFocus.unfocus();
    _toController.text = place.name;
    setState(() {
      _destination = place;
      _suggestions = [];
      _pick = null;
    });
    await _findRoutes();
  }

  void _clearRoute({bool keepText = false}) {
    _routeRequest++;
    if (!keepText) _toController.clear();
    setState(() {
      _destination = null;
      _routes = [];
      _routeEnd = null;
      _endGap = 0;
      _scoring = false;
      _loadingRoutes = false;
      _routeError = null;
      if (!keepText) _suggestions = [];
    });
  }

  // ------------------------------------------------------------------
  // Routes
  // ------------------------------------------------------------------

  Future<void> _findRoutes() async {
    final start = _start;
    final destination = _destination;
    if (destination == null) return;

    if (start == null) {
      setState(() => _routeError = _locationProblem ??
          'Still finding your location. Long-press the map to set a start point.');
      return;
    }

    final request = ++_routeRequest;
    setState(() {
      _loadingRoutes = true;
      _routeError = null;
      _routes = [];
      _routeEnd = null;
      _endGap = 0;
    });

    try {
      final result = _mode == TravelMode.walk
          ? await _routing.getWalkingRoutes(start, destination.point)
          : await _routing.getRoutes(start, destination.point, _mode);
      if (!mounted || request != _routeRequest) return;

      // Only routes that actually reach the destination.
      final valid = result.routes.where((route) {
        if (route.points.length < 2) return false;
        final end = route.points.last;
        return _distance.distance(end, result.snappedEnd) <= _endToleranceMetres ||
            (route.viaMainRoads &&
                _distance.distance(end, destination.point) <= _endToleranceMetres * 2);
      }).toList();

      if (valid.isEmpty) throw Exception('Could not find a route that reaches this place.');

      setState(() {
        _routes = valid.take(4).toList();
        _selected = _fastestIndex;
        _routeEnd = result.snappedEnd;
        _endGap = result.endSnapMetres;
        _loadingRoutes = false;
      });

      _fitRoutes();
      await _scoreRoutes();
    } catch (e) {
      if (!mounted || request != _routeRequest) return;
      setState(() {
        _loadingRoutes = false;
        _routeError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _scoreRoutes() async {
    if (_routes.isEmpty) return;
    final request = _routeRequest;
    final routes = _routes;
    setState(() => _scoring = true);

    bool stale() => !mounted || request != _routeRequest || !identical(routes, _routes);

    try {
      final check = await _api.checkRoutes(
        routes: [for (final r in routes) _sample(r.points, 30)],
        distancesMetres: [for (final r in routes) r.distanceMetres],
      );
      if (stale()) return;

      for (var i = 0; i < routes.length; i++) {
        final s = check.routes[i];
        routes[i]
          ..averageScore = s.score
          ..lowestScore = s.lowestCrimeScore
          ..mainRoadPct = s.mainRoadPct
          ..isolatedPct = s.isolatedPct
          ..litPct = s.litPct
          ..warnings = s.warnings;
      }
      setState(() {
        _night = check.night;
        _environmentChecked = check.environmentChecked;
        _selected = _safestIndex ?? _selected;
      });
    } catch (e) {
      debugPrint('Route check failed: $e');
      if (stale()) return;
      // Fall back to report-only scoring.
      try {
        final samples = [for (final r in routes) _sample(r.points, 20)];
        final results = await _api.fetchScoresBatch(samples.expand((s) => s).toList());
        if (stale()) return;
        var offset = 0;
        for (var i = 0; i < routes.length; i++) {
          final scores = results
              .sublist(offset, offset + samples[i].length)
              .map((r) => r.score)
              .toList();
          offset += samples[i].length;
          routes[i].averageScore = (scores.reduce((a, b) => a + b) / scores.length).round();
          routes[i].lowestScore = scores.reduce(math.min);
        }
        setState(() {
          _environmentChecked = false;
          _selected = _safestIndex ?? _selected;
        });
      } catch (_) {
        if (!stale()) _snack('Could not check route safety.');
      }
    } finally {
      if (mounted && request == _routeRequest) setState(() => _scoring = false);
    }
  }

  List<LatLng> _sample(List<LatLng> points, int count) {
    if (points.length <= count) return points;
    final step = (points.length - 1) / (count - 1);
    return [for (var i = 0; i < count; i++) points[(i * step).round()]];
  }

  int get _fastestIndex {
    var best = 0;
    for (var i = 1; i < _routes.length; i++) {
      if (_routes[i].durationSeconds < _routes[best].durationSeconds) best = i;
    }
    return best;
  }

  /// Safest route that isn't a big detour; near-ties go to the quicker one.
  int? get _safestIndex {
    if (_routes.isEmpty || _routes.any((r) => r.averageScore == null)) return null;
    final fastest = _routes[_fastestIndex].durationSeconds;
    final candidates = [
      for (var i = 0; i < _routes.length; i++)
        if (_routes[i].durationSeconds <= fastest * _maxDetourFactor) i,
    ];
    var best = candidates.first;
    for (final i in candidates.skip(1)) {
      final diff = _routes[i].averageScore! - _routes[best].averageScore!;
      final quicker = _routes[i].durationSeconds < _routes[best].durationSeconds;
      if (diff > 2 || (diff.abs() <= 2 && quicker)) best = i;
    }
    return best;
  }

  void _fitRoutes() {
    if (!_mapReady || _routes.isEmpty) return;
    _map.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints([
          ..._routes.expand((r) => r.points),
          if (_destination != null) _destination!.point,
        ]),
        padding: const EdgeInsets.all(36),
      ),
    );
  }

  Future<void> _startTrip() async {
    final route = _routes[_selected];
    final error = await context.read<TripState>().start(
          destinationName: _destination?.name ?? 'Destination',
          route: route.points,
          distanceMetres: route.distanceMetres,
          durationSeconds: route.durationSeconds,
          walking: _mode == TravelMode.walk,
          safetyScore: route.averageScore,
        );
    if (!mounted) return;
    if (error != null) {
      _snack(error);
      return;
    }
    Navigator.of(context).pushNamed('/trip');
  }

  // ------------------------------------------------------------------
  // Flags
  // ------------------------------------------------------------------

  void _openFlagSheet() {
    final at = _me ?? (_mapReady ? _map.camera.center : null);
    if (at == null) {
      _snack('Waiting for your location…');
      return;
    }
    showSSSheet<void>(
      context,
      builder: (_) => _FlagSheet(
        at: at,
        placeName: _me != null ? _hereName : null,
        usingMapCentre: _me == null,
        onAdded: (kind) {
          _loadFlags();
          context.read<AppPrefs>().notify(
                type: kind == 'safe-zone' ? 'success' : 'warning',
                title: 'Community flag added',
                message: 'Thanks for helping others stay safe.',
              );
        },
      ),
    );
  }

  void _snack(String message, {bool danger = false}) {
    if (!mounted || !_visible) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: danger ? const TextStyle(color: Colors.white) : null),
          backgroundColor: danger ? AppColors.destructive : null,
        ),
      );
  }

  // ------------------------------------------------------------------
  // Build
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_expanded) return _expandedView(context);

    // The map is never inside a scroll view, so dragging always pans the
    // map. Only the suggestions and the route panel scroll.
    return SSPage(
      header: _header(context),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_suggestions.isNotEmpty)
            Flexible(flex: 4, child: _suggestionList(context))
          else if (!_routeSet)
            _filterChips()
          else
            const SizedBox(height: 12),
          Expanded(
            flex: _routeSet ? 5 : 10,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    border: Border.all(color: context.ss.border),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: _mapCanvas(context, tall: false),
                ),
              ),
            ),
          ),
          if (_pick != null) _pickCard(context),
          if (_loadingRoutes)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_routeError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: MessageBanner(
                text: _routeError!,
                icon: Icons.error_outline_rounded,
                onClose: () => setState(() => _routeError = null),
              ),
            ),
          if (!_routeSet && _locationProblem != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: MessageBanner(
                text: '$_locationProblem Long-press the map to set a start point.',
                color: AppColors.warning,
                icon: Icons.location_off_outlined,
              ),
            ),
          if (_routeSet)
            Flexible(
              flex: 6,
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 16),
                child: _routePanel(context),
              ),
            )
          else
            const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final c = context.ss;
    return GlassHeader(
      title: 'Safety Map',
      subtitle: _routeSet
          ? 'Safe route plotted'
          : _customStart != null
              ? 'Start set on map'
              : 'Community heat map',
      onBack: () => context.read<ShellController>().go(ShellTab.home),
      trailing: LiveBadge(lastUpdated: _feed.lastUpdated, error: _feed.error),
      bottom: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Column(
          children: [
            // From
            _RouteField(
              dotColor: AppColors.success,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _customStart != null
                          ? 'Point chosen on map'
                          : _me != null
                              ? 'My Location${_hereName == null ? '' : ' · $_hereName'}'
                              : 'Finding your location…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: c.foreground),
                    ),
                  ),
                  if (_customStart != null)
                    GestureDetector(
                      onTap: () {
                        setState(() => _customStart = null);
                        if (_destination != null) _findRoutes();
                      },
                      child: Icon(Icons.close_rounded, size: 16, color: c.mutedForeground),
                    )
                  else
                    GestureDetector(
                      onTap: _recenter,
                      child: const Icon(Icons.my_location_rounded,
                          size: 16, color: AppColors.primary),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 18),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Column(
                  children: [
                    for (var i = 0; i < 2; i++)
                      Container(
                        width: 2,
                        height: 4,
                        margin: const EdgeInsets.symmetric(vertical: 1),
                        color: c.border,
                      ),
                  ],
                ),
              ),
            ),
            // To
            _RouteField(
              dotColor: AppColors.primary,
              pin: true,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _toController,
                      focusNode: _toFocus,
                      onChanged: _onQueryChanged,
                      onSubmitted: (t) => _searchNow(t, autoPickFirst: true),
                      textInputAction: TextInputAction.search,
                      style: TextStyle(fontSize: 13, color: c.foreground),
                      decoration: InputDecoration(
                        hintText: 'Where are you going?',
                        hintStyle: TextStyle(fontSize: 13, color: c.mutedForeground),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  if (_toController.text.isNotEmpty)
                    GestureDetector(
                      onTap: () => _clearRoute(),
                      child: Icon(Icons.close_rounded, size: 16, color: c.mutedForeground),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _ModeChip(
                  icon: Icons.directions_walk_rounded,
                  label: 'Walk',
                  selected: _mode == TravelMode.walk,
                  onTap: () {
                    setState(() => _mode = TravelMode.walk);
                    if (_destination != null) _findRoutes();
                  },
                ),
                const SizedBox(width: 8),
                _ModeChip(
                  icon: Icons.directions_car_rounded,
                  label: 'Drive',
                  selected: _mode == TravelMode.drive,
                  onTap: () {
                    setState(() => _mode = TravelMode.drive);
                    if (_destination != null) _findRoutes();
                  },
                ),
                const Spacer(),
                if (_destination != null && !_routeSet && !_loadingRoutes)
                  TextButton.icon(
                    onPressed: _findRoutes,
                    icon: const Icon(Icons.navigation_rounded, size: 16),
                    label: const Text('Check Safe Route'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterChips() {
    const filters = [(1, '1 Hour'), (24, '24 Hours'), (24 * 7, 'This Week')];
    final c = context.ss;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Row(
        children: [
          for (final (hours, label) in filters)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => _setWindow(hours),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: _windowHours == hours ? AppColors.primary : c.card,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _windowHours == hours ? AppColors.primary : c.border,
                    ),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: _windowHours == hours ? Colors.white : c.mutedForeground,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _suggestionList(BuildContext context) {
    final c = context.ss;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: SSCard(
        padding: EdgeInsets.zero,
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            for (final place in _suggestions.take(6))
              ListTile(
                dense: true,
                leading: const Icon(Icons.place_outlined, color: AppColors.primary),
                title: Text(place.name, style: TextStyle(color: c.foreground)),
                subtitle: Text(
                  place.detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: c.mutedForeground),
                ),
                trailing: place.distanceKm == null
                    ? null
                    : Text(
                        formatDistance(place.distanceKm! * 1000),
                        style: TextStyle(fontSize: 11, color: c.mutedForeground),
                      ),
                onTap: () => _chooseDestination(place),
              ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // Map canvas (normal and fullscreen)
  // ------------------------------------------------------------------

  Widget _mapCanvas(BuildContext context, {required bool tall}) {
    final me = _me;
    final showHeat = _layerMode != _LayerMode.safe;
    final showSafe = _layerMode != _LayerMode.heat || _routeSet;
    final incidents = _feed.reports.length +
        _flags.where((f) => !f.isSafe).length;

    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: _me ?? _defaultCenter,
            initialZoom: 13.5,
            minZoom: 3,
            maxZoom: 18,
            onMapReady: () {
              _mapReady = true;
              if (_routeSet) {
                _fitRoutes();
              } else if (_me != null) {
                _map.move(_me!, 14.5);
              }
            },
            onPositionChanged: _onCamera,
            onTap: (_, __) {
              _toFocus.unfocus();
              if (_pick != null) setState(() => _pick = null);
            },
            onLongPress: (_, point) {
              setState(() => _customStart = point);
              _snack('Start point set. Tap × next to it to use your location again.');
              if (_destination != null) _findRoutes();
            },
          ),
          children: [
            themedTileLayer(context),
            if (showHeat && !_routeSet)
              CircleLayer(
                circles: [
                  for (final d in _districts)
                    CircleMarker(
                      point: d.point,
                      radius: 4000 + 16000 * math.sqrt(d.intensity),
                      useRadiusInMeter: true,
                      color: districtColor(d.intensity).withValues(alpha: 0.14),
                      borderColor: districtColor(d.intensity).withValues(alpha: 0.35),
                      borderStrokeWidth: 1,
                    ),
                ],
              ),
            if (me != null) CircleLayer(circles: [userAccuracyCircle(me, _accuracy)]),
            if (_routeSet) PolylineLayer(polylines: _polylines()),
            MarkerLayer(
              markers: [
                if (showHeat)
                  for (final cluster in _clusters)
                    Marker(
                      point: cluster.center,
                      width: cluster.count > 1 ? 34 : 24,
                      height: cluster.count > 1 ? 34 : 24,
                      child: GestureDetector(
                        onTap: () => _tapCluster(cluster),
                        child: ZoneMarker(
                          level: ZoneLevel.unsafe,
                          size: cluster.count > 1 ? 30 : (cluster.count == 1 ? 16 : 12),
                          count: cluster.count,
                          fresh: cluster.items.any(
                            (r) => r.age != null && r.age!.inMinutes < 60,
                          ),
                        ),
                      ),
                    ),
                for (final f in _flags)
                  if ((f.isSafe && showSafe) || (!f.isSafe && showHeat))
                    Marker(
                      point: f.point,
                      width: 24,
                      height: 24,
                      child: GestureDetector(
                        onTap: () => setState(() => _pick = _MapPick(
                              title: f.label,
                              subtitle: 'Community flag · ${timeAgo(f.reportedAt)}',
                              color: f.isSafe
                                  ? AppColors.success
                                  : f.kind == 'dark-street'
                                      ? AppColors.warning
                                      : AppColors.destructive,
                              point: f.point,
                            )),
                        child: ZoneMarker(
                          level: f.isSafe
                              ? ZoneLevel.safe
                              : f.kind == 'dark-street'
                                  ? ZoneLevel.moderate
                                  : ZoneLevel.unsafe,
                          size: 14,
                        ),
                      ),
                    ),
                if (_customStart != null)
                  Marker(
                    point: _customStart!,
                    width: 20,
                    height: 20,
                    child: const ZoneMarker(level: ZoneLevel.safe, size: 16),
                  ),
                if (_destination != null)
                  Marker(
                    point: _destination!.point,
                    width: 40,
                    height: 40,
                    alignment: Alignment.topCenter,
                    child: const Icon(Icons.location_on_rounded,
                        size: 40, color: AppColors.primary),
                  ),
                if (me != null) userLocationMarker(me),
              ],
            ),
            mapAttribution(context),
          ],
        ),

        // Legend
        Positioned(
          top: tall ? 100 : 12,
          left: 12,
          child: _Legend(routeSet: _routeSet),
        ),

        if (!tall)
          Positioned(
            top: 12,
            right: 12,
            child: LiveBadge(
              compact: true,
              lastUpdated: _feed.lastUpdated,
              error: _feed.error,
            ),
          ),

        // Buttons
        Positioned(
          right: 12,
          bottom: tall ? 24 : 12,
          child: Column(
            children: [
              if (tall) ...[
                _MapFab(icon: Icons.add_rounded, onTap: () => _zoom(1)),
                const SizedBox(height: 8),
                _MapFab(icon: Icons.remove_rounded, onTap: () => _zoom(-1)),
                const SizedBox(height: 8),
              ],
              _MapFab(icon: Icons.my_location_rounded, onTap: _recenter),
              if (!_routeSet || tall) ...[
                const SizedBox(height: 8),
                _MapFab(
                  icon: Icons.add_location_alt_rounded,
                  primary: true,
                  tooltip: 'Add community flag',
                  onTap: _openFlagSheet,
                ),
              ],
              if (!tall) ...[
                const SizedBox(height: 8),
                _MapFab(
                  icon: Icons.open_in_full_rounded,
                  tinted: true,
                  tooltip: 'Expand map',
                  onTap: () => setState(() {
                    // A new map is built for fullscreen; wait for it.
                    _mapReady = false;
                    _expanded = true;
                    _pick = null;
                  }),
                ),
              ],
            ],
          ),
        ),

        if (!_routeSet && !tall)
          Positioned(
            left: 12,
            bottom: 28,
            child: _GlassPill(
              icon: Icons.shield_outlined,
              text: '$incidents incident${incidents == 1 ? '' : 's'}',
            ),
          ),
      ],
    );
  }

  void _zoom(double delta) {
    if (!_mapReady) return;
    final cam = _map.camera;
    _map.move(cam.center, (cam.zoom + delta).clamp(3, 18).toDouble());
  }

  void _tapCluster(PointCluster<LiveReport> cluster) {
    if (cluster.count > 1 && _mapReady) {
      _map.move(cluster.center, math.min(_map.camera.zoom + 2, 18));
      return;
    }
    final r = cluster.items.first;
    setState(() => _pick = _MapPick(
          title: 'Incident reported',
          subtitle: '${formatAge(r.age)} · approximate area (about 100 m). Details are private.',
          color: AppColors.destructive,
          point: r.point,
        ));
  }

  List<Polyline> _polylines() {
    final lines = <Polyline>[];
    for (var i = 0; i < _routes.length; i++) {
      if (i == _selected) continue;
      lines.add(Polyline(
        points: _routes[i].points,
        strokeWidth: 5,
        color: context.ss.mutedForeground.withValues(alpha: 0.6),
      ));
    }

    final chosen = _routes[_selected];
    final color = chosen.averageScore == null ? AppColors.primary : scoreColor(chosen.averageScore!);

    lines.add(Polyline(
      points: chosen.points,
      strokeWidth: 12,
      color: color.withValues(alpha: 0.18),
    ));
    lines.add(Polyline(
      points: chosen.points,
      strokeWidth: 4,
      color: color,
      pattern: const StrokePattern.dashed(segments: [10, 5]),
    ));

    final destination = _destination;
    if (_routeEnd != null && destination != null && _endGap > _showGapMetres) {
      lines.add(Polyline(
        points: [chosen.points.last, destination.point],
        strokeWidth: 3,
        color: color.withValues(alpha: 0.7),
        pattern: const StrokePattern.dotted(),
      ));
    }
    return lines;
  }

  Widget _pickCard(BuildContext context) {
    final pick = _pick!;
    final c = context.ss;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: SSCard(
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: pick.color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    pick.title,
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: c.foreground),
                  ),
                  const SizedBox(height: 2),
                  Text(pick.subtitle, style: TextStyle(fontSize: 11, color: c.mutedForeground)),
                ],
              ),
            ),
            GestureDetector(
              onTap: () => setState(() => _pick = null),
              child: Icon(Icons.close_rounded, size: 18, color: c.mutedForeground),
            ),
          ],
        ),
      ),
    );
  }

  Widget _routePanel(BuildContext context) {
    final c = context.ss;
    final route = _routes[_selected];
    final score = route.averageScore;
    final safest = _safestIndex;
    final fastest = _fastestIndex;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.success.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.success.withValues(alpha: 0.25)),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle_outline_rounded, color: AppColors.success),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _scoring
                            ? 'Checking route safety…'
                            : safest == _selected
                                ? 'Safest route found ✓'
                                : 'Route ${_selected + 1} selected',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: c.foreground,
                        ),
                      ),
                      Text(
                        '${_customStart != null ? 'Map point' : 'My Location'} → ${_destination?.name ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: c.mutedForeground),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => _clearRoute(),
                  child: Icon(Icons.close_rounded, size: 18, color: c.mutedForeground),
                ),
              ],
            ),
          ),
          if (_routes.length > 1) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (var i = 0; i < _routes.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        selected: i == _selected,
                        onSelected: (_) => setState(() => _selected = i),
                        selectedColor: AppColors.primary.withValues(alpha: 0.2),
                        backgroundColor: c.card,
                        side: BorderSide(
                          color: i == _selected ? AppColors.primary : c.border,
                        ),
                        showCheckmark: false,
                        label: Text(
                          [
                            if (i == safest) 'Safest',
                            if (i == fastest) 'Fastest',
                            if (_routes[i].viaMainRoads) 'Main roads',
                            if (i != safest && i != fastest && !_routes[i].viaMainRoads)
                              'Option ${i + 1}',
                          ].join(' · ') +
                              ' · ${_routes[i].durationMinutes.round()} min',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: i == _selected ? AppColors.primary : c.mutedForeground,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  icon: Icons.schedule_rounded,
                  label: 'ETA',
                  value: formatDuration(Duration(seconds: route.durationSeconds.round())),
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: StatTile(
                  icon: Icons.place_outlined,
                  label: 'Distance',
                  value: formatDistance(route.distanceMetres),
                  color: AppColors.warning,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: StatTile(
                  icon: Icons.shield_outlined,
                  label: 'Safety',
                  value: score == null ? (_scoring ? '…' : '–') : '$score%',
                  color: score == null ? AppColors.success : scoreColor(score),
                ),
              ),
            ],
          ),
          if (route.mainRoadPct != null || !_environmentChecked || _night) ...[
            const SizedBox(height: 8),
            Text(
              [
                if (route.mainRoadPct != null) 'Main roads ${route.mainRoadPct}%',
                if (route.litPct != null && route.litPct! > 0) 'Lit ${route.litPct}%',
                if (_night) 'Rated for night',
                if (!_environmentChecked) 'Based on reports only',
              ].join(' · '),
              style: TextStyle(fontSize: 11, color: c.mutedForeground),
            ),
          ],
          for (final warning in route.warnings) ...[
            const SizedBox(height: 8),
            MessageBanner(
              text: warning,
              color: AppColors.warning,
              icon: Icons.warning_amber_rounded,
            ),
          ],
          if (_endGap > _showGapMetres) ...[
            const SizedBox(height: 8),
            Text(
              'The last ${formatDistance(_endGap)} to the pin is off-road (dotted line).',
              style: TextStyle(fontSize: 11, color: c.mutedForeground),
            ),
          ],
          const SizedBox(height: 16),
          GradientButton(
            label: 'Start Safe Trip',
            icon: Icons.navigation_rounded,
            onPressed: _startTrip,
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // Fullscreen
  // ------------------------------------------------------------------

  Widget _expandedView(BuildContext context) {
    const filters = [(1, '1 Hour'), (24, '24 Hours'), (24 * 7, 'This Week')];
    final incidents = _feed.reports.length + _flags.where((f) => !f.isSafe).length;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          setState(() {
            _mapReady = false;
            _expanded = false;
          });
        }
      },
      child: Scaffold(
        backgroundColor: context.ss.screen,
        body: Stack(
          children: [
            Positioned.fill(child: _mapCanvas(context, tall: true)),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _MapFab(
                          icon: Icons.close_fullscreen_rounded,
                          size: 36,
                          onTap: () => setState(() {
                            _mapReady = false;
                            _expanded = false;
                          }),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _GlassPill(
                            icon: Icons.place_outlined,
                            text: _routeSet
                                ? 'My Location → ${_destination?.name ?? ''}'
                                : '${_hereName ?? 'Near you'} · $incidents incidents',
                          ),
                        ),
                        const SizedBox(width: 8),
                        _MapFab(
                          icon: Icons.layers_outlined,
                          size: 36,
                          tooltip: switch (_layerMode) {
                            _LayerMode.heat => 'Showing incidents',
                            _LayerMode.safe => 'Showing safe zones',
                            _LayerMode.all => 'Showing everything',
                          },
                          onTap: () => setState(() {
                            _layerMode = _LayerMode.values[
                                (_layerMode.index + 1) % _LayerMode.values.length];
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        for (final (hours, label) in filters)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: GestureDetector(
                              onTap: () => _setWindow(hours),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                                decoration: BoxDecoration(
                                  color: _windowHours == hours
                                      ? AppColors.primary
                                      : const Color(0xC70A0814),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: _windowHours == hours
                                        ? AppColors.primary
                                        : Colors.white24,
                                  ),
                                ),
                                child: Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: _windowHours == hours ? Colors.white : Colors.white60,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ======================================================================
// Small pieces
// ======================================================================

class _RouteField extends StatelessWidget {
  const _RouteField({required this.dotColor, required this.child, this.pin = false});

  final Color dotColor;
  final Widget child;
  final bool pin;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: dotColor.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: pin
                  ? Icon(Icons.place_rounded, size: 12, color: dotColor)
                  : Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                    ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withValues(alpha: 0.15) : c.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? AppColors.primary : c.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: selected ? AppColors.primary : c.mutedForeground),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: selected ? AppColors.primary : c.mutedForeground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MapFab extends StatelessWidget {
  const _MapFab({
    required this.icon,
    required this.onTap,
    this.primary = false,
    this.tinted = false,
    this.size = 40,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool primary;
  final bool tinted;
  final double size;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final button = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: primary ? AppColors.primaryGradient : null,
        color: primary
            ? null
            : tinted
                ? AppColors.primary.withValues(alpha: 0.18)
                : c.sheet,
        borderRadius: BorderRadius.circular(size * 0.4),
        border: primary
            ? null
            : Border.all(
                color: tinted ? AppColors.primary.withValues(alpha: 0.3) : c.border,
              ),
        boxShadow: [
          BoxShadow(
            color: primary
                ? AppColors.primary.withValues(alpha: 0.4)
                : Colors.black.withValues(alpha: 0.25),
            blurRadius: primary ? 18 : 8,
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(size * 0.4),
          onTap: onTap,
          child: Icon(
            icon,
            size: size * 0.45,
            color: primary ? Colors.white : (tinted ? AppColors.primary : c.foreground),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

class _GlassPill extends StatelessWidget {
  const _GlassPill({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: c.sheet.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppColors.primary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: c.foreground),
            ),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.routeSet});

  final bool routeSet;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final items = routeSet
        ? const [
            (AppColors.success, 'Safer path'),
            (AppColors.warning, 'Be alert'),
            (AppColors.primary, 'Destination'),
          ]
        : const [
            (AppColors.success, 'Safe zone'),
            (AppColors.warning, 'Dark street'),
            (AppColors.destructive, 'Incident'),
          ];

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: c.sheet.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            routeSet ? 'Route Key' : 'Safety Zones',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: c.foreground),
          ),
          const SizedBox(height: 6),
          for (final (color, label) in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(label, style: TextStyle(fontSize: 9, color: c.mutedForeground)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// "Add Community Flag" sheet.
class _FlagSheet extends StatefulWidget {
  const _FlagSheet({
    required this.at,
    required this.placeName,
    required this.usingMapCentre,
    required this.onAdded,
  });

  final LatLng at;
  final String? placeName;
  final bool usingMapCentre;
  final void Function(String kind) onAdded;

  @override
  State<_FlagSheet> createState() => _FlagSheetState();
}

class _FlagSheetState extends State<_FlagSheet> {
  String? _sending;
  String? _error;

  static const _types = [
    ('dark-street', 'Dark Street', 'Poorly lit area', Icons.nightlight_round, AppColors.warning),
    ('harassment', 'Harassment', 'Incident reported', Icons.warning_amber_rounded, AppColors.destructive),
    ('suspicious', 'Suspicious Activity', 'Unusual behaviour', Icons.visibility_outlined, AppColors.primary),
    ('safe-zone', 'Mark Safe Zone', 'Community-verified safe', Icons.shield_outlined, AppColors.success),
  ];

  Future<void> _add(String kind) async {
    setState(() {
      _sending = kind;
      _error = null;
    });
    try {
      final response = await ApiService.addFlag(
        kind: kind,
        lat: widget.at.latitude,
        lng: widget.at.longitude,
      );
      if (!mounted) return;
      if (response.statusCode == 201) {
        widget.onAdded(kind);
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Flag added. Thanks for keeping others safe.')),
        );
        return;
      }
      setState(() {
        _sending = null;
        _error = response.statusCode == 429
            ? 'Too many flags in the last hour. Try again later.'
            : 'Could not add the flag (${response.statusCode}).';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sending = null;
        _error = 'Cannot reach the server.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetTitle(
          title: 'Add Community Flag',
          subtitle: 'Help others stay safe by marking safety concerns',
        ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              const Icon(Icons.place_outlined, size: 16, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.usingMapCentre ? 'Centre of the map' : 'Detected location',
                      style: TextStyle(fontSize: 10, color: c.mutedForeground),
                    ),
                    Text(
                      widget.placeName ??
                          '${widget.at.latitude.toStringAsFixed(4)}, '
                              '${widget.at.longitude.toStringAsFixed(4)}',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.foreground),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        for (final (kind, label, desc, icon, color) in _types)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SSCard(
              padding: const EdgeInsets.all(14),
              onTap: _sending == null ? () => _add(kind) : null,
              child: Row(
                children: [
                  IconTile(icon: icon, color: color, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label,
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600, color: c.foreground)),
                        Text(desc, style: TextStyle(fontSize: 11, color: c.mutedForeground)),
                      ],
                    ),
                  ),
                  _sending == kind
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.flag_outlined, size: 16, color: c.mutedForeground),
                ],
              ),
            ),
          ),
        if (_error != null) ...[
          MessageBanner(text: _error!),
          const SizedBox(height: 8),
        ],
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: c.mutedForeground)),
        ),
      ],
    );
  }
}
