import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:material_ui/material_ui.dart';
import '../../core/widgets.dart';

final _fs = FirebaseFirestore.instance;

// ---------------- Fee policy ----------------
class FeePolicyPage extends StatelessWidget {
  const FeePolicyPage({super.key});

  Future<void> _add(BuildContext context) async {
    final r = await formDialog(context, 'New fee policy', const [
      F('year', 'Academic session', initial: '2026-27'),
      F(
        'method',
        'Method',
        initial: 'perKm',
        choices: {'perKm': 'Rate per km', 'slabs': 'Distance slabs'},
      ),
      F('rate', 'Rate per km (Rs)', number: true),
      F(
        'slabs',
        'Slabs as maxKm:amount, e.g. 10:8000, 25:14000',
        multiline: true,
      ),
      F('from', 'Effective from (YYYY-MM-DD)'),
      F('to', 'Effective to (blank = open ended)'),
    ], action: 'Create');
    if (r == null || !context.mounted) return;
    await runAction(context, () async {
      final from = DateTime.tryParse(r['from']!);
      final to = r['to']!.isEmpty ? null : DateTime.tryParse(r['to']!);
      if (from == null || (r['to']!.isNotEmpty && to == null)) {
        throw 'Enter dates as YYYY-MM-DD.';
      }
      final slabs = <Map<String, num>>[];
      if (r['method'] == 'slabs') {
        for (final part
            in r['slabs']!.split(',').where((p) => p.trim().isNotEmpty)) {
          final kv = part.split(':');
          final km = kv.length == 2 ? num.tryParse(kv[0].trim()) : null,
              amt = kv.length == 2 ? num.tryParse(kv[1].trim()) : null;
          if (km == null || amt == null) {
            throw 'Slabs must look like 10:8000, 25:14000.';
          }
          slabs.add({'maxKm': km, 'amount': amt});
        }
        if (slabs.isEmpty) throw 'Add at least one slab.';
      } else if ((double.tryParse(r['rate']!) ?? 0) <= 0) {
        throw 'Enter a rate per km above zero.';
      }
      final existing = await _fs
          .collection('feePolicies')
          .where('academicYear', isEqualTo: r['year'])
          .get();
      final version =
          existing.docs.fold<int>(
            0,
            (m, d) => ((d.data()['version'] as num?)?.toInt() ?? 0) > m
                ? (d.data()['version'] as num).toInt()
                : m,
          ) +
          1;
      final ref = _fs.collection('feePolicies').doc();
      await ref.set({
        'policyId': ref.id,
        'academicYear': r['year'],
        'calculationMethod': r['method'],
        'ratePerKm': double.tryParse(r['rate']!) ?? 0,
        'distanceSlabs': slabs,
        'effectiveFrom': Timestamp.fromDate(from),
        'effectiveTo': to == null ? null : Timestamp.fromDate(to),
        'version': version,
        'updatedBy': FirebaseAuth.instance.currentUser!.uid,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return 'Policy version $version created. It applies to fees calculated from now on.';
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton(
      onPressed: () => _add(context),
      child: const Icon(Icons.add),
    ),
    body: DocList(
      query: _fs
          .collection('feePolicies')
          .orderBy('effectiveFrom', descending: true),
      empty:
          'No fee policy yet. Students cannot be charged until one is active.',
      itemBuilder: (c, d) {
        final p = d.data();
        final slabs = (p['distanceSlabs'] as List?) ?? [];
        return ListTile(
          leading: const Icon(Icons.payments),
          title: Text('${p['academicYear']}, version ${p['version']}'),
          subtitle: Text(
            p['calculationMethod'] == 'slabs'
                ? slabs
                      .map((s) => 'up to ${s['maxKm']} km: Rs ${s['amount']}')
                      .join('\n')
                : 'Rs ${p['ratePerKm']} per km (annual)',
          ),
          trailing: Text(
            '${fmt(p['effectiveFrom'])}\nto ${p['effectiveTo'] == null ? 'open' : fmt(p['effectiveTo'])}',
            style: const TextStyle(fontSize: 11),
          ),
        );
      },
    ),
  );
}

// ---------------- System settings ----------------
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _app = {
    'academicYear': ['Academic session', '2026-27'],
    'timezone': ['Time zone', 'Asia/Kolkata'],
    'trackingStart': ['Tracking starts (HH:MM)', '06:00'],
    'trackingEnd': ['Tracking ends (HH:MM)', '20:00'],
    'gpsStaleSeconds': ['GPS failure alert after (seconds)', '120'],
    'deviationMeters': ['Route deviation distance (metres)', '300'],
    'deviationUpdates': ['Deviation updates before alert', '3'],
    'historyIntervalSec': ['History sample every (seconds)', '15'],
    'historyRetentionDays': ['Keep location history (days)', '30'],
    'approachMeters': ['"Bus is nearby" notice distance (metres)', '1200'],
    'delayGraceMinutes': ['Delay grace after due time (minutes)', '10'],
    'delayWindowMinutes': ['Delay alert window (minutes)', '90'],
    'webBaseUrl': ['App web address for invitation links (https://...)', ''],
  };
  final Map<String, TextEditingController> _c = {};
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    for (final k in [
      'collegeName',
      'collegeLat',
      'collegeLng',
      'boardingChangeEmail',
      ..._app.keys,
    ]) {
      _c[k] = TextEditingController();
    }
    _load();
  }

  Future<void> _load() async {
    final col = (await _fs.doc('config/college').get()).data() ?? {};
    final app = (await _fs.doc('config/app').get()).data() ?? {};
    _c['collegeName']!.text = '${col['name'] ?? ''}';
    _c['collegeLat']!.text = '${col['lat'] ?? ''}';
    _c['collegeLng']!.text = '${col['lng'] ?? ''}';
    _c['boardingChangeEmail']!.text = '${col['boardingChangeEmail'] ?? ''}';
    for (final e in _app.entries) {
      _c[e.key]!.text = '${app[e.key] ?? e.value[1]}';
    }
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _save() => runAction(context, () async {
    final lat = double.tryParse(_c['collegeLat']!.text),
        lng = double.tryParse(_c['collegeLng']!.text);
    if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180) {
      throw 'Enter the college latitude and longitude.';
    }
    final hhmm = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
    for (final k in ['trackingStart', 'trackingEnd']) {
      if (!hhmm.hasMatch(_c[k]!.text.trim())) {
        throw 'Use 24-hour times like 06:00.';
      }
    }
    final url = _c['webBaseUrl']!.text.trim();
    if (url.isNotEmpty &&
        !url.startsWith('https://') &&
        !url.startsWith('http://localhost')) {
      throw 'The app web address must start with https://.';
    }
    int n(String k) {
      final v = int.tryParse(_c[k]!.text.trim());
      if (v == null || v <= 0) {
        throw '${_app[k]![0]} must be a number above zero.';
      }
      return v;
    }

    await _fs.doc('config/college').set({
      'name': _c['collegeName']!.text.trim(),
      'lat': lat,
      'lng': lng,
      'boardingChangeEmail': _c['boardingChangeEmail']!.text.trim(),
    });
    await _fs.doc('config/app').set({
      'academicYear': _c['academicYear']!.text.trim(),
      'timezone': _c['timezone']!.text.trim(),
      'trackingStart': _c['trackingStart']!.text.trim(),
      'trackingEnd': _c['trackingEnd']!.text.trim(),
      'gpsStaleSeconds': n('gpsStaleSeconds'),
      'deviationMeters': n('deviationMeters'),
      'deviationUpdates': n('deviationUpdates'),
      'historyIntervalSec': n('historyIntervalSec'),
      'historyRetentionDays': n('historyRetentionDays'),
      'approachMeters': n('approachMeters'),
      'delayGraceMinutes': n('delayGraceMinutes'),
      'delayWindowMinutes': n('delayWindowMinutes'),
      'webBaseUrl': url,
    }, SetOptions(merge: true));
    return 'Settings saved.';
  });

  Widget _f(String k, String label, {bool number = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: _c[k],
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      decoration: InputDecoration(labelText: label),
    ),
  );

  @override
  Widget build(BuildContext context) => !_ready
      ? loading()
      : ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'College',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            _f('collegeName', 'College name'),
            _f('collegeLat', 'Latitude', number: true),
            _f('collegeLng', 'Longitude', number: true),
            _f('boardingChangeEmail', 'Boarding-point change request email'),
            const SizedBox(height: 8),
            const Text(
              'Tracking and alerts',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            for (final e in _app.entries) _f(e.key, e.value[0]),
            FilledButton(onPressed: _save, child: const Text('Save settings')),
          ],
        );
}

// ---------------- Audit log ----------------
class AuditPage extends StatefulWidget {
  const AuditPage({super.key});
  @override
  State<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends State<AuditPage> {
  String _role = 'all';

  @override
  Widget build(BuildContext context) {
    Query<Map<String, dynamic>> q = _fs.collection('auditLogs');
    if (_role != 'all') q = q.where('actorRole', isEqualTo: _role);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: DropdownButtonFormField<String>(
            initialValue: _role,
            decoration: const InputDecoration(labelText: 'Show activity by'),
            items: const [
              DropdownMenuItem(value: 'all', child: Text('Everyone')),
              DropdownMenuItem(
                value: 'routeAdmin',
                child: Text('Route Admins'),
              ),
              DropdownMenuItem(
                value: 'superAdmin',
                child: Text('Super Admins'),
              ),
              DropdownMenuItem(value: 'student', child: Text('Students')),
              DropdownMenuItem(value: 'system', child: Text('System')),
            ],
            onChanged: (v) => setState(() => _role = v ?? 'all'),
          ),
        ),
        Expanded(
          child: DocList(
            key: ValueKey(_role),
            query: q.orderBy('timestamp', descending: true).limit(150),
            empty: 'No activity recorded yet.',
            itemBuilder: (c, d) {
              final a = d.data();
              return ListTile(
                dense: true,
                title: Text('${a['action']}  on ${a['affectedRecord']}'),
                subtitle: Text(
                  '${a['actorRole']} ${a['actorId']}   ${fmt(a['timestamp'])}${a['reason'] != null ? '\nReason: ${a['reason']}' : ''}',
                ),
                isThreeLine: a['reason'] != null,
              );
            },
          ),
        ),
      ],
    );
  }
}
