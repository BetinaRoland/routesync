import 'package:firebase_database/firebase_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../core/theme.dart';

class BusPos {
  final String busId;
  final LatLng pos;
  final DateTime time;
  final double? speed;
  final int staleAfterSeconds;
  BusPos(this.busId, this.pos, this.time, this.speed, this.staleAfterSeconds);

  bool get stale =>
      DateTime.now().difference(time).inSeconds > staleAfterSeconds;

  static BusPos? from(String id, Object? raw, {int staleAfterSeconds = 120}) {
    if (raw is! Map) return null;
    final lat = (raw['lat'] as num?)?.toDouble();
    final lng = (raw['lng'] as num?)?.toDouble();
    final ts = (raw['ts'] as num?)?.toInt();
    if (lat == null || lng == null || ts == null) return null;
    return BusPos(
      id,
      LatLng(lat, lng),
      DateTime.fromMillisecondsSinceEpoch(ts),
      (raw['speed'] as num?)?.toDouble(),
      staleAfterSeconds,
    );
  }
}

LatLng _pt(Map<String, dynamic> s) =>
    LatLng((s['lat'] as num).toDouble(), (s['lng'] as num).toDouble());

int clampRouteProgress(int progress, int pointCount) {
  if (pointCount <= 0) return 0;
  return progress.clamp(1, pointCount).toInt();
}

class LiveMap extends StatelessWidget {
  final String? busId;
  final List<Map<String, dynamic>> stops;
  final Map<String, dynamic>? myStop;
  final bool showEta;
  final List<Map<String, dynamic>> routeGeometry;
  final bool trackingEnabled;
  final String? trackingUnavailableMessage;
  final int staleAfterSeconds;
  final String? busLabel;
  const LiveMap({
    super.key,
    this.busId,
    this.stops = const [],
    this.myStop,
    this.showEta = true,
    this.routeGeometry = const [],
    this.trackingEnabled = true,
    this.trackingUnavailableMessage,
    this.staleAfterSeconds = 120,
    this.busLabel,
  });

  String? _eta(BusPos b) {
    if (myStop == null || !showEta) return null;
    if (b.stale) {
      return 'Live ETA unavailable: the bus has not reported recently.';
    }
    final km = const Distance().distance(b.pos, _pt(myStop!)) / 1000;
    final kmh = ((b.speed ?? 0) * 3.6).clamp(20.0, 45.0);
    final mins = (km * 1.3 / kmh * 60).round();
    return mins <= 1
        ? 'Arriving now (estimate).'
        : 'About $mins min to your stop (estimate).';
  }

