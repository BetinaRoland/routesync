import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../core/api.dart';
import '../../core/widgets.dart';

final _fs = FirebaseFirestore.instance;

// ---------------- Buses ----------------
class BusesPage extends StatelessWidget {
  const BusesPage({super.key});

  Future<void> _edit(BuildContext context, [Doc? d]) async {
    final b = d?.data();
    final routes = await _fs.collection('routes').get();
    if (!context.mounted) return;
    final r = await formDialog(context, d == null ? 'Add bus' : 'Edit bus', [
      F('busNumber', 'Bus number', initial: '${b?['busNumber'] ?? ''}'),
      F(
        'capacity',
        'Seating capacity',
        initial: '${b?['capacity'] ?? ''}',
        number: true,
      ),
      F(
        'permittedRegionId',
        'Region (optional)',
        initial: '${b?['permittedRegionId'] ?? ''}',
      ),
      F(
        'routeId',
        'Route',
        initial: '${b?['routeId'] ?? ''}',
        choices: {
          '': 'No route',
          for (final x in routes.docs) x.id: '${x.data()['routeName']}',
        },
      ),
      F(
        'gpsDeviceId',
        'GPS device ID (optional)',
        initial: '${b?['gpsDeviceId'] ?? ''}',
      ),
      F(
        'availability',
        'Availability',
        initial: '${b?['availability'] ?? true}',
        choices: const {'true': 'Available', 'false': 'Unavailable'},
      ),
      F(
        'maintenanceStatus',
        'Maintenance',
        initial: '${b?['maintenanceStatus'] ?? 'ok'}',
        choices: const {
          'ok': 'In service',
          'maintenance': 'Under maintenance',
          'breakdown': 'Breakdown',
        },
      ),
    ]);
    if (r == null || !context.mounted) return;
    await runAction(context, () async {
      final out = await Api.call('saveBus', {
        'busId': d?.id,
        'busNumber': r['busNumber'],
        'capacity': int.tryParse(r['capacity'] ?? '') ?? 0,
        'permittedRegionId': r['permittedRegionId'],
        'routeId': r['routeId'],
        'gpsDeviceId': r['gpsDeviceId'],
        'availability': r['availability'] != 'false',
        'maintenanceStatus': r['maintenanceStatus'],
      });
      return (out['warning'] as String?) ?? 'Bus saved.';
    });
  }

  Future<void> _assign(BuildContext context, Doc d) async {
    final drivers = await _fs.collection('drivers').get();
    if (!context.mounted) return;
    String label(QueryDocumentSnapshot<Map<String, dynamic>> x) {
      final on = x.data()['assignedBusId'];
      return '${x.data()['name']}${on != null ? ' (on bus $on)' : ''}';
    }

    final r = await formDialog(context, 'Assign driver', [
      F(
        'driverId',
        'Driver',
        initial: '${d.data()['driverId'] ?? ''}',
        choices: {
          '': 'No driver',
          for (final x in drivers.docs) x.id: label(x),
        },
      ),
    ], action: 'Assign');
    if (r == null || !context.mounted) return;
    await runAction(context, () async {
      await Api.call('assignDriver', {
        'busId': d.id,
        'driverId': r['driverId']!.isEmpty ? null : r['driverId'],
      });
      return 'Driver updated.';
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton(
      onPressed: () => _edit(context),
      child: const Icon(Icons.add),
    ),
    body: DocList(
      query: _fs.collection('buses').orderBy('busNumber'),
      empty: 'No buses yet. Add the first bus with the + button.',
      itemBuilder: (c, d) {
        final b = d.data();
        return ListTile(
          leading: const Icon(Icons.directions_bus),
          title: Text('Bus ${b['busNumber']}: ${b['capacity']} seats'),
          subtitle: Wrap(
            children: [
              chip(
                b['availability'] == true ? 'Available' : 'Unavailable',
                b['availability'] == true ? Colors.green : Colors.red,
              ),
              chip('${b['maintenanceStatus']}'),
              chip(
                'GPS ${b['trackingStatus']}',
                b['trackingStatus'] == 'active' ? Colors.green : Colors.orange,
              ),
              if (b['scheduleStatus'] == 'delayed')
                chip('Delayed', Colors.amber.shade800),
              chip(
                b['driverId'] == null ? 'No driver' : 'Driver assigned',
                b['driverId'] == null ? Colors.red : Colors.green,
              ),
              chip(
                b['routeId'] == null ? 'No route' : 'Route set',
                b['routeId'] == null ? Colors.red : Colors.green,
              ),
            ],
          ),
          trailing: PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'edit') {
                await _edit(c, d);
              } else if (v == 'driver') {
                await _assign(c, d);
              } else if (v == 'remove' &&
                  await confirm(
                    c,
                    'Remove bus ${b['busNumber']}?',
                    'This cannot be undone. It is blocked while students are allocated to it.',
                    action: 'Remove',
                  ) &&
                  c.mounted) {
                await runAction(c, () async {
                  await Api.call('removeBus', {'busId': d.id});
                  return 'Bus removed.';
                });
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'driver', child: Text('Assign driver')),
              PopupMenuItem(value: 'remove', child: Text('Remove')),
            ],
          ),
        );
      },
    ),
  );
}

