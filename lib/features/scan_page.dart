import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Scans an invitation QR code and returns the code. Accepts a RouteSync link or the bare code.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan invitation QR')),
    body: Stack(
      children: [
        MobileScanner(
          onDetect: (capture) {
            if (_done) return;
            final raw = capture.barcodes.isEmpty
                ? null
                : capture.barcodes.first.rawValue;
            if (raw == null || raw.isEmpty) return;
            _done = true;
            final code = Uri.tryParse(raw)?.queryParameters['code'] ?? raw;
            Navigator.pop(context, code.trim());
          },
        ),
        const Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Point the camera at the QR code from your college',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
