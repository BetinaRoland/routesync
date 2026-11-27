import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:material_ui/material_ui.dart';
import '../../core/components.dart';
import '../../core/logic.dart' as lg;
import '../../core/theme.dart';
import '../../core/widgets.dart';

final _fs = FirebaseFirestore.instance;

// ---------------- Fee policy ----------------
class FeePolicyPage extends StatefulWidget {
  const FeePolicyPage({super.key});
  @override
  State<FeePolicyPage> createState() => _FeePolicyPageState();
}

class _FeePolicyPageState extends State<FeePolicyPage> {
  String? _policyId;
  final _km = TextEditingController();

  @override
  void dispose() {
    _km.dispose();
    super.dispose();
  }

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

  /// Whether a policy applies today, from its own effective dates.
  (Tone, String) _state(Map<String, dynamic> p) {
    final now = DateTime.now();
    final from = (p['effectiveFrom'] as Timestamp?)?.toDate();
    final to = (p['effectiveTo'] as Timestamp?)?.toDate();
    if (from != null && from.isAfter(now)) return (Tone.info, 'Scheduled');
    if (to != null && to.isBefore(now)) return (Tone.neutral, 'Ended');
    return (Tone.success, 'Active');
  }

  String _label(Map<String, dynamic> p) =>
      '${p['academicYear']} v${p['version']}';

