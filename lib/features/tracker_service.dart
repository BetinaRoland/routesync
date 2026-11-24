import 'dart:async';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import '../core/logic.dart' as lg;
import '../services/common.dart';

class _RouteStop {
  final String id;
  final int sequence;
  final double lat;
  final double lng;
  const _RouteStop(this.id, this.sequence, this.lat, this.lng);
}

/// Driver phone as the GPS source. Dedicated trackers sign in with their own account and write the same place.
/// Positions that cannot be sent are kept (up to 500) and added to the history when the connection returns.
class TrackerService {
  final String busId;
  TrackerService(this.busId);

  final ValueNotifier<DateTime?> lastFix = ValueNotifier(null);
  final ValueNotifier<String?> error = ValueNotifier(null);
  final List<Map<String, dynamic>> _pending = [];
  StreamSubscription<Position>? _sub;
  bool _flushing = false, _wasAway = false;
  int _lastHist = 0, _histEvery = 15, _grace = 10;
  String _arrivedDay = '';
  M? _college;
  String? _arrivalBy;
  String? _routeId;
  List<_RouteStop> _routeStops = [];
  int _currentStopSequence = 0;
  int _maxFixTs = 0;
  final int _arriveMeters = 150;
  int _approachMeters = 500;
  bool get running => _sub != null;

  Future<void> _preload() async {
    try {
      _college = (await fs.doc('config/college').get()).data();
      final conf = await cfg();
      _histEvery = (conf['historyIntervalSec'] as num).toInt();
      _grace = (conf['delayGraceMinutes'] as num).toInt();
      final bus = (await fs.doc('buses/$busId').get()).data();
      if (bus?['routeId'] != null) {
        _routeId = '${bus!['routeId']}';
        final route = (await fs.doc('routes/$_routeId').get()).data();
        _arrivalBy = route?['arrivalBy'] as String?;
        final ids = List<String>.from((route?['stopIds'] as List?) ?? []);
        _routeStops = [];
        for (var i = 0; i < ids.length; i++) {
          final stop = (await fs.doc('boardingPoints/${ids[i]}').get()).data();
          if (stop != null &&
              stop['latitude'] is num &&
              stop['longitude'] is num) {
            _routeStops.add(
              _RouteStop(
                ids[i],
                i,
                (stop['latitude'] as num).toDouble(),
                (stop['longitude'] as num).toDouble(),
              ),
            );
          }
        }
        _approachMeters = (conf['approachMeters'] as num? ?? 500).toInt();
        final progress = (await fs.doc('routeProgress/$busId').get()).data();
        if (progress != null &&
            progress['routeId'] == _routeId &&
            progress['currentStopSequence'] is num) {
          _currentStopSequence = (progress['currentStopSequence'] as num)
              .toInt();
        } else if (_routeStops.isNotEmpty) {
          final initial = <String, Object?>{
            'busId': busId,
            'routeId': _routeId,
            'stopId': _routeStops.first.id,
            'stopSequence': 0,
            'status': 'upcoming',
            'arrivalTimestamp': null,
            'visitedTimestamp': null,
            'lastUpdatedAt': DateTime.now().millisecondsSinceEpoch,
            'visitedStopIds': <String>[],
            'stopStatuses': <String, Object?>{
              for (var i = 0; i < _routeStops.length; i++)
                _routeStops[i].id: 'upcoming',
            },
          };
          await fs.doc('routeProgress/$busId').set(initial);
          await rt('routeProgress/$busId').set(initial);
        }
      }
    } catch (_) {}
  }

