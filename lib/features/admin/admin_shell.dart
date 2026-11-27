import 'package:firebase_auth/firebase_auth.dart';
import 'package:material_ui/material_ui.dart';
import '../../core/session.dart';
import '../../core/components.dart';
import '../../core/theme.dart';
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
import 'planning_page.dart';
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
  final String title;
  final String subtitle;
  const _AdminWorkspace({
    super.key,
    required this.tabs,
    this.title = '',
    this.subtitle = '',
  });

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

  /// Workspace name, one line about what lives here, and the outline bus on wide screens.
  Widget _header(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 700;
        return Container(
          color: scheme.surface,
          padding: EdgeInsets.fromLTRB(20, wide ? 14 : 10, 20, wide ? 8 : 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (widget.subtitle.isNotEmpty)
                      Text(
                        widget.subtitle,
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (wide) const BusOutline(height: 52, opacity: 0.85),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (widget.title.isNotEmpty) _header(context),
      Material(
        color: Theme.of(context).colorScheme.surface,
        // Tabs share the full width when there is room; they scroll only on narrow phones.
        child: LayoutBuilder(
          builder: (context, box) => TabBar(
            controller: _controller,
            isScrollable: box.maxWidth < 640,
            tabs: [for (final item in widget.tabs) Tab(text: item.title)],
          ),
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

  /// Which menu page (and tab) a destination name belongs to.
  (String, String) _route(String title) => switch (title) {
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
      'Fee policy' || 'Staff accounts' || 'Audit log' => (title, ''),
      'System settings' => ('Settings', ''),
      _ => (title, ''),
    };

  void _go(String title) {
    final route = _route(title);
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
      _Item('', 'Dashboard', Icons.dashboard_outlined, OverviewPage(onGo: _go, isSuper: isSuper)),
      _Item(
        'People',
        'People',
        Icons.people_outline,
        _AdminWorkspace(
          key: _peopleKey,
          title: 'People',
          subtitle: 'Students, bulk import and drivers',
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
          title: 'Transport management',
          subtitle: 'Buses, routes, boarding points and GPS devices',
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
          title: 'Schedules',
          subtitle: 'Working days, holidays, daily planning and tracking hours',
          tabs: const [
            _WorkspaceTab('Schedules', SchedulesPage()),
            _WorkspaceTab(
              'Daily Transport Planning',
              DailyTransportPlanningPage(),
            ),
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
          title: 'Requests and alerts',
          subtitle: 'Stop requests, alerts, emergencies, feedback and announcements',
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
          title: 'Reports',
          subtitle: 'Reports, bus health, location history and on-time performance',
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

  final _scaffoldKey = GlobalKey<ScaffoldState>();

  // Phone bottom bar: the four most-used pages, then "More" which opens the full menu.
  static const _bottomBar = [
    ('Dashboard', 'Home'),
    ('People', 'People'),
    ('Live Tracking', 'Live map'),
    ('Requests & Alerts', 'Requests'),
  ];

  // Desktop top bar: these come first, in this order. Whatever does not fit goes under "More".
  static const _topBarOrder = [
    'Dashboard',
    'People',
    'Transport Management',
    'Schedules',
    'Allocations',
    'Live Tracking',
    'Requests & Alerts',
    'Reports',
    'Expenses',
  ];

  // Everything the page search can open. Pages the signed-in role does not have are left out.
  static const _searchTargets = [
    'Dashboard',
    'Students',
    'Import students',
    'Drivers',
    'Buses',
    'Routes',
    'Boarding points',
    'GPS devices',
    'Schedules',
    'Tracking hours',
    'Boarding requests',
    'Alerts',
    'Emergency',
    'Feedback',
    'Announcements',
    'Allocation',
    'Live Tracking',
    'Reports',
    'Bus health',
    'Location history',
    'On-time report',
    'Suggestions',
    'Cost & Expenses',
    'Settings',
    'Staff accounts',
    'Audit log',
    'Fee policy',
    'Notifications',
  ];

  List<String> _searchable() => [
    for (final t in _searchTargets)
      if (_items.indexWhere((e) => e.title == _route(t).$1) >= 0) t,
  ];

  Future<void> _openSearch() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => _PageSearch(options: _searchable()),
    );
    if (choice != null) _go(choice);
  }

  Widget _brand(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
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
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
                Text(
                  '${widget.title}\n${widget.session.user.email ?? ''}',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The full menu, used in the drawer on phones.
  Widget _navList(BuildContext context) => Column(
    children: [
      _brand(context),
      const BusOutline(height: 56, opacity: 0.8),
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
                selectedTileColor: selectedTint(context),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Rd.control),
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
  );

  Widget _accountMenu(BuildContext context, {required bool showName}) {
    final scheme = Theme.of(context).colorScheme;
    final email = widget.session.user.email ?? '';
    final initial = email.isEmpty ? widget.title[0] : email[0].toUpperCase();
    return PopupMenuButton<String>(
      tooltip: 'Account',
      onSelected: (v) {
        if (v == 'out') FirebaseAuth.instance.signOut();
      },
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Text(email.isEmpty ? widget.title : email),
        ),
        const PopupMenuItem<String>(
          value: 'out',
          child: Row(
            children: [
              Icon(Icons.logout, size: 20),
              SizedBox(width: 12),
              Text('Sign out'),
            ],
          ),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 17,
              backgroundColor: scheme.primaryContainer,
              foregroundColor: scheme.onPrimaryContainer,
              child: Text(initial),
            ),
            if (showName) ...[
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    'Signed in',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ],
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  /// A navigation button in the top bar. Filled when it is the current page.
  Widget _pill(
    BuildContext context,
    IconData icon,
    String label,
    bool selected,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onPrimary : scheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: selected ? scheme.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(Rd.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar(BuildContext context, double width) {
    final scheme = Theme.of(context).colorScheme;
    final inBar = [
      for (final t in _topBarOrder) _items.indexWhere((e) => e.title == t),
    ].where((n) => n >= 0).toList();
    final inMore = [
      for (var n = 0; n < _items.length; n++)
        if (!inBar.contains(n) && _items[n].title != 'Notifications') n,
    ];
    // Room for the pills: the width minus the logo, the tools on the right and the "More" button.
    var room = width - 200 - 380 - 110;
    final shown = <int>[];
    for (final n in inBar) {
      final w = 52 + _items[n].title.length * 7.4;
      if (room - w < 0) break;
      room -= w;
      shown.add(n);
    }
    final overflow = [...inBar.skip(shown.length), ...inMore];
    return Material(
      color: scheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        ),
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: 68,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.asset(
                      'assets/logo_small.png',
                      height: 40,
                      width: 40,
                      errorBuilder: (_, _, _) =>
                          const Icon(Icons.directions_bus_filled, size: 36),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'RouteSync',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final n in shown)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(Rd.pill),
                                onTap: () => setState(() => _i = n),
                                child: _pill(
                                  context,
                                  _items[n].icon,
                                  _items[n].title,
                                  n == _i,
                                ),
                              ),
                            ),
                          if (overflow.isNotEmpty)
                            PopupMenuButton<int>(
                              tooltip: 'More pages',
                              onSelected: (n) => setState(() => _i = n),
                              itemBuilder: (_) => [
                                for (final n in overflow)
                                  PopupMenuItem<int>(
                                    value: n,
                                    child: Row(
                                      children: [
                                        Icon(_items[n].icon, size: 20),
                                        const SizedBox(width: 12),
                                        Text(_items[n].title),
                                      ],
                                    ),
                                  ),
                              ],
                              child: _pill(
                                context,
                                Icons.apps,
                                'More',
                                overflow.contains(_i),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Search pages',
                    icon: const Icon(Icons.search),
                    onPressed: _openSearch,
                  ),
                  const ThemeToggleButton(),
                  IconButton(
                    tooltip: 'Notifications',
                    icon: const Icon(Icons.notifications_outlined),
                    onPressed: () => _go('Notifications'),
                  ),
                  const SizedBox(width: 4),
                  _accountMenu(context, showName: width >= 1100),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _page(BuildContext context, _Item item) {
    final reduce = MediaQuery.of(context).disableAnimations;
    // Fades the new page in. The old page is removed straight away, so no page is built twice.
    return TweenAnimationBuilder<double>(
      key: ValueKey(_i),
      tween: Tween(begin: reduce ? 1.0 : 0.0, end: 1.0),
      duration: reduce ? Duration.zero : const Duration(milliseconds: 220),
      builder: (_, v, child) => Opacity(opacity: v, child: child),
      child: KeyedSubtree(key: ValueKey(_i), child: item.page),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final wide = box.maxWidth >= 900;
      final item = _items[_i];

      if (wide) {
        return Scaffold(
          body: Column(
            children: [
              _topBar(context, box.maxWidth),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1600),
                    child: _page(context, item),
                  ),
                ),
              ),
            ],
          ),
        );
      }

      final primary = [
        for (final p in _bottomBar) _items.indexWhere((e) => e.title == p.$1),
      ];
      final selected = primary.indexOf(_i);
      return Scaffold(
        key: _scaffoldKey,
        appBar: AppBar(
          title: Text(item.title),
          actions: [
            IconButton(
              tooltip: 'Search pages',
              icon: const Icon(Icons.search),
              onPressed: _openSearch,
            ),
            const ThemeToggleButton(),
            IconButton(
              tooltip: 'Notifications',
              icon: const Icon(Icons.notifications_outlined),
              onPressed: () => _go('Notifications'),
            ),
          ],
        ),
        drawer: Drawer(child: SafeArea(child: _navList(context))),
        body: _page(context, item),
        bottomNavigationBar: NavigationBar(
          selectedIndex: selected < 0 ? _bottomBar.length : selected,
          onDestinationSelected: (n) {
            if (n == _bottomBar.length) {
              _scaffoldKey.currentState?.openDrawer();
            } else {
              setState(() => _i = primary[n]);
            }
          },
          destinations: [
            for (var n = 0; n < _bottomBar.length; n++)
              NavigationDestination(
                icon: Icon(_items[primary[n]].icon),
                label: _bottomBar[n].$2,
              ),
            const NavigationDestination(icon: Icon(Icons.menu), label: 'More'),
          ],
        ),
      );
    },
  );
}

/// Dialog that filters the pages this role can open.
class _PageSearch extends StatefulWidget {
  final List<String> options;
  const _PageSearch({required this.options});
  @override
  State<_PageSearch> createState() => _PageSearchState();
}

class _PageSearchState extends State<_PageSearch> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final hits = [
      for (final o in widget.options)
        if (o.toLowerCase().contains(_q.trim().toLowerCase())) o,
    ];
    return AlertDialog(
      title: const Text('Search pages'),
      content: SizedBox(
        width: 420,
        height: 380,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Type a page name, e.g. Buses or Alerts',
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: hits.isEmpty
                  ? const EmptyState('No page matches that name.')
                  : ListView(
                      children: [
                        for (final h in hits)
                          ListTile(
                            leading: const Icon(Icons.arrow_forward),
                            title: Text(h),
                            onTap: () => Navigator.pop(context, h),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
