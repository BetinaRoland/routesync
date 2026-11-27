import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:material_ui/material_ui.dart';
import '../../core/components.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../live_map.dart';

/// Admin home. Every figure here is read from Firestore or the live location
/// feed; when a list is empty the panel says so or hides itself.
class OverviewPage extends StatefulWidget {
  final void Function(String page) onGo;
  final bool isSuper;
  const OverviewPage({super.key, required this.onGo, this.isSuper = false});
  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

/// One recent change shown in "Recent transport activity".
class _Activity {
  final IconData icon;
  final String title, detail, status;
  final DateTime? at;
  const _Activity(this.icon, this.title, this.detail, this.status, this.at);
}

class _OverviewPageState extends State<OverviewPage> {
  final _fs = FirebaseFirestore.instance;
  late Future<List<int>> _counts;
  late Future<List<_Activity>> _activity;

  @override
  void initState() {
    super.initState();
    _counts = _loadCounts();
    _activity = _loadActivity();
  }

  void _reload() => setState(() {
    _counts = _loadCounts();
    _activity = _loadActivity();
  });

  /// 0 buses, 1 buses sharing GPS, 2 allocated students, 3 pending stop
  /// requests, 4 open alerts, 5 registered students without a bus, 6 open
  /// reports, 7 proposals awaiting approval.
  Future<List<int>> _loadCounts() async {
    final r = await Future.wait([
      _fs.collection('buses').count().get(),
      _fs
          .collection('buses')
          .where('trackingStatus', isEqualTo: 'active')
          .count()
          .get(),
      _fs
          .collection('students')
          .where('allocationId', isNotEqualTo: null)
          .count()
          .get(),
      _fs
          .collection('boardingRequests')
          .where('status', isEqualTo: 'pending')
          .count()
          .get(),
      _fs.collection('alerts').count().get(),
      _fs
          .collection('students')
          .where('registrationStatus', isEqualTo: 'registered')
          .where('allocationId', isEqualTo: null)
          .count()
          .get(),
      _fs
          .collection('feedback')
          .where('status', isEqualTo: 'open')
          .count()
          .get(),
      _fs
          .collection('changeRequests')
          .where('status', isEqualTo: 'pending')
          .count()
          .get(),
    ]);
    return r.map((e) => e.count ?? 0).toList();
  }

  /// Latest emergency actions (bus, route and driver replacements) and
  /// allocation proposals. Both collections are readable by every admin.
  Future<List<_Activity>> _loadActivity() async {
    final r = await Future.wait([
      _fs
          .collection('emergencyActions')
          .orderBy('createdAt', descending: true)
          .limit(5)
          .get(),
      _fs
          .collection('changeRequests')
          .orderBy('createdAt', descending: true)
          .limit(5)
          .get(),
    ]);
    final out = <_Activity>[];
    for (final d in r[0].docs) {
      final a = d.data();
      final reason = a['reason'];
      out.add(
        _Activity(
          Icons.emergency_outlined,
          switch (a['actionType']) {
            'bus_replacement' => 'Replacement bus assigned',
            'route_change' => 'Temporary route change',
            'driver_change' => 'Driver replaced',
            _ => 'Emergency action',
          },
          'Bus ${a['affectedBusId'] ?? '-'}${reason == null || '$reason'.isEmpty ? '' : ' - $reason'}',
          '${a['reviewStatus'] ?? ''}',
          (a['createdAt'] as Timestamp?)?.toDate(),
        ),
      );
    }
    for (final d in r[1].docs) {
      final a = d.data();
      out.add(
        _Activity(
          Icons.alt_route,
          switch (a['type']) {
            'allocation' => 'Allocation proposal',
            'rebalance' => 'Bus rebalance proposal',
            _ => 'Change request',
          },
          '${a['requestDescription'] ?? ''}',
          '${a['status'] ?? ''}',
          (a['createdAt'] as Timestamp?)?.toDate(),
        ),
      );
    }
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    out.sort((a, b) => (b.at ?? epoch).compareTo(a.at ?? epoch));
    return out.take(6).toList();
  }

  String _ago(DateTime? t) {
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return fmt(t);
  }

  /// Status word as a coloured pill; empty status shows nothing.
  Widget _statusPill(String status) {
    if (status.isEmpty) return const SizedBox.shrink();
    final (tone, label) = switch (status) {
      'pending' => (Tone.warning, 'Pending'),
      'approved' => (Tone.success, 'Approved'),
      'rejected' => (Tone.danger, 'Rejected'),
      'active' => (Tone.info, 'Active'),
      _ => (Tone.neutral, status[0].toUpperCase() + status.substring(1)),
    };
    return statusPill(context, tone, label);
  }

