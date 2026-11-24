import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../core/api.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

final _boardingPointFs = FirebaseFirestore.instance;

class BoardingPointsPage extends StatefulWidget {
  const BoardingPointsPage({super.key});

  @override
  State<BoardingPointsPage> createState() => _BoardingPointsPageState();
}

class _BoardingPointsPageState extends State<BoardingPointsPage> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  int _duplicateDistance = 150;

  @override
  void initState() {
    super.initState();
    _loadDuplicateDistance();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadDuplicateDistance() async {
    try {
      final data =
          (await _boardingPointFs.doc('config/operations').get()).data() ?? {};
      final value = data['boardingPointDuplicateDistanceMeters'];
      if (mounted && value is num && value >= 25 && value <= 5000) {
        setState(() => _duplicateDistance = value.toInt());
      }
    } on FirebaseException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not load the nearby-duplicate setting.'),
          ),
        );
      }
    }
  }

  Future<void> _configureDuplicateDistance() async {
    final result = await formDialog(context, 'Nearby duplicate check', [
      F(
        'meters',
        'Nearby distance in metres (25–5,000)',
        initial: '$_duplicateDistance',
        number: true,
      ),
    ]);
    if (result == null || !mounted) return;
    await runAction(context, () async {
      final saved = await Api.call('setBoardingPointDuplicateDistance', {
        'meters': int.tryParse(result['meters'] ?? ''),
      });
      if (mounted) setState(() => _duplicateDistance = saved['meters'] as int);
      return 'Nearby duplicate distance saved.';
    });
  }

  Future<void> _openEditor([
    QueryDocumentSnapshot<Map<String, dynamic>>? doc,
  ]) async {
    Map<String, dynamic>? college;
    var collegeMessage = '';
    try {
      college = (await _boardingPointFs.doc('config/college').get()).data();
      final lat = college?['lat'], lng = college?['lng'];
      if (lat is! num ||
          lng is! num ||
          !lat.isFinite ||
          !lng.isFinite ||
          lat < -90 ||
          lat > 90 ||
          lng < -180 ||
          lng > 180) {
        college = null;
        collegeMessage =
            'The college location is not set. Search for a place to begin.';
      }
    } on FirebaseException {
      collegeMessage =
          'The college location could not be loaded. You can still search for a place.';
    }
    if (!mounted) return;
    var count = 0;
    if (doc == null) {
      try {
        count =
            (await _boardingPointFs.collection('boardingPoints').count().get())
                .count ??
            0;
      } on FirebaseException {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not prepare a boarding point name. Retry.'),
            ),
          );
        }
        return;
      }
    }
    if (!mounted) return;
    final old = doc?.data();
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => BoardingPointMapDialog(
        collegeCenter: college == null
            ? null
            : LatLng(
                (college['lat'] as num).toDouble(),
                (college['lng'] as num).toDouble(),
              ),
        collegeMessage: collegeMessage,
        fallbackName:
            'Boarding Point ${(count + 1).toString().padLeft(3, '0')}',
        existing: old == null ? null : {...old, 'boardingPointId': doc!.id},
      ),
    );
    if (result == null || !mounted) return;
    await _savePoint(result, old == null ? null : doc!.id);
  }

  Future<void> _savePoint(
    Map<String, dynamic> point, [
    String? pointId,
    String? status,
  ]) async {
    await runAction(context, () async {
      final request = <String, dynamic>{
        ...point,
        ...?(pointId == null ? null : {'boardingPointId': pointId}),
        ...?(status == null ? null : {'status': status}),
      };
      var result = await Api.call('saveBoardingPoint', request);
      final duplicates = asList(result['duplicates']);
      if (duplicates.isNotEmpty) {
        final choice = await _duplicateDialog(duplicates);
        if (!mounted) return null;
        if (choice == null) return null;
        if (choice.startsWith('inspect:')) {
          await _showPointById(choice.substring('inspect:'.length));
          return null;
        }
        request['allowDuplicate'] = true;
        result = await Api.call('saveBoardingPoint', request);
      }
      if (!mounted) return null;
      if (result['needsReviewConfirmation'] == true) {
        final count = result['affectedStudentCount'] as int? ?? 0;
        final confirmed = await confirm(
          context,
          'Review affected student assignments?',
          'This change affects $count student record${count == 1 ? '' : 's'}. Their boarding assignments will not be changed, and the point will be flagged for authorized review. Continue?',
          action: 'Continue',
        );
        if (!confirmed || !mounted) return null;
        request['confirmAffected'] = true;
        result = await Api.call('saveBoardingPoint', request);
      }
      final isEdit = pointId != null;
      final warning = result['distanceWarning'] as String?;
      final review = result['reviewRequired'] == true;
      return [
        isEdit ? 'Boarding point updated.' : 'Boarding point saved.',
        if (review) 'Student assignments were flagged for review.',
        ...?(warning == null ? null : [warning]),
      ].join(' ');
    });
  }

  Future<String?> _duplicateDialog(
    List<Map<String, dynamic>> duplicates,
  ) => showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Check nearby boarding points'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'A boarding point already exists near this location. Please check it before creating another.',
              ),
              const SizedBox(height: 12),
              for (final point in duplicates)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.location_on_outlined),
                  title: Text('${point['name']}'),
                  subtitle: Text(
                    '${point['address'] ?? ''}\n${point['distanceMeters']} m away',
                  ),
                  trailing: const Text('Inspect'),
                  onTap: () => Navigator.pop(
                    dialogContext,
                    'inspect:${point['boardingPointId']}',
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        FilledButton.tonal(
          onPressed: () => Navigator.pop(dialogContext, 'save'),
          child: const Text('Save anyway'),
        ),
      ],
    ),
  );

  Future<void> _showPointById(String id) async {
    try {
      final snap = await _boardingPointFs.doc('boardingPoints/$id').get();
      final point = snap.data();
      if (point == null || !mounted) return;
      await _showPointMap(point);
    } on FirebaseException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open that boarding point.')),
        );
      }
    }
  }

  Future<void> _showPointMap(Map<String, dynamic> point) async {
    final lat = point['latitude'], lng = point['longitude'];
    if (lat is! num || lng is! num) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${point['name'] ?? 'Boarding point'}'),
        content: SizedBox(
          width: 600,
          height: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if ('${point['address'] ?? ''}'.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('${point['address']}'),
                ),
              Expanded(
                child: _BoardingPointPreview(
                  point: LatLng(lat.toDouble(), lng.toDouble()),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showRoutes(String id, String name) async {
    try {
      final routes = await _boardingPointFs
          .collection('routes')
          .where('stopIds', arrayContains: id)
          .get();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Routes using $name'),
          content: SizedBox(
            width: 400,
            child: routes.docs.isEmpty
                ? const Text('No routes currently use this boarding point.')
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final route in routes.docs)
                        ListTile(
                          leading: const Icon(Icons.alt_route),
                          title: Text(
                            '${route.data()['routeName'] ?? 'Unnamed route'}',
                          ),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } on FirebaseException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load associated routes.')),
        );
      }
    }
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _matching(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    if (_query.isEmpty) return docs;
    return docs.where((doc) {
      final p = doc.data();
      return '${p['name'] ?? ''} ${p['address'] ?? ''} ${p['district'] ?? ''}'
          .toLowerCase()
          .contains(_query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            runSpacing: 8,
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => _openEditor(),
                icon: const Icon(Icons.add_location_alt_outlined),
                label: const Text('Add Boarding Point'),
              ),
              OutlinedButton.icon(
                onPressed: _configureDuplicateDistance,
                icon: const Icon(Icons.radar),
                label: Text('Nearby check: $_duplicateDistance m'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: TextField(
            controller: _search,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'Search name, address or district',
            ),
            onChanged: (value) =>
                setState(() => _query = value.trim().toLowerCase()),
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _boardingPointFs
                .collection('boardingPoints')
                .orderBy('name')
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const EmptyState(
                  'Could not load boarding points. Check your connection and try again.',
                  icon: Icons.cloud_off,
                );
              }
              if (!snapshot.hasData) return loading();
              final matches = _matching(snapshot.data!.docs);
              if (matches.isEmpty) {
                return EmptyState(
                  _query.isEmpty
                      ? 'No boarding points yet. Add one by searching or selecting a location on the map.'
                      : 'No boarding points match your search.',
                  icon: Icons.location_on_outlined,
                );
              }
              final groups =
                  <String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};
              for (final point in matches) {
                final district = '${point.data()['district'] ?? ''}'.trim();
                (groups[district.isEmpty
                            ? 'District not recorded'
                            : district] ??=
                        [])
                    .add(point);
              }
              final districts = groups.keys.toList()
                ..sort((a, b) {
                  if (a == 'District not recorded') return 1;
                  if (b == 'District not recorded') return -1;
                  return a.compareTo(b);
                });
              return ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  for (final district in districts)
                    ExpansionTile(
                      key: PageStorageKey<String>(
                        'boarding-district-$district',
                      ),
                      leading: const Icon(Icons.account_tree_outlined),
                      title: Text(district),
                      subtitle: Text(
                        '${groups[district]!.length} boarding point${groups[district]!.length == 1 ? '' : 's'}',
                      ),
                      children: [
                        for (final doc in groups[district]!)
                          _pointTile(context, doc),
                      ],
                    ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );

  Widget _pointTile(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final point = doc.data();
    final inactive = point['status'] == 'inactive';
    final needsReview = point['reviewRequired'] == true;
    final address = '${point['address'] ?? ''}';
    final lat = point['latitude'], lng = point['longitude'];
    return Card(
      child: ListTile(
        leading: Icon(
          inactive ? Icons.location_disabled_outlined : Icons.location_on,
          color: inactive ? Colors.grey : navy,
        ),
        title: Text('${point['name'] ?? 'Unnamed boarding point'}'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (address.isNotEmpty) Text(address),
            Text(
              '${inactive ? 'Inactive' : 'Active'}'
              '${point['roadDistanceKm'] is num ? ' · ${point['roadDistanceKm']} km by road' : ''}'
              '${lat is num && lng is num ? ' · ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}' : ''}',
            ),
            if (needsReview)
              Text(
                'Student assignments need review (${point['reviewAffectedStudentCount'] ?? 0} affected)',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          tooltip: 'Boarding point actions',
          onSelected: (action) async {
            if (action == 'view') {
              await _showPointMap(point);
            } else if (action == 'edit') {
              await _openEditor(doc);
            } else if (action == 'routes') {
              await _showRoutes(doc.id, '${point['name']}');
            } else if (action == 'toggle') {
              final next = inactive ? 'active' : 'inactive';
              if (next == 'inactive' &&
                  !await confirm(
                    context,
                    'Deactivate ${point['name']}?',
                    'Existing routes and student boarding assignments will not be changed. Affected student records will be flagged for review.',
                    action: 'Deactivate',
                  )) {
                return;
              }
              if (!context.mounted) return;
              await _savePoint(
                {
                  'name': point['name'],
                  'nameManuallyEdited': point['nameManuallyEdited'] != false,
                  'address': point['address'] ?? '',
                  'district': point['district'] ?? '',
                  'latitude': point['latitude'],
                  'longitude': point['longitude'],
                },
                doc.id,
                next,
              );
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'view', child: Text('View on map')),
            const PopupMenuItem(
              value: 'edit',
              child: Text('Edit name or location'),
            ),
            const PopupMenuItem(
              value: 'routes',
              child: Text('View associated routes'),
            ),
            PopupMenuItem(
              value: 'toggle',
              child: Text(inactive ? 'Activate' : 'Deactivate'),
            ),
          ],
        ),
      ),
    );
  }
}

class BoardingPointMapDialog extends StatefulWidget {
  final LatLng? collegeCenter;
  final String collegeMessage;
  final String fallbackName;
  final Map<String, dynamic>? existing;

  const BoardingPointMapDialog({
    super.key,
    required this.collegeCenter,
    required this.collegeMessage,
    required this.fallbackName,
    this.existing,
  });

  @override
  State<BoardingPointMapDialog> createState() => _BoardingPointMapDialogState();
}

class _BoardingPointMapDialogState extends State<BoardingPointMapDialog> {
  final GlobalKey _mapKey = GlobalKey();
  final MapController _mapController = MapController();
  final TextEditingController _search = TextEditingController();
  final TextEditingController _name = TextEditingController();
  Timer? _reverseTimer;
  int _reverseRequest = 0;
  LatLng? _point;
  List<Map<String, dynamic>> _results = [];
  String _address = '', _district = '', _message = '';
  bool _searching = false, _geocoding = false, _manualName = false;
  bool _mapTilesFailed = false;

  @override
  void initState() {
    super.initState();
    final old = widget.existing;
    final lat = old?['latitude'], lng = old?['longitude'];
    if (lat is num && lng is num) {
      _point = LatLng(lat.toDouble(), lng.toDouble());
      _name.text = '${old?['name'] ?? ''}';
      _address = '${old?['address'] ?? ''}';
      _district = '${old?['district'] ?? ''}';
      _manualName = old?['nameManuallyEdited'] != false;
    }
  }

  @override
  void dispose() {
    _reverseTimer?.cancel();
    _search.dispose();
    _name.dispose();
    _mapController.dispose();
    super.dispose();
  }

  String get _fallbackName => widget.fallbackName;

  Future<void> _searchPlaces() async {
    if (_search.text.trim().length < 3) {
      setState(() => _message = 'Enter at least 3 letters to search.');
      return;
    }
    setState(() {
      _searching = true;
      _message = '';
      _results = [];
    });
    try {
      final result = await Api.call('searchBoardingPlaces', {
        'query': _search.text.trim(),
      });
      if (!mounted) return;
      setState(() {
        _results = asList(result['places']);
        _searching = false;
        if (_results.isEmpty) {
          _message = 'No matching places found. Try a nearby landmark or road.';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _message =
            'Location search failed. Check your connection and try again, or tap the map.';
      });
    }
  }

  void _selectSearchResult(Map<String, dynamic> result) {
    final lat = result['latitude'], lng = result['longitude'];
    if (lat is! num || lng is! num) {
      setState(
        () => _message = 'That search result has no usable map location.',
      );
      return;
    }
    final point = LatLng(lat.toDouble(), lng.toDouble());
    if (!_validPoint(point)) {
      setState(() => _message = 'That search result has invalid coordinates.');
      return;
    }
    final rawName = '${result['name'] ?? ''}'.trim();
    final needsReverse = rawName.isEmpty || rawName == 'Selected location';
    setState(() {
      _point = point;
      _results = [];
      _address = '${result['address'] ?? ''}';
      _district = '${result['district'] ?? ''}';
      _message = '';
      _geocoding = false;
      if (!_manualName) {
        _name.text = needsReverse ? _fallbackName : rawName;
      }
    });
    _mapController.move(point, 16);
    if (needsReverse) _selectMapPoint(point);
  }

  bool _validPoint(LatLng point) =>
      point.latitude.isFinite &&
      point.longitude.isFinite &&
      point.latitude >= -90 &&
      point.latitude <= 90 &&
      point.longitude >= -180 &&
      point.longitude <= 180;

  String _placeName(Object? value) {
    final text = '$value'.trim();
    return text.isEmpty || text == 'null' ? _fallbackName : text;
  }

  void _selectMapPoint(LatLng point) {
    if (!_validPoint(point)) {
      setState(() => _message = 'Choose a valid location on the map.');
      return;
    }
    setState(() {
      _point = point;
      _address = '';
      _district = '';
      _message = '';
      _geocoding = true;
    });
    _reverseTimer?.cancel();
    final request = ++_reverseRequest;
    _reverseTimer = Timer(
      const Duration(milliseconds: 900),
      () => _reverse(point, request),
    );
  }

  void _dragPin(DragUpdateDetails details) {
    final renderObject = _mapKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox) return;
    final local = renderObject.globalToLocal(details.globalPosition);
    final point = _mapController.camera.offsetToCrs(local);
    _selectMapPoint(point);
  }

  Future<void> _reverse(LatLng point, int request) async {
    try {
      final result = await Api.call('reverseGeocodeBoardingPoint', {
        'latitude': point.latitude,
        'longitude': point.longitude,
      });
      if (!mounted || request != _reverseRequest) return;
      final suggested = _placeName(result['name']);
      setState(() {
        _address = '${result['address'] ?? ''}';
        _district = '${result['district'] ?? ''}';
        if (!_manualName) _name.text = suggested;
        _geocoding = false;
        _message = result['name'] == null || '${result['name']}'.trim().isEmpty
            ? 'A nearby place name was not found. You can keep or edit the fallback name.'
            : '';
      });
    } catch (_) {
      if (!mounted || request != _reverseRequest) return;
      setState(() {
        _address = '';
        _district = '';
        if (!_manualName) _name.text = _fallbackName;
        _geocoding = false;
        _message =
            'Could not detect a nearby name. A fallback is ready; you can still save this location.';
      });
    }
  }

  Future<void> _refreshSuggestion() async {
    final point = _point;
    if (point == null) return;
    _reverseTimer?.cancel();
    final request = ++_reverseRequest;
    setState(() {
      _manualName = false;
      _geocoding = true;
      _message = '';
    });
    await _reverse(point, request);
  }

  void _save() {
    final point = _point;
    final name = _name.text.trim();
    if (point == null || !_validPoint(point)) {
      setState(() => _message = 'Select a location on the map first.');
      return;
    }
    if (name.isEmpty) {
      setState(() => _message = 'Enter a boarding point name.');
      return;
    }
    Navigator.pop(context, {
      'name': name,
      'nameManuallyEdited': _manualName,
      'address': _address,
      'district': _district,
      'latitude': point.latitude,
      'longitude': point.longitude,
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final initialCenter = _point ?? widget.collegeCenter ?? const LatLng(0, 0);
    final initialZoom = _point != null || widget.collegeCenter != null
        ? 14.0
        : 2.0;
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 920,
          maxHeight: size.height * 0.92,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.existing == null
                          ? 'Add boarding point'
                          : 'Edit boarding point',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Cancel',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (widget.collegeCenter == null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      widget.collegeMessage.isEmpty
                          ? 'College location is not configured. Search for a location to centre the map.'
                          : widget.collegeMessage,
                    ),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _search,
                      textInputAction: TextInputAction.search,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        labelText: 'Search a place or address',
                      ),
                      onSubmitted: (_) => _searchPlaces(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _searching ? null : _searchPlaces,
                    child: _searching
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Search'),
                  ),
                ],
              ),
              if (_results.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 140),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final result in _results)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.place_outlined),
                          title: Text(
                            '${result['name']}'.trim().isEmpty
                                ? 'Location result'
                                : '${result['name']}',
                          ),
                          subtitle: Text(
                            '${result['address'] ?? ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _selectSearchResult(result),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    children: [
                      FlutterMap(
                        key: _mapKey,
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: initialCenter,
                          initialZoom: initialZoom,
                          onTap: (_, point) => _selectMapPoint(point),
                        ),
                        children: [
                          TileLayer(
                            urlTemplate:
                                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.example.routesync',
                            errorTileCallback: (_, _, _) {
                              if (mounted && !_mapTilesFailed) {
                                setState(() => _mapTilesFailed = true);
                              }
                            },
                          ),
                          if (_point != null)
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: _point!,
                                  width: 56,
                                  height: 62,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onPanUpdate: _dragPin,
                                    child: const Align(
                                      alignment: Alignment.topCenter,
                                      child: Icon(
                                        Icons.location_on,
                                        size: 48,
                                        color: Colors.red,
                                        semanticLabel:
                                            'Selected boarding point; drag to adjust',
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                      if (_point == null)
                        const Positioned(
                          left: 12,
                          top: 12,
                          child: Card(
                            child: Padding(
                              padding: EdgeInsets.all(10),
                              child: Text('Tap the map to place a pin.'),
                            ),
                          ),
                        ),
                      if (_mapTilesFailed)
                        const Positioned(
                          left: 8,
                          right: 8,
                          bottom: 8,
                          child: Card(
                            child: Padding(
                              padding: EdgeInsets.all(8),
                              child: Text(
                                'Map tiles could not be loaded. Check your internet connection; location search and pin selection remain available.',
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              if (_point != null) ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _name,
                        maxLength: 120,
                        decoration: InputDecoration(
                          labelText: 'Boarding Point Name',
                          suffixIcon: IconButton(
                            tooltip: 'Refresh suggested name',
                            onPressed: _geocoding ? null : _refreshSuggestion,
                            icon: const Icon(Icons.refresh),
                          ),
                        ),
                        onChanged: (_) => _manualName = true,
                      ),
                    ),
                    if (_geocoding)
                      const Padding(
                        padding: EdgeInsets.only(left: 8, bottom: 20),
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      _address.isEmpty
                          ? 'Detected address will appear here when available.'
                          : 'Detected address: $_address',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (_district.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('District: $_district'),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Selected coordinates: ${_point!.latitude.toStringAsFixed(6)}, ${_point!.longitude.toStringAsFixed(6)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
              if (_message.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _message,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _point == null || _geocoding ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save Boarding Point'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BoardingPointPreview extends StatelessWidget {
  final LatLng point;
  const _BoardingPointPreview({required this.point});

  @override
  Widget build(BuildContext context) => FlutterMap(
    options: MapOptions(initialCenter: point, initialZoom: 15),
    children: [
      TileLayer(
        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        userAgentPackageName: 'com.example.routesync',
      ),
      MarkerLayer(
        markers: [
          Marker(
            point: point,
            width: 48,
            height: 54,
            child: const Icon(
              Icons.location_on,
              color: Colors.red,
              size: 44,
              semanticLabel: 'Boarding point location',
            ),
          ),
        ],
      ),
    ],
  );
}