  Future<String?> start() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'Turn on location services.';
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return 'Location permission is required to share the bus position.';
    }
    await _preload();
    final LocationSettings settings = kIsWeb
        ? const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
          )
        : defaultTargetPlatform == TargetPlatform.android
        ? AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
            intervalDuration: const Duration(seconds: 5),
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'RouteSync tracking active',
              notificationText: 'Sharing this bus location',
              enableWakeLock: true,
            ),
          )
        : AppleSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
            allowBackgroundLocationUpdates: true,
            showBackgroundLocationIndicator: true,
            pauseLocationUpdatesAutomatically: false,
          );
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen((
      p,
    ) async {
      if (p.accuracy > 100) {
        return; // too inaccurate; admins see the bus as stale instead
      }
      final ts = DateTime.now().millisecondsSinceEpoch;
      final fixTs = p.timestamp.millisecondsSinceEpoch;
      await _updateRouteProgress(p.latitude, p.longitude, fixTs);
      final fix = {
        'lat': p.latitude,
        'lng': p.longitude,
        'speed': p.speed,
        'heading': p.heading,
        'accuracy': p.accuracy,
        'ts': ts,
      };
      try {
        await rt(
          'liveLocations/$busId',
        ).set(fix).timeout(const Duration(seconds: 8));
        lastFix.value = DateTime.now();
        error.value = null;
        if (ts - _lastHist >= _histEvery * 1000) {
          _lastHist = ts;
          rt('history/$busId/${dateKey()}/$ts')
              .set({
                'lat': p.latitude,
                'lng': p.longitude,
                'speed': p.speed,
                'heading': p.heading,
                'accuracy': p.accuracy,
              })
              .catchError((_) {});
        }
        _arrival(p);
        if (_pending.isNotEmpty) _flush();
      } catch (_) {
        _pending.add({
          'lat': p.latitude,
          'lng': p.longitude,
          'speed': p.speed,
          'accuracy': p.accuracy,
          'ts': ts,
        });
        if (_pending.length > 500) _pending.removeAt(0);
        error.value =
            'No connection. ${_pending.length} positions saved; they upload when you are back online.';
      }
    }, onError: (e) => error.value = 'GPS error. Check location settings.');
    return null;
  }

  Future<void> _updateRouteProgress(double lat, double lng, int fixTs) async {
    if (_routeId == null || _routeStops.isEmpty || fixTs < _maxFixTs - 1000) {
      return;
    }
    _maxFixTs = fixTs;
    if (_currentStopSequence >= _routeStops.length) return;

    final current = _routeStops[_currentStopSequence];
    final distance = lg.haversineM(lat, lng, current.lat, current.lng);

    if (distance <= _arriveMeters) {
      _currentStopSequence++;
      final stopStatuses = <String, Object?>{
        for (var i = 0; i < _routeStops.length; i++)
          _routeStops[i].id: i < _currentStopSequence
              ? 'visited'
              : i == _currentStopSequence
              ? 'upcoming'
              : 'upcoming',
      };
      final data = <String, Object?>{
        'busId': busId,
        'routeId': _routeId,
        'stopId': _currentStopSequence < _routeStops.length
            ? _routeStops[_currentStopSequence].id
            : null,
        'stopSequence': _currentStopSequence,
        'status': _currentStopSequence < _routeStops.length
            ? 'upcoming'
            : 'visited',
        'arrivalTimestamp': fixTs,
        'visitedTimestamp': fixTs,
        'lastUpdatedAt': fixTs,
        'visitedStopIds': _routeStops
            .take(_currentStopSequence)
            .map((stop) => stop.id)
            .toList(),
        'stopStatuses': stopStatuses,
      };
      await fs.doc('routeProgress/$busId').set(data, SetOptions(merge: true));
      await rt('routeProgress/$busId').set(data);
      return;
    }

    if (distance <= _approachMeters) {
      final data = <String, Object?>{
        'busId': busId,
        'routeId': _routeId,
        'stopId': current.id,
        'stopSequence': current.sequence,
        'status': 'approaching',
        'arrivalTimestamp': null,
        'lastUpdatedAt': fixTs,
        'visitedStopIds': _routeStops
            .take(_currentStopSequence)
            .map((stop) => stop.id)
            .toList(),
        'stopStatuses': <String, Object?>{
          for (var i = 0; i < _routeStops.length; i++)
            _routeStops[i].id: i < _currentStopSequence
                ? 'visited'
                : i == _currentStopSequence
                ? 'approaching'
                : 'upcoming',
        },
      };
      await fs.doc('routeProgress/$busId').set(data, SetOptions(merge: true));
      await rt('routeProgress/$busId').set(data);
    }
  }

  /// First arrival at the college after being away: used for the on-time report.
  Future<void> _arrival(Position p) async {
    final c = _college, due = _arrivalBy, day = dateKey();
    if (c == null || due == null || _arrivedDay == day) return;
    final dc = lg.haversineM(
      p.latitude,
      p.longitude,
      (c['lat'] as num).toDouble(),
      (c['lng'] as num).toDouble(),
    );
    if (dc > 1500) _wasAway = true;
    if (!_wasAway || dc > 300) return;
    _arrivedDay = day;
    final late = lg.minutesOf(hhmm()) - lg.minutesOf(due);
    try {
      await fs.doc('journeys/${busId}_$day').set({
        'journeyId': '${busId}_$day',
        'busId': busId,
        'arrivedAt': Timestamp.now(),
        'arrivalBy': due,
        'lateMinutes': max(0, late),
        'onTime': late <= _grace,
      }, SetOptions(merge: true));
    } catch (_) {
      _arrivedDay = '';
    }
  }

  Future<void> _flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      while (_pending.isNotEmpty) {
        final part = _pending.take(200).toList(),
            byDay = <String, Map<String, Object?>>{};
        for (final x in part) {
          final day = dateKey(
            DateTime.fromMillisecondsSinceEpoch(x['ts'] as int),
          );
          (byDay[day] ??= {})['${x['ts']}'] = {
            'lat': x['lat'],
            'lng': x['lng'],
            'speed': x['speed'],
            'accuracy': x['accuracy'],
          };
        }
        for (final e in byDay.entries) {
          await rt('history/$busId/${e.key}').update(e.value);
        }
        _pending.removeRange(0, part.length);
      }
    } catch (_) {
      // try again after the next successful send
    }
    _flushing = false;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }
}
