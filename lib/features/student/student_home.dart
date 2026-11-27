import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/api.dart';
import '../../core/session.dart';
import '../../core/components.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../services/common.dart' show hhmm, need;
import '../eta_badge.dart';
import '../live_map.dart';
import '../notifications_page.dart';
import 'feedback_page.dart';

bool _withinTrackingHours(Map<String, dynamic> transport) {
  final start = '${transport['trackingStart'] ?? ''}';
  final end = '${transport['trackingEnd'] ?? ''}';
  final now = hhmm();
  return start.isNotEmpty &&
      end.isNotEmpty &&
      now.compareTo(start) >= 0 &&
      now.compareTo(end) <= 0;
}

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
  String? _transportRefreshError;
  List<Map<String, dynamic>> _alts = [];
  int _tab = 0;
  Timer? _trackingClock;

  @override
  void initState() {
    super.initState();
    _trackingClock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
      unawaited(_refreshAssignment());
    });
    _load();
  }

  @override
  void dispose() {
    _trackingClock?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _t = await Api.call('getMyTransport');
      final alternative = asMap(_t?['alternativeTransport']);
      _altBus = alternative['busId'] as String?;
      _transportRefreshError = null;
      _err = null;
    } catch (e) {
      _err = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _refreshAssignment() async {
    try {
      final latest = await Api.call('getMyTransport');
      final alternative = asMap(latest['alternativeTransport']);
      if (!mounted) return;
      setState(() {
        _t = latest;
        _altBus = alternative['busId'] as String?;
        _transportRefreshError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _transportRefreshError =
            'Could not confirm your current bus assignment. Refresh to retry.',
      );
    }
  }

  // ---------- Bus tab ----------
  String _scheduleText(Map<String, dynamic> t) => [
    if (t['arrivalBy'] != null) 'Due at college by ${t['arrivalBy']}',
    if (t['trackingStart'] != null)
      'Live tracking ${t['trackingStart']} to ${t['trackingEnd']}',
  ].join('   ');

  Map<String, dynamic> get _activeTransport =>
      _altBus == null ? (_t ?? {}) : asMap(_t?['alternativeTransport']);

  bool _trackingAllowed(Map<String, dynamic> transport) {
    return _withinTrackingHours(transport);
  }

  String _trackingMessage(Map<String, dynamic> transport) {
    final start = '${transport['trackingStart'] ?? ''}';
    final end = '${transport['trackingEnd'] ?? ''}';
    return start.isEmpty || end.isEmpty
        ? 'Live tracking hours are not configured.'
        : 'Live tracking is unavailable outside $start–$end.';
  }

  Widget _trackCard(Map<String, dynamic> transport) {
    final busId = transport['busId'] as String?;
    final available = busId != null;
    final tracking =
        available &&
        _transportRefreshError == null &&
        _trackingAllowed(transport);
    final description = !available
        ? 'Your bus map will be available after an allocation is published.'
        : _transportRefreshError != null
        ? _transportRefreshError!
        : 'Bus ${transport['busNumber'] ?? busId}'
              '${transport['routeName'] == null ? '' : ' · ${transport['routeName']}'}'
              '${tracking ? ' · Tracking available now' : ' · ${_trackingMessage(transport)}'}';
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: ListTile(
        leading: const Icon(Icons.map_outlined, size: 30),
        title: const Text(
          'Track My Bus',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(description),
        trailing: FilledButton(
          onPressed: !available
              ? null
              : () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => StudentTrackingPage(
                      transport: transport,
                      assignedStop: asMap(_t?['boardingPoint']),
                      assignmentConfirmed: _transportRefreshError == null,
                    ),
                  ),
                ),
          child: const Text('Open map'),
        ),
        onTap: !available
            ? null
            : () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => StudentTrackingPage(
                    transport: transport,
                    assignedStop: asMap(_t?['boardingPoint']),
                    assignmentConfirmed: _transportRefreshError == null,
                  ),
                ),
              ),
      ),
    );
  }

  /// Bus, route, pickup, driver and tracking state in one card, with a way to open the full-screen map.
  Widget _busSummary(
    Map<String, dynamic> transport,
    Map<String, dynamic> stop,
    Map<String, dynamic> driver,
    bool tracking,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            right: 12,
            bottom: 48,
            child: BusOutline(height: 64, opacity: 0.16),
          ),
          Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  foregroundColor: scheme.onPrimaryContainer,
                  child: Icon(
                    _altBus == null ? Icons.directions_bus : Icons.alt_route,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${_altBus == null ? 'Bus' : 'Alternative bus'} ${transport['busNumber']}'
                    '${transport['routeName'] == null ? '' : ' · ${transport['routeName']}'}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                tracking
                    ? statusPill(
                        context,
                        Tone.success,
                        'Live now',
                        icon: Icons.sensors,
                      )
                    : statusPill(
                        context,
                        Tone.neutral,
                        'Not live',
                        icon: Icons.sensors_off,
                      ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Pickup: ${stop['name'] ?? '-'}'),
            if (driver.isNotEmpty)
              Text('Driver: ${driver['name']}  ${driver['contact'] ?? ''}'),
            if (!tracking && _transportRefreshError == null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_trackingMessage(transport), style: muted),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => StudentTrackingPage(
                      transport: transport,
                      assignedStop: asMap(_t?['boardingPoint']),
                      assignmentConfirmed: _transportRefreshError == null,
                    ),
                  ),
                ),
                icon: const Icon(Icons.fullscreen),
                label: const Text('Full-screen map'),
              ),
            ),
          ],
        ),
      ),
        ],
      ),
    );
  }

  Widget _busTab() {
    if (_loading) return loading();
    if (_err != null) {
      return Center(
        child: Padding(padding: const EdgeInsets.all(24), child: Text('$_err')),
      );
    }
    final t = _t!;
    final transport = _activeTransport;
    final hasBus = transport['busId'] != null;
    final driver = asMap(transport['driver']);
    final stop = asMap(t['boardingPoint']);
    if (!hasBus) {
      final msg = stop.isEmpty
          ? 'Your college-assigned boarding point is not available yet.'
          : 'Your assigned stop is set. Your bus will appear here once the Route Admin publishes an allocation. Tap refresh to check.';
      return Column(
        children: [
          _trackCard(transport),
          Expanded(child: EmptyState(msg, icon: Icons.directions_bus_outlined)),
        ],
      );
    }
    final tracking =
        _transportRefreshError == null && _trackingAllowed(transport);
    return Column(
      children: [
        _busSummary(transport, stop, driver, tracking),
        if (_transportRefreshError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _transportRefreshError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_scheduleText(t).isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _scheduleText(transport),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        EtaBadge(busId: '${transport['busId']}'),
        Expanded(
          child: transport['busId'] == null
              ? EmptyState(
                  _transportRefreshError ??
                      'There is no active bus allocation to track.',
                  icon: Icons.directions_bus_outlined,
                )
              : LiveMap(
                  busId: transport['busId'] as String?,
                  stops: asList(transport['stops']),
                  routeGeometry: asList(transport['routeGeometry']),
                  showEta: false,
                  trackingEnabled: tracking,
                  trackingUnavailableMessage: _trackingMessage(transport),
                  staleAfterSeconds:
                      (transport['gpsStaleSeconds'] as num?)?.toInt() ?? 120,
                  busLabel: 'Bus ${transport['busNumber']}',
                  myStop: stop.isEmpty ? null : stop,
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
            leading: Icon(
              Icons.check_circle,
              color: toneColor(context, Tone.success),
            ),
            title: Text(
              'Alternative bus active: ${_activeTransport['busNumber'] ?? _altBus}',
            ),
            subtitle: const Text('Valid for today. Board at your usual stop.'),
          ),
          EtaBadge(busId: _altBus!),
          Expanded(
            child: LiveMap(
              busId: _altBus,
              showEta: false,
              stops: asList(_activeTransport['stops']),
              routeGeometry: asList(_activeTransport['routeGeometry']),
              trackingEnabled: _trackingAllowed(_activeTransport),
              trackingUnavailableMessage: _trackingMessage(_activeTransport),
              staleAfterSeconds:
                  (asMap(_activeTransport)['gpsStaleSeconds'] as num?)
                      ?.toInt() ??
                  120,
              busLabel: 'Bus ${asMap(_activeTransport)['busNumber']}',
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
          const ThemeToggleButton(),
          IconButton(
            tooltip: 'Report a problem',
            icon: const Icon(Icons.report_problem_outlined),
            onPressed: () => _menu('report'),
          ),
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
            busId: _activeTransport['busId'] as String?,
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

class StudentTrackingPage extends StatefulWidget {
  final Map<String, dynamic> transport;
  final Map<String, dynamic> assignedStop;
  final bool assignmentConfirmed;

  const StudentTrackingPage({
    super.key,
    required this.transport,
    required this.assignedStop,
    required this.assignmentConfirmed,
  });

  @override
  State<StudentTrackingPage> createState() => _StudentTrackingPageState();
}

class _StudentTrackingPageState extends State<StudentTrackingPage> {
  Timer? _clock;
  late Map<String, dynamic> _transport;
  late Map<String, dynamic> _assignedStop;
  String? _refreshError;

  @override
  void initState() {
    super.initState();
    _transport = widget.transport;
    _assignedStop = widget.assignedStop;
    _refreshError = widget.assignmentConfirmed
        ? null
        : 'Could not confirm your current bus assignment. Refresh to retry.';
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_refreshTransport());
    });
    unawaited(_refreshTransport());
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _refreshTransport() async {
    try {
      final latest = await Api.call('getMyTransport');
      final alternative = asMap(latest['alternativeTransport']);
      final transport = alternative.isNotEmpty ? alternative : latest;
      if (!mounted) return;
      setState(() {
        _transport = transport;
        _assignedStop = asMap(latest['boardingPoint']);
        _refreshError = transport['busId'] == null
            ? 'There is no active bus allocation to track.'
            : null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _refreshError =
            'Could not confirm your current bus assignment. Refresh to retry.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final transport = _transport;
    final assignedStop = _assignedStop;
    final trackingEnabled =
        _refreshError == null && _withinTrackingHours(transport);
    final driver = asMap(transport['driver']);
    final busNumber = '${transport['busNumber'] ?? ''}';
    final trackingStart = '${transport['trackingStart'] ?? ''}';
    final trackingEnd = '${transport['trackingEnd'] ?? ''}';
    final staleSeconds =
        ((transport['gpsStaleSeconds'] as num?)?.toInt() ?? 120).clamp(1, 3600);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Track My Bus'),
        actions: [
          IconButton(
            tooltip: 'Refresh bus assignment',
            onPressed: _refreshTransport,
            icon: const Icon(Icons.refresh),
          ),
        ],
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
          tooltip: 'Back to dashboard',
        ),
      ),
      body: Column(
        children: [
          Card(
            margin: const EdgeInsets.all(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 20,
                runSpacing: 8,
                children: [
                  Text('Bus $busNumber'),
                  if (driver.isNotEmpty) Text('Driver: ${driver['name']}'),
                  if (assignedStop.isNotEmpty)
                    Text('Your stop: ${assignedStop['name']}'),
                  if (transport['routeName'] != null)
                    Text('Route: ${transport['routeName']}'),
                  if (_refreshError != null)
                    Text(
                      _refreshError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  Text(
                    trackingEnabled
                        ? 'Tracking hours: $trackingStart–$trackingEnd'
                        : trackingStart.isEmpty || trackingEnd.isEmpty
                        ? 'Live tracking hours are not configured.'
                        : 'Tracking unavailable outside $trackingStart–$trackingEnd.',
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: LiveMap(
              busId: transport['busId'] as String?,
              busLabel: 'Bus $busNumber',
              stops: asList(transport['stops']),
              routeGeometry: asList(transport['routeGeometry']),
              myStop: assignedStop.isEmpty ? null : assignedStop,
              showEta: false,
              trackingEnabled: trackingEnabled,
              trackingUnavailableMessage: trackingEnabled
                  ? null
                  : trackingStart.isEmpty || trackingEnd.isEmpty
                  ? 'Live tracking hours are not configured.'
                  : 'Tracking unavailable outside $trackingStart–$trackingEnd.',
              staleAfterSeconds: staleSeconds,
            ),
          ),
        ],
      ),
    );
  }
}
