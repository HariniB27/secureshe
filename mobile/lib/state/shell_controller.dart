import 'package:flutter/foundation.dart';

import '../services/routing_service.dart';

enum ShellTab { home, report, map, circle, profile }

enum EvidenceKind { photo, audio, video, file }

/// A recording or file waiting to be attached to a report.
class EvidenceDraft {
  EvidenceDraft({
    required this.bytes,
    required this.filename,
    required this.kind,
    this.duration,
  });

  final Uint8List bytes;
  final String filename;
  final EvidenceKind kind;
  final Duration? duration;
}

/// Which bottom tab is showing, plus hand-offs between tabs (e.g. Home's
/// "Start Safe Trip" sheet opening the Map with a destination filled in).
class ShellController extends ChangeNotifier {
  ShellTab tab = ShellTab.home;

  /// A destination for the Map tab to route to as soon as it shows.
  PlaceResult? pendingDestination;

  /// Text for the Map's destination box when no exact place was picked.
  String? pendingDestinationQuery;

  void go(ShellTab next) {
    if (tab == next) return;
    tab = next;
    notifyListeners();
  }

  void planTrip({PlaceResult? place, String? query}) {
    pendingDestination = place;
    pendingDestinationQuery = query;
    tab = ShellTab.map;
    notifyListeners();
  }

  PlaceResult? takePendingDestination() {
    final p = pendingDestination;
    pendingDestination = null;
    return p;
  }

  String? takePendingQuery() {
    final q = pendingDestinationQuery;
    pendingDestinationQuery = null;
    return q;
  }

  /// Evidence recorded on Home, to be attached on the Report tab.
  EvidenceDraft? pendingEvidence;

  void reportWith(EvidenceDraft evidence) {
    pendingEvidence = evidence;
    tab = ShellTab.report;
    notifyListeners();
  }

  EvidenceDraft? takePendingEvidence() {
    final e = pendingEvidence;
    pendingEvidence = null;
    return e;
  }
}
