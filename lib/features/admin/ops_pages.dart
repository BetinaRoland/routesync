import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:firebase_database/firebase_database.dart';
import '../../core/api.dart';
import '../../services/common.dart' show dateKey, resolveAlert;
import '../../core/pdf_export.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'emergency_tabs.dart';

final _fs = FirebaseFirestore.instance;

// ---------------- Alerts ----------------

class AlertsPage extends StatefulWidget {
  const AlertsPage({super.key});
  @override
  State<AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends State<AlertsPage> {
  bool _open = true;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ChoiceChip(
              label: const Text('Open'),
              selected: _open,
              onSelected: (_) => setState(() => _open = true),
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('Resolved history'),
              selected: !_open,
              onSelected: (_) => setState(() => _open = false),
            ),
          ],
        ),
      ),
      Expanded(
        child: DocList(
          key: ValueKey(_open),
          query: _open
              ? _fs
                    .collection('alerts')
                    .orderBy('createdAt', descending: true)
                    .limit(100)
              : _fs
                    .collection('alertHistory')
                    .orderBy('resolvedAt', descending: true)
                    .limit(100),
          empty: _open
              ? 'No open alerts. Every bus is reporting normally.'
              : 'No resolved alerts yet.',
          itemBuilder: (c, d) {
            final a = d.data();
            return ListTile(
              leading: Icon(
                _open ? Icons.warning_amber : Icons.check_circle_outline,
                color: !_open
                    ? Colors.green
                    : (a['severity'] == 'high' ? Colors.red : Colors.orange),
              ),
              title: Text(
                '${alertNames[a['alertType']] ?? a['alertType']}: bus ${a['busId']}',
              ),
              subtitle: Text(
                '${a['description']}\nRaised ${fmt(a['createdAt'])}${a['acknowledgedAt'] != null ? '   Acknowledged ${fmt(a['acknowledgedAt'])}' : ''}${a['resolvedAt'] != null ? '   Resolved ${fmt(a['resolvedAt'])}' : ''}',
              ),
              isThreeLine: true,
              trailing: !_open
                  ? null
                  : PopupMenuButton<String>(
                      onSelected: (v) => runAction(c, () async {
                        if (v == 'ack') {
                          await d.reference.update({
                            'acknowledgedAt': FieldValue.serverTimestamp(),
                            'acknowledgedBy':
                                FirebaseAuth.instance.currentUser!.uid,
                          });
                          return 'Acknowledged.';
                        }
                        await resolveAlert(
                          '${a['busId']}',
                          '${a['alertType']}',
                        );
                        return 'Marked resolved.';
                      }),
                      itemBuilder: (_) => [
                        if (a['acknowledgedAt'] == null)
                          const PopupMenuItem(
                            value: 'ack',
                            child: Text('Acknowledge'),
                          ),
                        const PopupMenuItem(
                          value: 'resolve',
                          child: Text('Mark resolved'),
                        ),
                      ],
                    ),
            );
          },
        ),
      ),
    ],
  );
}

// ---------------- Allocation ----------------
class AllocationPage extends StatefulWidget {
  const AllocationPage({super.key});
  @override
  State<AllocationPage> createState() => _AllocationPageState();
}

