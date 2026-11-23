import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../core/pdf_export.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

final _fs = FirebaseFirestore.instance;
String _rs(num n) => 'Rs ${n.toStringAsFixed(0)}';

// ---------------- Transport costs ----------------
class _CostData {
  final List<Doc> docs;
  final double income;
  final Map<String, String> names;
  _CostData(this.docs, this.income, this.names);

  double _amt(Doc d) => (d.data()['amount'] as num).toDouble();
  double get total => docs.fold(0.0, (s, d) => s + _amt(d));
  Map<String, double> _group(String Function(Map<String, dynamic>) key) {
    final m = <String, double>{};
    for (final d in docs) {
      m.update(key(d.data()), (v) => v + _amt(d), ifAbsent: () => _amt(d));
    }
    return Map.fromEntries(
      m.entries.toList()..sort((a, b) => b.value.compareTo(a.value)),
    );
  }

  Map<String, double> get byCategory => _group((x) => '${x['category']}');
  Map<String, double> get byBus => _group(
    (x) => x['busId'] == null
        ? 'No bus'
        : (names['${x['busId']}'] ?? '${x['busId']}'),
  );
}

class CostsPage extends StatefulWidget {
  const CostsPage({super.key});
  @override
  State<CostsPage> createState() => _CostsPageState();
}

class _CostsPageState extends State<CostsPage> {
  late Future<_CostData> _f;

  @override
  void initState() {
    super.initState();
    _f = _load();
  }

  Future<_CostData> _load() async {
    final ex = await _fs
        .collection('expenses')
        .orderBy('date', descending: true)
        .limit(1000)
        .get();
    final buses = await _fs.collection('buses').get();
    return _CostData(ex.docs, 0, {
      for (final b in buses.docs) b.id: 'Bus ${b.data()['busNumber']}',
    });
  }

  void _reload() => setState(() => _f = _load());

  Future<void> _add(_CostData d) async {
    final today = DateTime.now().toString().substring(0, 10);
    final r = await formDialog(context, 'Add expense', [
      const F(
        'category',
        'Category',
        initial: 'Fuel',
        choices: {
          'Fuel': 'Fuel',
          'Maintenance': 'Maintenance',
          'Salary': 'Driver salary',
          'Insurance': 'Insurance',
          'Tolls': 'Tolls',
          'Other': 'Other',
        },
      ),
      const F('amount', 'Amount (Rs)', number: true),
      F(
        'busId',
        'Bus (optional)',
        choices: {'': 'Not tied to one bus', ...d.names},
      ),
      F('date', 'Date (YYYY-MM-DD)', initial: today),
      const F('note', 'Note (optional)'),
    ]);
    if (r == null || !mounted) return;
    await runAction(context, () async {
      final amount = double.tryParse(r['amount'] ?? ''),
          date = DateTime.tryParse(r['date'] ?? '');
      if (amount == null || amount <= 0) throw 'Enter an amount above zero.';
      if (date == null) throw 'Enter the date as YYYY-MM-DD.';
      await _fs.collection('expenses').add({
        'amount': amount,
        'category': r['category'],
        'busId': (r['busId'] ?? '').isEmpty ? null : r['busId'],
        'note': r['note'],
        'date': Timestamp.fromDate(date),
        'createdBy': FirebaseAuth.instance.currentUser!.uid,
        'createdAt': FieldValue.serverTimestamp(),
      });
      _reload();
      return 'Expense saved.';
    });
  }

  List<List<String>> _rows(_CostData d) => [
    for (final x in d.docs.map((e) => e.data()))
      [
        fmt(x['date']).substring(0, 5),
        '${x['category']}',
        x['busId'] == null
            ? '-'
            : (d.names['${x['busId']}'] ?? '${x['busId']}'),
        _rs(x['amount'] as num),
        '${x['note'] ?? ''}',
      ],
  ];

  @override
  Widget build(BuildContext context) => FutureBuilder<_CostData>(
    future: _f,
    builder: (context, s) {
      if (s.hasError) {
        return EmptyState(
          'Could not load costs.\n${s.error}',
          icon: Icons.cloud_off,
        );
      }
      if (!s.hasData) return loading();
      final d = s.data!;
      return Scaffold(
        floatingActionButton: FloatingActionButton(
          onPressed: () => _add(d),
          child: const Icon(Icons.add),
        ),
        body: RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Total expenses'),
                      Text(
                        _rs(d.total),
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text('${d.docs.length} entries'),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => copyCsv(
                        context,
                        ['date', 'category', 'bus', 'amount', 'note'],
                        [for (final r in _rows(d)) r],
                      ),
                      icon: const Icon(Icons.copy_all),
                      label: const Text('Copy CSV'),
                    ),
                    TextButton.icon(
                      onPressed: () => exportPdf('RouteSync costs', [
                        PdfSection(
                          'Summary',
                          ['Item', 'Amount'],
                          [
                            ['Total expenses', _rs(d.total)],
                          ],
                        ),
                        PdfSection(
                          'By category',
                          ['Category', 'Amount'],
                          [
                            for (final e in d.byCategory.entries)
                              [e.key, _rs(e.value)],
                          ],
                        ),
                        PdfSection(
                          'By bus',
                          ['Bus', 'Amount'],
                          [
                            for (final e in d.byBus.entries)
                              [e.key, _rs(e.value)],
                          ],
                        ),
                        PdfSection('Expenses', [
                          'Date',
                          'Category',
                          'Bus',
                          'Amount',
                          'Note',
                        ], _rows(d)),
                      ]),
                      icon: const Icon(Icons.picture_as_pdf),
                      label: const Text('PDF'),
                    ),
                  ],
                ),
              ),
              sectionLabel(context, 'By category'),
              for (final e in d.byCategory.entries)
                _bar(e.key, e.value, d.total),
              sectionLabel(context, 'By bus'),
              for (final e in d.byBus.entries) _bar(e.key, e.value, d.total),
              sectionLabel(context, 'Recent expenses'),
              if (d.docs.isEmpty)
                const EmptyState(
                  'No expenses recorded yet.',
                  icon: Icons.receipt_long_outlined,
                ),
              for (final doc in d.docs.take(60))
                ListTile(
                  dense: true,
                  title: Text(
                    '${_rs(doc.data()['amount'] as num)}   ${doc.data()['category']}',
                  ),
                  subtitle: Text(
                    '${fmt(doc.data()['date']).substring(0, 5)}   ${doc.data()['busId'] == null ? 'No bus' : (d.names['${doc.data()['busId']}'] ?? '')}   ${doc.data()['note'] ?? ''}',
                  ),
                  trailing: IconButton(
                    tooltip: 'Delete (Super Admin)',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final c = context;
                      if (await confirm(
                            c,
                            'Delete this expense?',
                            'Only a Super Admin can delete expenses.',
                            action: 'Delete',
                          ) &&
                          c.mounted) {
                        await runAction(c, () async {
                          await doc.reference.delete();
                          _reload();
                          return 'Deleted.';
                        });
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );

  Widget _bar(String label, double v, double total) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label   ${_rs(v)}', style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 3),
        LinearProgressIndicator(
          value: total == 0 ? 0 : (v / total).clamp(0.0, 1.0),
          minHeight: 6,
          color: navy,
          borderRadius: BorderRadius.circular(3),
        ),
      ],
    ),
  );
}

