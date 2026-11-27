import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:material_ui/material_ui.dart';
import '../../core/api.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

class DailyTransportPlanningPage extends StatefulWidget {
  const DailyTransportPlanningPage({super.key});

  @override
  State<DailyTransportPlanningPage> createState() =>
      _DailyTransportPlanningPageState();
}

class _DailyTransportPlanningPageState
    extends State<DailyTransportPlanningPage> {
  DateTime _date = DateTime.now();

  String get _dateKey =>
      '${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final value = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2024),
      lastDate: DateTime(2100),
    );
    if (value != null) setState(() => _date = value);
  }

  Future<void> _saveTemplate() async {
    final result = await formDialog(context, 'Normal day template', const [
      F('name', 'Template name'),
      F('weekdays', 'Weekdays', initial: 'Mon,Tue,Wed,Thu,Fri'),
      F(
        'specialDates',
        'Special dates (YYYY-MM-DD, comma separated)',
        multiline: true,
      ),
    ], action: 'Save');
    if (result == null || !mounted) return;
    await runAction(context, () async {
      final weekdays = (result['weekdays'] ?? '')
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      final specialDates = (result['specialDates'] ?? '')
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      await Api.call('saveTransportTemplate', {
        'name': result['name'],
        'weekdays': weekdays,
        'specialDates': specialDates,
      });
      return 'Normal day template saved.';
    });
  }

  Future<void> _rollover() async {
    await runAction(context, () async {
      final preview = await Api.call('previewAcademicRollover', {
        'date': _dateKey,
      });
      final changes = asList(preview['changes']);
      if (!mounted) return null;
      final confirmed = await confirm(
        context,
        'Confirm academic rollover',
        'Preview: ${changes.length} eligible student records will progress. Graduated, withdrawn and inactive students are excluded.',
        action: 'Apply rollover',
      );
      if (!confirmed) return null;
      final result = await Api.call('applyAcademicRollover', {
        'date': _dateKey,
        'confirmed': true,
      });
      return 'Academic rollover completed for ${result['count']} students.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final fs = FirebaseFirestore.instance;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _pickDate,
              icon: const Icon(Icons.calendar_month),
              label: Text(_dateKey),
            ),
            FilledButton.icon(
              onPressed: _saveTemplate,
              icon: const Icon(Icons.note_add),
              label: const Text('Normal Day Template'),
            ),
            FilledButton.tonalIcon(
              onPressed: _rollover,
              icon: const Icon(Icons.school),
              label: const Text('Academic rollover'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          'Normal Day Templates',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: fs.collection('transportTemplates').snapshots(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) return loading();
            final docs = snapshot.data!.docs;
            if (docs.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No reusable templates yet.'),
              );
            }
            return Column(
              children: [
                for (final doc in docs)
                  ListTile(
                    leading: Icon(
                      doc.data()['active'] == true
                          ? Icons.check_circle
                          : Icons.pause_circle,
                      color: doc.data()['active'] == true
                          ? toneColor(context, Tone.success)
                          : toneColor(context, Tone.neutral),
                    ),
                    title: Text('${doc.data()['name']}'),
                    subtitle: Text(
                      'Weekdays: ${(doc.data()['weekdays'] as List?)?.join(', ') ?? ''}',
                    ),
                    trailing: Wrap(
                      spacing: 4,
                      children: [
                        IconButton(
                          tooltip: 'Duplicate',
                          icon: const Icon(Icons.copy),
                          onPressed: () async {
                            await runAction(context, () async {
                              await Api.call('duplicateTransportTemplate', {
                                'templateId': doc.id,
                              });
                              return 'Template duplicated.';
                            });
                          },
                        ),
                        IconButton(
                          tooltip: doc.data()['active'] == true
                              ? 'Deactivate'
                              : 'Activate',
                          icon: Icon(
                            doc.data()['active'] == true
                                ? Icons.toggle_on
                                : Icons.toggle_off,
                          ),
                          onPressed: () async {
                            await runAction(context, () async {
                              await Api.call('setTransportTemplateActive', {
                                'templateId': doc.id,
                                'active': doc.data()['active'] != true,
                              });
                              return 'Template status updated.';
                            });
                          },
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        Text('Daily schedule', style: Theme.of(context).textTheme.titleMedium),
        StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: fs.doc('dailyTransportSchedules/$_dateKey').snapshots(),
          builder: (context, snapshot) {
            final data = snapshot.data?.data();
            if (data == null) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No daily schedule has been saved for this date. Use the attendance and recommendation workflow before publishing.',
                ),
              );
            }
            final demand = Map<String, dynamic>.from(
              data['demandByPlace'] as Map? ?? {},
            );
            final warnings =
                (data['warnings'] as List?)?.map((e) => '$e').toList() ??
                const <String>[];
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Status: ${data['status']}'),
                    Text('Attending: ${data['attendingCount']}'),
                    for (final entry in demand.entries)
                      Text('${entry.key}: ${entry.value} students'),
                    for (final warning in warnings)
                      Text(
                        warning,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