class _AllocationPageState extends State<AllocationPage> {
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    await runAction(context, () async {
      final r = await Api.call('proposeAllocation', {});
      final s = asMap(r['summary']);
      return 'Proposal ready: ${s['assigned']} of ${s['eligible']} students placed. Review it below.';
    });
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _rebalance() async {
    setState(() => _busy = true);
    await runAction(context, () async {
      final r = await Api.call('proposeRebalance', {});
      if (r['requestId'] == null) return '${r['message']}';
      final s = asMap(r['summary']);
      return 'Proposal ready: ${s['assigned']} riders move so bus ${(s['busesFreed'] as List).join(', ')} can be freed.';
    });
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _decide(Doc d, bool approve) async {
    if (approve &&
        !await confirm(
          context,
          'Approve this allocation?',
          'The system re-checks capacity and availability, then publishes it to students and drivers.',
          action: 'Approve',
        ))
      return;
    if (!mounted) return;
    setState(() => _busy = true);
    await runAction(context, () async {
      final r = await Api.call('reviewChangeRequest', {
        'requestId': d.id,
        'approve': approve,
      });
      return approve
          ? 'Applied ${r['applied']} allocations${(r['skipped'] as num) > 0 ? ', ${r['skipped']} skipped because their records changed' : ''}.'
          : 'Proposal rejected.';
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : _run,
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('Allocate'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _rebalance,
                icon: const Icon(Icons.compress),
                label: const Text('Free up buses'),
              ),
            ),
          ],
        ),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          'Paid students with an approved stop are placed on existing buses first. Nothing changes until you approve.',
        ),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: DocList(
          query: _fs
              .collection('changeRequests')
              .orderBy('createdAt', descending: true)
              .limit(20),
          empty: 'No proposals yet.',
          itemBuilder: (c, d) {
            final cr = d.data(),
                s = asMap(cr['summary']),
                pending = cr['status'] == 'pending';
            final changes = asList(cr['proposedChanges']),
                un = asList(cr['unallocated']);
            return ExpansionTile(
              title: Text('${cr['requestDescription']}'),
              subtitle: Wrap(
                children: [
                  chip(
                    '${cr['status']}',
                    pending ? Colors.orange : Colors.blueGrey,
                  ),
                  chip('${s['assigned']} placed'),
                  if ((s['unallocated'] as num? ?? 0) > 0)
                    chip('${s['unallocated']} not placed', Colors.red),
                  chip(fmt(cr['createdAt'])),
                ],
              ),
              childrenPadding: const EdgeInsets.symmetric(horizontal: 16),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cr['type'] == 'rebalance'
                      ? 'Buses that can be freed: ${(s['busesFreed'] as List?)?.join(', ') ?? '-'}. Riders moved: ${s['assigned']}.'
                      : 'Buses used: ${s['busesUsed']}. Idle buses started: ${s['idleBusesStarted']}. Solver: ${s['solver']}.',
                ),
                const SizedBox(height: 6),
                Text('${s['recommendation']}'),
                if (cr['invalidReason'] != null)
                  Text(
                    'Invalidated: ${cr['invalidReason']}',
                    style: const TextStyle(color: Colors.red),
                  ),
                if (un.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Not placed',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  for (final u in un.take(15))
                    Text('${u['name']}: ${u['reason']}'),
                ],
                const SizedBox(height: 8),
                const Text(
                  'Proposed placements',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                for (final x in changes.take(40))
                  Text(
                    '${x['studentName']} ${x['fromBusNumber'] != null ? 'from bus ${x['fromBusNumber']} ' : ''}to bus ${x['busNumber']}',
                  ),
                if (changes.length > 40)
                  Text('and ${changes.length - 40} more'),
                if (pending)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        OutlinedButton(
                          onPressed: _busy ? null : () => _decide(d, false),
                          child: const Text('Reject'),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: _busy ? null : () => _decide(d, true),
                          child: const Text('Approve'),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ],
  );
}

// ---------------- Emergency ----------------
class EmergencyPage extends StatefulWidget {
  const EmergencyPage({super.key});
  @override
  State<EmergencyPage> createState() => _EmergencyPageState();
}

class _EmergencyPageState extends State<EmergencyPage> {
  List<Doc> _buses = [], _drivers = [];
  String? _bus, _repl, _driver;
  final _reason = TextEditingController();
  final _hours = TextEditingController(text: '8');
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _fs.collection('buses').orderBy('busNumber').get().then((s) {
      if (mounted) setState(() => _buses = s.docs);
    });
    _fs.collection('drivers').orderBy('name').get().then((s) {
      if (mounted) setState(() => _drivers = s.docs);
    });
  }

  Future<void> _submit() async {
    if (_bus == null || _repl == null || _reason.text.trim().length < 5) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose both buses and enter a reason.')),
      );
      return;
    }
    if (!await confirm(
          context,
          'Replace this bus now?',
          'Students on the affected bus move to the replacement immediately. This is recorded in the audit log.',
          action: 'Replace bus',
        ) ||
        !mounted)
      return;
    setState(() => _busy = true);
    await runAction(context, () async {
      final r = await Api.call('emergencyReplaceBus', {
        'busId': _bus,
        'replacementBusId': _repl,
        'replacementDriverId': _driver,
        'reason': _reason.text.trim(),
        'hours': int.tryParse(_hours.text) ?? 8,
      });
      _reason.clear();
      return 'Done. ${r['moved']} students moved to the replacement bus.';
    });
    if (mounted) setState(() => _busy = false);
  }

  Widget _drop(
    String label,
    String? value,
    List<Doc> docs,
    String Function(Doc) text,
    ValueChanged<String?> on, {
    bool optional = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<String>(
      key: ValueKey('$label-$value'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        if (optional)
          const DropdownMenuItem(value: '', child: Text('Keep the bus driver')),
        for (final d in docs)
          DropdownMenuItem(
            value: d.id,
            child: Text(text(d), overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: on,
    ),
  );

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 4,
    child: Column(
      children: [
        const TabBar(
          isScrollable: true,
          labelColor: navy,
          tabs: [
            Tab(text: 'Replace a bus'),
            Tab(text: 'Change route'),
            Tab(text: 'Replace driver'),
            Tab(text: 'Recent actions'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _drop(
                    'Bus that is out of service',
                    _bus,
                    _buses,
                    (d) => 'Bus ${d.data()['busNumber']}',
                    (v) => setState(() {
                      _bus = v;
                      if (_repl == v) _repl = null;
                    }),
                  ),
                  _drop(
                    'Replacement bus',
                    _repl,
                    _buses.where((d) => d.id != _bus).toList(),
                    (d) =>
                        'Bus ${d.data()['busNumber']} (${d.data()['capacity']} seats)',
                    (v) => setState(() => _repl = v),
                  ),
                  _drop(
                    'Replacement driver',
                    _driver,
                    _drivers,
                    (d) => '${d.data()['name']}',
                    (v) => setState(
                      () => _driver = (v == null || v.isEmpty) ? null : v,
                    ),
                    optional: true,
                  ),
                  TextField(
                    controller: _reason,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Reason (required)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _hours,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Review after (hours)',
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: const Text('Replace bus'),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Capacity, route and driver authorisation are still checked. If any check fails, nothing changes.',
                  ),
                ],
              ),
              const RouteChangeTab(),
              const DriverChangeTab(),
              DocList(
                query: _fs
                    .collection('emergencyActions')
                    .orderBy('createdAt', descending: true)
                    .limit(20),
                empty: 'No emergency actions yet.',
                itemBuilder: (c, d) {
                  final e = d.data(),
                      open = [
                        'active',
                        'review_required',
                      ].contains(e['reviewStatus']);
                  return ListTile(
                    title: Text(
                      e['actionType'] == 'route_change'
                          ? 'Temporary route for bus ${e['affectedBusId']}'
                          : e['actionType'] == 'driver_change'
                          ? 'Driver changed on bus ${e['affectedBusId']}'
                          : 'Bus ${e['affectedBusId']} replaced by ${e['replacementBusId']}',
                    ),
                    subtitle: Text(
                      '${e['reason']}\n${fmt(e['createdAt'])}   expires ${fmt(e['expiresAt'])}',
                    ),
                    isThreeLine: true,
                    leading: Icon(
                      Icons.emergency,
                      color: e['reviewStatus'] == 'review_required'
                          ? Colors.red
                          : (open ? Colors.orange : Colors.grey),
                    ),
                    trailing: open
                        ? PopupMenuButton<String>(
                            onSelected: (v) => runAction(c, () async {
                              await Api.call('reviewEmergency', {
                                'emergencyId': d.id,
                                'action': v == 'keep' ? 'keep' : 'revert',
                                'restoreBus': v == 'revert_restore',
                              });
                              return v == 'keep'
                                  ? 'Change confirmed.'
                                  : 'Change reverted.';
                            }),
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'keep',
                                child: Text('Keep this change'),
                              ),
                              PopupMenuItem(
                                value: 'revert',
                                child: Text('Revert'),
                              ),
                              PopupMenuItem(
                                value: 'revert_restore',
                                child: Text('Revert and return bus to service'),
                              ),
                            ],
                          )
                        : chip('${e['reviewStatus']}'),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

// ---------------- Location history ----------------
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<Doc> _buses = [];
  String? _bus;
  DateTime _day = DateTime.now();
  List<LatLng> _pts = [];
  String? _summary;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _fs.collection('buses').orderBy('busNumber').get().then((s) {
      if (mounted) setState(() => _buses = s.docs);
    });
  }

  Future<void> _pickDay() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (d != null) setState(() => _day = d);
  }

  Future<void> _load() async {
    if (_bus == null) return;
    setState(() => _busy = true);
    await runAction(context, () async {
      final snap = await FirebaseDatabase.instance
          .ref('history/$_bus/${dateKey(_day)}')
          .get();
      final v = snap.value, pts = <LatLng>[];
      var gaps = 0;
      int? prev, first, last;
      if (v is Map) {
        final keys = v.keys.map((k) => int.parse('$k')).toList()..sort();
        for (final k in keys) {
          final p = v['$k'] as Map;
          pts.add(
            LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()),
          );
          if (prev != null && k - prev >= 120000) gaps++;
          prev = k;
        }
        if (keys.isNotEmpty) {
          first = keys.first;
          last = keys.last;
        }
      }
      _pts = pts;
      _summary = pts.isEmpty
          ? 'No tracking data for this day.'
          : '${pts.length} points, ${fmt(DateTime.fromMillisecondsSinceEpoch(first!))} to ${fmt(DateTime.fromMillisecondsSinceEpoch(last!))}, $gaps tracking interruptions of 2 min or more.';
      return null;
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _bus,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Bus'),
                items: [
                  for (final d in _buses)
                    DropdownMenuItem(
                      value: d.id,
                      child: Text('Bus ${d.data()['busNumber']}'),
                    ),
                ],
                onChanged: (v) => setState(() => _bus = v),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _pickDay,
              child: Text('${_day.day}/${_day.month}/${_day.year}'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _busy ? null : _load,
              child: const Text('Show'),
            ),
          ],
        ),
      ),
      if (_summary != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(_summary!),
        ),
      Expanded(
        child: _pts.isEmpty
            ? const SizedBox.shrink()
            : FlutterMap(
                options: MapOptions(
                  initialCenter: _pts[_pts.length ~/ 2],
                  initialZoom: 12,
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.example.routesync',
                  ),
                  PolylineLayer(
                    polylines: [
                      Polyline(points: _pts, strokeWidth: 4, color: navy),
                    ],
                  ),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: _pts.first,
                        width: 36,
                        height: 36,
                        child: const Icon(Icons.flag, color: Colors.green),
                      ),
                      Marker(
                        point: _pts.last,
                        width: 36,
                        height: 36,
                        child: const Icon(Icons.flag, color: Colors.red),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    ],
  );
}

// ---------------- Reports ----------------
class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key});
  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  late Future<List<QuerySnapshot<Map<String, dynamic>>>> _f;
  @override
  void initState() {
    super.initState();
    _f = _loadAll();
  }

  Future<List<QuerySnapshot<Map<String, dynamic>>>> _loadAll() => Future.wait([
    _fs.collection('students').get(),
    _fs.collection('buses').get(),
    _fs.collection('allocations').where('status', isEqualTo: 'active').get(),
  ]);

  @override
  Widget build(
    BuildContext context,
  ) => FutureBuilder<List<QuerySnapshot<Map<String, dynamic>>>>(
    future: _f,
    builder: (context, s) {
      if (s.hasError)
        return Center(child: Text('Could not build the report.\n${s.error}'));
      if (!s.hasData) return loading();
      final students = s.data![0].docs.map((d) => d.data()).toList();
      final buses = s.data![1].docs.map((d) => d.data()).toList();
      final allocs = s.data![2].docs.map((d) => d.data()).toList();
      final perBus = <String, int>{};
      for (final a in allocs) {
        perBus['${a['busId']}'] = (perBus['${a['busId']}'] ?? 0) + 1;
      }
      final dept = <String, List<int>>{}; // total, stop chosen, allocated
      for (final x in students) {
        final r = dept.putIfAbsent('${x['departmentId']}', () => [0, 0, 0]);
        r[0]++;
        if (x['approvedBoardingPointId'] != null) r[1]++;
        if (x['allocationId'] != null) r[2]++;
      }
      final paid = students
          .where((x) => x['approvedBoardingPointId'] != null)
          .length;
      final waiting = students
          .where(
            (x) =>
                x['authUid'] != null &&
                x['approvedBoardingPointId'] != null &&
                x['allocationId'] == null,
          )
          .length;
      final low = buses
          .where(
            (b) =>
                b['availability'] == true &&
                (perBus['${b['busId']}'] ?? 0) > 0 &&
                (perBus['${b['busId']}'] ?? 0) / (b['capacity'] as num) < 0.5,
          )
          .toList();
      return RefreshIndicator(
        onRefresh: () async {
          setState(() => _f = _loadAll());
          await _f;
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => exportPdf('RouteSync summary', [
                  PdfSection(
                    'Students',
                    ['Measure', 'Count'],
                    [
                      ['Students', '${students.length}'],
                      [
                        'Registered',
                        '${students.where((x) => x['authUid'] != null).length}',
                      ],
                      ['Stop chosen', '$paid'],
                      ['On a bus', '${allocs.length}'],
                      ['Ready, no bus', '$waiting'],
                    ],
                  ),
                  PdfSection(
                    'Bus occupancy',
                    ['Bus', 'Allocated', 'Seats'],
                    [
                      for (final b in buses)
                        [
                          '${b['busNumber']}',
                          '${perBus['${b['busId']}'] ?? 0}',
                          '${b['capacity']}',
                        ],
                    ],
                  ),
                  PdfSection(
                    'By department',
                    ['Department', 'Students', 'Stop chosen', 'On bus'],
                    [
                      for (final e in dept.entries)
                        [
                          e.key,
                          '${e.value[0]}',
                          '${e.value[1]}',
                          '${e.value[2]}',
                        ],
                    ],
                  ),
                ]),
                icon: const Icon(Icons.picture_as_pdf),
                label: const Text('PDF'),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _stat('Students', '${students.length}'),
                _stat(
                  'Registered',
                  '${students.where((x) => x['authUid'] != null).length}',
                ),
                _stat('Stop chosen', '$paid'),
                _stat('On a bus', '${allocs.length}'),
                _stat('Ready, no bus', '$waiting'),
              ],
            ),
            const SizedBox(height: 20),
            const Text(
              'Bus occupancy',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            for (final b in buses)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Bus ${b['busNumber']}: ${perBus['${b['busId']}'] ?? 0} of ${b['capacity']} seats',
                    ),
                    LinearProgressIndicator(
                      value:
                          ((perBus['${b['busId']}'] ?? 0) /
                                  (b['capacity'] as num))
                              .clamp(0.0, 1.0)
                              .toDouble(),
                      minHeight: 8,
                    ),
                  ],
                ),
              ),
            if (low.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Under half full: ${low.map((b) => b['busNumber']).join(', ')}. Check whether their riders could share a route.',
                  style: const TextStyle(color: Colors.orange),
                ),
              ),
            const SizedBox(height: 20),
            const Text(
              'By department',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            DataTable(
              columns: const [
                DataColumn(label: Text('Dept')),
                DataColumn(label: Text('Students')),
                DataColumn(label: Text('Stop')),
                DataColumn(label: Text('On bus')),
              ],
              rows: [
                for (final e in dept.entries)
                  DataRow(
                    cells: [
                      DataCell(Text(e.key)),
                      DataCell(Text('${e.value[0]}')),
                      DataCell(Text('${e.value[1]}')),
                      DataCell(Text('${e.value[2]}')),
                    ],
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );

  Widget _stat(String label, String v) => Container(
    width: 150,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      border: Border.all(color: Colors.black12),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          v,
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            color: navy,
          ),
        ),
        Text(label),
      ],
    ),
  );
}

