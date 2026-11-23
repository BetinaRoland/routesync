import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/widgets.dart';

final _fs = FirebaseFirestore.instance;

Widget _drop(String label, String? value, Map<String, String> items, ValueChanged<String?> on) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        key: ValueKey('$label-$value'),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))],
        onChanged: on,
      ),
    );

// ---------------- Temporary route change (road closed, detour) ----------------
class RouteChangeTab extends StatefulWidget {
  const RouteChangeTab({super.key});
  @override
  State<RouteChangeTab> createState() => _RouteChangeTabState();
}

class _RouteChangeTabState extends State<RouteChangeTab> {
  final Map<String, Map<String, dynamic>> _buses = {};
  final Map<String, String> _points = {};
  List<String> _stops = [];
  String? _bus;
  final _reason = TextEditingController();
  final _hours = TextEditingController(text: '8');
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _fs.collection('buses').orderBy('busNumber').get().then((s) { if (mounted) setState(() { for (final d in s.docs) { _buses[d.id] = d.data(); } }); });
    _fs.collection('boardingPoints').get().then((s) { if (mounted) setState(() { for (final d in s.docs) { _points[d.id] = '${d.data()['name']}'; } }); });
  }

  Future<void> _pick(String? id) async {
    setState(() { _bus = id; _stops = []; });
    final routeId = id == null ? null : _buses[id]?['routeId'];
    if (routeId == null) return;
    final r = await _fs.doc('routes/$routeId').get();
    if (mounted) setState(() => _stops = List<String>.from((r.data()?['stopIds'] as List?) ?? []));
  }

  Future<void> _addStop() async {
    final free = {for (final e in _points.entries) if (!_stops.contains(e.key)) e.key: e.value};
    if (free.isEmpty) return;
    final r = await formDialog(context, 'Add a stop', [F('id', 'Boarding point', choices: free)], action: 'Add');
    if (r != null && r['id']!.isNotEmpty) setState(() => _stops.add(r['id']!));
  }

  Future<void> _submit() async {
    if (_bus == null || _stops.isEmpty || _reason.text.trim().length < 5) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Choose a bus, keep at least one stop and enter a reason.')));
      return;
    }
    if (!await confirm(context, 'Change this bus route now?', 'Riders and the driver are told. The change expires after the review time and you will be asked to confirm or revert it.', action: 'Change route') || !mounted) return;
    setState(() => _busy = true);
    await runAction(context, () async {
      final r = await Api.call('emergencyRouteChange', {'busId': _bus, 'stopIds': _stops, 'reason': _reason.text.trim(), 'hours': int.tryParse(_hours.text) ?? 8});
      _reason.clear();
      return 'Temporary route set for ${r['riders']} riders.';
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Use this when a road is closed. Reorder stops or add a detour stop. Stops that have riders must stay.'),
        const SizedBox(height: 12),
        _drop('Bus', _bus, {for (final e in _buses.entries) e.key: 'Bus ${e.value['busNumber']}'}, _pick),
        if (_bus != null) ...[
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            onReorderItem: (a, b) => setState(() => _stops.insert(b, _stops.removeAt(a))),
            children: [
              for (final id in _stops)
                ListTile(key: ValueKey(id), dense: true, leading: const Icon(Icons.drag_handle), title: Text(_points[id] ?? id), trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _stops.remove(id)))),
            ],
          ),
          Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: _addStop, icon: const Icon(Icons.add), label: const Text('Add detour stop'))),
        ],
        TextField(controller: _reason, maxLines: 2, decoration: const InputDecoration(labelText: 'Reason (required)')),
        const SizedBox(height: 12),
        TextField(controller: _hours, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Review after (hours)')),
        const SizedBox(height: 16),
        FilledButton(onPressed: _busy ? null : _submit, child: const Text('Apply temporary route')),
      ]);
}

// ---------------- Driver unavailable ----------------
class DriverChangeTab extends StatefulWidget {
  const DriverChangeTab({super.key});
  @override
  State<DriverChangeTab> createState() => _DriverChangeTabState();
}

class _DriverChangeTabState extends State<DriverChangeTab> {
  final Map<String, String> _buses = {}, _drivers = {};
  String? _bus, _driver;
  final _reason = TextEditingController();
  final _hours = TextEditingController(text: '8');
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _fs.collection('buses').orderBy('busNumber').get().then((s) { if (mounted) setState(() { for (final d in s.docs) { _buses[d.id] = 'Bus ${d.data()['busNumber']}'; } }); });
    _fs.collection('drivers').orderBy('name').get().then((s) {
      if (!mounted) return;
      setState(() {
        for (final d in s.docs) {
          final x = d.data();
          _drivers[d.id] = '${x['name']}${x['assignedBusId'] != null ? ' (on bus ${x['assignedBusId']})' : ''}';
        }
      });
    });
  }

  Future<void> _submit() async {
    if (_bus == null || _driver == null || _reason.text.trim().length < 5) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Choose a bus, a replacement driver and enter a reason.')));
      return;
    }
    if (!await confirm(context, 'Change the driver now?', 'The current driver is taken off this bus. The replacement must be authorised for the region and free.', action: 'Change driver') || !mounted) return;
    setState(() => _busy = true);
    await runAction(context, () async {
      await Api.call('emergencyReplaceDriver', {'busId': _bus, 'driverId': _driver, 'reason': _reason.text.trim(), 'hours': int.tryParse(_hours.text) ?? 8});
      _reason.clear();
      return 'Driver changed. Review it in Recent actions.';
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Use this when the usual driver cannot drive. Riders and the route stay the same.'),
        const SizedBox(height: 12),
        _drop('Bus', _bus, _buses, (v) => setState(() => _bus = v)),
        _drop('Replacement driver', _driver, _drivers, (v) => setState(() => _driver = v)),
        TextField(controller: _reason, maxLines: 2, decoration: const InputDecoration(labelText: 'Reason (required)')),
        const SizedBox(height: 12),
        TextField(controller: _hours, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Review after (hours)')),
        const SizedBox(height: 16),
        FilledButton(onPressed: _busy ? null : _submit, child: const Text('Change driver')),
      ]);
}
