import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/pdf_export.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../services/expenses.dart';

final _fs = FirebaseFirestore.instance;
String _rs(num n) => '₹${n.toStringAsFixed(2)}';

// ---------------- Transport costs ----------------
class CostsPage extends StatefulWidget {
  final String role;
  const CostsPage({super.key, required this.role});
  @override
  State<CostsPage> createState() => _CostsPageState();
}

class _CostsPageState extends State<CostsPage> {
  static const _pageSize = 50;
  bool get _canManage => canManageExpenseRecords(widget.role);
  bool _loading = true;
  String? _error;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _docs = [];
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _buses = [];
  Map<String, String> _recorders = {};
  String _search = '', _busFilter = '', _categoryFilter = '';
  DateTime? _fromDate, _toDate;
  int _visibleCount = _pageSize;
  int? _year;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final expenses = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      final baseQuery = _fs
          .collection('expenses')
          .orderBy(FieldPath.documentId)
          .limit(250);
      QueryDocumentSnapshot<Map<String, dynamic>>? last;
      while (true) {
        final query = last == null
            ? baseQuery
            : baseQuery.startAfterDocument(last);
        final page = await query.get();
        expenses.addAll(page.docs);
        if (page.docs.length < 250) break;
        last = page.docs.last;
      }
      expenses.sort((a, b) {
        final ad = expenseDateFrom(a.data()) ?? DateTime(1970);
        final bd = expenseDateFrom(b.data()) ?? DateTime(1970);
        return bd.compareTo(ad);
      });
      final buses = await _fs.collection('buses').orderBy('busNumber').get();
      final recorderIds = expenses
          .map((d) => expenseRecordedByFrom(d.data()))
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();
      final recorders = <String, String>{};
      for (var i = 0; i < recorderIds.length; i += 30) {
        final ids = recorderIds.skip(i).take(30).toList();
        final users = await _fs
            .collection('users')
            .where(FieldPath.documentId, whereIn: ids)
            .get();
        for (final user in users.docs) {
          recorders[user.id] =
              '${user.data()['name'] ?? user.data()['email'] ?? user.id}';
        }
      }
      if (!mounted) return;
      setState(() {
        _docs = expenses;
        _buses = buses.docs;
        _recorders = recorders;
        _year ??= expenses
            .map((d) => expenseDateFrom(d.data())?.year)
            .whereType<int>()
            .fold<int>(
              DateTime.now().year,
              (year, item) => item > year ? item : year,
            );
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Map<String, dynamic> _recordData(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    return {
      ...data,
      'busNumber':
          data['busNumber'] ??
          (data['busId'] == null ? 'No bus' : _busNumber('${data['busId']}')),
    };
  }

  List<Map<String, dynamic>> get _allRecords => _docs.map(_recordData).toList();

  List<QueryDocumentSnapshot<Map<String, dynamic>>> get _filteredDocs =>
      _docs.where((doc) {
        final data = doc.data();
        final date = expenseDateFrom(data);
        if (_busFilter.isNotEmpty && data['busId'] != _busFilter) return false;
        if (_categoryFilter.isNotEmpty && data['category'] != _categoryFilter) {
          return false;
        }
        if (_fromDate != null &&
            (date == null || date.isBefore(_dayStart(_fromDate!)))) {
          return false;
        }
        if (_toDate != null &&
            (date == null || date.isAfter(_dayEnd(_toDate!)))) {
          return false;
        }
        if (_search.isNotEmpty) {
          final bus = '${data['busNumber'] ?? _busNumber('${data['busId']}')}';
          final recorder = _recorders[expenseRecordedByFrom(data)] ?? '';
          final text = [
            bus,
            data['category'],
            expenseDescriptionFrom(data),
            data['vendorName'],
            recorder,
          ].join(' ').toLowerCase();
          if (!text.contains(_search.toLowerCase())) return false;
        }
        return true;
      }).toList();

  static DateTime _dayStart(DateTime date) =>
      DateTime(date.year, date.month, date.day);
  static DateTime _dayEnd(DateTime date) =>
      DateTime(date.year, date.month, date.day, 23, 59, 59, 999);

  String _busNumber(String busId) {
    for (final bus in _buses) {
      if (bus.id == busId) return '${bus.data()['busNumber']}';
    }
    return busId;
  }

  ExpenseSummary get _summary => ExpenseSummary.fromRecords(_allRecords);

  Future<void> _edit([QueryDocumentSnapshot<Map<String, dynamic>>? doc]) async {
    if (!_canManage) return;
    final old = doc?.data();
    if (doc != null &&
        ![
          'expenseId',
          'busId',
          'busNumber',
          'category',
          'amount',
          'description',
          'expenseDate',
          'vendorName',
          'receiptUrl',
          'recordedBy',
          'recordedByRole',
          'createdAt',
          'updatedAt',
          'updatedBy',
        ].every(old!.containsKey)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Legacy expenses are read-only and cannot be edited.',
            ),
          ),
        );
      }
      return;
    }
    final result = await showDialog<_ExpenseFormResult>(
      context: context,
      builder: (context) => _ExpenseFormDialog(buses: _buses, existing: old),
    );
    if (result == null || !mounted) return;
    final success = await runAction(context, () async {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw 'Sign in again before recording an expense.';
      final ref = doc?.reference ?? _fs.collection('expenses').doc();
      var receiptUrl = old?['receiptUrl'] as String?;
      if (result.receiptBytes != null) {
        final extension = result.receiptExtension!;
        final contentType = switch (extension) {
          'jpg' || 'jpeg' => 'image/jpeg',
          'png' => 'image/png',
          _ => 'application/pdf',
        };
        final receipt = FirebaseStorage.instance.ref().child(
          'expenses/${ref.id}/receipt_${DateTime.now().microsecondsSinceEpoch}.$extension',
        );
        await receipt.putData(
          result.receiptBytes!,
          SettableMetadata(contentType: contentType),
        );
        receiptUrl = await receipt.getDownloadURL();
      }
      final draft = result.draft;
      final values = <String, dynamic>{
        'expenseId': ref.id,
        'busId': draft.busId,
        'busNumber': _busNumber(draft.busId),
        'category': draft.category,
        'amount': double.parse(draft.amount.trim()),
        'description': draft.description.trim(),
        'expenseDate': Timestamp.fromDate(draft.expenseDate!),
        'vendorName': result.vendorName.isEmpty ? null : result.vendorName,
        'receiptUrl': receiptUrl,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': user.uid,
      };
      if (doc == null) {
        await ref.set({
          ...values,
          'recordedBy': user.uid,
          'recordedByRole': 'routeAdmin',
          'createdAt': FieldValue.serverTimestamp(),
        });
      } else {
        final history = _fs.collection('expenseHistory').doc();
        final batch = _fs.batch();
        batch.update(ref, values);
        batch.set(history, {
          'expenseId': ref.id,
          'recordedBy': user.uid,
          'recordedByRole': 'routeAdmin',
          'changedAt': FieldValue.serverTimestamp(),
          'previousValues': old,
        });
        await batch.commit();
      }
      await _load();
      return doc == null ? 'Expense saved.' : 'Expense updated.';
    });
    if (!success || !mounted) return;
  }

  String _dateLabel(Map<String, dynamic> data) {
    final date = expenseDateFrom(data);
    if (date == null) return '-';
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  List<List<String>> _reportRows(List<Map<String, dynamic>> records) => [
    for (final data in records)
      [
        _dateLabel(data),
        '${data['busNumber'] ?? _busNumber('${data['busId'] ?? ''}')}',
        '${data['category'] ?? 'Other Expenses'}',
        expenseDescriptionFrom(data),
        _rs((data['amount'] as num?) ?? 0),
        _recorders[expenseRecordedByFrom(data)] ?? expenseRecordedByFrom(data),
        data['receiptUrl'] == null ? 'No' : 'Yes',
      ],
  ];

  Future<bool> _exportExcel(List<Map<String, dynamic>> records) async {
    final workbook = Excel.createExcel();
    final sheet = workbook['Expenses'];
    sheet.appendRow([
      TextCellValue('Date'),
      TextCellValue('Bus number'),
      TextCellValue('Category'),
      TextCellValue('Description'),
      TextCellValue('Amount (INR)'),
      TextCellValue('Recorded by'),
      TextCellValue('Receipt'),
    ]);
    for (final record in records) {
      final row = _reportRows([record]).single;
      sheet.appendRow([
        for (var i = 0; i < row.length; i++)
          i == 4
              ? DoubleCellValue(((record['amount'] as num?) ?? 0).toDouble())
              : TextCellValue(row[i]),
      ]);
    }
    final summary = _summary;
    final summarySheet = workbook['Summary'];
    summarySheet.appendRow([
      TextCellValue('Section'),
      TextCellValue('Item'),
      TextCellValue('Amount (INR)'),
    ]);
    void addSummaryRow(String section, String item, double amount) {
      summarySheet.appendRow([
        TextCellValue(section),
        TextCellValue(item),
        DoubleCellValue(amount),
      ]);
    }

    addSummaryRow('Total', 'All expenses', summary.total);
    for (final entry in summary.byCategory.entries) {
      addSummaryRow('Category', entry.key, entry.value);
    }
    for (final entry in summary.byBus.entries) {
      addSummaryRow('Bus', entry.key, entry.value);
    }
    for (final entry in summary.byMonth.entries) {
      addSummaryRow('Month', entry.key, entry.value);
    }
    for (final entry in summary.byYear.entries) {
      addSummaryRow('Year', entry.key, entry.value);
    }
    final bytes = workbook.save();
    if (bytes == null) throw 'Could not generate the Excel report.';
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save expense report',
      fileName: 'routesync_expense_report.xlsx',
      type: FileType.custom,
      allowedExtensions: const ['xlsx'],
      bytes: Uint8List.fromList(bytes),
    );
    return path != null;
  }

  Future<void> _showDetails(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final data = doc.data();
    final date = _dateLabel(data);
    final bus = '${data['busNumber'] ?? _busNumber('${data['busId'] ?? ''}')}';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Expense details'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _detail('Expense ID', doc.id),
                _detail('Date', date),
                _detail('Bus', bus),
                _detail('Category', '${data['category'] ?? 'Other Expenses'}'),
                _detail('Amount', _rs((data['amount'] as num?) ?? 0)),
                _detail('Description', expenseDescriptionFrom(data)),
                if ('${data['vendorName'] ?? ''}'.isNotEmpty)
                  _detail('Vendor / service provider', '${data['vendorName']}'),
                _detail(
                  'Recorded by',
                  _recorders[expenseRecordedByFrom(data)] ??
                      expenseRecordedByFrom(data),
                ),
                _detail('Role', '${data['recordedByRole'] ?? 'Legacy record'}'),
                _detail('Created', fmt(data['createdAt'])),
                _detail('Last updated', fmt(data['updatedAt'])),
                if (data['receiptUrl'] != null) ...[
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      final url = Uri.tryParse('${data['receiptUrl']}');
                      if (url == null ||
                          !await launchUrl(
                            url,
                            mode: LaunchMode.externalApplication,
                          )) {
                        if (dialogContext.mounted) {
                          ScaffoldMessenger.of(dialogContext).showSnackBar(
                            const SnackBar(
                              content: Text('Could not open the receipt.'),
                            ),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.receipt_long_outlined),
                    label: const Text('Open receipt'),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _detail(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(child: SelectableText(value.isEmpty ? '-' : value)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!canViewExpenseRecords(widget.role)) {
      return const EmptyState(
        'You do not have permission to view expense records.',
        icon: Icons.lock_outline,
      );
    }
    if (_loading) return loading();
    if (_error != null) {
      return EmptyState(
        'Could not load expenses.\n$_error',
        icon: Icons.cloud_off,
      );
    }
    final summary = _summary;
    final filteredDocs = _filteredDocs;
    final filtered = filteredDocs.map(_recordData).toList();
    final years = summary.byYear.keys.map(int.parse).toList()..sort();
    final selectedYear = years.contains(_year)
        ? _year!
        : (years.isEmpty ? DateTime.now().year : years.last);
    final monthEntries =
        summary.byMonth.entries
            .where((entry) => entry.key.startsWith('$selectedYear-'))
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    return Scaffold(
      floatingActionButton: !_canManage
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _edit(),
              icon: const Icon(Icons.add),
              label: const Text('Add expense'),
            ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 96),
          children: [
            if (!_canManage)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(14),
                  child: Text(
                    'Read-only overview across all buses. Expense entry and editing are restricted to Route Admins.',
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _summaryCard('Total expenses', summary.total, Icons.payments),
                  _summaryCard('Fuel', summary.fuel, Icons.local_gas_station),
                  _summaryCard(
                    'Maintenance',
                    summary.maintenance,
                    Icons.build_outlined,
                  ),
                  _summaryCard(
                    'Other expenses',
                    summary.other,
                    Icons.receipt_long_outlined,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      await runAction(context, () async {
                        final saved = await _exportExcel(filtered);
                        return saved ? 'Excel report saved.' : null;
                      });
                    },
                    icon: const Icon(Icons.table_view_outlined),
                    label: const Text('Export Excel'),
                  ),
                  TextButton.icon(
                    onPressed: () => runAction(context, () async {
                      await exportPdf('RouteSync expense report', [
                        PdfSection(
                          'Summary',
                          ['Item', 'Amount'],
                          [
                            ['Total expenses', _rs(summary.total)],
                            ['Fuel expenses', _rs(summary.fuel)],
                            ['Maintenance expenses', _rs(summary.maintenance)],
                            ['Other expenses', _rs(summary.other)],
                          ],
                        ),
                        PdfSection(
                          'By category',
                          ['Category', 'Amount'],
                          [
                            for (final entry in summary.byCategory.entries)
                              [entry.key, _rs(entry.value)],
                          ],
                        ),
                        PdfSection(
                          'By bus',
                          ['Bus', 'Amount'],
                          [
                            for (final entry in summary.byBus.entries)
                              [entry.key, _rs(entry.value)],
                          ],
                        ),
                        PdfSection(
                          'Monthly summary',
                          ['Month', 'Amount'],
                          [
                            for (final entry in summary.byMonth.entries)
                              [entry.key, _rs(entry.value)],
                          ],
                        ),
                        PdfSection(
                          'Yearly summary',
                          ['Year', 'Amount'],
                          [
                            for (final entry in summary.byYear.entries)
                              [entry.key, _rs(entry.value)],
                          ],
                        ),
                        PdfSection('Expenses matching filters', [
                          'Date',
                          'Bus number',
                          'Category',
                          'Description',
                          'Amount',
                          'Recorded by',
                          'Receipt',
                        ], _reportRows(filtered)),
                      ]);
                      return 'PDF report generated.';
                    }),
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                    label: const Text('Export PDF'),
                  ),
                  TextButton.icon(
                    onPressed: () => copyCsv(context, const [
                      'Date',
                      'Bus number',
                      'Category',
                      'Description',
                      'Amount',
                      'Recorded by',
                      'Receipt',
                    ], _reportRows(filtered)),
                    icon: const Icon(Icons.copy_all_outlined),
                    label: const Text('Copy CSV'),
                  ),
                  IconButton(
                    tooltip: 'Refresh expenses',
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            sectionLabel(context, 'Category-wise expense breakdown'),
            if (summary.byCategory.isEmpty)
              const EmptyState(
                'No expenses recorded yet.',
                icon: Icons.receipt_long_outlined,
              )
            else
              for (final entry in _sorted(summary.byCategory))
                _bar(entry.key, entry.value, summary.total),
            sectionLabel(context, 'Bus-wise expense comparison'),
            if (summary.byBus.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('No bus expenses to compare.'),
              )
            else
              for (final entry in _sorted(summary.byBus))
                _bar(entry.key, entry.value, summary.total),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
              child: Row(
                children: [
                  Expanded(child: sectionLabel(context, 'Monthly expenses')),
                  DropdownButton<int>(
                    value: selectedYear,
                    items: [
                      for (final year in years.isEmpty ? [selectedYear] : years)
                        DropdownMenuItem(value: year, child: Text('$year')),
                    ],
                    onChanged: (value) => setState(() => _year = value),
                  ),
                ],
              ),
            ),
            if (monthEntries.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('No monthly expenses for this year.'),
              )
            else
              for (final entry in monthEntries)
                _bar(
                  _monthLabel(entry.key),
                  entry.value,
                  summary.byYear['$selectedYear'] ?? 0,
                ),
            sectionLabel(context, 'Yearly expense summary'),
            if (years.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('No yearly expenses to summarize.'),
              )
            else
              for (final year in years.reversed)
                ListTile(
                  dense: true,
                  title: Text('$year'),
                  trailing: Text(_rs(summary.byYear['$year']!)),
                ),
            sectionLabel(context, 'Expense history'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: TextField(
                controller: _searchController,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  labelText: 'Search expenses',
                  hintText: 'Bus, category, description, vendor or recorder',
                ),
                onChanged: (value) => setState(() {
                  _search = value.trim();
                  _visibleCount = _pageSize;
                }),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  SizedBox(
                    width: 220,
                    child: DropdownButtonFormField<String>(
                      initialValue: _busFilter,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Bus'),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('All buses'),
                        ),
                        for (final bus in _buses)
                          DropdownMenuItem(
                            value: bus.id,
                            child: Text('Bus ${bus.data()['busNumber']}'),
                          ),
                      ],
                      onChanged: (value) => setState(() {
                        _busFilter = value ?? '';
                        _visibleCount = _pageSize;
                      }),
                    ),
                  ),
                  SizedBox(
                    width: 250,
                    child: DropdownButtonFormField<String>(
                      initialValue: _categoryFilter,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Category'),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('All categories'),
                        ),
                        for (final category in expenseCategories)
                          DropdownMenuItem(
                            value: category,
                            child: Text(category),
                          ),
                      ],
                      onChanged: (value) => setState(() {
                        _categoryFilter = value ?? '';
                        _visibleCount = _pageSize;
                      }),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final selected = await showDatePicker(
                        context: context,
                        initialDate: _fromDate ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                        helpText: 'Start date',
                      );
                      if (selected != null) {
                        setState(() {
                          _fromDate = selected;
                          _visibleCount = _pageSize;
                        });
                      }
                    },
                    icon: const Icon(Icons.calendar_today_outlined),
                    label: Text(
                      _fromDate == null ? 'From date' : _shortDate(_fromDate!),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final selected = await showDatePicker(
                        context: context,
                        initialDate: _toDate ?? _fromDate ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                        helpText: 'End date',
                      );
                      if (selected != null) {
                        setState(() {
                          _toDate = selected;
                          _visibleCount = _pageSize;
                        });
                      }
                    },
                    icon: const Icon(Icons.event_outlined),
                    label: Text(
                      _toDate == null ? 'To date' : _shortDate(_toDate!),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _busFilter = '';
                      _categoryFilter = '';
                      _fromDate = null;
                      _toDate = null;
                      _search = '';
                      _searchController.clear();
                      _visibleCount = _pageSize;
                    }),
                    child: const Text('Clear filters'),
                  ),
                ],
              ),
            ),
            if (filteredDocs.isEmpty)
              const EmptyState(
                'No expenses match these filters.',
                icon: Icons.search_off_outlined,
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Text('${filteredDocs.length} expense records'),
              ),
              for (final doc in filteredDocs.take(_visibleCount))
                _expenseTile(doc, _recordData(doc)),
              if (_visibleCount < filteredDocs.length)
                Center(
                  child: TextButton(
                    onPressed: () => setState(() => _visibleCount += _pageSize),
                    child: const Text('Load more expenses'),
                  ),
                ),
            ],
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Cost & Expenses records bus operating expenses only. Student bus fees and payments remain managed by the college payment system.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryCard(String title, double value, IconData icon) => SizedBox(
    width: 240,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: navy),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 4),
                  Text(
                    _rs(value),
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  List<MapEntry<String, double>> _sorted(Map<String, double> values) =>
      values.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

  Widget _bar(String label, double v, double total) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
            Text(_rs(v), style: const TextStyle(fontSize: 13)),
          ],
        ),
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

  Widget _expenseTile(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    Map<String, dynamic> data,
  ) {
    final legacy = !data.containsKey('expenseId');
    final recorder = expenseRecordedByFrom(data);
    final amount = data['amount'] as num? ?? 0;
    return Card(
      child: ListTile(
        isThreeLine: true,
        leading: Icon(
          data['receiptUrl'] == null
              ? Icons.receipt_long_outlined
              : Icons.receipt,
          color: navy,
        ),
        title: Text(
          '${_dateLabel(data)}  ·  Bus ${data['busNumber'] ?? _busNumber('${data['busId'] ?? ''}')}  ·  ${_rs(amount)}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${data['category'] ?? 'Other Expenses'}  ·  ${expenseDescriptionFrom(data)}\n'
          'Recorded by ${_recorders[recorder] ?? recorder} '
          '(${data['recordedByRole'] ?? 'legacy record'})  ·  '
          '${data['receiptUrl'] == null ? 'No receipt' : 'Receipt attached'}'
          '${legacy ? '  ·  Legacy record (read-only)' : ''}',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => _showDetails(doc),
        trailing: PopupMenuButton<String>(
          tooltip: 'Expense actions',
          onSelected: (action) {
            if (action == 'view') _showDetails(doc);
            if (action == 'edit') _edit(doc);
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'view', child: Text('View details')),
            if (_canManage && !legacy)
              const PopupMenuItem(value: 'edit', child: Text('Edit')),
          ],
        ),
      ),
    );
  }
}

