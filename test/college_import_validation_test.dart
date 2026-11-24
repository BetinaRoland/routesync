import 'package:flutter_test/flutter_test.dart';
import 'package:routesync/services/college_import_validation.dart';

void main() {
  final buses = {
    'B1': {
      'busNumber': '21',
      'capacity': 2,
      'routeId': 'R1',
      'driverId': 'D1',
      'permittedRegionId': 'north',
      'availability': true,
      'maintenanceStatus': 'ok',
    },
  };
  final routes = {
    'R1': {
      'status': 'active',
      'stopIds': ['P1'],
    },
  };
  final points = {
    'P1': {'status': 'active', 'approvalStatus': 'approved'},
  };
  final drivers = {
    'D1': {
      'status': 'active',
      'assignedBusId': 'B1',
      'permittedRegionIds': ['north'],
    },
  };

  Map<String, dynamic> studentRow(String registerNumber) => {
    'registerNumber': registerNumber,
    'name': 'Student $registerNumber',
    'departmentId': 'CS',
    'academicYear': '2',
    'email': '$registerNumber@example.com',
    'busId': 'B1',
    'boardingPointId': 'P1',
  };

  Map<String, dynamic> existingStudent(String uid) => {
    'authUid': uid,
    'allocationId': null,
    'approvedBoardingPointId': 'P1',
    'email': '$uid@example.com',
  };

  group('college import validation', () {
    test(
      'valid roster without account stays unallocated with an exact reason',
      () {
        final result = validateCollegeImport(
          busRows: const [],
          studentRows: [studentRow('S1')],
          existingBuses: buses,
          existingStudents: const {},
          authenticatedUsers: const {},
          routes: routes,
          boardingPoints: points,
          drivers: drivers,
          activeAllocationCounts: const {},
          duplicatePolicy: 'skip',
        );

        expect(result.studentsToWrite, hasLength(1));
        expect(result.allocationsToCreate, isEmpty);
        expect(result.notAllocated, hasLength(1));
        expect(
          result.notAllocated.single['reason'],
          contains('no existing authenticated account'),
        );
      },
    );

    test(
      'does not partially allocate a group that would exceed bus capacity',
      () {
        final result = validateCollegeImport(
          busRows: const [],
          studentRows: [studentRow('S1'), studentRow('S2')],
          existingBuses: buses,
          existingStudents: {
            'S1': existingStudent('U1'),
            'S2': existingStudent('U2'),
          },
          authenticatedUsers: {
            'U1': {'status': 'active', 'role': 'student', 'studentId': 'S1'},
            'U2': {'status': 'active', 'role': 'student', 'studentId': 'S2'},
          },
          routes: routes,
          boardingPoints: points,
          drivers: drivers,
          activeAllocationCounts: const {'B1': 1},
          duplicatePolicy: 'update',
        );

        expect(result.allocationsToCreate, isEmpty);
        expect(result.notAllocated, hasLength(2));
        expect(
          result.notAllocated.map((row) => row['reason']).toSet(),
          everyElement(contains('no new students assigned')),
        );
      },
    );

    test(
      'creates an allocation only when all existing references validate',
      () {
        final result = validateCollegeImport(
          busRows: const [],
          studentRows: [studentRow('S1')],
          existingBuses: buses,
          existingStudents: {'S1': existingStudent('U1')},
          authenticatedUsers: {
            'U1': {'status': 'active', 'role': 'student', 'studentId': 'S1'},
          },
          routes: routes,
          boardingPoints: points,
          drivers: drivers,
          activeAllocationCounts: const {'B1': 1},
          duplicatePolicy: 'update',
        );

        expect(result.allocationsToCreate, hasLength(1));
        expect(result.allocationsToCreate.single['authUid'], 'U1');
        expect(result.allocationsToCreate.single['busId'], 'B1');
        expect(result.allocationsToCreate.single['routeId'], 'R1');
        expect(result.allocationsToCreate.single['boardingPointId'], 'P1');
        expect(result.notAllocated, isEmpty);
      },
    );
  });
}