  /// Uses the same calculation the app uses when it charges a student.
  Widget _calculator(List<Doc> docs) {
    final scheme = Theme.of(context).colorScheme;
    final chosen = docs.firstWhere(
      (d) => d.id == _policyId,
      orElse: () => docs.firstWhere(
        (d) => _state(d.data()).$2 == 'Active',
        orElse: () => docs.first,
      ),
    );
    final km = double.tryParse(_km.text.trim());
    final fee = (km == null || km < 0)
        ? null
        : lg.computeFee(chosen.data(), km);
    return SectionCard(
      title: 'Fee calculator',
      icon: Icons.calculate_outlined,
      bodyPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Policy', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final d in docs)
                ChoiceChip(
                  label: Text(_label(d.data())),
                  selected: d.id == chosen.id,
                  onSelected: (_) => setState(() => _policyId = d.id),
                ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _km,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Distance (km)',
              prefixIcon: Icon(Icons.route_outlined),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(Rd.control),
            ),
            child: km == null || km < 0
                ? const Text('Enter a distance to see the yearly fee.')
                : fee == null
                ? Text('No slab in this policy covers $km km.')
                : Row(
                    children: [
                      Text(
                        'Rs $fee',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'per year for $km km under ${_label(chosen.data())}',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _policyCard(Doc d) {
    final scheme = Theme.of(context).colorScheme;
    final p = d.data();
    final (tone, state) = _state(p);
    final slabs =
        ((p['distanceSlabs'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList()
          ..sort((a, b) => (a['maxKm'] as num).compareTo(b['maxKm'] as num));
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: RsCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  foregroundColor: scheme.onPrimaryContainer,
                  child: const Icon(Icons.payments_outlined),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${p['academicYear']}, version ${p['version']}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
                statusPill(context, tone, state),
              ],
            ),
            const SizedBox(height: 10),
            if (p['calculationMethod'] == 'slabs')
              Wrap(
                children: [
                  for (final sl in slabs)
                    chip('up to ${sl['maxKm']} km: Rs ${sl['amount']}'),
                ],
              )
            else
              Text('Rs ${p['ratePerKm']} per km (annual)'),
            const SizedBox(height: 8),
            Text(
              'From ${fmt(p['effectiveFrom'])} to ${p['effectiveTo'] == null ? 'open ended' : fmt(p['effectiveTo'])}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => _add(context),
      icon: const Icon(Icons.add),
      label: const Text('New policy'),
    ),
    body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _fs
          .collection('feePolicies')
          .orderBy('effectiveFrom', descending: true)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return const ErrorState('Could not load policies.');
        if (!snap.hasData) return loading();
        final docs = snap.data!.docs;
        if (docs.isEmpty) {
          return const EmptyState(
            'No fee policy yet. Students cannot be charged until one is active.',
            icon: Icons.payments_outlined,
          );
        }
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                _calculator(docs),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text(
                    'Policies',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                for (final d in docs) _policyCard(d),
              ],
            ),
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
  static const _roles = {
    'all': 'Everyone',
    'routeAdmin': 'Route Admins',
    'superAdmin': 'Super Admins',
    'student': 'Students',
    'system': 'System',
  };
  String _role = 'all';
  String _action = 'all';
  String _q = '';
  String? _open;

  IconData _roleIcon(String r) => switch (r) {
    'superAdmin' => Icons.admin_panel_settings_outlined,
    'routeAdmin' => Icons.alt_route,
    'student' => Icons.school_outlined,
    _ => Icons.settings_suggest_outlined,
  };

  String _value(Object? v) => v is Timestamp ? fmt(v) : '$v';

  Widget _event(Doc d) {
    final scheme = Theme.of(context).colorScheme;
    final a = d.data();
    final open = _open == d.id;
    final role = '${a['actorRole']}';
    final keys = a.keys.toList()..sort();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: RsCard(
        selected: open,
        onTap: () => setState(() => _open = open ? null : d.id),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: scheme.primaryContainer,
                  foregroundColor: scheme.onPrimaryContainer,
                  child: Icon(_roleIcon(role), size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${a['action']}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        'on ${a['affectedRecord']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      fmt(a['timestamp']),
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    statusPill(context, Tone.neutral, _roles[role] ?? role),
                  ],
                ),
                Icon(open ? Icons.expand_less : Icons.expand_more),
              ],
            ),
            if (a['reason'] != null && !open)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Reason: ${a['reason']}',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            if (open) ...[
              const Divider(height: 24),
              for (final k in keys)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 130,
                        child: Text(
                          k,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Expanded(child: SelectableText(_value(a[k]))),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Query<Map<String, dynamic>> q = _fs.collection('auditLogs');
    if (_role != 'all') q = q.where('actorRole', isEqualTo: _role);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                children: [
                  TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search action, record, person or reason',
                    ),
                    onChanged: (v) =>
                        setState(() => _q = v.trim().toLowerCase()),
                  ),
                  const SizedBox(height: 10),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final e in _roles.entries)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(e.value),
                              selected: _role == e.key,
                              onSelected: (_) => setState(() {
                                _role = e.key;
                                _action = 'all';
                                _open = null;
                              }),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                key: ValueKey(_role),
                stream: q
                    .orderBy('timestamp', descending: true)
                    .limit(150)
                    .snapshots(),
                builder: (context, snap) {
                  if (snap.hasError) {
                    return const ErrorState('Could not load activity.');
                  }
                  if (!snap.hasData) return loading();
                  final all = snap.data!.docs;
                  final actions = {
                    for (final d in all) '${d.data()['action']}',
                  }.toList()..sort();
                  final docs = all.where((d) {
                    final a = d.data();
                    if (_action != 'all' && '${a['action']}' != _action) {
                      return false;
                    }
                    if (_q.isEmpty) return true;
                    return '${a['action']} ${a['affectedRecord']} ${a['actorId']} ${a['reason']}'
                        .toLowerCase()
                        .contains(_q);
                  }).toList();
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${docs.length} events',
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            PopupMenuButton<String>(
                              tooltip: 'Filter by action',
                              onSelected: (v) => setState(() => _action = v),
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  value: 'all',
                                  child: Text('All actions'),
                                ),
                                for (final x in actions)
                                  PopupMenuItem(value: x, child: Text(x)),
                              ],
                              child: Chip(
                                avatar: const Icon(Icons.filter_list, size: 18),
                                label: Text(
                                  _action == 'all' ? 'All actions' : _action,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: docs.isEmpty
                            ? const EmptyState(
                                'No activity matches. Try another filter.',
                                icon: Icons.manage_search,
                              )
                            : ListView(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  32,
                                ),
                                children: [for (final d in docs) _event(d)],
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
