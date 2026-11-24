import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/widgets.dart';

class StudentsPage extends StatefulWidget {
  const StudentsPage({super.key});
  @override
  State<StudentsPage> createState() => _StudentsPageState();
}

class _StudentsPageState extends State<StudentsPage> {
  String _f = 'all';
  String _q = '';

  bool _match(Map<String, dynamic> s) {
    final ok = switch (_f) {
      'unregistered' => s['authUid'] == null,
      'nostop' => s['authUid'] != null && s['approvedBoardingPointId'] == null,
      'unallocated' =>
        s['authUid'] != null &&
            s['approvedBoardingPointId'] != null &&
            s['allocationId'] == null,
      _ => true,
    };
    if (!ok) return false;
    if (_q.isEmpty) return true;
    return '${s['name']} ${s['registerNumber']} ${s['departmentId']} ${s['email']}'
        .toLowerCase()
        .contains(_q);
  }

  Future<void> _edit(Doc d) async {
    final s = d.data();
    final r = await formDialog(context, 'Edit student', [
      F('name', 'Name', initial: '${s['name']}'),
      F('departmentId', 'Department', initial: '${s['departmentId']}'),
      F(
        'academicYear',
        'Academic year (1-6)',
        initial: '${s['academicYear']}',
        number: true,
      ),
      F('mobile', 'Mobile', initial: '${s['mobile'] ?? ''}'),
    ]);
    if (r == null || !mounted) return;
    await runAction(context, () async {
      await Api.call('updateStudent', {
        'studentId': d.id,
        'name': r['name'],
        'departmentId': r['departmentId'],
        'academicYear': int.tryParse(r['academicYear'] ?? ''),
        'mobile': r['mobile'],
      });
      return 'Student updated.';
    });
  }

  Future<void> _invite(Doc d) => runAction(context, () async {
    final r = await Api.call('reissueInvite', {'studentId': d.id});
    if (mounted) {
      await showInviteDialog(
        context,
        name: '${d.data()['name']}',
        email: '${r['email']}',
        code: '${r['code']}',
        link: r['link'] as String?,
      );
    }
    return null;
  });

  Future<void> _cancel(Doc d) async {
    final r = await formDialog(context, 'Remove bus allocation', const [
      F('reason', 'Reason (required)'),
    ], action: 'Remove');
    if (r == null || !mounted) return;
    await runAction(context, () async {
      await Api.call('cancelAllocation', {
        'studentId': d.id,
        'reason': r['reason'],
      });
      return 'Allocation removed. The student can be allocated again.';
    });
  }

  Future<void> _move(Doc d) async {
    final buses = await FirebaseFirestore.instance
        .collection('buses')
        .orderBy('busNumber')
        .get();
    if (!mounted) return;
    final usable = buses.docs.where(
      (b) =>
          b.data()['availability'] == true &&
          b.data()['maintenanceStatus'] == 'ok',
    );
    final r = await formDialog(context, 'Move ${d.data()['name']}', [
      F(
        'bus',
        'New bus',
        choices: {for (final b in usable) b.id: 'Bus ${b.data()['busNumber']}'},
      ),
      const F('reason', 'Reason (required)'),
    ], action: 'Move');
    if (r == null || !mounted) return;
    await runAction(context, () async {
      await Api.call('moveStudent', {
        'studentId': d.id,
        'toBusId': r['bus'],
        'reason': r['reason'],
      });
      return 'Student moved. They keep the same stop.';
    });
  }

