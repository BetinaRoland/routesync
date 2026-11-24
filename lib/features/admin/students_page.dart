import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
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

class _CsvDraft {
  final String fileName;
  final List<String> headers;
  final List<List<dynamic>> rows;
  final Map<String, int?> mapping;

  const _CsvDraft({
    required this.fileName,
    required this.headers,
    required this.rows,
    required this.mapping,
  });

  List<Map<String, dynamic>> mappedRows() => [
    for (final row in rows)
      {
        for (final entry in mapping.entries)
          if (entry.value != null &&
              entry.value! < row.length &&
              '${row[entry.value!]}'.trim().isNotEmpty)
            entry.key: '${row[entry.value!]}'.trim(),
      },
  ];
}

class _ImportPageState extends State<ImportPage> {
  _CsvDraft? _buses;
  _CsvDraft? _students;
  Map<String, dynamic>? _check;
  List<Map<String, dynamic>> _invites = [];
  bool _busy = false;
  String _duplicatePolicy = 'skip';

  static const _busFields = <String, String>{
    'busId': 'Bus ID',
    'busNumber': 'Bus number',
    'registrationNumber': 'Registration number',
    'capacity': 'Seating capacity',
    'routeId': 'Existing route ID',
    'driverId': 'Existing driver ID',
    'permittedRegionId': 'Permitted region ID',
    'status': 'Bus status',
  };
  static const _studentFields = <String, String>{
    'registerNumber': 'Register / roll number',
    'name': 'Student name',
    'departmentId': 'Department',
    'academicYear': 'Academic year (1-6)',
    'email': 'Email',
    'mobile': 'Mobile (optional)',
    'place': 'Place (optional)',
    'busId': 'Bus ID (optional)',
    'busNumber': 'Bus number (optional)',
    'routeId': 'Existing route ID (optional)',
    'driverId': 'Existing driver ID (optional)',
    'boardingPointId': 'Existing boarding-point ID (optional)',
  };
  static const _aliases = <String, List<String>>{
    'busId': ['busid', 'assignedbusid'],
    'busNumber': ['busnumber', 'busno', 'busnum'],
    'registrationNumber': [
      'registrationnumber',
      'regnumber',
      'vehicleregistration',
    ],
    'capacity': ['capacity', 'seatingcapacity', 'seatcapacity'],
    'routeId': ['routeid'],
    'driverId': ['driverid'],
    'permittedRegionId': ['permittedregionid', 'regionid'],
    'status': ['status', 'busstatus', 'activeinactivestatus'],
    'registerNumber': ['registernumber', 'rollnumber', 'studentid'],
    'name': ['name', 'studentname', 'fullname'],
    'departmentId': ['departmentid', 'department', 'course'],
    'academicYear': ['academicyear', 'year', 'classyear'],
    'email': ['email', 'emailaddress'],
    'mobile': ['mobile', 'mobilenumber', 'phone', 'contactnumber'],
    'place': ['place', 'region', 'address'],
    'boardingPointId': ['boardingpointid', 'stopid'],
  };

  String _normalized(String value) => value
      .toLowerCase()
      .replaceAll('\ufeff', '')
      .replaceAll(RegExp(r'[^a-z0-9]'), '');