// ---------------- Drivers ----------------
class DriversPage extends StatelessWidget {
  const DriversPage({super.key});

  Future<void> _add(BuildContext context) async {
    final r = await formDialog(context, 'Add driver', const [
      F('name', 'Full name'),
      F('email', 'Email'),
      F('password', 'Temporary password (8+ characters)', obscure: true),
      F('contact', 'Phone number'),
      F('regions', 'Permitted regions (comma separated, optional)'),
    ]);
    if (r == null || !context.mounted) return;
    await runAction(context, () async {
      await Api.call('createDriver', {
        'name': r['name'],
        'email': r['email'],
        'password': r['password'],
        'contact': r['contact'],
        'permittedRegionIds': r['regions']!
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
      });
      return 'Driver account created.';
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton(
      onPressed: () => _add(context),
      child: const Icon(Icons.add),
    ),
    body: DocList(
      query: _fs.collection('drivers').orderBy('name'),
      empty: 'No drivers yet.',
      itemBuilder: (c, d) {
        final x = d.data();
        return ListTile(
          leading: const Icon(Icons.badge),
          title: Text('${x['name']}'),
          subtitle: Text(
            '${x['contact']}   ${x['assignedBusId'] == null ? 'Not assigned' : 'Bus ${x['assignedBusId']}'}\nRegions: ${(x['permittedRegionIds'] as List?)?.join(', ') ?? 'any'}',
          ),
          isThreeLine: true,
        );
      },
    ),
  );
}

// ---------------- Boarding points ----------------
class BoardingPointsPage extends StatelessWidget {
  const BoardingPointsPage({super.key});

  Future<void> _add(BuildContext context) async {
    final r = await formDialog(context, 'Add boarding point', const [
      F('name', 'Stop name'),
      F('lat', 'Latitude', number: true),
      F('lng', 'Longitude', number: true),
    ]);
    if (r == null || !context.mounted) return;
    await runAction(context, () async {
      final out = await Api.call('saveBoardingPoint', {
        'name': r['name'],
        'lat': double.tryParse(r['lat'] ?? ''),
        'lng': double.tryParse(r['lng'] ?? ''),
      });
      return 'Saved. Road distance to college: ${(out['roadDistanceKm'] as num).toStringAsFixed(1)} km.';
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton(
      onPressed: () => _add(context),
      child: const Icon(Icons.add_location_alt),
    ),
    body: DocList(
      query: _fs.collection('boardingPoints').orderBy('name'),
      empty:
          'No boarding points yet. Set the college location in System settings first.',
      itemBuilder: (c, d) {
        final p = d.data();
        return ListTile(
          leading: const Icon(Icons.location_on),
          title: Text('${p['name']}'),
          subtitle: Text(
            '${p['roadDistanceKm']} km by road   (${p['latitude']}, ${p['longitude']})',
          ),
          trailing: IconButton(
            tooltip: 'Delete stop',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (await confirm(
                    c,
                    'Delete ${p['name']}?',
                    'Blocked if a route or any student uses this stop.',
                    action: 'Delete',
                  ) &&
                  c.mounted) {
                await runAction(c, () async {
                  await Api.call('deleteBoardingPoint', {
                    'boardingPointId': d.id,
                  });
                  return 'Stop deleted.';
                });
              }
            },
          ),
        );
      },
    ),
  );
}

class RequestsPage extends StatelessWidget {
  const RequestsPage({super.key});

  Future<void> _review(BuildContext context, Doc d) async {
    final r = d.data();
    final p = LatLng(
      (r['requestedLatitude'] as num).toDouble(),
      (r['requestedLongitude'] as num).toDouble(),
    );
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${r['requestedName']}'),
        content: SizedBox(
          width: 420,
          height: 300,
          child: Column(
            children: [
              Text(
                'Requested by ${r['studentName']}${r['isChange'] == true ? ' (change of an approved stop)' : ''}',
              ),
              const SizedBox(height: 8),
              Expanded(
                child: FlutterMap(
                  options: MapOptions(initialCenter: p, initialZoom: 15),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.routesync',
                    ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: p,
                          width: 40,
                          height: 40,
                          child: const Icon(
                            Icons.location_on,
                            color: Colors.red,
                            size: 36,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'reject'),
            child: const Text('Reject'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'approve'),
            child: const Text('Verify and approve'),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    await runAction(context, () async {
      final out = await Api.call('reviewBoardingRequest', {
        'requestId': d.id,
        'approve': choice == 'approve',
      });
      return choice == 'approve'
          ? 'Approved. Road distance ${(out['distanceKm'] as num).toStringAsFixed(1)} km${out['amount'] == null ? '. Fee policy is not configured.' : ', annual fee Rs ${out['amount']} payable at the college office.'}'
          : 'Request rejected.';
    });
  }

  @override
  Widget build(BuildContext context) => DocList(
    query: _fs
        .collection('boardingRequests')
        .where('status', isEqualTo: 'pending')
        .orderBy('submittedAt', descending: true),
    empty: 'No boarding point requests are waiting.',
    itemBuilder: (c, d) {
      final r = d.data();
      return ListTile(
        leading: const Icon(Icons.pin_drop),
        title: Text('${r['requestedName']}'),
        subtitle: Text('${r['studentName']}   ${fmt(r['submittedAt'])}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _review(c, d),
      );
    },
  );
}

// ---------------- Routes ----------------
class RoutesPage extends StatelessWidget {
  const RoutesPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton(
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const RouteEditorPage()),
      ),
      child: const Icon(Icons.add),
    ),
    body: DocList(
      query: _fs.collection('routes').orderBy('routeName'),
      empty:
          'No routes yet. Add boarding points first, then build a route from them.',
      itemBuilder: (c, d) {
        final r = d.data();
        return ListTile(
          leading: const Icon(Icons.alt_route),
          title: Text('${r['routeName']}'),
          subtitle: Text(
            '${(r['stopIds'] as List).length} stops, ${r['routeKm']} km to college${r['arrivalBy'] != null ? ', due ${r['arrivalBy']}' : ''}',
          ),
          onTap: () => Navigator.push(
            c,
            MaterialPageRoute(builder: (_) => RouteEditorPage(route: d)),
          ),
          trailing: IconButton(
            tooltip: 'Delete route',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (await confirm(
                    c,
                    'Delete ${r['routeName']}?',
                    'Blocked while a bus uses this route.',
                    action: 'Delete',
                  ) &&
                  c.mounted) {
                await runAction(c, () async {
                  await Api.call('deleteRoute', {'routeId': d.id});
                  return 'Route deleted.';
                });
              }
            },
          ),
        );
      },
    ),
  );
}

class RouteEditorPage extends StatefulWidget {
  final Doc? route;
  const RouteEditorPage({super.key, this.route});
  @override
  State<RouteEditorPage> createState() => _RouteEditorPageState();
}

class _RouteEditorPageState extends State<RouteEditorPage> {
  final _name = TextEditingController();
  final _region = TextEditingController();
  final _arrival = TextEditingController();
  final List<String> _stops = [];
  final Map<String, String> _names = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final r = widget.route?.data();
    if (r != null) {
      _name.text = '${r['routeName']}';
      _region.text = '${r['permittedRegionId'] ?? ''}';
      _arrival.text = '${r['arrivalBy'] ?? ''}';
      _stops.addAll(List<String>.from(r['stopIds'] as List));
    }
    _fs.collection('boardingPoints').get().then((s) {
      if (mounted) {
        setState(() {
          for (final d in s.docs) {
            _names[d.id] = '${d.data()['name']}';
          }
        });
      }
    });
  }

  Future<void> _addStop() async {
    final free = {
      for (final e in _names.entries)
        if (!_stops.contains(e.key)) e.key: e.value,
    };
    if (free.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No more boarding points to add.')),
      );
      return;
    }
    final r = await formDialog(context, 'Add stop', [
      F('id', 'Boarding point', choices: free),
    ], action: 'Add');
    if (r != null && r['id']!.isNotEmpty) setState(() => _stops.add(r['id']!));
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final nav = Navigator.of(context);
    final ok = await runAction(context, () async {
      await Api.call('saveRoute', {
        'routeId': widget.route?.id,
        'routeName': _name.text.trim(),
        'stopIds': _stops,
        'permittedRegionId': _region.text.trim().isEmpty
            ? null
            : _region.text.trim(),
        'arrivalBy': _arrival.text.trim().isEmpty ? null : _arrival.text.trim(),
        'baseVersion': widget.route?.data()['version'],
      });
      return 'Route saved.';
    });
    if (ok) nav.pop();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.route == null ? 'New route' : 'Edit route'),
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Route name'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _region,
                decoration: const InputDecoration(
                  labelText: 'Region (optional)',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _arrival,
                decoration: const InputDecoration(
                  labelText: 'Must reach college by (HH:MM, optional)',
                  helperText: 'Used to detect delayed buses',
                ),
              ),
              const SizedBox(height: 10),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Stops in pickup order. The last leg ends at the college. Drag to reorder.',
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ReorderableListView(
            onReorderItem: (a, b) =>
                setState(() => _stops.insert(b, _stops.removeAt(a))),
            children: [
              for (final id in _stops)
                ListTile(
                  key: ValueKey(id),
                  leading: const Icon(Icons.drag_handle),
                  title: Text(_names[id] ?? id),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _stops.remove(id)),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: _addStop,
                icon: const Icon(Icons.add),
                label: const Text('Add stop'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: const Text('Save route'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