  Future<List<Map<String, dynamic>>> _loadAdminStops() async {
    final fs = FirebaseFirestore.instance;
    final buses = await fs.collection('buses').get();
    final ids = <String>{};
    for (final bus in buses.docs) {
      final routeId = bus.data()['routeId'] as String?;
      if (routeId == null) continue;
      final route = (await fs.doc('routes/$routeId').get()).data();
      ids.addAll(List<String>.from((route?['stopIds'] as List?) ?? const []));
    }
    final out = <Map<String, dynamic>>[];
    for (final id in ids) {
      final point = (await fs.doc('boardingPoints/$id').get()).data();
      if (point != null &&
          point['latitude'] is num &&
          point['longitude'] is num) {
        out.add({
          'id': id,
          'name': point['name'],
          'lat': (point['latitude'] as num).toDouble(),
          'lng': (point['longitude'] as num).toDouble(),
        });
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final adminStopsFuture = busId == null
        ? _loadAdminStops()
        : Future<List<Map<String, dynamic>>>.value(stops);
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: adminStopsFuture,
      builder: (context, adminSnap) {
        final effectiveStops = adminSnap.data ?? stops;
        final locationRef = FirebaseDatabase.instance.ref(
          busId == null ? 'liveLocations' : 'liveLocations/$busId',
        );
        final progressRef = FirebaseDatabase.instance.ref(
          busId == null ? 'routeProgress' : 'routeProgress/$busId',
        );
        return StreamBuilder<DatabaseEvent>(
          stream: trackingEnabled ? progressRef.onValue : null,
          builder: (context, progressSnap) {
            final progressValue = progressSnap.data?.snapshot.value;
            final progress = progressValue is Map
                ? Map<String, dynamic>.from(progressValue)
                : <String, dynamic>{};
            final stopStatuses = <String, dynamic>{};
            final currentStopIds = <String>{};
            final visitedIds = <String>{};
            if (busId != null) {
              if (progress['stopStatuses'] is Map) {
                stopStatuses.addAll(
                  Map<String, dynamic>.from(progress['stopStatuses'] as Map),
                );
              }
              final stopId = progress['stopId']?.toString();
              if (stopId != null) currentStopIds.add(stopId);
              visitedIds.addAll(
                ((progress['visitedStopIds'] as List?) ?? const []).map(
                  (e) => '$e',
                ),
              );
            } else if (progressValue is Map) {
              progressValue.forEach((key, value) {
                if (value is! Map) return;
                final one = Map<String, dynamic>.from(value);
                final stopId = one['stopId']?.toString();
                if (stopId != null) currentStopIds.add(stopId);
                visitedIds.addAll(
                  ((one['visitedStopIds'] as List?) ?? const []).map(
                    (e) => '$e',
                  ),
                );
                if (one['stopStatuses'] is Map) {
                  stopStatuses.addAll(
                    Map<String, dynamic>.from(one['stopStatuses'] as Map),
                  );
                }
              });
            }

            return StreamBuilder<DatabaseEvent>(
              stream: trackingEnabled ? locationRef.onValue : null,
              builder: (context, locationSnap) {
                if (locationSnap.hasError) {
                  return const Center(
                    child: Text('Tracking is unavailable right now.'),
                  );
                }
                final buses = <BusPos>[];
                final value = locationSnap.data?.snapshot.value;
                if (busId != null) {
                  final bus = BusPos.from(
                    busId!,
                    value,
                    staleAfterSeconds: staleAfterSeconds,
                  );
                  if (bus != null) buses.add(bus);
                } else if (value is Map) {
                  value.forEach((key, raw) {
                    final bus = BusPos.from(
                      '$key',
                      raw,
                      staleAfterSeconds: staleAfterSeconds,
                    );
                    if (bus != null) buses.add(bus);
                  });
                }

                final centre = buses.isNotEmpty
                    ? buses.first.pos
                    : myStop != null
                    ? _pt(myStop!)
                    : effectiveStops.isNotEmpty
                    ? _pt(effectiveStops.first)
                    : const LatLng(13.0827, 80.2707);
                final eta = buses.isNotEmpty ? _eta(buses.first) : null;

                final allRoutePoints = routeGeometry.isNotEmpty
                    ? routeGeometry.map(_pt).toList()
                    : effectiveStops.map(_pt).toList();
                var split = effectiveStops.isEmpty
                    ? allRoutePoints.length
                    : visitedIds.length.clamp(0, effectiveStops.length);
                if (allRoutePoints.length >= 2 &&
                    split > 0 &&
                    split < effectiveStops.length &&
                    effectiveStops.isNotEmpty) {
                  final completedStop = _pt(effectiveStops[split - 1]);
                  split =
                      allRoutePoints.indexWhere(
                        (point) =>
                            const Distance().distance(point, completedStop) <
                            250,
                      ) +
                      1;
                  if (split <= 0) split = 1;
                }
                split = clampRouteProgress(split, allRoutePoints.length);

                final completed = allRoutePoints.length >= 2
                    ? allRoutePoints.take(split).toList()
                    : allRoutePoints;
                final remaining = allRoutePoints.length >= 2
                    ? allRoutePoints
                          .skip((split - 1).clamp(0, allRoutePoints.length - 1))
                          .toList()
                    : allRoutePoints;

                return Column(
                  children: [
                    Expanded(
                      child: FlutterMap(
                        options: MapOptions(
                          initialCenter: centre,
                          initialZoom: 13,
                        ),
                        children: [
                          TileLayer(
                            urlTemplate:
                                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.example.routesync',
                          ),
                          if (completed.length >= 2)
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: completed,
                                  strokeWidth: 5,
                                  color: Colors.blueGrey.shade700,
                                ),
                              ],
                            ),
                          if (remaining.length >= 2)
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: remaining,
                                  strokeWidth: 7,
                                  color: teal,
                                ),
                              ],
                            ),
                          MarkerLayer(
                            markers: [
                              for (final stop in effectiveStops)
                                Marker(
                                  point: _pt(stop),
                                  width: 44,
                                  height: 48,
                                  child: Column(
                                    children: [
                                      Icon(
                                        Icons.location_on,
                                        size: 34,
                                        color: visitedIds.contains(stop['id'])
                                            ? Colors.grey.shade600
                                            : currentStopIds.contains(
                                                    stop['id'],
                                                  ) ||
                                                  stop['id'] == myStop?['id'] ||
                                                  stopStatuses[stop['id']] ==
                                                      'approaching'
                                            ? amber
                                            : teal,
                                      ),
                                      if ((stop['name'] ?? '')
                                          .toString()
                                          .isNotEmpty)
                                        Text(
                                          '${stop['name']}',
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 9,
                                            color:
                                                visitedIds.contains(stop['id'])
                                                ? Colors.grey.shade700
                                                : Colors.black87,
                                            fontWeight:
                                                currentStopIds.contains(
                                                  stop['id'],
                                                )
                                                ? FontWeight.bold
                                                : FontWeight.normal,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              for (final bus in buses)
                                Marker(
                                  point: bus.pos,
                                  width: 70,
                                  height: 56,
                                  child: Column(
                                    children: [
                                      Icon(
                                        Icons.directions_bus,
                                        size: 32,
                                        color: bus.stale ? Colors.grey : navy,
                                      ),
                                      Text(
                                        busLabel ?? bus.busId,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                      child: Wrap(
                        spacing: 10,
                        children: const [
                          _Legend(Icons.location_on, Colors.grey, 'Visited'),
                          _Legend(Icons.location_on, amber, 'Current'),
                          _Legend(Icons.location_on, teal, 'Upcoming'),
                        ],
                      ),
                    ),
                    if (eta != null)
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text(
                          eta,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    if (buses.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          trackingEnabled
                              ? 'No location received yet. The complete route remains visible.'
                              : trackingUnavailableMessage ??
                                    'Tracking is currently unavailable. The complete route remains visible.',
                        ),
                      )
                    else
                      for (final bus in buses)
                        ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.circle,
                            size: 12,
                            color: bus.stale ? Colors.orange : Colors.green,
                          ),
                          title: Text(
                            'Bus ${bus.busId}: ${bus.stale ? "stale (last known position)" : "live"}',
                          ),
                          subtitle: Text(
                            'Last update ${bus.time.toLocal().toString().substring(11, 19)}',
                          ),
                        ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

class _Legend extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  const _Legend(this.icon, this.color, this.label);

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: 3),
      Text(label, style: const TextStyle(fontSize: 11)),
    ],
  );
}