String _shortDate(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

String _monthLabel(String key) {
  final parts = key.split('-');
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[int.parse(parts[1]) - 1]} ${parts[0]}';
}

class _ExpenseFormResult {
  final ExpenseDraft draft;
  final String vendorName;
  final Uint8List? receiptBytes;
  final String? receiptExtension;

  const _ExpenseFormResult({
    required this.draft,
    required this.vendorName,
    required this.receiptBytes,
    required this.receiptExtension,
  });
}

class _ExpenseFormDialog extends StatefulWidget {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> buses;
  final Map<String, dynamic>? existing;

  const _ExpenseFormDialog({required this.buses, this.existing});

  @override
  State<_ExpenseFormDialog> createState() => _ExpenseFormDialogState();
}

class _ExpenseFormDialogState extends State<_ExpenseFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _description;
  late final TextEditingController _vendor;
  String? _busId, _category;
  DateTime? _date;
  Uint8List? _receiptBytes;
  String? _receiptName, _receiptExtension, _error;

  @override
  void initState() {
    super.initState();
    final old = widget.existing;
    _amount = TextEditingController(text: '${old?['amount'] ?? ''}');
    _description = TextEditingController(
      text: expenseDescriptionFrom(old ?? const {}),
    );
    _vendor = TextEditingController(text: '${old?['vendorName'] ?? ''}');
    _busId = old?['busId'] as String?;
    _category = old?['category'] as String?;
    _date = expenseDateFrom(old ?? const {});
  }

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    _vendor.dispose();
    super.dispose();
  }

  Future<void> _pickReceipt() async {
    final selection = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'pdf'],
      withData: true,
    );
    if (!mounted || selection == null || selection.files.isEmpty) return;
    final file = selection.files.single;
    final extension = file.extension?.toLowerCase();
    if (extension == null ||
        !const {'jpg', 'jpeg', 'png', 'pdf'}.contains(extension)) {
      setState(() => _error = 'Choose a JPG, PNG or PDF receipt.');
      return;
    }
    if (file.size >= 10 * 1024 * 1024) {
      setState(() => _error = 'Receipt must be smaller than 10 MB.');
      return;
    }
    if (file.bytes == null) {
      setState(() => _error = 'Could not read the selected receipt file.');
      return;
    }
    if (!isValidExpenseReceipt(file.bytes!, extension)) {
      setState(
        () => _error = 'The selected file does not match its file type.',
      );
      return;
    }
    setState(() {
      _error = null;
      _receiptBytes = file.bytes;
      _receiptName = file.name;
      _receiptExtension = extension;
    });
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final draft = ExpenseDraft(
      busId: _busId ?? '',
      category: _category ?? '',
      amount: _amount.text,
      expenseDate: _date,
      description: _description.text,
    );
    final error = draft.validate();
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(
      context,
      _ExpenseFormResult(
        draft: draft,
        vendorName: _vendor.text.trim(),
        receiptBytes: _receiptBytes,
        receiptExtension: _receiptExtension,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existing == null ? 'Add expense' : 'Edit expense'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: widget.buses.any((bus) => bus.id == _busId)
                    ? _busId
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Bus number *'),
                items: [
                  for (final bus in widget.buses)
                    DropdownMenuItem(
                      value: bus.id,
                      child: Text('Bus ${bus.data()['busNumber']}'),
                    ),
                ],
                validator: (value) =>
                    value == null || value.isEmpty ? 'Select a bus.' : null,
                onChanged: (value) => setState(() => _busId = value),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: expenseCategories.contains(_category)
                    ? _category
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Category *'),
                items: [
                  for (final category in expenseCategories)
                    DropdownMenuItem(value: category, child: Text(category)),
                ],
                validator: (value) =>
                    value == null ? 'Select an expense category.' : null,
                onChanged: (value) => setState(() => _category = value),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _amount,
                decoration: const InputDecoration(
                  labelText: 'Amount (₹) *',
                  prefixText: '₹ ',
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: (value) {
                  final amount = double.tryParse(value?.trim() ?? '');
                  return amount == null ||
                          !amount.isFinite ||
                          amount <= 0 ||
                          amount >= 100000000
                      ? 'Enter an amount greater than zero.'
                      : null;
                },
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final selected = await showDatePicker(
                    context: context,
                    initialDate: _date ?? DateTime.now(),
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (selected != null) setState(() => _date = selected);
                },
                icon: const Icon(Icons.calendar_today_outlined),
                label: Text(
                  _date == null ? 'Select expense date *' : _shortDate(_date!),
                ),
              ),
              if (_date == null)
                const Padding(
                  padding: EdgeInsets.only(left: 12, top: 4),
                  child: Text(
                    'Expense date is required.',
                    style: TextStyle(color: Colors.red, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _description,
                minLines: 2,
                maxLines: 4,
                maxLength: 2000,
                decoration: const InputDecoration(
                  labelText: 'Description *',
                  alignLabelWithHint: true,
                ),
                validator: (value) => (value ?? '').trim().isEmpty
                    ? 'Enter a description.'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _vendor,
                maxLength: 200,
                decoration: const InputDecoration(
                  labelText: 'Vendor / service provider (optional)',
                ),
              ),
              const SizedBox(height: 4),
              OutlinedButton.icon(
                onPressed: _pickReceipt,
                icon: const Icon(Icons.attach_file),
                label: Text(
                  _receiptName ??
                      (widget.existing?['receiptUrl'] == null
                          ? 'Attach receipt (JPG, PNG or PDF)'
                          : 'Replace attached receipt'),
                ),
              ),
              if (widget.existing?['receiptUrl'] != null &&
                  _receiptName == null)
                const Text(
                  'The existing receipt will be retained unless replaced.',
                  style: TextStyle(fontSize: 12),
                ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 8),
              const Text(
                'Recorded by and timestamps are set automatically. Receipts must be under 10 MB.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Save expense')),
    ],
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
