import 'dart:math' as math;

// Pure logic (no Firebase) so it can be unit-tested.

double haversineM(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  double rad(double x) => x * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1);
  final h =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.pow(math.sin(dLng / 2), 2);
  return 2 * r * math.asin(math.sqrt(h));
}

/// Shortest distance in metres from a point to a polyline of [lat, lng] pairs.
double distToPolylineM(double lat, double lng, List<List<double>> poly) {
  if (poly.isEmpty) return 0;
  final k = math.cos(lat * math.pi / 180);
  final pts = [
    for (final p in poly) [(p[1] - lng) * 111320 * k, (p[0] - lat) * 110540],
  ];
  if (pts.length == 1) {
    return math.sqrt(pts[0][0] * pts[0][0] + pts[0][1] * pts[0][1]);
  }
  var best = double.infinity;
  for (var i = 0; i < pts.length - 1; i++) {
    final a = pts[i],
        b = pts[i + 1],
        dx = b[0] - a[0],
        dy = b[1] - a[1],
        l2 = dx * dx + dy * dy;
    var t = l2 == 0 ? 0.0 : (-a[0] * dx - a[1] * dy) / l2;
    t = t.clamp(0.0, 1.0);
    final x = a[0] + t * dx, y = a[1] + t * dy;
    best = math.min(best, math.sqrt(x * x + y * y));
  }
  return best;
}