  Future<void> _pick(bool buses) async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
      withData: true,
    );
    if (r == null || r.files.single.bytes == null) return;
    final expectedName = buses ? 'buses.csv' : 'students.csv';
    if (r.files.single.name.toLowerCase() != expectedName) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Choose the exact file $expectedName.')),
        );
      }
      return;
    }
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
    final headers = table.first.map((value) => '$value'.trim()).toList();
    final rawRows = table
        .skip(1)
        .where((row) => row.any((value) => '$value'.trim().isNotEmpty))
        .map((row) => List<dynamic>.from(row))
        .toList();
    final fields = buses ? _busFields : _studentFields;
    final mapping = <String, int?>{};
    for (final field in fields.keys) {
      final aliases = _aliases[field] ?? [field.toLowerCase()];
      final index = headers.indexWhere(
        (header) => aliases.contains(_normalized(header)),
      );
      mapping[field] = index < 0 ? null : index;
    }
    final draft = _CsvDraft(
      fileName: r.files.single.name,
      headers: headers,
      rows: rawRows,
      mapping: mapping,
    );
    setState(() {
      if (buses) {
        _buses = draft;
      } else {
        _students = draft;
      }
      _check = null;
      _invites = [];
    });
    await _run(true);
  }

  void _mapColumn(bool buses, String field, int? index) {
    final source = buses ? _buses : _students;
    if (source == null) return;
    final next = _CsvDraft(
      fileName: source.fileName,
      headers: source.headers,
      rows: source.rows,
      mapping: {...source.mapping, field: index},
    );
    setState(() {
      if (buses) {
        _buses = next;
      } else {
        _students = next;
      }
      _check = null;
    });
  }

  List<Widget> _mappingFields(bool buses, _CsvDraft? source) {
    if (source == null) return const [];
    final fields = buses ? _busFields : _studentFields;
    return [
      ExpansionTile(
        title: Text('Map ${buses ? 'bus' : 'student'} columns'),
        children: [
          for (final entry in fields.entries)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<int?>(
                initialValue: source.mapping[entry.key],
                decoration: InputDecoration(labelText: entry.value),
                items: [
                  const DropdownMenuItem<int?>(
                    value: null,
                    child: Text('Not mapped'),
                  ),
                  for (var index = 0; index < source.headers.length; index++)
                    DropdownMenuItem<int?>(
                      value: index,
                      child: Text(
                        source.headers[index].isEmpty
                            ? 'Column ${index + 1}'
                            : source.headers[index],
                      ),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (index) => _mapColumn(buses, entry.key, index),
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ];
  }

  Future<void> _run(bool dry) async {
    if (_buses == null && _students == null) return;
    var confirmedUpdates = false;
    if (!dry && _duplicatePolicy == 'update') {
      confirmedUpdates =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Confirm updates'),
              content: const Text(
                'Existing bus and student roster fields may be updated. Existing student allocations and account IDs will be preserved. Continue?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Confirm updates'),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmedUpdates) return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    await runAction(context, () async {
      final result = await Api.call('importCollegeData', {
        'busRows': _buses?.mappedRows() ?? const [],
        'studentRows': _students?.mappedRows() ?? const [],
        'dryRun': dry,
        'duplicatePolicy': _duplicatePolicy,
        'confirmedUpdates': confirmedUpdates,
      });
      _check = result;
      if (dry) return null;
      _invites = asList(result['invites']);
      return 'Imported ${result['importedBuses'] ?? 0} buses and ${result['importedStudents'] ?? 0} students; created ${result['createdAllocations'] ?? 0} allocations.';
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final errors = asList(_check?['errors']);
    final validBuses = (_check?['validBuses'] as num?)?.toInt() ?? 0;
    final validStudents = (_check?['validStudents'] as num?)?.toInt() ?? 0;
    final allocations = (_check?['allocations'] as num?)?.toInt() ?? 0;
    final notAllocated = asList(_check?['notAllocatedRows']);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const Text('Duplicates'),
            const SizedBox(width: 12),
            DropdownButton<String>(
              value: _duplicatePolicy,
              items: const [
                DropdownMenuItem(value: 'skip', child: Text('Skip')),
                DropdownMenuItem(value: 'update', child: Text('Update')),
              ],
              onChanged: _busy
                  ? null
                  : (value) =>
                        setState(() => _duplicatePolicy = value ?? 'skip'),
            ),
          ],
        ),
        const Text(
          'Import buses.csv and students.csv only. Column mappings are editable. New students are roster records; an active allocation is created only when an existing account, bus, route, driver and approved boarding point all validate.',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _pick(true),
              icon: const Icon(Icons.directions_bus),
              label: Text(
                _buses == null ? 'Choose buses.csv' : 'Replace buses.csv',
              ),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _pick(false),
              icon: const Icon(Icons.people),
              label: Text(
                _students == null
                    ? 'Choose students.csv'
                    : 'Replace students.csv',
              ),
            ),
            FilledButton.tonal(
              onPressed: _busy || (_buses == null && _students == null)
                  ? null
                  : () => _run(true),
              child: const Text('Preview import'),
            ),
          ],
        ),
        if (_buses != null) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.directions_bus),
            title: Text(_buses!.fileName),
            subtitle: Text('${_buses!.rows.length} rows'),
          ),
          ..._mappingFields(true, _buses),
        ],
        if (_students != null) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.people),
            title: Text(_students!.fileName),
            subtitle: Text('${_students!.rows.length} rows'),
          ),
          ..._mappingFields(false, _students),
          ExpansionTile(
            title: const Text('Student row preview (first 5)'),
            children: [
              for (final row in _students!.mappedRows().take(5))
                ListTile(
                  dense: true,
                  title: Text(
                    '${row['registerNumber'] ?? 'Missing register number'} - '
                    '${row['name'] ?? 'Missing name'}',
                  ),
                  subtitle: Text(
                    '${row['departmentId'] ?? ''}, year ${row['academicYear'] ?? ''}; '
                    'email ${row['email'] ?? ''}; bus '
                    '${row['busId'] ?? row['busNumber'] ?? 'not provided'}; '
                    'boarding point ${row['boardingPointId'] ?? 'not provided'}',
                  ),
                ),
            ],
          ),
        ],
        if (_buses != null) ...[
          ExpansionTile(
            title: const Text('Bus row preview (first 5)'),
            children: [
              for (final row in _buses!.mappedRows().take(5))
                ListTile(
                  dense: true,
                  title: Text(
                    'Bus ${row['busNumber'] ?? 'missing number'} '
                    '(${row['busId'] ?? 'ID derived from number'})',
                  ),
                  subtitle: Text(
                    'Capacity ${row['capacity'] ?? 'missing'}; '
                    'route ${row['routeId'] ?? 'not provided'}; '
                    'driver ${row['driverId'] ?? 'not provided'}',
                  ),
                ),
            ],
          ),
        ],
        if (_check != null) ...[
          const SizedBox(height: 12),
          Text(
            _check!['dryRun'] == true
                ? '$validBuses buses and $validStudents students ready; '
                      '$allocations active allocations qualify; '
                      '${notAllocated.length} students will remain Not Allocated; '
                      '${errors.length} validation issues'
                : 'Import complete: ${_check!['importedBuses'] ?? 0} buses, '
                      '${_check!['importedStudents'] ?? 0} students, '
                      '${_check!['createdAllocations'] ?? 0} allocations; '
                      '${notAllocated.length} students Not Allocated; '
                      '${errors.length} validation issues',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          for (final row in notAllocated.take(50))
            ListTile(
              dense: true,
              leading: const Icon(Icons.info_outline),
              title: Text('${row['studentId'] ?? 'Line ${row['line']}'}'),
              subtitle: Text('${row['reason']}'),
            ),
          for (final e in errors.take(50))
            ListTile(
              dense: true,
              leading: const Icon(Icons.error_outline, color: Colors.red),
              title: Text(
                '${e['registerNumber'] ?? e['id'] ?? 'Line ${e['line']}'}',
              ),
              subtitle: Text('${e['error']}'),
            ),
          if (errors.isNotEmpty || notAllocated.isNotEmpty)
            OutlinedButton.icon(
              onPressed: () => copyCsv(
                context,
                [
                  'category',
                  'line',
                  'id',
                  'registerNumber',
                  'warning',
                  'error',
                ],
                [
                  for (final e in errors)
                    [
                      e['category'],
                      e['line'],
                      e['id'],
                      e['registerNumber'],
                      e['warning'] ?? false,
                      e['error'],
                    ],
                  for (final e in notAllocated)
                    [
                      'student',
                      e['line'],
                      e['studentId'],
                      e['registerNumber'],
                      false,
                      e['reason'],
                    ],
                ],
              ),
              icon: const Icon(Icons.copy),
              label: const Text('Copy validation report as CSV'),
            ),
          if (_check!['dryRun'] == true && validBuses + validStudents > 0)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: FilledButton(
                onPressed: _busy ? null : () => _run(false),
                child: Text(
                  _busy
                      ? 'Importing...'
                      : 'Import $validBuses buses and $validStudents students',
                ),
              ),
            ),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Invalid roster rows are skipped. Valid roster rows remain separate from active allocations if any relationship is missing or invalid. Existing allocations are preserved.',
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
