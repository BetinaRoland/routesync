import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../core/session.dart';
import '../../core/widgets.dart';
import '../live_map.dart';
import '../notifications_page.dart';
import '../../services/monitor.dart';
import 'comms_pages.dart';
import 'devices_page.dart';
import 'fleet_pages.dart';
import 'insights_page.dart';
import 'monitor_pages.dart';
import 'ops_pages.dart';
import 'overview_page.dart';
import 'reports_pages.dart';
import 'students_page.dart';
import 'super_pages.dart';

class _Item {
  final String group, title;
  final IconData icon;
  final Widget page;
  const _Item(this.group, this.title, this.icon, this.page);
}

class AdminShell extends StatefulWidget {
  final Session session;
  final String title;
  const AdminShell({super.key, required this.session, required this.title});
  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  int _i = 0;
  late final List<_Item> _items;

  void _go(String title) {
    final i = _items.indexWhere((e) => e.title == title);
    if (i >= 0) setState(() => _i = i);
  }

  @override
  void dispose() {
    MonitorService.stop();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    MonitorService.start(); // alerts and bus status refresh while an admin has the app open
    final isSuper = widget.session.role == Role.superAdmin;
    _items = [
      _Item('', 'Overview', Icons.dashboard_outlined, OverviewPage(onGo: _go)),
      const _Item('Operations', 'Live map', Icons.map_outlined, LiveMap()),
      const _Item(
        'Operations',
        'Bus health',
        Icons.monitor_heart_outlined,
        BusHealthPage(),
      ),
      const _Item(
        'Operations',
        'Alerts',
        Icons.warning_amber_outlined,
        AlertsPage(),
      ),
      const _Item(
        'Operations',
        'Allocation',
        Icons.auto_fix_high_outlined,
        AllocationPage(),
      ),
      const _Item(
        'Operations',
        'Emergency',
        Icons.emergency_outlined,
        EmergencyPage(),
      ),
      const _Item(
        'Operations',
        'Location history',
        Icons.history,
        HistoryPage(),
      ),
      const _Item(
        'Operations',
        'On-time report',
        Icons.timer_outlined,
        OnTimePage(),
      ),
      const _Item(
        'Operations',
        'Suggestions',
        Icons.lightbulb_outline,
        InsightsPage(),
      ),
      const _Item('People', 'Students', Icons.school_outlined, StudentsPage()),
      const _Item('People', 'Import students', Icons.upload_file, ImportPage()),
      const _Item(
        'People',
        'Boarding requests',
        Icons.pin_drop_outlined,
        RequestsPage(),
      ),
      const _Item(
        'People',
        'Feedback',
        Icons.forum_outlined,
        FeedbackInboxPage(),
      ),
      const _Item(
        'People',
        'Announcements',
        Icons.campaign_outlined,
        AnnouncementsPage(),
      ),
      const _Item(
        'Network',
        'Buses',
        Icons.directions_bus_outlined,
        BusesPage(),
      ),
      const _Item('Network', 'Drivers', Icons.badge_outlined, DriversPage()),
      const _Item(
        'Network',
        'GPS devices',
        Icons.satellite_alt_outlined,
        DevicesPage(),
      ),
      const _Item('Network', 'Routes', Icons.alt_route, RoutesPage()),
      const _Item(
        'Network',
        'Boarding points',
        Icons.location_on_outlined,
        BoardingPointsPage(),
      ),
      const _Item(
        'Network',
        'Schedules',
        Icons.calendar_month_outlined,
        SchedulesPage(),
      ),
      const _Item('Network', 'Tracking hours', Icons.schedule, HoursPage()),
      const _Item('Money', 'Reports', Icons.bar_chart, ReportsPage()),
      const _Item('Money', 'Costs', Icons.receipt_long_outlined, CostsPage()),
      if (isSuper)
        const _Item(
          'Money',
          'Fee policy',
          Icons.request_quote_outlined,
          FeePolicyPage(),
        ),
      if (isSuper)
        const _Item(
          'System',
          'Staff accounts',
          Icons.manage_accounts_outlined,
          StaffPage(),
        ),
      if (isSuper)
        const _Item(
          'System',
          'System settings',
          Icons.settings_outlined,
          SettingsPage(),
        ),
      if (isSuper)
        const _Item(
          'System',
          'Audit log',
          Icons.fact_check_outlined,
          AuditPage(),
        ),
      const _Item(
        'System',
        'Notifications',
        Icons.notifications_outlined,
        NotificationsPage(),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final item = _items[_i];
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(item.title),
        actions: [
          IconButton(
            tooltip: 'Notifications',
            icon: const Icon(Icons.notifications_outlined),
            onPressed: () => _go('Notifications'),
          ),
        ],
      ),
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.asset(
                        'assets/logo_small.png',
                        height: 44,
                        width: 44,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.directions_bus_filled, size: 40),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'RouteSync',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            '${widget.title}\n${widget.session.user.email ?? ''}',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    for (var n = 0; n < _items.length; n++) ...[
                      if (_items[n].group.isNotEmpty &&
                          (n == 0 || _items[n - 1].group != _items[n].group))
                        sectionLabel(context, _items[n].group),
                      ListTile(
                        dense: true,
                        leading: Icon(_items[n].icon, size: 22),
                        title: Text(_items[n].title),
                        selected: n == _i,
                        selectedTileColor: amberTint(context),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        onTap: () {
                          setState(() => _i = n);
                          Navigator.pop(context);
                        },
                      ),
                    ],
                  ],
                ),
              ),
              const Divider(),
              ListTile(
                dense: true,
                leading: const Icon(Icons.logout, size: 22),
                title: const Text('Sign out'),
                onTap: () => FirebaseAuth.instance.signOut(),
              ),
            ],
          ),
        ),
      ),
      body: KeyedSubtree(key: ValueKey(_i), child: item.page),
    );
  }
}