  Future<void> _manageBoardingPoints(Doc d) async {
    final snap = await FirebaseFirestore.instance
        .collection('boardingPoints')
        .orderBy('name')
        .get();
    if (!mounted) return;
    final approved = snap.docs
        .where(
          (p) =>
              p.data()['approvalStatus'] == 'approved' &&
              p.data()['status'] != 'inactive',
        )
        .toList();
    final s = d.data();
    final assigned = ((s['availableBoardingPointIds'] as List?) ?? [])
        .map((e) => '$e')
        .toSet();
    final currentStop = s['approvedBoardingPointId'] as String?;
    var hasActiveAllocation = s['allocationId'] != null;
    if (hasActiveAllocation) {
      final allocation = await FirebaseFirestore.instance
          .doc('allocations/${s['allocationId']}')
          .get();
      hasActiveAllocation =
          allocation.exists && allocation.data()?['status'] == 'active';
    }
    if (!mounted) return;

    final selected = <String>{...assigned};
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('Manage boarding points: ${s['name']}'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hasActiveAllocation)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        'This student has an active bus allocation. The currently selected stop cannot be removed until they are explicitly reallocated.',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  if (approved.isEmpty)
                    const Text('There are no approved boarding points.')
                  else
                    for (final p in approved)
                      CheckboxListTile(
                        value: selected.contains(p.id),
                        title: Text('${p.data()['name']}'),
                        subtitle: Text(
                          '${p.data()['roadDistanceKm']} km by road',
                        ),
                        onChanged: hasActiveAllocation && p.id == currentStop
                            ? null
                            : (v) => setState(() {
                                if (v == true) {
                                  selected.add(p.id);
                                } else {
                                  selected.remove(p.id);
                                }
                              }),
                      ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;
    await runAction(context, () async {
      final r = await Api.call('assignStudentBoardingPoints', {
        'studentId': d.id,
        'boardingPointIds': selected.toList(),
      });
      return 'Assigned ${r['assignedCount']} approved boarding point${r['assignedCount'] == 1 ? '' : 's'}.';
    });
  }

  Future<void> _copyAll() async {
    final snap = await FirebaseFirestore.instance
        .collection('students')
        .orderBy('registerNumber')
        .get();
    if (!mounted) return;
    await copyCsv(
      context,
      [
        'registerNumber',
        'name',
        'department',
        'year',
        'email',
        'registered',
        'stopChosen',
        'busAllocated',
      ],
      [
        for (final d in snap.docs.where((d) => _match(d.data())))
          [
            d['registerNumber'],
            d['name'],
            d['departmentId'],
            d['academicYear'],
            d['email'],
            d['authUid'] != null,
            d['approvedBoardingPointId'] != null,
            d['allocationId'] != null,
          ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                decoration: const InputDecoration(
                  labelText: 'Search name, register number, department',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
              ),
            ),
            IconButton(
              tooltip: 'Copy list as CSV',
              icon: const Icon(Icons.copy_all),
              onPressed: _copyAll,
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: DropdownButtonFormField<String>(
          initialValue: _f,
          decoration: const InputDecoration(labelText: 'Show'),
          items: const [
            DropdownMenuItem(value: 'all', child: Text('All students')),
            DropdownMenuItem(
              value: 'unregistered',
              child: Text('Not registered yet'),
            ),
            DropdownMenuItem(
              value: 'nostop',
              child: Text('Registered, no stop chosen'),
            ),
            DropdownMenuItem(
              value: 'unallocated',
              child: Text('Ready, no bus yet'),
            ),
          ],
          onChanged: (v) => setState(() => _f = v ?? 'all'),
        ),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: DocList(
          query: FirebaseFirestore.instance
              .collection('students')
              .orderBy('registerNumber'),
          filter: _match,
          empty: 'No students match. Import a student list to begin.',
          itemBuilder: (c, d) {
            final s = d.data();
            return ListTile(
              title: Text('${s['name']}  (${s['registerNumber']})'),
              subtitle: Wrap(
                children: [
                  chip('Dept ${s['departmentId']}'),
                  chip('Year ${s['academicYear']}'),
                  chip(
                    s['authUid'] == null ? 'Invited' : 'Registered',
                    s['authUid'] == null ? Colors.orange : Colors.green,
                  ),
                  chip(
                    s['approvedBoardingPointId'] == null
                        ? 'No stop'
                        : 'Stop chosen',
                    s['approvedBoardingPointId'] == null
                        ? Colors.orange
                        : Colors.green,
                  ),
                  chip(
                    s['allocationId'] == null ? 'No bus' : 'Bus allocated',
                    s['allocationId'] == null ? Colors.red : Colors.green,
                  ),
                ],
              ),
              trailing: PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'edit') {
                    await _edit(d);
                  } else if (v == 'invite') {
                    await _invite(d);
                  } else if (v == 'boarding') {
                    await _manageBoardingPoints(d);
                  } else if (v == 'cancel') {
                    await _cancel(d);
                  } else if (v == 'move') {
                    await _move(d);
                  } else if (v == 'remove' &&
                      await confirm(
                        c,
                        'Remove ${s['name']}?',
                        'Their invitation is deleted too. This cannot be undone.',
                        action: 'Remove',
                      ) &&
                      c.mounted) {
                    await runAction(c, () async {
                      await Api.call('removeStudent', {'studentId': d.id});
                      return 'Student removed.';
                    });
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'edit',
                    child: Text('Edit details'),
                  ),
                  const PopupMenuItem(
                    value: 'boarding',
                    child: Text('Manage Boarding Points'),
                  ),
                  if (s['authUid'] == null)
                    const PopupMenuItem(
                      value: 'invite',
                      child: Text('New invitation (code and QR)'),
                    ),
                  if (s['allocationId'] != null)
                    const PopupMenuItem(
                      value: 'move',
                      child: Text('Move to another bus'),
                    ),
                  if (s['allocationId'] != null)
                    const PopupMenuItem(
                      value: 'cancel',
                      child: Text('Remove bus allocation'),
                    ),
                  if (s['authUid'] == null)
                    const PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove student'),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    ],
  );
}

class ImportPage extends StatefulWidget {
  const ImportPage({super.key});
  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  List<Map<String, dynamic>> _rows = [];
  String? _fileName;
  Map<String, dynamic>? _check;
  List<Map<String, dynamic>> _invites = [];
  bool _busy = false;

  Future<void> _pick() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
      withData: true,
    );
    if (r == null || r.files.single.bytes == null) return;
    final text = utf8
        .decode(r.files.single.bytes!, allowMalformed: true)
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final table = const CsvToListConverter(
      shouldParseNumbers: false,
      eol: '\n',
    ).convert(text);
    if (table.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('The file has no data rows.')),
        );
      }
      return;
    }
    final head = table.first
        .map((h) => '$h'.trim().toLowerCase().replaceAll('\ufeff', ''))
        .toList();
    const keys = {
      'registernumber': 'registerNumber',
      'name': 'name',
      'departmentid': 'departmentId',
      'department': 'departmentId',
      'academicyear': 'academicYear',
      'year': 'academicYear',
      'email': 'email',
      'mobile': 'mobile',
    };
    final rows = <Map<String, dynamic>>[];
    for (final line in table.skip(1)) {
      if (line.every((v) => '$v'.trim().isEmpty)) continue;
      final m = <String, dynamic>{};
      for (var i = 0; i < head.length && i < line.length; i++) {
        final k = keys[head[i]];
        if (k != null) m[k] = '${line[i]}'.trim();
      }
      rows.add(m);
    }
    setState(() {
      _rows = rows;
      _fileName = r.files.single.name;
      _check = null;
      _invites = [];
    });
    await _run(true);
  }

  Future<void> _run(bool dry) async {
    setState(() => _busy = true);
    await runAction(context, () async {
      final r = await Api.call('importStudents', {
        'rows': _rows,
        'dryRun': dry,
      });
      if (dry) {
        _check = r;
        return null;
      }
      _invites = asList(r['invites']);
      _check = {'valid': 0, 'errors': r['errors']};
      return 'Imported ${r['imported']} students.';
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final errors = asList(_check?['errors']);
    final valid = (_check?['valid'] as num?)?.toInt() ?? 0;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Upload a CSV with these columns: registerNumber, name, departmentId, academicYear, email, mobile (optional). From Excel, use Save as CSV. Big files take a minute to write.',
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _pick,
          icon: const Icon(Icons.upload_file),
          label: Text(
            _fileName == null ? 'Choose CSV file' : 'Choose another file',
          ),
        ),
        if (_fileName != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text('$_fileName: ${_rows.length} rows read'),
          ),
        if (_check != null && _invites.isEmpty) ...[
          const SizedBox(height: 12),
          Text(
            '$valid ready to import, ${errors.length} with problems',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          for (final e in errors.take(50))
            ListTile(
              dense: true,
              leading: const Icon(Icons.error_outline, color: Colors.red),
              title: Text('${e['registerNumber'] ?? 'Line ${e['line']}'}'),
              subtitle: Text('${e['error']}'),
            ),
          if (valid > 0)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: FilledButton(
                onPressed: _busy ? null : () => _run(false),
                child: Text(_busy ? 'Importing...' : 'Import $valid students'),
              ),
            ),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Rows with problems are skipped. Fix them in the file and import again.',
            ),
          ),
        ],
        if (_invites.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            '${_invites.length} invitations created',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const Text(
            'Codes are shown only now. Copy the list, or tap a student for their code, QR and an email button. Each works once and expires in 14 days.',
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => copyCsv(
              context,
              ['registerNumber', 'name', 'email', 'code', 'link'],
              [
                for (final i in _invites)
                  [
                    i['registerNumber'],
                    i['name'],
                    i['email'],
                    i['code'],
                    i['link'],
                  ],
              ],
            ),
            icon: const Icon(Icons.copy),
            label: const Text('Copy invitation list'),
          ),
          for (final i in _invites.take(100))
            ListTile(
              dense: true,
              leading: const Icon(Icons.qr_code),
              title: Text('${i['name']}'),
              subtitle: Text('${i['registerNumber']}'),
              onTap: () => showInviteDialog(
                context,
                name: '${i['name']}',
                email: '${i['email']}',
                code: '${i['code']}',
                link: i['link'] as String?,
              ),
            ),
        ],
      ],
    );
  }
}
