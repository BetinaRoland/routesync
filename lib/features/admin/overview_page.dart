import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../core/widgets.dart';

/// First screen for admins: what needs attention right now.
class OverviewPage extends StatefulWidget {
  final void Function(String page) onGo;
  const OverviewPage({super.key, required this.onGo});
  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  final _fs = FirebaseFirestore.instance;
  late Future<List<int>> _f;

  @override
  void initState() {
    super.initState();
    _f = _load();
  }

  Future<List<int>> _load() async {
    final r = await Future.wait([
      _fs.collection('alerts').count().get(),
      _fs.collection('students').where('registrationStatus', isEqualTo: 'registered').where('allocationId', isEqualTo: null).count().get(),
      _fs.collection('boardingRequests').where('status', isEqualTo: 'pending').count().get(),
      _fs.collection('feedback').where('status', isEqualTo: 'open').count().get(),
      _fs.collection('buses').where('trackingStatus', isEqualTo: 'active').count().get(),
      _fs.collection('students').count().get(),
    ]);
    return r.map((e) => e.count ?? 0).toList();
  }

  Widget _tile(double w, String label, int n, String page, [Color? attention]) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: w,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => widget.onGo(page),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(border: Border.all(color: scheme.outlineVariant), borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$n', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: n > 0 ? attention : null)),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }

  Widget _action(String label, IconData icon, String page) => OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
        onPressed: () => widget.onGo(page),
        icon: Icon(icon, size: 18),
        label: Text(label),
      );

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: () async {
          setState(() => _f = _load());
          await _f;
        },
        child: FutureBuilder<List<int>>(
          future: _f,
          builder: (context, s) {
            if (s.hasError) return ListView(children: const [SizedBox(height: 120), EmptyState('Could not load the overview. Pull down to try again.', icon: Icons.cloud_off)]);
            if (!s.hasData) return loading();
            final v = s.data!;
            return LayoutBuilder(
              builder: (context, box) {
                final w = (box.maxWidth - 32 - 12) / 2;
                return ListView(padding: const EdgeInsets.only(top: 12, bottom: 24), children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(spacing: 12, runSpacing: 12, children: [
                      _tile(w, 'Open alerts', v[0], 'Alerts', Colors.red),
                      _tile(w, 'Registered, no bus yet', v[1], 'Allocation', Colors.orange),
                      _tile(w, 'Stop requests', v[2], 'Boarding requests', Colors.orange),
                      _tile(w, 'Open reports', v[3], 'Feedback', Colors.orange),
                      _tile(w, 'Buses reporting', v[4], 'Bus health'),
                      _tile(w, 'Students', v[5], 'Students'),
                    ]),
                  ),
                  sectionLabel(context, 'Quick actions'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(spacing: 8, runSpacing: 8, children: [
                      _action('Run allocation', Icons.auto_fix_high, 'Allocation'),
                      _action('Announce', Icons.campaign_outlined, 'Announcements'),
                      _action('Emergency', Icons.emergency_outlined, 'Emergency'),
                      _action('Import students', Icons.upload_file, 'Import students'),
                    ]),
                  ),
                  sectionLabel(context, 'Open alerts'),
                  StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _fs.collection('alerts').orderBy('createdAt', descending: true).limit(5).snapshots(),
                    builder: (context, a) {
                      final docs = a.data?.docs ?? [];
                      if (docs.isEmpty) return const ListTile(leading: Icon(Icons.check_circle_outline, color: Colors.green), title: Text('All clear'), subtitle: Text('No open alerts.'));
                      return Column(children: [
                        for (final d in docs)
                          ListTile(
                            leading: Icon(Icons.warning_amber, color: d['severity'] == 'high' ? Colors.red : Colors.orange),
                            title: Text('${alertNames[d['alertType']] ?? d['alertType']}: bus ${d['busId']}'),
                            subtitle: Text('${d['description']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                            onTap: () => widget.onGo('Alerts'),
                          ),
                      ]);
                    },
                  ),
                ]);
              },
            );
          },
        ),
      );
}
