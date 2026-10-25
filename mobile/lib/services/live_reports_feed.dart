import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'safety_api_service.dart';

/// Keeps the list of recent reports up to date by asking the backend every
/// [interval] for anything new since the last check.
///
/// The first call loads the last 30 days; after that each call sends the
/// server's own timestamp back as `since`, so only new reports come down.
/// If the server can't be reached it waits longer between tries (up to 8x)
/// and recovers on its own.
class LiveReportsFeed extends ChangeNotifier {
  LiveReportsFeed({
    SafetyApiService? api,
    this.interval = const Duration(seconds: 10),
  }) : _api = api ?? SafetyApiService();

  final SafetyApiService _api;
  final Duration interval;

  final Map<int, LiveReport> _reports = {};
  String? _cursor;
  Timer? _timer;
  bool _polling = false;
  bool _disposed = false;
  int _failures = 0;

  /// When the last successful check finished.
  DateTime? lastUpdated;

  /// Set while the server can't be reached.
  String? error;

  /// Reports that arrived in the most recent check. Always empty after the
  /// first load, so screens only alert on genuinely new reports.
  List<LiveReport> latestNew = const [];

  List<LiveReport> get reports => _reports.values.toList(growable: false);

  bool get hasLoaded => _cursor != null;

  void start() {
    if (_timer != null || _disposed) return;
    _poll();
    _scheduleNext();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> refresh() => _poll();

  void _scheduleNext() {
    _timer?.cancel();
    final delay = interval * (1 << math.min(_failures, 3));

    _timer = Timer(delay, () async {
      await _poll();
      if (_timer != null && !_disposed) _scheduleNext();
    });
  }

  Future<void> _poll() async {
    if (_polling || _disposed) return;
    _polling = true;

    final firstLoad = _cursor == null;

    try {
      final page = await _api.fetchLiveReports(since: _cursor);
      final fresh = <LiveReport>[];

      for (final report in page.reports) {
        if (!_reports.containsKey(report.id)) fresh.add(report);
        _reports[report.id] = report;
      }

      _cursor = page.serverTime ?? _cursor;
      latestNew = firstLoad ? const [] : fresh;
      lastUpdated = DateTime.now();
      error = null;
      _failures = 0;
    } catch (e) {
      debugPrint('Live reports poll failed: $e');
      latestNew = const [];
      error = 'Reconnecting…';
      _failures++;
    } finally {
      _polling = false;
    }

    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
