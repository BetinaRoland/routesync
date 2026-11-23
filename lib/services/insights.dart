import '../core/logic.dart' as lg;
import 'common.dart';

/// Rule-based suggestions for the Route Admin. No outside AI service is used.
Future<M> insights(M d) async {
  await need(adminRoles);
  final f = await loadFleet();
  final students = (await fs.collection('students').get()).docs.map((e) => e.data()).toList();
  final ready = students.where((s) => s['authUid'] != null && s['approvedBoardingPointId'] != null && s['allocationId'] == null).toList();
  final eligible = f.all.where((b) => b.availability && b.maintenanceStatus == 'ok' && b.routeId != null && b.driverId != null && b.driverAuthorized).toList();
  final plan = lg.planRebalance(eligible, f.riders);
  final byId = {for (final b in f.all) b.id: b};
  final overlaps = lg.routeOverlaps([for (final e in f.routes.entries) lg.RouteInfo(e.key, '${e.value['routeName']}', List<String>.from((e.value['stopIds'] as List?) ?? []))]);
  final dept = <String, List<int>>{};
  for (final s in students) {
    final r = dept.putIfAbsent('${s['departmentId']}', () => [0, 0]);
    r[0]++;
    if (s['allocationId'] != null) r[1]++;
  }
  final alerts = (await fs.collection('alerts').count().get()).count ?? 0;
  return {
    'notRegistered': students.where((s) => s['authUid'] == null).length,
    'noStop': students.where((s) => s['authUid'] != null && s['approvedBoardingPointId'] == null).length,
    'ready': ready.length,
    'readyNames': ready.take(12).map((s) => '${s['name']} (${s['registerNumber']})').toList(),
    'openAlerts': alerts,
    'buses': [for (final b in f.all) {'number': b.number, 'allocated': b.allocated, 'capacity': b.capacity, 'usable': eligible.any((e) => e.id == b.id)}],
    'underHalf': [for (final b in f.all) if (b.allocated > 0 && b.allocated / b.capacity < 0.5) b.number],
    'overlaps': [for (final o in overlaps.take(8)) '${o.a.name} and ${o.b.name}: ${o.shared.length} shared stops (${o.share}% of the shorter route)'],
    'consolidation': [for (final id in plan.freed) 'Bus ${byId[id]!.number} could be freed: its ${plan.moves.where((m) => m.from == id).length} riders fit on other buses at the same stops'],
    'departments': [for (final e in dept.entries) {'dept': e.key, 'students': e.value[0], 'onBus': e.value[1]}],
  };
}

/// Which buses could take over a bus that is out of service.
Future<M> replacementSuggestions(M d) async {
  await need(adminRoles);
  final f = await loadFleet();
  final bus = f.all.where((b) => b.id == d['busId']).toList();
  if (bus.isEmpty) fail('Bus not found.');
  final options = lg.replacementOptions(bus.first.allocated, f.all.where((b) => b.id != bus.first.id).toList()).take(5);
  return {
    'riders': bus.first.allocated,
    'options': [for (final o in options) {'bus': o.number, 'freeSeats': o.spare, 'hasDriver': o.driverId != null, 'driverAuthorised': o.driverAuthorized, 'spare': o.allocated == 0}],
  };
}
