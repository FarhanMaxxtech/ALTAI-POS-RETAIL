import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'altai_theme.dart';
import 'altai_widgets.dart';

/// Opens the camera and returns the first barcode or QR code it reads. Null = cancelled.
Future<String?> scanBarcode(BuildContext context) =>
    Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const BarcodeScanScreen()));

/// Camera view for reading the barcode printed on a StoreHub receipt.
class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({super.key});

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen> {
  final _controller = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool _done = false; // the camera can report the same code several times

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final value = b.rawValue?.trim();
      if (value != null && value.isNotEmpty) {
        _done = true;
        Navigator.of(context).pop(value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Scaffold(
      appBar: AltaiAppBar(
        title: 'Scan receipt barcode',
        onBack: () => Navigator.of(context).pop(),
        actions: [
          AppBarIcon(Icons.flash_on_rounded, tooltip: 'Torch', onPressed: _controller.toggleTorch),
          AppBarIcon(Icons.cameraswitch_rounded, tooltip: 'Switch camera', onPressed: _controller.switchCamera),
        ],
      ),
      body: Stack(fit: StackFit.expand, children: [
        MobileScanner(
          controller: _controller,
          onDetect: _onDetect,
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(D.space6),
              child: AltaiNotice(error.errorCode == MobileScannerErrorCode.permissionDenied
                  ? 'The app needs the camera. Allow it in the tablet\'s Settings › Apps › Altai POS.'
                  : 'The camera could not start. Type the number instead.'),
            ),
          ),
        ),
        // A frame to aim with.
        Center(
          child: Container(
            width: 320,
            height: 200,
            decoration: BoxDecoration(
              border: Border.all(color: c.brand, width: 3),
              borderRadius: BorderRadius.circular(D.radiusMd),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: D.space6,
          child: Text('Point the camera at the barcode on the receipt',
              textAlign: TextAlign.center,
              style: AltaiType.label.copyWith(color: Colors.white, shadows: const [Shadow(blurRadius: 6)])),
        ),
      ]),
    );
  }
}
