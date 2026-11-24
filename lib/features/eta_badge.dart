import 'dart:async';
import 'package:material_ui/material_ui.dart';
import '../core/api.dart';

/// Arrival time to the rider's stop by road. Refreshes every 30 seconds. No live traffic is included.
class EtaBadge extends StatefulWidget {
  final String busId;
  const EtaBadge({super.key, required this.busId});
  @override
  State<EtaBadge> createState() => _EtaBadgeState();
}

class _EtaBadgeState extends State<EtaBadge> {
  Timer? _t;
  String _text = 'Checking arrival time...';

  @override
  void initState() {
    super.initState();
    _tick();
    _t = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Future<void> _tick() async {
    String text;
    try {
      final r = await Api.call('getEta', {'busId': widget.busId});
      if (r['available'] == true) {
        final m = (r['minutes'] as num).toInt();
        final km = (r['km'] as num).toDouble();
        text = km <= 1.2
            ? 'Bus is nearby: about ${m <= 1 ? 'a minute' : '$m min'} to your stop'
            : (m <= 1
                  ? 'Arriving now'
                  : 'About $m min to your stop (${km.toStringAsFixed(1)} km by road)');
      } else {
        text = '${r['reason'] ?? 'Arrival time unavailable'}';
      }
    } catch (_) {
      text = 'Arrival time unavailable right now.';
    }
    if (mounted) setState(() => _text = text);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Row(
      children: [
        Icon(
          Icons.schedule,
          size: 18,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '$_text. Estimate only.',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    ),
  );
}
