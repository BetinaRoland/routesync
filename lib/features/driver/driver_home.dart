import 'package:firebase_auth/firebase_auth.dart';
import 'package:material_ui/material_ui.dart';
import '../../core/api.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../notifications_page.dart';
import '../tracker_service.dart';
import '../live_map.dart';

class DriverHome extends StatefulWidget {
  final Session session;
  const DriverHome({super.key, required this.session});
  @override
  State<DriverHome> createState() => _DriverHomeState();
}

const _reportTypes = {
  'breakdown': ('Breakdown', Icons.build_circle_outlined),
  'delay': ('Running late', Icons.schedule),
  'road_blocked': ('Road blocked', Icons.block),
  'accident': ('Accident', Icons.car_crash_outlined),
  'other': ('Something else', Icons.report_problem_outlined),
};

class _DriverHomeState extends State<DriverHome> {
  Map<String, dynamic>? _t;
  Object? _err;
  bool _loading = true;
  TrackerService? _tracker;
  String? _msg;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tracker?.stop();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      await FirebaseAuth.instance.currentUser!.getIdToken(
        true,
      ); // pick up a new bus assignment
      final t = await Api.call('getMyTransport');
      _t = t;
      _err = null;
      final id = t['busId'] as String?;
      if (t['assigned'] == true && id != null && _tracker?.busId != id) {
        await _tracker?.stop();
        _tracker = TrackerService(id);
      }
    } catch (e) {
      _err = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _toggle() async {
    final t = _tracker!;
    if (t.running) {
      await t.stop();
      _msg = null;
    } else {
      _msg = await t.start();
    }
    if (mounted) setState(() {});
  }

  Future<void> _report() async {
    final type = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'What is happening?',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            for (final e in _reportTypes.entries)
              ListTile(
                leading: Icon(e.value.$2),
                title: Text(e.value.$1),
                onTap: () => Navigator.pop(ctx, e.key),
              ),
          ],
        ),
      ),
    );
    if (type == null || !mounted) return;
    final r = await formDialog(context, _reportTypes[type]!.$1, const [
      F('note', 'Details (optional)', multiline: true),
    ], action: 'Send report');
    if (r == null || !mounted) return;
    await runAction(context, () async {
      await Api.call('driverReport', {'type': type, 'note': r['note']});
      return 'Reported. The Route Admin has been alerted.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(
        title: const Text('RouteSync driver'),
        actions: [
          IconButton(
            tooltip: 'Notifications',
            icon: const Icon(Icons.notifications),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => NotificationsPage(
                  standalone: true,
                  audience: 'drivers',
                  busId: _t?['busId'] as String?,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
          PopupMenuButton<String>(
            tooltip: 'Account',
            onSelected: (v) async {
              if (v == 'password') {
                final email = FirebaseAuth.instance.currentUser?.email;
                if (email == null) return;
                final c = context;
                await FirebaseAuth.instance.sendPasswordResetEmail(
                  email: email,
                );
                if (c.mounted) {
                  ScaffoldMessenger.of(c).showSnackBar(
                    SnackBar(
                      content: Text(
                        'A password reset link was sent to $email.',
                      ),
                    ),
                  );
                }
              } else {
                await _tracker?.stop();
                await FirebaseAuth.instance.signOut();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'password', child: Text('Change password')),
              PopupMenuItem(value: 'out', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('$_err'),
              ),
            )
          : t == null || t['assigned'] != true
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No bus is assigned to you yet. Ask the Route Admin, then tap refresh.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: ListTile(
                    leading: const Icon(
                      Icons.directions_bus,
                      color: navy,
                      size: 32,
                    ),
                    title: Text('Bus ${t['busNumber']}'),
                    subtitle: Text(
                      '${t['routeName'] ?? 'No route set'}\n${t['passengers']} of ${t['capacity']} seats allocated',
                    ),
                    isThreeLine: true,
                  ),
                ),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.schedule, color: teal),
                    title: Text(
                      t['workingToday'] == false
                          ? 'No college today'
                          : 'Duty today',
                    ),
                    subtitle: Text(
                      [
                        if (t['arrivalBy'] != null)
                          'Reach the college by ${t['arrivalBy']}',
                        'Tracking window ${t['trackingStart']} to ${t['trackingEnd']}',
                      ].join('\n'),
                    ),
                    isThreeLine: t['arrivalBy'] != null,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ValueListenableBuilder<DateTime?>(
                          valueListenable: _tracker!.lastFix,
                          builder: (_, fix, _) => Row(
                            children: [
                              Icon(
                                Icons.circle,
                                size: 12,
                                color: _tracker!.running
                                    ? (fix == null
                                          ? Colors.orange
                                          : Colors.green)
                                    : Colors.grey,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  !_tracker!.running
                                      ? 'Location sharing is off'
                                      : fix == null
                                      ? 'Waiting for a GPS fix'
                                      : 'Sharing location, last sent ${fix.toLocal().toString().substring(11, 19)}',
                                ),
                              ),
                            ],
                          ),
                        ),
                        ValueListenableBuilder<String?>(
                          valueListenable: _tracker!.error,
                          builder: (_, e, _) => e == null
                              ? const SizedBox.shrink()
                              : Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                    e,
                                    style: const TextStyle(color: Colors.red),
                                  ),
                                ),
                        ),
                        if (_msg != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              _msg!,
                              style: const TextStyle(color: Colors.red),
                            ),
                          ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: _toggle,
                            child: Text(
                              _tracker!.running
                                  ? 'Stop sharing location'
                                  : 'Start sharing location',
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _report,
                            icon: const Icon(Icons.report_problem_outlined),
                            label: const Text('Report a problem'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Keep RouteSync running while you drive. Only the bus position is shared, never passenger locations.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 280,
                  child: LiveMap(
                    busId: t['busId'] as String?,
                    stops: asList(t['stops']),
                    routeGeometry: asList(t['routeGeometry']),
                    showEta: false,
                  ),
                ),
                const SizedBox(height: 8),
                sectionLabel(context, 'Stops and riders'),
                for (final s in asList(t['stops']))
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.location_on, color: teal),
                    title: Text('${s['name']}'),
                    trailing: Text('${s['passengers']} riders'),
                  ),
              ],
            ),
    );
  }
}
