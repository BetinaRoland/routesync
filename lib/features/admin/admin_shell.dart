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
import 'boarding_points_page.dart';
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

class _WorkspaceTab {
  final String title;
  final Widget page;
  const _WorkspaceTab(this.title, this.page);
}

class _AdminWorkspace extends StatefulWidget {
  final List<_WorkspaceTab> tabs;
  const _AdminWorkspace({super.key, required this.tabs});

  @override
  State<_AdminWorkspace> createState() => _AdminWorkspaceState();
}

class _AdminWorkspaceState extends State<_AdminWorkspace>
    with SingleTickerProviderStateMixin {
  late final TabController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TabController(length: widget.tabs.length, vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void select(String tab) {
    final index = widget.tabs.indexWhere((item) => item.title == tab);
    if (index >= 0) _controller.animateTo(index);
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Material(
        color: Theme.of(context).colorScheme.surface,
        child: TabBar(
          controller: _controller,
          isScrollable: true,
          tabs: [for (final item in widget.tabs) Tab(text: item.title)],
        ),
      ),
      Expanded(
        child: TabBarView(
          controller: _controller,
          children: [for (final item in widget.tabs) item.page],
        ),
      ),
    ],
  );
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
  final _peopleKey = GlobalKey<_AdminWorkspaceState>();
  final _transportKey = GlobalKey<_AdminWorkspaceState>();
  final _schedulesKey = GlobalKey<_AdminWorkspaceState>();
  final _requestsKey = GlobalKey<_AdminWorkspaceState>();
  final _reportsKey = GlobalKey<_AdminWorkspaceState>();

  void _go(String title) {
    final route = switch (title) {
      'Students' || 'Import students' || 'Drivers' => ('People', title),
      'Buses' ||
      'Routes' ||
      'Boarding points' ||
      'GPS devices' => ('Transport Management', title),
      'Schedules' || 'Tracking hours' => ('Schedules', title),
      'Boarding requests' ||
      'Alerts' ||
      'Emergency' ||
      'Feedback' ||
      'Announcements' => ('Requests & Alerts', title),
      'Bus health' ||
      'Location history' ||
      'On-time report' ||
      'Suggestions' ||
      'Reports' => ('Reports', title),
      'Allocation' => ('Allocations', 'Allocation review'),
      'Cost & Expenses' => ('Expenses', ''),
      'Fee policy' ||
      'Staff accounts' ||
      'System settings' ||
      'Audit log' => ('Settings', title),
      _ => (title, ''),
    };
    final i = _items.indexWhere((e) => e.title == route.$1);
    if (i < 0) return;
    setState(() => _i = i);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = switch (route.$1) {
        'People' => _peopleKey,
        'Transport Management' => _transportKey,
        'Schedules' => _schedulesKey,
        'Requests & Alerts' => _requestsKey,
        'Reports' => _reportsKey,
        _ => null,
      };
      if (route.$2.isNotEmpty) key?.currentState?.select(route.$2);
    });
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
      _Item('', 'Dashboard', Icons.dashboard_outlined, OverviewPage(onGo: _go)),
      _Item(
        'People',
        'People',
        Icons.people_outline,
        _AdminWorkspace(
          key: _peopleKey,
          tabs: const [
            _WorkspaceTab('Students', StudentsPage()),
            _WorkspaceTab('Import students', ImportPage()),
            _WorkspaceTab('Drivers', DriversPage()),
          ],
        ),
      ),
      _Item(
        'Transport Management',
        'Transport Management',
        Icons.directions_bus_outlined,
        _AdminWorkspace(
          key: _transportKey,
          tabs: const [
            _WorkspaceTab('Buses', BusesPage()),
            _WorkspaceTab('Routes', RoutesPage()),
            _WorkspaceTab('Boarding points', BoardingPointsPage()),
            _WorkspaceTab('GPS devices', DevicesPage()),
          ],
        ),
      ),
      _Item(
        'Schedules',
        'Schedules',
        Icons.calendar_month_outlined,
        _AdminWorkspace(
          key: _schedulesKey,
          tabs: const [
            _WorkspaceTab('Schedules', SchedulesPage()),
            _WorkspaceTab('Tracking hours', HoursPage()),
          ],
        ),
      ),
      _Item(
        'Allocations',
        'Allocations',
        Icons.auto_fix_high_outlined,
        _AdminWorkspace(
          tabs: const [_WorkspaceTab('Allocation review', AllocationPage())],
        ),
      ),
      const _Item(
        'Live Tracking',
        'Live Tracking',
        Icons.map_outlined,
        LiveMap(),
      ),
      _Item(
        'Requests & Alerts',
        'Requests & Alerts',
        Icons.notifications_active_outlined,
        _AdminWorkspace(
          key: _requestsKey,
          tabs: const [
            _WorkspaceTab('Boarding requests', RequestsPage()),
            _WorkspaceTab('Alerts', AlertsPage()),
            _WorkspaceTab('Emergency', EmergencyPage()),
            _WorkspaceTab('Feedback', FeedbackInboxPage()),
            _WorkspaceTab('Announcements', AnnouncementsPage()),
          ],
        ),
      ),
      _Item(
        'Expenses',
        'Expenses',
        Icons.receipt_long_outlined,
        CostsPage(role: isSuper ? 'superAdmin' : 'routeAdmin'),
      ),
      _Item(
        'Reports',
        'Reports',
        Icons.bar_chart,
        _AdminWorkspace(
          key: _reportsKey,
          tabs: const [
            _WorkspaceTab('Reports', ReportsPage()),
            _WorkspaceTab('Bus health', BusHealthPage()),
            _WorkspaceTab('Location history', HistoryPage()),
            _WorkspaceTab('On-time report', OnTimePage()),
            _WorkspaceTab('Suggestions', InsightsPage()),
          ],
        ),
      ),
      if (isSuper)
        const _Item(
          'Settings',
          'Settings',
          Icons.settings_outlined,
          SettingsPage(),
        ),
      if (isSuper)
        const _Item(
          'Settings',
          'Staff accounts',
          Icons.manage_accounts_outlined,
          StaffPage(),
        ),
      if (isSuper)
        const _Item(
          'Settings',
          'Audit log',
          Icons.fact_check_outlined,
          AuditPage(),
        ),
      if (isSuper)
        const _Item(
          'Settings',
          'Fee policy',
          Icons.request_quote_outlined,
          FeePolicyPage(),
        ),
      const _Item(
        'Account',
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
