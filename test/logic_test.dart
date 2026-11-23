import 'package:flutter_test/flutter_test.dart';
import 'package:routesync/core/logic.dart';

void main() {
  group('fees', () {
    test('per km', () => expect(computeFee({'calculationMethod': 'perKm', 'ratePerKm': 1200}, 12.5), 15000));
    final slabs = {'calculationMethod': 'slabs', 'distanceSlabs': [{'maxKm': 25, 'amount': 14000}, {'maxKm': 10, 'amount': 8000}]};
    test('slab edge', () => expect(computeFee(slabs, 10), 8000));
    test('next slab', () => expect(computeFee(slabs, 10.1), 14000));
    test('beyond last slab', () => expect(computeFee(slabs, 30), isNull));
  });

  group('geometry', () {
    final line = [[13.0, 80.0], [13.0, 80.1]];
    test('on the route', () => expect(distToPolylineM(13.0, 80.05, line), lessThan(1)));
    test('about 1.1 km off', () {
      final d = distToPolylineM(13.01, 80.05, line);
      expect(d, inInclusiveRange(1000, 1200));
    });
    test('haversine one degree', () => expect(haversineM(0, 0, 0, 1), closeTo(111195, 200)));
    test('downsample keeps ends', () {
      final d = downsample(List.generate(1000, (i) => i), 100);
      expect(d.length, 100);
      expect(d.first, 0);
      expect(d.last, 999);
    });
    test('minutes', () => expect(minutesOf('08:30'), 510));
  });

  group('allocation', () {
    test('extra students go on the bus that already has seats', () {
      final buses = [GBus('A', 5, ['s1', 's2'], true), GBus('B', 40, ['s1', 's2', 's3'], false)];
      final r = greedyAllocate([const Rider('x', 's1'), const Rider('y', 's1'), const Rider('z', 's2')], buses);
      expect(r.assignments.values.toSet(), {'A'});
      expect(r.unallocated, isEmpty);
    });
    test('capacity is never exceeded', () {
      final buses = [GBus('A', 5, ['s1'], true), GBus('B', 40, ['s1'], false)];
      final r = greedyAllocate([for (var i = 0; i < 8; i++) Rider('m$i', 's1')], buses);
      final load = <String, int>{};
      for (final b in r.assignments.values) { load[b] = (load[b] ?? 0) + 1; }
      expect(load['A']! <= 5, isTrue);
      expect(r.unallocated, isEmpty);
    });
    test('a stop no bus serves stays unallocated', () {
      final r = greedyAllocate([const Rider('q', 'nowhere')], [GBus('A', 5, ['s1'], true)]);
      expect(r.unallocated, ['q']);
    });
  });

  group('rebalance', () {
    FleetBus bus(String id, int cap, int alloc, List<String> stops) => FleetBus(id: id, number: id, capacity: cap, allocated: alloc, stops: stops);
    test('a nearly empty bus on the same stops is freed', () {
      final plan = planRebalance([bus('A', 40, 5, ['s1', 's2']), bus('B', 40, 30, ['s1', 's2', 's3']), bus('C', 40, 35, ['s9'])],
          {'A': [for (var i = 0; i < 5; i++) Rider('a$i', 's1')]});
      expect(plan.freed, ['A']);
      expect(plan.moves.length, 5);
      expect(plan.moves.every((m) => m.to == 'B'), isTrue);
    });
    test('no free seats means nothing is freed', () {
      final plan = planRebalance([bus('A', 40, 5, ['s1']), bus('B', 40, 38, ['s1'])], {'A': [for (var i = 0; i < 5; i++) Rider('a$i', 's1')]});
      expect(plan.moves, isEmpty);
    });
    test('a stop only its own bus serves cannot move', () {
      final plan = planRebalance([bus('A', 40, 2, ['z']), bus('B', 40, 2, ['s1'])], {'A': [const Rider('q', 'z')]});
      expect(plan.moves, isEmpty);
    });
  });

  group('routes and replacements', () {
    test('overlapping routes found', () {
      final o = routeOverlaps(const [RouteInfo('r1', 'North', ['a', 'b', 'c', 'd']), RouteInfo('r2', 'North 2', ['b', 'c', 'x']), RouteInfo('r3', 'South', ['p', 'q'])]);
      expect(o.length, 1);
      expect(o.first.shared.length, 2);
    });
    test('replacement ranking', () {
      FleetBus b(String id, int cap, int alloc, bool avail, bool auth) => FleetBus(id: id, number: id, capacity: cap, allocated: alloc, stops: const [], availability: avail, driverAuthorized: auth);
      final opts = replacementOptions(10, [b('x', 50, 10, true, false), b('y', 30, 15, true, true), b('z', 60, 0, false, true), b('w', 20, 15, true, true)]);
      expect(opts.map((e) => e.id).toList(), ['y', 'x']);
    });
  });
}
