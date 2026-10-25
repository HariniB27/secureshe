import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

class PointCluster<T> {
  PointCluster(this.center, this.items);

  final LatLng center;
  final List<T> items;

  int get count => items.length;
}

/// Groups points that would sit within [cellPixels] of each other on screen
/// at the given [zoom]. Re-run it when the whole-number zoom changes.
List<PointCluster<T>> clusterPoints<T>(
  Iterable<T> items,
  LatLng Function(T item) pointOf,
  double zoom, {
  double cellPixels = 64,
}) {
  final worldSize = 256 * math.pow(2, zoom).toDouble();
  final cells = <String, List<T>>{};

  for (final item in items) {
    final p = pointOf(item);
    final lat = p.latitude.clamp(-85.0, 85.0) * math.pi / 180;

    // Web Mercator, the same projection the map tiles use.
    final x = (p.longitude + 180) / 360 * worldSize;
    final y = (1 - math.log(math.tan(lat) + 1 / math.cos(lat)) / math.pi) /
        2 *
        worldSize;

    final key = '${(x / cellPixels).floor()}:${(y / cellPixels).floor()}';
    (cells[key] ??= <T>[]).add(item);
  }

  return cells.values.map((group) {
    var lat = 0.0;
    var lng = 0.0;

    for (final item in group) {
      final p = pointOf(item);
      lat += p.latitude;
      lng += p.longitude;
    }

    return PointCluster<T>(
      LatLng(lat / group.length, lng / group.length),
      group,
    );
  }).toList();
}
