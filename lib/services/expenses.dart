import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

const expenseCategories = [
  'Fuel',
  'Maintenance and Repairs',
  'Tyres and Puncture',
  'Driver Allowances and Trip Expenses',
  'Tolls',
  'Insurance',
  'Permits and Certificates',
  'Cleaning',
  'Other Expenses',
];

bool canViewExpenseRecords(String role) =>
    role == 'routeAdmin' || role == 'superAdmin';

bool canManageExpenseRecords(String role) => role == 'routeAdmin';

bool isValidExpenseReceipt(Uint8List bytes, String extension) {
  if (bytes.length >= 10 * 1024 * 1024) return false;
  final fileType = extension.toLowerCase();
  if (fileType == 'jpg' || fileType == 'jpeg') {
    return bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff;
  }
  if (fileType == 'png') {
    const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    if (bytes.length < signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    return true;
  }
  if (fileType == 'pdf') {
    return bytes.length >= 5 &&
        bytes[0] == 0x25 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x44 &&
        bytes[3] == 0x46 &&
        bytes[4] == 0x2d;
  }
  return false;
}

class ExpenseDraft {
  final String busId;
  final String category;
  final String amount;
  final DateTime? expenseDate;
  final String description;

  const ExpenseDraft({
    required this.busId,
    required this.category,
    required this.amount,
    required this.expenseDate,
    required this.description,
  });

  String? validate() {
    if (busId.isEmpty) return 'Select a bus.';
    if (!expenseCategories.contains(category)) {
      return 'Select a valid expense category.';
    }
    final value = double.tryParse(amount.trim());
    if (value == null || !value.isFinite || value <= 0 || value >= 100000000) {
      return 'Enter an amount greater than zero.';
    }
    if (expenseDate == null) return 'Select an expense date.';
    if (description.trim().isEmpty) return 'Enter a description.';
    if (description.trim().length > 2000) {
      return 'Description must be 2,000 characters or fewer.';
    }
    return null;
  }
}

DateTime? expenseDateFrom(Map<String, dynamic> data) {
  final value = data['expenseDate'] ?? data['date'];
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

String expenseDescriptionFrom(Map<String, dynamic> data) =>
    '${data['description'] ?? data['note'] ?? ''}';

String expenseRecordedByFrom(Map<String, dynamic> data) =>
    '${data['recordedBy'] ?? data['createdBy'] ?? ''}';

class ExpenseSummary {
  final double total;
  final double fuel;
  final double maintenance;
  final double other;
  final Map<String, double> byCategory;
  final Map<String, double> byBus;
  final Map<String, double> byMonth;
  final Map<String, double> byYear;

  ExpenseSummary._({
    required this.total,
    required this.fuel,
    required this.maintenance,
    required this.other,
    required this.byCategory,
    required this.byBus,
    required this.byMonth,
    required this.byYear,
  });

  factory ExpenseSummary.fromRecords(Iterable<Map<String, dynamic>> records) {
    var total = 0.0, fuel = 0.0, maintenance = 0.0, other = 0.0;
    final byCategory = <String, double>{};
    final byBus = <String, double>{};
    final byMonth = <String, double>{};
    final byYear = <String, double>{};
    for (final record in records) {
      final rawAmount = record['amount'];
      if (rawAmount is! num || !rawAmount.isFinite || rawAmount <= 0) continue;
      final amount = rawAmount.toDouble();
      final category = '${record['category'] ?? 'Other Expenses'}';
      final bus = '${record['busNumber'] ?? record['busId'] ?? 'Unknown bus'}';
      total += amount;
      byCategory.update(
        category,
        (value) => value + amount,
        ifAbsent: () => amount,
      );
      byBus.update(bus, (value) => value + amount, ifAbsent: () => amount);
      if (category == 'Fuel') {
        fuel += amount;
      } else if (category == 'Maintenance and Repairs' ||
          category == 'Maintenance') {
        maintenance += amount;
      } else {
        other += amount;
      }
      final date = expenseDateFrom(record);
      if (date != null) {
        final month = '${date.year}-${date.month.toString().padLeft(2, '0')}';
        final year = '${date.year}';
        byMonth.update(
          month,
          (value) => value + amount,
          ifAbsent: () => amount,
        );
        byYear.update(year, (value) => value + amount, ifAbsent: () => amount);
      }
    }
    return ExpenseSummary._(
      total: total,
      fuel: fuel,
      maintenance: maintenance,
      other: other,
      byCategory: byCategory,
      byBus: byBus,
      byMonth: byMonth,
      byYear: byYear,
    );
  }
}
