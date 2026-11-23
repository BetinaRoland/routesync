import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/api.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../services/common.dart' show dateKey, need;
import '../eta_badge.dart';
import '../live_map.dart';
import '../notifications_page.dart';
import 'feedback_page.dart';

// Privacy: the student app never asks for device location. Boarding points are chosen by search or by tapping the map.
class StudentHome extends StatefulWidget {
  final Session session;
  const StudentHome({super.key, required this.session});
  @override
  State<StudentHome> createState() => _StudentHomeState();
}

class _StudentHomeState extends State<StudentHome> {
  Map<String, dynamic>? _t;
  Object? _err;
  bool _loading = true;
  String? _altBus;
  List<Map<String, dynamic>> _alts = [];
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _t = await Api.call('getMyTransport');
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final a =
          (await FirebaseFirestore.instance
                  .doc('alternativeBoardings/${uid}_${dateKey()}')
                  .get())
              .data();
      _altBus = a != null && a['status'] == 'reserved'
          ? '${a['alternativeBusId']}'
          : null;
      _err = null;
    } catch (e) {
      _err = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  // ---------- Bus tab ----------
  String _scheduleText(Map<String, dynamic> t) => [
    if (t['arrivalBy'] != null) 'Due at college by ${t['arrivalBy']}',
    if (t['trackingStart'] != null)
      'Live tracking ${t['trackingStart']} to ${t['trackingEnd']}',
  ].join('   ');

  Widget _busTab() {
    if (_loading) return loading();
    if (_err != null) {
      return Center(
        child: Padding(padding: const EdgeInsets.all(24), child: Text('$_err')),
      );
    }
    final t = _t!;
    if (t['allocated'] != true) {
      final msg = t['boardingPoint'] == null
          ? 'Your college-assigned boarding point is not available yet.'
          : 'Your assigned stop is set. Your bus will appear here once the Route Admin publishes an allocation. Tap refresh to check.';
      return EmptyState(msg, icon: Icons.directions_bus_outlined);
    }
    final driver = asMap(t['driver']);
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.directions_bus, color: navy, size: 32),
          title: Text('Bus ${t['busNumber']}   ${t['routeName'] ?? ''}'),
          subtitle: Text(
            'Pickup: ${asMap(t['boardingPoint'])['name']}${driver.isNotEmpty ? '\nDriver: ${driver['name']}  ${driver['contact'] ?? ''}' : ''}',
          ),
          isThreeLine: driver.isNotEmpty,
        ),
        if (_scheduleText(t).isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _scheduleText(t),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        EtaBadge(busId: '${t['busId']}'),
        Expanded(
          child: LiveMap(
            busId: t['busId'] as String?,
            stops: asList(t['stops']),
            showEta: false,
            myStop: asMap(t['boardingPoint']).isEmpty
                ? null
                : asMap(t['boardingPoint']),
          ),
        ),
      ],
    );
  }

  // ---------- Stop tab ----------
  Future<void> _requestPointByEmail() async {
    final c = await need(['student']);
    final s =
        (await FirebaseFirestore.instance.doc('students/${c.studentId}').get())
            .data();
    final college =
        (await FirebaseFirestore.instance.doc('config/college').get()).data() ??
        {};
    final recipient =
        '${college['boardingChangeEmail'] ?? college['changeRequestEmail'] ?? college['email'] ?? ''}'
            .trim();
    if (recipient.isEmpty) {
      if (mounted) {
        await info(
          context,
          'College request',
          'The college boarding-change email has not been configured.',
        );
      }
      return;
    }
    final stopId = s?['approvedBoardingPointId'];
    final stop = stopId == null
        ? null
        : (await FirebaseFirestore.instance.doc('boardingPoints/$stopId').get())
              .data();
    final subject =
        'Pre-payment boarding point change request - ${s?['registerNumber'] ?? c.studentId}';
    final body =
        'Hello,\n\nI request a boarding-point change before payment.\n\n'
        'Student: ${s?['name'] ?? c.name}\n'
        'Register number: ${s?['registerNumber'] ?? '-'}\n'
        'Current assigned boarding point: ${stop?['name'] ?? 'Not assigned'}\n'
        'Please advise me of the college process.\n';
    await launchUrl(
      Uri(
        scheme: 'mailto',
        path: recipient,
        queryParameters: {'subject': subject, 'body': body},
      ),
    );
  }

  Widget _stopTab() {
    if (_loading) return loading();
    final t = _t ?? {};
    final fee = asMap(t['fee']),
        bp = asMap(t['boardingPoint']),
        allocated = t['allocated'] == true;
    return Column(
      children: [
        Card(
          margin: const EdgeInsets.all(12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bp.isEmpty
                      ? 'No boarding point chosen yet'
                      : 'Boarding point: ${bp['name']}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                if (fee.isNotEmpty)
                  Text(
                    'Estimated annual fee Rs ${fee['amount']} for ${fee['distanceKm']} km by road. It is paid at the college office.',
                  ),
                if (bp.isNotEmpty && fee.isEmpty)
                  const Text(
                    'Your fee will show once the college sets its fee policy.',
                  ),
                if (allocated) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Your bus, driver and assigned boarding point are controlled by the college and Route Admin.',
                  ),
                ],
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _requestPointByEmail,
                  icon: const Icon(Icons.email_outlined),
                  label: const Text('Request change by email (before payment)'),
                ),
                const SizedBox(height: 8),
                const Text(
                  'After payment, contact the college in person. RouteSync does not submit boarding-point changes.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              bp.isEmpty
                  ? 'No assigned boarding point is available yet. Your college record will appear here when synchronized.'
                  : 'Official boarding point: ${bp['name']}. This record is read-only in RouteSync.',
            ),
          ),
        ),
      ],
    );
  }

  // ---------- Alternative bus tab ----------
  Future<void> _find() async {
    await runAction(context, () async {
      final r = await Api.call('findAlternatives');
      _alts = asList(r['buses']);
      if (mounted) setState(() {});
      return _alts.isEmpty
          ? 'No other bus on your stop has a free seat right now.'
          : null;
    });
  }

  Widget _altTab() {
    if (_altBus != null) {
      return Column(
        children: [
          ListTile(
            leading: const Icon(Icons.check_circle, color: Colors.green),
            title: Text('Alternative bus reserved: $_altBus'),
            subtitle: const Text('Valid for today. Board at your usual stop.'),
          ),
          EtaBadge(busId: _altBus!),
          Expanded(
            child: LiveMap(
              busId: _altBus,
              showEta: false,
              myStop: asMap(_t?['boardingPoint']).isEmpty
                  ? null
                  : asMap(_t?['boardingPoint']),
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Missed your bus or it is not running? Find another bus that serves your stop and has a free seat.',
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _find,
                icon: const Icon(Icons.search),
                label: const Text('Find alternative buses'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final b in _alts)
                ListTile(
                  leading: const Icon(Icons.directions_bus),
                  title: Text('Bus ${b['busNumber']}   ${b['routeName']}'),
                  subtitle: Text('${b['seatsLeft']} seats free'),
                  trailing: FilledButton(
                    onPressed: () async {
                      final ok = await runAction(context, () async {
                        final r = await Api.call('reserveAlternative', {
                          'busId': b['busId'],
                        });
                        return 'Seat reserved on bus ${r['busNumber']}.';
                      });
                      if (ok) {
                        _alts = [];
                        await _load();
                      }
                    },
                    child: const Text('Reserve'),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _menu(String v) async {
    final user = FirebaseAuth.instance.currentUser!;
    if (v == 'out') {
      await FirebaseAuth.instance.signOut();
      return;
    }
    if (v == 'report') {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const FeedbackPage()),
      );
      return;
    }
    if (v == 'password') {
      await runAction(context, () async {
        await FirebaseAuth.instance.sendPasswordResetEmail(email: user.email!);
        return 'A password reset link was sent to ${user.email}.';
      });
      return;
    }
    try {
      final c = await need(['student']);
      final s =
          (await FirebaseFirestore.instance
                  .doc('students/${c.studentId}')
                  .get())
              .data();
      if (!mounted) return;
      final mobile = (s?['mobile'] as String?)?.isNotEmpty == true
          ? s!['mobile']
          : '-';
      await info(
        context,
        'My profile',
        '${s?['name']}\nRegister number: ${s?['registerNumber']}\nDepartment: ${s?['departmentId']}\nYear: ${s?['academicYear']}\nEmail: ${s?['email']}\nMobile: $mobile',
      );
    } catch (e) {
      if (mounted) {
        await info(context, 'My profile', 'Could not load your profile.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const titles = ['My bus', 'My stop', 'Alternative bus', 'Alerts'];
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_tab]),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
          PopupMenuButton<String>(
            tooltip: 'Account',
            onSelected: _menu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'profile', child: Text('My profile')),
              PopupMenuItem(value: 'report', child: Text('Report a problem')),
              PopupMenuItem(value: 'password', child: Text('Change password')),
              PopupMenuItem(value: 'out', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          _busTab(),
          _stopTab(),
          _altTab(),
          NotificationsPage(
            audience: 'students',
            busId: _t?['busId'] as String?,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.directions_bus_outlined),
            selectedIcon: Icon(Icons.directions_bus),
            label: 'Bus',
          ),
          NavigationDestination(
            icon: Icon(Icons.location_on_outlined),
            selectedIcon: Icon(Icons.location_on),
            label: 'Stop',
          ),
          NavigationDestination(
            icon: Icon(Icons.alt_route),
            label: 'Alternative',
          ),
          NavigationDestination(
            icon: Icon(Icons.notifications_outlined),
            selectedIcon: Icon(Icons.notifications),
            label: 'Alerts',
          ),
        ],
      ),
    );
  }
}