/// policy: {calculationMethod: 'perKm' | 'slabs', ratePerKm, distanceSlabs: [{maxKm, amount}]}
int? computeFee(Map<String, dynamic> p, double km) {
  if (p['calculationMethod'] == 'slabs') {
    final slabs =
        ((p['distanceSlabs'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList()
          ..sort((a, b) => (a['maxKm'] as num).compareTo(b['maxKm'] as num));
    for (final s in slabs) {
      if (km <= (s['maxKm'] as num)) return (s['amount'] as num).round();
    }
    return null;
  }
  return (km * ((p['ratePerKm'] as num?) ?? 0)).round();
}

List<T> downsample<T>(List<T> a, int max) {
  if (a.length <= max) return a;
  final step = (a.length - 1) / (max - 1);
  return [for (var i = 0; i < max; i++) a[(i * step).round()]];
}

int minutesOf(String hhmm) {
  final p = hhmm.split(':');
  return int.parse(p[0]) * 60 + int.parse(p[1]);
}

String distancePriority(double distanceM) {
  final km = distanceM / 1000;
  if (km > 30) return 'Very high';
  if (km > 20) return 'High';
  if (km >= 10) return 'Medium';
  return 'Low';
}

Map<String, dynamic> capacityStatus({
  required int capacity,
  required int assigned,
}) {
  final overflow = math.max(0, assigned - capacity);
  return {
    'capacity': capacity,
    'assigned': assigned,
    'remaining': math.max(0, capacity - assigned),
    'unaccommodated': overflow,
    'overCapacity': overflow > 0,
  };
}

bool isDriverEligible(
  Map<String, dynamic> driver,
  String? regionId, {
  String? busId,
}) {
  if (driver['status'] != null && driver['status'] != 'active') return false;
  final assigned = driver['assignedBusId'];
  if (assigned != null && assigned != busId) return false;
  if (regionId == null || regionId.isEmpty) return true;
  return ((driver['permittedRegionIds'] as List?) ?? const [])
      .map((e) => '$e')
      .contains(regionId);
}

class Rider {
  final String id, stopId;
  const Rider(this.id, this.stopId);
}

class GBus {
  final String id;
  int remaining;
  final List<String> stops;
  final bool active;
  GBus(this.id, this.remaining, this.stops, this.active);
}

class GResult {
  final Map<String, String> assignments;
  final List<String> unallocated;
  GResult(this.assignments, this.unallocated);
}

/// Fills buses already in use first and opens an idle bus only when it must. Never exceeds seats.
GResult greedyAllocate(List<Rider> students, List<GBus> buses) {
  final left = {for (final b in buses) b.id: b.remaining};
  final stopsOf = {for (final b in buses) b.id: b.stops.toSet()};
  final used = {
    for (final b in buses)
      if (b.active) b.id,
  };
  final byStop = <String, List<Rider>>{};
  for (final s in students) {
    (byStop[s.stopId] ??= []).add(s);
  }
  final assignments = <String, String>{}, unallocated = <String>[];
  final groups = byStop.entries.toList()
    ..sort((a, b) => b.value.length.compareTo(a.value.length));
  for (final g in groups) {
    final queue = [...g.value];
    while (queue.isNotEmpty) {
      final cands = buses
          .where((b) => stopsOf[b.id]!.contains(g.key) && left[b.id]! > 0)
          .toList();
      if (cands.isEmpty) {
        unallocated.addAll(queue.map((s) => s.id));
        break;
      }
      cands.sort((a, b) {
        final u = (used.contains(b.id) ? 1 : 0) - (used.contains(a.id) ? 1 : 0);
        return u != 0 ? u : left[b.id]!.compareTo(left[a.id]!);
      });
      final bus = cands.first, n = math.min(left[bus.id]!, queue.length);
      for (final s in queue.take(n)) {
        assignments[s.id] = bus.id;
      }
      queue.removeRange(0, n);
      left[bus.id] = left[bus.id]! - n;
      used.add(bus.id);
    }
  }
  return GResult(assignments, unallocated);
}

class FleetBus {
  final String id, number;
  final int capacity, allocated;
  final List<String> stops;
  final String? routeId, driverId, permittedRegionId;
  final bool availability, driverAuthorized;
  final String maintenanceStatus;
  const FleetBus({
    required this.id,
    required this.number,
    required this.capacity,
    required this.allocated,
    required this.stops,
    this.routeId,
    this.driverId,
    this.permittedRegionId,
    this.availability = true,
    this.maintenanceStatus = 'ok',
    this.driverAuthorized = true,
  });
  int get spare => capacity - allocated;
}

class Move {
  final String studentId, from, to;
  const Move(this.studentId, this.from, this.to);
}

class RebalancePlan {
  final List<Move> moves;
  final List<String> freed;
  RebalancePlan(this.moves, this.freed);
}

/// Finds buses whose riders all fit on other buses (same stops, free seats). Receiving buses are locked so later steps stay valid.
RebalancePlan planRebalance(
  List<FleetBus> buses,
  Map<String, List<Rider>> riders, {
  int maxFreed = 3,
}) {
  final remaining = {for (final b in buses) b.id: b.capacity - b.allocated};
  final freed = <String>{}, locked = <String>{}, moves = <Move>[];
  final candidates = buses.where((b) => b.allocated > 0).toList()
    ..sort((a, b) => a.allocated.compareTo(b.allocated));
  for (final cand in candidates) {
    if (freed.length >= maxFreed) break;
    if (locked.contains(cand.id)) continue;
    final mine = riders[cand.id] ?? [];
    if (mine.isEmpty) continue;
    final targets = [
      for (final b in buses)
        if (b.id != cand.id && !freed.contains(b.id))
          GBus(b.id, remaining[b.id]!, b.stops, true),
    ];
    final r = greedyAllocate(mine, targets);
    if (r.unallocated.isNotEmpty) continue;
    for (final e in r.assignments.entries) {
      moves.add(Move(e.key, cand.id, e.value));
      remaining[e.value] = remaining[e.value]! - 1;
      locked.add(e.value);
    }
    freed.add(cand.id);
    remaining[cand.id] = 0;
  }
  return RebalancePlan(moves, freed.toList());
}

/// Buses that could take over [needed] riders: usable, enough free seats, authorised driver first, tightest fit first.
List<FleetBus> replacementOptions(int needed, List<FleetBus> candidates) {
  final list = candidates
      .where(
        (c) =>
            c.availability && c.maintenanceStatus == 'ok' && c.spare >= needed,
      )
      .toList();
  list.sort((a, b) {
    final d = (b.driverAuthorized ? 1 : 0) - (a.driverAuthorized ? 1 : 0);
    return d != 0 ? d : a.spare.compareTo(b.spare);
  });
  return list;
}

class RouteInfo {
  final String id, name;
  final List<String> stopIds;
  const RouteInfo(this.id, this.name, this.stopIds);
}

class Overlap {
  final RouteInfo a, b;
  final List<String> shared;
  final int share;
  Overlap(this.a, this.b, this.shared, this.share);
}

/// Pairs of routes that share at least two stops and at least half of the shorter route.
List<Overlap> routeOverlaps(List<RouteInfo> routes) {
  final out = <Overlap>[];
  for (var i = 0; i < routes.length; i++) {
    for (var j = i + 1; j < routes.length; j++) {
      final a = routes[i], b = routes[j], set = a.stopIds.toSet();
      final shared = b.stopIds.where(set.contains).toList();
      final min = math.min(a.stopIds.length, b.stopIds.length);
      if (shared.length >= 2 && min > 0 && shared.length / min >= 0.5) {
        out.add(Overlap(a, b, shared, (100 * shared.length / min).round()));
      }
    }
  }
  out.sort((x, y) => y.share.compareTo(x.share));
  return out;
}