// ---------------- College schedules ----------------
class SchedulesPage extends StatelessWidget {
  const SchedulesPage({super.key});

  List<String> _csv(String s) =>
      s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  Future<void> _add(BuildContext context) async {
    final r = await formDialog(context, 'Add schedule', const [
      F('year', 'Academic year 1-6 (blank = all years)'),
      F('dept', 'Department (blank = all)'),
      F('days', 'Working days', initial: 'Mon,Tue,Wed,Thu,Fri'),
      F('holidays', 'Holidays (YYYY-MM-DD, comma separated)', multiline: true),
      F('special', 'Special working days (YYYY-MM-DD)', multiline: true),
    ]);
    if (r == null || !context.mounted) return;
    await runAction(context, () async {
      const valid = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      final days = _csv(r['days']!)
          .map(
            (d) => d.isEmpty
                ? d
                : d[0].toUpperCase() +
                      d.substring(1, d.length < 3 ? d.length : 3).toLowerCase(),
          )
          .toList();
      if (days.isEmpty || days.any((d) => !valid.contains(d)))
        throw 'Use day names like Mon, Tue, Wed.';
      final date = RegExp(r'^\d{4}-\d{2}-\d{2}$');
      final hol = _csv(r['holidays']!), spec = _csv(r['special']!);
      if ([...hol, ...spec].any((x) => !date.hasMatch(x)))
        throw 'Enter dates as YYYY-MM-DD.';
      await _fs.collection('collegeSchedules').add({
        'academicYear': r['year'],
        'departmentId': r['dept'],
        'workingDays': days,
        'holidayDates': hol,
        'specialWorkingDates': spec,
        'createdAt': FieldValue.serverTimestamp(),
      });
      return 'Schedule saved.';
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton(
      onPressed: () => _add(context),
      child: const Icon(Icons.add),
    ),
    body: DocList(
      query: _fs.collection('collegeSchedules'),
      empty:
          'No schedules yet. With none set, every day counts as a working day.',
      itemBuilder: (c, d) {
        final s = d.data();
        return ListTile(
          leading: const Icon(Icons.calendar_month),
          title: Text(
            'Year ${(s['academicYear'] as String?)?.isEmpty ?? true ? 'all' : s['academicYear']}, dept ${(s['departmentId'] as String?)?.isEmpty ?? true ? 'all' : s['departmentId']}',
          ),
          subtitle: Text(
            '${(s['workingDays'] as List).join(', ')}\nHolidays: ${(s['holidayDates'] as List).length}   Special days: ${(s['specialWorkingDates'] as List).length}',
          ),
          isThreeLine: true,
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (await confirm(
                c,
                'Delete this schedule?',
                'Students it covered fall back to any other matching schedule.',
                action: 'Delete',
              ))
                await d.reference.delete();
            },
          ),
        );
      },
    ),
  );
}