  Widget _row({
    required IconData icon,
    required Tone tone,
    required String title,
    String? subtitle,
    Widget? badge,
    VoidCallback? onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final c = toneColor(context, tone);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: c.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(Rd.control),
              ),
              child: Icon(icon, color: c, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (subtitle != null && subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (badge != null) ...[const SizedBox(width: 8), badge],
            if (onTap != null)
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _alertsCard(List<int> v) => SectionCard(
    title: 'Active alerts',
    icon: Icons.notifications_active_outlined,
    trailing: TextButton(
      onPressed: () => widget.onGo('Alerts'),
      child: const Text('View all'),
    ),
    bodyPadding: const EdgeInsets.only(bottom: 8),
    child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _fs
          .collection('alerts')
          .orderBy('createdAt', descending: true)
          .limit(4)
          .snapshots(),
      builder: (context, a) {
        if (a.hasError) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Could not load alerts. Pull down to try again.'),
          );
        }
        final docs = a.data?.docs ?? [];
        final rows = <Widget>[
          for (final d in docs)
            _row(
              icon: Icons.warning_amber_rounded,
              tone: d['severity'] == 'high' ? Tone.danger : Tone.warning,
              title:
                  '${alertNames[d['alertType']] ?? d['alertType']}: bus ${d['busId']}',
              subtitle: '${d['description'] ?? ''}',
              badge: d['severity'] == 'high'
                  ? statusPill(context, Tone.danger, 'High')
                  : null,
              onTap: () => widget.onGo('Alerts'),
            ),
          if (v[4] > docs.length)
            _row(
              icon: Icons.more_horiz,
              tone: Tone.neutral,
              title: '${v[4] - docs.length} more open alerts',
              onTap: () => widget.onGo('Alerts'),
            ),
          if (v[3] > 0)
            _row(
              icon: Icons.edit_location_alt_outlined,
              tone: Tone.warning,
              title: '${v[3]} pending stop requests',
              subtitle: 'Students asking for a different boarding point',
              onTap: () => widget.onGo('Boarding requests'),
            ),
          if (v[5] > 0)
            _row(
              icon: Icons.person_search_outlined,
              tone: Tone.warning,
              title: '${v[5]} registered students without a bus',
              subtitle: 'Run allocation to place them',
              onTap: () => widget.onGo('Allocation'),
            ),
          if (v[6] > 0)
            _row(
              icon: Icons.feedback_outlined,
              tone: Tone.info,
              title: '${v[6]} open reports from students',
              onTap: () => widget.onGo('Feedback'),
            ),
        ];
        if (a.connectionState == ConnectionState.waiting && docs.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (rows.isEmpty) {
          return _row(
            icon: Icons.check_circle_outline,
            tone: Tone.success,
            title: 'All clear',
            subtitle: 'No open alerts or waiting requests.',
          );
        }
        return Column(children: rows);
      },
    ),
  );

  Widget _activityCard() => SectionCard(
    title: 'Recent transport activity',
    icon: Icons.history,
    bodyPadding: const EdgeInsets.only(bottom: 8),
    child: FutureBuilder<List<_Activity>>(
      future: _activity,
      builder: (context, s) {
        if (s.hasError) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Recent activity could not be loaded.'),
          );
        }
        if (!s.hasData) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (s.data!.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No transport changes recorded yet.'),
          );
        }
        return Column(
          children: [
            for (final e in s.data!)
              _row(
                icon: e.icon,
                tone: Tone.info,
                title: e.title,
                subtitle: [
                  e.detail,
                  _ago(e.at),
                ].where((t) => t.isNotEmpty).join('  -  '),
                badge: _statusPill(e.status),
              ),
          ],
        );
      },
    ),
  );

  Widget _quickActions() => SectionCard(
    title: 'Quick actions',
    icon: Icons.bolt,
    bodyPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    child: GridView.extent(
      maxCrossAxisExtent: 160,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.25,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        ActionTile(
          icon: Icons.auto_fix_high,
          label: 'Run allocation',
          onTap: () => widget.onGo('Allocation'),
        ),
        ActionTile(
          icon: Icons.campaign_outlined,
          label: 'Announce',
          onTap: () => widget.onGo('Announcements'),
        ),
        ActionTile(
          icon: Icons.emergency_outlined,
          label: 'Emergency',
          onTap: () => widget.onGo('Emergency'),
        ),
        ActionTile(
          icon: Icons.upload_file,
          label: 'Import students',
          onTap: () => widget.onGo('Import students'),
        ),
        ActionTile(
          icon: Icons.bar_chart,
          label: 'View reports',
          onTap: () => widget.onGo('Reports'),
        ),
      ],
    ),
  );

  Widget _mapCard(bool wide) => SectionCard(
    title: 'Live fleet map',
    icon: Icons.map_outlined,
    trailing: TextButton.icon(
      onPressed: () => widget.onGo('Live Tracking'),
      icon: const Icon(Icons.open_in_full, size: 18),
      label: const Text('View full map'),
    ),
    child: ClipRRect(
      borderRadius: const BorderRadius.vertical(
        bottom: Radius.circular(Rd.card),
      ),
      child: SizedBox(height: wide ? 420 : 320, child: const LiveMap()),
    ),
  );

  List<Widget> _spaced(List<Widget> items) => [
    for (var i = 0; i < items.length; i++) ...[
      if (i > 0) const SizedBox(height: 16),
      items[i],
    ],
  ];

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: () async {
      _reload();
      await _counts;
    },
    child: FutureBuilder<List<int>>(
      future: _counts,
      builder: (context, s) {
        if (s.hasError) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              const SizedBox(height: 80),
              ErrorState(
                'Could not load the overview. Check your connection.',
                onRetry: _reload,
              ),
            ],
          );
        }
        if (!s.hasData) return loading();
        final v = s.data!;
        return LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= 1000;
            final cols = wide ? 4 : 2;
            final cw = (box.maxWidth - 32 - 12 * (cols - 1)) / cols;
            final cards = Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: cw,
                  child: SummaryCard(
                    icon: Icons.directions_bus_outlined,
                    label: 'Total buses',
                    value: '${v[0]}',
                    onTap: () => widget.onGo('Buses'),
                  ),
                ),
                SizedBox(
                  width: cw,
                  child: SummaryCard(
                    icon: Icons.sensors,
                    label: 'Active buses',
                    value: '${v[1]}',
                    caption: 'sharing GPS now',
                    onTap: () => widget.onGo('Bus health'),
                  ),
                ),
                SizedBox(
                  width: cw,
                  child: SummaryCard(
                    icon: Icons.groups_outlined,
                    label: 'Allocated students',
                    value: '${v[2]}',
                    caption: v[5] > 0 ? '${v[5]} registered, no bus yet' : null,
                    onTap: () => widget.onGo('Students'),
                  ),
                ),
                SizedBox(
                  width: cw,
                  child: SummaryCard(
                    icon: Icons.pending_actions_outlined,
                    label: 'Pending requests',
                    value: '${v[3]}',
                    tone: v[3] > 0 ? Tone.warning : null,
                    onTap: () => widget.onGo('Boarding requests'),
                  ),
                ),
                if (widget.isSuper)
                  SizedBox(
                    width: cw,
                    child: SummaryCard(
                      icon: Icons.fact_check_outlined,
                      label: 'Awaiting approval',
                      value: '${v[7]}',
                      caption: 'allocation and rebalance proposals',
                      tone: v[7] > 0 ? Tone.warning : null,
                      onTap: () => widget.onGo('Allocation'),
                    ),
                  ),
              ],
            );
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                PageHeader(
                  title: 'Transport dashboard',
                  subtitle: 'Live overview of your college transport operations',
                  actions: [
                    FilledButton.icon(
                      onPressed: () => widget.onGo('Allocation'),
                      icon: const Icon(Icons.auto_fix_high, size: 18),
                      label: const Text('Run allocation'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => widget.onGo('Live Tracking'),
                      icon: const Icon(Icons.map_outlined, size: 18),
                      label: const Text('Live tracking'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                cards,
                const SizedBox(height: 16),
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 3,
                        child: Column(
                          children: _spaced([_mapCard(true), _quickActions()]),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 2,
                        child: Column(
                          children: _spaced([_alertsCard(v), _activityCard()]),
                        ),
                      ),
                    ],
                  )
                else
                  ..._spaced([
                    _alertsCard(v),
                    _mapCard(false),
                    _activityCard(),
                    _quickActions(),
                  ]),
              ],
            );
          },
        );
      },
    ),
  );
}
