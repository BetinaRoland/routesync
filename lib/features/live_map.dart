import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../core/theme.dart';

class BusPos {
  final String busId;
  final LatLng pos;
  final DateTime time;
  final double? speed; // m/s
  BusPos(this.busId, this.pos, this.time, this.speed);

  /// A position older than 60 s is shown as stale, never as live.
  bool get stale => DateTime.now().difference(time).inSeconds > 60;

  static BusPos? from(String id, Object? raw) {
    if (raw is! Map) return null;
    final lat = (raw['lat'] as num?)?.toDouble(), lng = (raw['lng'] as num?)?.toDouble(), ts = (raw['ts'] as num?)?.toInt();
    if (lat == null || lng == null || ts == null) return null;
    return BusPos(id, LatLng(lat, lng), DateTime.fromMillisecondsSinceEpoch(ts), (raw['speed'] as num?)?.toDouble());
  }
}

LatLng _pt(Map<String, dynamic> s) => LatLng((s['lat'] as num).toDouble(), (s['lng'] as num).toDouble());

/// One bus ([busId] set) or every bus (admins). Optional route stops and the rider's own stop for an ETA estimate.
class LiveMap extends StatelessWidget {
  final String? busId;
  final List<Map<String, dynamic>> stops;
  final Map<String, dynamic>? myStop;
  final bool showEta; // false when an EtaBadge supplies the road-based time
  const LiveMap({super.key, this.busId, this.stops = const [], this.myStop, this.showEta = true});

  String? _eta(BusPos b) {
    if (myStop == null || !showEta) return null;
    if (b.stale) return 'Live ETA unavailable: the bus has not reported recently.';
    final km = const Distance().distance(b.pos, _pt(myStop!)) / 1000;
    final kmh = ((b.speed ?? 0) * 3.6).clamp(20.0, 45.0);
    final mins = (km * 1.3 / kmh * 60).round();
    return mins <= 1 ? 'Arriving now (estimate).' : 'About $mins min to your stop (estimate).';
  }

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseDatabase.instance.ref(busId == null ? 'liveLocations' : 'liveLocations/$busId');
    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snap) {
        if (snap.hasError) return const Center(child: Text('Tracking is unavailable right now.'));
        final buses = <BusPos>[];
        final v = snap.data?.snapshot.value;
        if (busId != null) {
          final b = BusPos.from(busId!, v);
          if (b != null) buses.add(b);
        } else if (v is Map) {
          v.forEach((k, val) {
            final b = BusPos.from('$k', val);
            if (b != null) buses.add(b);
          });
        }
        final centre = buses.isNotEmpty ? buses.first.pos : (myStop != null ? _pt(myStop!) : (stops.isNotEmpty ? _pt(stops.first) : const LatLng(13.0827, 80.2707)));
        final eta = buses.isNotEmpty ? _eta(buses.first) : null;
        return Column(children: [
          Expanded(
            child: FlutterMap(
              options: MapOptions(initialCenter: centre, initialZoom: 13),
              children: [
                TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.example.routesync'),
                MarkerLayer(markers: [
                  for (final s in stops)
                    Marker(point: _pt(s), width: 36, height: 36, child: Icon(Icons.location_on, color: s['id'] == myStop?['id'] ? amber : teal, size: 30)),
                  if (myStop != null) Marker(point: _pt(myStop!), width: 40, height: 40, child: const Icon(Icons.location_on, color: amber, size: 36)),
                  for (final b in buses)
                    Marker(
                      point: b.pos, width: 70, height: 56,
                      child: Column(children: [
                        Icon(Icons.directions_bus, size: 32, color: b.stale ? Colors.grey : navy),
                        Text(b.busId, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      ]),
                    ),
                ]),
              ],
            ),
          ),
          if (eta != null) Padding(padding: const EdgeInsets.all(10), child: Text(eta, style: const TextStyle(fontWeight: FontWeight.w600))),
          if (buses.isEmpty)
            const Padding(padding: EdgeInsets.all(12), child: Text('No location received yet.'))
          else
            SizedBox(
              height: buses.length > 2 ? 120 : null,
              child: ListView(shrinkWrap: true, children: [
                for (final b in buses)
                  ListTile(
                    dense: true,
                    leading: Icon(Icons.circle, size: 12, color: b.stale ? Colors.orange : Colors.green),
                    title: Text('Bus ${b.busId}: ${b.stale ? "stale (last known position)" : "live"}'),
                    subtitle: Text('Last update ${b.time.toLocal().toString().substring(11, 19)}'),
                  ),
              ]),
            ),
        ]);
      },
    );
  }
}
