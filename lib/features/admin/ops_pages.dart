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
import '../../core/components.dart';
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
                    ? toneColor(context, Tone.success)
                    : (a['severity'] == 'high'
                          ? toneColor(context, Tone.danger)
                          : toneColor(context, Tone.warning)),
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
        )) {
      return;
    }
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
                    style: TextStyle(color: toneColor(context, Tone.danger)),
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
        !mounted) {
      return;
    }
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
        LayoutBuilder(
          builder: (context, box) => TabBar(
            isScrollable: box.maxWidth < 640,
            tabs: const [
              Tab(text: 'Replace a bus'),
              Tab(text: 'Change route'),
              Tab(text: 'Replace driver'),
              Tab(text: 'Recent actions'),
            ],
          ),
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
                          ? toneColor(context, Tone.danger)
                          : (open
                                ? toneColor(context, Tone.warning)
                                : toneColor(context, Tone.neutral)),
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
      if (s.hasError) {
        return Center(child: Text('Could not build the report.\n${s.error}'));
      }
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
                  style: TextStyle(color: toneColor(context, Tone.warning)),
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
class SchedulesPage extends StatefulWidget {
  const SchedulesPage({super.key});
  @override
  State<SchedulesPage> createState() => _SchedulesPageState();
}

class _SchedulesPageState extends State<SchedulesPage> {
  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  static const _full = {
    'Mon': 'Monday',
    'Tue': 'Tuesday',
    'Wed': 'Wednesday',
    'Thu': 'Thursday',
    'Fri': 'Friday',
    'Sat': 'Saturday',
  };
  late String _day;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now().weekday; // Monday is 1, Sunday is 7
    _day = _days[today > 6 ? 0 : today - 1];
  }

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
      if (days.isEmpty || days.any((d) => !valid.contains(d))) {
        throw 'Use day names like Mon, Tue, Wed.';
      }
      final date = RegExp(r'^\d{4}-\d{2}-\d{2}$');
      final hol = _csv(r['holidays']!), spec = _csv(r['special']!);
      if ([...hol, ...spec].any((x) => !date.hasMatch(x))) {
        throw 'Enter dates as YYYY-MM-DD.';
      }
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

  String _group(Map<String, dynamic> s) {
    String v(Object? x) => (x as String?)?.isEmpty ?? true ? 'all' : '$x';
    return 'Year ${v(s['academicYear'])}, dept ${v(s['departmentId'])}';
  }

  bool _runs(Map<String, dynamic> s) =>
      ((s['workingDays'] as List?) ?? const []).contains(_day);

  /// Horizontal day tabs. Each shows how many schedules run that day.
  Widget _dayTabs(List<Doc> docs) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Row(
      children: [
        for (final d in _days)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              showCheckmark: false,
              labelPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 6,
              ),
              label: Text(
                '${_full[d]}'
                '${docs.isEmpty ? '' : '  ${docs.where((x) => ((x.data()['workingDays'] as List?) ?? const []).contains(d)).length}'}',
              ),
              selected: _day == d,
              onSelected: (_) => setState(() => _day = d),
            ),
          ),
      ],
    ),
  );

  Widget _scheduleCard(BuildContext c, Doc d) {
    final s = d.data();
    final runs = _runs(s);
    final scheme = Theme.of(c).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: RsCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              foregroundColor: scheme.onPrimaryContainer,
              child: const Icon(Icons.calendar_month),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _group(s),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Working days: ${((s['workingDays'] as List?) ?? const []).join(', ')}',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  Text(
                    'Holidays: ${((s['holidayDates'] as List?) ?? const []).length}   Special days: ${((s['specialWorkingDates'] as List?) ?? const []).length}',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  runs
                      ? statusPill(
                          c,
                          Tone.success,
                          'Working day',
                          icon: Icons.directions_bus_outlined,
                        )
                      : statusPill(
                          c,
                          Tone.neutral,
                          'Not a working day',
                          icon: Icons.event_busy_outlined,
                        ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Delete schedule',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (await confirm(
                  c,
                  'Delete this schedule?',
                  'Students it covered fall back to any other matching schedule.',
                  action: 'Delete',
                )) {
                  await d.reference.delete();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Holidays and special working dates that fall on the selected weekday.
  Widget _dateCard(BuildContext c, List<Doc> docs) {
    final wd = _days.indexOf(_day) + 1;
    final rows = <(String, bool, String)>[];
    for (final d in docs) {
      final s = d.data();
      final g = _group(s);
      for (final x in (s['holidayDates'] as List?) ?? const []) {
        if (DateTime.tryParse('$x')?.weekday == wd) rows.add(('$x', true, g));
      }
      for (final x in (s['specialWorkingDates'] as List?) ?? const []) {
        if (DateTime.tryParse('$x')?.weekday == wd) rows.add(('$x', false, g));
      }
    }
    rows.sort((a, b) => a.$1.compareTo(b.$1));
    return SectionCard(
      title: 'Holidays and special days on a ${_full[_day]}',
      icon: Icons.event_note_outlined,
      bodyPadding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: rows.isEmpty
          ? Text(
              'None recorded.',
              style: TextStyle(color: Theme.of(c).colorScheme.onSurfaceVariant),
            )
          : Column(
              children: [
                for (final r in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(child: Text('${r.$1}  -  ${r.$3}')),
                        statusPill(
                          c,
                          r.$2 ? Tone.warning : Tone.info,
                          r.$2 ? 'Holiday' : 'Special working day',
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _dayBody(BuildContext c, List<Doc> docs) {
    if (docs.isEmpty) {
      return const EmptyState(
        'No schedules yet. With none set, every day counts as a working day.',
        icon: Icons.calendar_month_outlined,
      );
    }
    final running = docs.where((d) => _runs(d.data())).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        PageHeader(
          title: '${_full[_day]}',
          subtitle:
              '$running of ${docs.length} schedules run on this day'
              '${running == docs.length ? '' : ', ${docs.length - running} do not'}.',
          showBus: false,
        ),
        const SizedBox(height: 16),
        for (final d in docs) _scheduleCard(c, d),
        const SizedBox(height: 6),
        _dateCard(c, docs),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => _add(context),
      icon: const Icon(Icons.add),
      label: const Text('Add schedule'),
    ),
    body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _fs.collection('collegeSchedules').snapshots(),
      builder: (context, s) {
        if (s.hasError) return const ErrorState('Could not load schedules.');
        if (!s.hasData) return loading();
        final docs = s.data!.docs;
        final reduce = MediaQuery.of(context).disableAnimations;
        return Column(
          children: [
            _dayTabs(docs),
            Expanded(
              child: AnimatedSwitcher(
                duration: reduce ? Duration.zero : const Duration(milliseconds: 200),
                child: KeyedSubtree(
                  key: ValueKey(_day),
                  child: _dayBody(context, docs),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}
