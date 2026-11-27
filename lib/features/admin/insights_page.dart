import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:material_ui/material_ui.dart';
import '../../core/api.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Rule-based suggestions for the Route Admin. Nothing here changes live data without your approval.
class InsightsPage extends StatefulWidget {
  const InsightsPage({super.key});
  @override
  State<InsightsPage> createState() => _InsightsPageState();
}

class _InsightsPageState extends State<InsightsPage> {
  late Future<Map<String, dynamic>> _f;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _buses = [];
  String? _bus;
  Map<String, dynamic>? _repl;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _f = Api.call('insights');
    FirebaseFirestore.instance
        .collection('buses')
        .orderBy('busNumber')
        .get()
        .then((s) {
          if (mounted) setState(() => _buses = s.docs);
        });
  }

  Future<void> _propose(String fn, String done) async {
    setState(() => _busy = true);
    await runAction(context, () async {
      final r = await Api.call(fn);
      if (r['requestId'] == null) return '${r['message']}';
      return done;
    });
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _replacement() async {
    if (_bus == null) return;
    await runAction(context, () async {
      final r = await Api.call('replacementSuggestions', {'busId': _bus});
      if (mounted) setState(() => _repl = r);
      return null;
    });
  }

  Widget _line(IconData icon, String text, [Color? color]) => ListTile(
    dense: true,
    leading: Icon(icon, size: 20, color: color),
    title: Text(text),
  );

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: () async {
      setState(() => _f = Api.call('insights'));
      await _f;
    },
    child: FutureBuilder<Map<String, dynamic>>(
      future: _f,
      builder: (context, s) {
        if (s.hasError) {
          return ListView(
            children: [
              const SizedBox(height: 120),
              EmptyState('${s.error}', icon: Icons.cloud_off),
            ],
          );
        }
        if (!s.hasData) return loading();
        final d = s.data!,
            buses = asList(d['buses']),
            overlaps = List<String>.from(d['overlaps'] as List),
            free = List<String>.from(d['consolidation'] as List),
            under = List<String>.from(d['underHalf'] as List);
        final ready = (d['ready'] as num).toInt();
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            sectionLabel(context, 'Needs attention'),
            _line(
              Icons.person_add_alt,
              '${d['notRegistered']} students have not registered yet',
            ),
            _line(
              Icons.location_off_outlined,
              '${d['noStop']} registered students have not chosen a stop',
            ),
            _line(
              ready > 0 ? Icons.warning_amber : Icons.check_circle_outline,
              '$ready students are ready but have no bus',
              ready > 0
                  ? toneColor(context, Tone.warning)
                  : toneColor(context, Tone.success),
            ),
            for (final n in List<String>.from(d['readyNames'] as List))
              Padding(
                padding: const EdgeInsets.only(left: 56),
                child: Text(n, style: const TextStyle(fontSize: 12)),
              ),
            _line(
              (d['openAlerts'] as num) > 0
                  ? Icons.notifications_active_outlined
                  : Icons.check_circle_outline,
              '${d['openAlerts']} open alerts',
              (d['openAlerts'] as num) > 0
                  ? toneColor(context, Tone.danger)
                  : toneColor(context, Tone.success),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _propose(
                            'proposeAllocation',
                            'Allocation proposal created. Review it on the Allocation screen.',
                          ),
                    child: const Text('Propose allocation'),
                  ),
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _propose(
                            'proposeRebalance',
                            'Proposal created. Review it on the Allocation screen.',
                          ),
                    child: const Text('Propose freeing buses'),
                  ),
                ],
              ),
            ),
            sectionLabel(context, 'Ways to save a bus'),
            if (free.isEmpty)
              _line(
                Icons.info_outline,
                'No bus can be freed without exceeding seats or leaving a stop unserved.',
              ),
            for (final f in free)
              _line(
                Icons.savings_outlined,
                f,
                toneColor(context, Tone.success),
              ),
            for (final o in overlaps)
              _line(Icons.merge_type, 'Routes overlap: $o'),
            if (under.isNotEmpty)
              _line(
                Icons.trending_down,
                'Under half full: ${under.join(', ')}',
                toneColor(context, Tone.warning),
              ),
            sectionLabel(context, 'Bus occupancy'),
            for (final b in buses)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 5,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Bus ${b['number']}: ${b['allocated']} of ${b['capacity']} seats${b['usable'] == true ? '' : '  (not usable for allocation)'}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 3),
                    LinearProgressIndicator(
                      value: ((b['allocated'] as num) / (b['capacity'] as num))
                          .clamp(0.0, 1.0)
                          .toDouble(),
                      minHeight: 6,
                      color: navy,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ],
                ),
              ),
            sectionLabel(context, 'If a bus breaks down'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _bus,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Bus out of service',
                      ),
                      items: [
                        for (final b in _buses)
                          DropdownMenuItem(
                            value: b.id,
                            child: Text('Bus ${b.data()['busNumber']}'),
                          ),
                      ],
                      onChanged: (v) => _bus = v,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _replacement,
                    child: const Text('Find options'),
                  ),
                ],
              ),
            ),
            if (_repl != null) ...[
              _line(
                Icons.groups_outlined,
                '${_repl!['riders']} riders would need a bus',
              ),
              if (asList(_repl!['options']).isEmpty)
                _line(
                  Icons.info_outline,
                  'No single bus has enough free seats. Riders could be split across buses.',
                ),
              for (final o in asList(_repl!['options']))
                _line(
                  Icons.directions_bus_outlined,
                  'Bus ${o['bus']}: ${o['freeSeats']} free seats${o['spare'] == true ? ', spare bus' : ''}${o['hasDriver'] == true ? '' : ', no driver'}${o['driverAuthorised'] == true ? '' : ', driver not authorised here'}',
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(
                  'Do the replacement on the Emergency screen.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
            sectionLabel(context, 'By department'),
            for (final x in asList(d['departments']))
              ListTile(
                dense: true,
                title: Text('${x['dept']}'),
                trailing: Text('${x['onBus']} of ${x['students']} on a bus'),
              ),
          ],
        );
      },
    ),
  );
}