// ---------------- On-time performance ----------------
class OnTimePage extends StatefulWidget {
  const OnTimePage({super.key});
  @override
  State<OnTimePage> createState() => _OnTimePageState();
}

class _OnTimePageState extends State<OnTimePage> {
  late Future<(List<Map<String, dynamic>>, Map<String, String>)> _f;

  @override
  void initState() {
    super.initState();
    _f = _load();
  }

  Future<(List<Map<String, dynamic>>, Map<String, String>)> _load() async {
    final j = await _fs
        .collection('journeys')
        .orderBy('arrivedAt', descending: true)
        .limit(600)
        .get();
    final b = await _fs.collection('buses').get();
    return (
      j.docs.map((d) => d.data()).toList(),
      {for (final x in b.docs) x.id: 'Bus ${x.data()['busNumber']}'},
    );
  }

  @override
  Widget build(
    BuildContext context,
  ) => FutureBuilder<(List<Map<String, dynamic>>, Map<String, String>)>(
    future: _f,
    builder: (context, s) {
      if (s.hasError) {
        return EmptyState(
          'Could not load the report.\n${s.error}',
          icon: Icons.cloud_off,
        );
      }
      if (!s.hasData) return loading();
      final trips = s.data!.$1, names = s.data!.$2;
      if (trips.isEmpty) {
        return const EmptyState(
          'No arrivals recorded yet. Set a "must reach college by" time on each route; arrivals are logged automatically.',
          icon: Icons.timer_outlined,
        );
      }
      final per = <String, List<Map<String, dynamic>>>{};
      for (final t in trips) {
        (per[names['${t['busId']}'] ?? '${t['busId']}'] ??= []).add(t);
      }
      final onTime = trips.where((t) => t['onTime'] == true).length;
      final rows = [
        for (final e in per.entries)
          [
            e.key,
            '${e.value.length}',
            '${(100 * e.value.where((t) => t['onTime'] == true).length / e.value.length).round()}%',
            '${(e.value.fold<num>(0, (a, t) => a + ((t['lateMinutes'] as num?) ?? 0)) / e.value.length).round()} min',
          ],
      ];
      return ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${(100 * onTime / trips.length).round()}% on time',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text('$onTime of ${trips.length} recorded arrivals'),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () => copyCsv(context, [
                    'bus',
                    'trips',
                    'onTime',
                    'avgLate',
                  ], rows),
                  icon: const Icon(Icons.copy_all),
                  label: const Text('Copy CSV'),
                ),
                TextButton.icon(
                  onPressed: () => exportPdf('RouteSync on-time performance', [
                    PdfSection('By bus', [
                      'Bus',
                      'Trips',
                      'On time',
                      'Avg late',
                    ], rows),
                  ]),
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('PDF'),
                ),
              ],
            ),
          ),
          sectionLabel(context, 'By bus'),
          for (final r in rows)
            ListTile(
              dense: true,
              title: Text(r[0]),
              subtitle: Text('${r[1]} trips, average ${r[3]} late'),
              trailing: chip(
                r[2],
                int.parse(r[2].replaceAll('%', '')) >= 80
                    ? Colors.green
                    : Colors.orange,
              ),
            ),
          sectionLabel(context, 'Latest arrivals'),
          for (final t in trips.take(30))
            ListTile(
              dense: true,
              leading: Icon(
                t['onTime'] == true
                    ? Icons.check_circle_outline
                    : Icons.schedule,
                color: t['onTime'] == true ? Colors.green : Colors.orange,
              ),
              title: Text(
                '${names['${t['busId']}'] ?? t['busId']}   due ${t['arrivalBy']}',
              ),
              subtitle: Text(
                '${fmt(t['arrivedAt'])}   ${(t['lateMinutes'] as num?) == 0 ? 'on time' : '${t['lateMinutes']} min late'}',
              ),
            ),
        ],
      );
    },
  );
}
