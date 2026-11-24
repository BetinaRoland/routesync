import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:material_ui/material_ui.dart';
import '../../core/api.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

final _fs = FirebaseFirestore.instance;

// ---------------- Bus health ----------------
class BusHealthPage extends StatelessWidget {
  const BusHealthPage({super.key});

  // Spec statuses: Active, Offline, Delayed, Under Maintenance, Tracking Problem.
  (String, Color) _status(Map<String, dynamic> b, Map? loc) {
    if (b['maintenanceStatus'] != 'ok')
      return ('Under maintenance', Colors.blueGrey);
    if (b['trackingStatus'] == 'tracking_problem')
      return ('Tracking problem', Colors.red);
    final age = loc == null
        ? null
        : DateTime.now()
              .difference(
                DateTime.fromMillisecondsSinceEpoch((loc['ts'] as num).toInt()),
              )
              .inSeconds;
    if (age == null || age > 120) return ('Offline', Colors.orange);
    if (b['scheduleStatus'] == 'delayed')
      return ('Delayed', Colors.amber.shade800);
    return ('Active', Colors.green);
  }

  @override
  Widget build(
    BuildContext context,
  ) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
    stream: _fs.collection('buses').orderBy('busNumber').snapshots(),
    builder: (context, bs) => StreamBuilder<DatabaseEvent>(
      stream: FirebaseDatabase.instance.ref('liveLocations').onValue,
      builder: (context, ls) {
        if (bs.hasError)
          return Center(child: Text('Could not load buses.\n${bs.error}'));
        if (!bs.hasData) return loading();
        if (bs.data!.docs.isEmpty)
          return const Center(child: Text('No buses yet.'));
        final raw = ls.data?.snapshot.value;
        final live = raw is Map ? raw : <dynamic, dynamic>{};
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            for (final d in bs.data!.docs)
              Builder(
                builder: (_) {
                  final b = d.data(), loc = live[b['busId']] as Map?;
                  final (label, color) = _status(b, loc);
                  final t = loc == null
                      ? null
                      : DateTime.fromMillisecondsSinceEpoch(
                          (loc['ts'] as num).toInt(),
                        );
                  return Card(
                    child: ListTile(
                      leading: Icon(
                        Icons.directions_bus,
                        color: color,
                        size: 32,
                      ),
                      title: Text('Bus ${b['busNumber']}'),
                      subtitle: Text(
                        [
                          if (t != null)
                            'Last update ${t.toLocal().toString().substring(11, 19)}'
                          else
                            'No location received',
                          if (loc?['speed'] != null)
                            '${((loc!['speed'] as num) * 3.6).round()} km/h',
                          if (loc?['accuracy'] != null)
                            'accuracy ${(loc!['accuracy'] as num).round()} m',
                          b['driverId'] == null
                              ? 'No driver'
                              : 'Driver assigned',
                        ].join('   '),
                      ),
                      trailing: chip(label, color),
                    ),
                  );
                },
              ),
          ],
        );
      },
    ),
  );
}

// ---------------- Staff accounts (Super Admin) ----------------
class StaffPage extends StatelessWidget {
  const StaffPage({super.key});

  Future<void> _add(BuildContext context) async {
    final r = await formDialog(context, 'Add staff account', const [
      F('name', 'Full name'),
      F('email', 'Email'),
      F(
        'role',
        'Role',
        initial: 'routeAdmin',
        choices: {'routeAdmin': 'Route Admin', 'superAdmin': 'Super Admin'},
      ),
    ], action: 'Create');
    if (r == null || !context.mounted) return;
    await runAction(context, () async {
      await Api.call('createStaff', {
        'name': r['name'],
        'email': r['email'],
        'role': r['role'],
      });
      return 'Account created. A password setup email was sent to ${r['email']}.';
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton(
      onPressed: () => _add(context),
      child: const Icon(Icons.person_add),
    ),
    body: DocList(
      query: _fs
          .collection('users')
          .where('role', whereIn: ['superAdmin', 'routeAdmin']),
      empty: 'No staff accounts yet. Add one with the + button.',
      itemBuilder: (c, d) {
        final s = d.data(), active = s['status'] == 'active';
        return ListTile(
          leading: Icon(
            s['role'] == 'superAdmin'
                ? Icons.admin_panel_settings
                : Icons.manage_accounts,
            color: active ? navy : Colors.grey,
          ),
          title: Text('${s['name']}'),
          subtitle: Text('${s['email']}'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              chip(s['role'] == 'superAdmin' ? 'Super Admin' : 'Route Admin'),
              Switch(
                value: active,
                onChanged: (v) => runAction(c, () async {
                  await Api.call('setAccountDisabled', {
                    'uid': d.id,
                    'disabled': !v,
                  });
                  return v ? 'Account enabled.' : 'Account disabled.';
                }),
              ),
            ],
          ),
        );
      },
    ),
  );
}

// ---------------- Tracking hours (Route Admin, inside the Super Admin window) ----------------
class HoursPage extends StatefulWidget {
  const HoursPage({super.key});
  @override
  State<HoursPage> createState() => _HoursPageState();
}

class _HoursPageState extends State<HoursPage> {
  final _s = TextEditingController(), _e = TextEditingController();
  String _limit = '';
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    () async {
      final g = (await _fs.doc('config/app').get()).data() ?? {};
      final o = (await _fs.doc('config/operations').get()).data() ?? {};
      final gs = '${g['trackingStart'] ?? '06:00'}',
          ge = '${g['trackingEnd'] ?? '20:00'}';
      _limit = '$gs to $ge';
      _s.text = '${o['trackingStart'] ?? gs}';
      _e.text = '${o['trackingEnd'] ?? ge}';
      if (mounted) setState(() => _ready = true);
    }();
  }

  @override
  Widget build(BuildContext context) => !_ready
      ? loading()
      : ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'The college allows tracking between $_limit. You can narrow that window for daily operations. Outside it, buses are not treated as live and no GPS alerts are raised.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _s,
              decoration: const InputDecoration(
                labelText: 'Tracking starts (HH:MM)',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _e,
              decoration: const InputDecoration(
                labelText: 'Tracking ends (HH:MM)',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => runAction(context, () async {
                await Api.call('setOperationalHours', {
                  'start': _s.text.trim(),
                  'end': _e.text.trim(),
                });
                return 'Tracking hours saved.';
              }),
              child: const Text('Save hours'),
            ),
          ],
        );
}
