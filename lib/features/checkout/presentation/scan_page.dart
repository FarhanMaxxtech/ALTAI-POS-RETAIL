import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/altai_theme.dart';
import '../../../shared/altai_widgets.dart';
import '../../../shared/beeper.dart';
import '../../../shared/rfid_reader.dart';

enum ScanPhase { ready, reading, done }

/// Put the items on the reader, press Scan, and every tag is read in one go.
///
/// The app tells the USB reader ([reader]) to read, round after round, until a couple of rounds
/// bring nothing new. Returns the tags read (null = cancelled).
class ScanPage extends StatefulWidget {
  const ScanPage({
    super.key,
    required this.reader,
    this.target = 'basket',
    this.minRead = const Duration(seconds: 2),
    this.round = const Duration(milliseconds: 800),
  });

  /// The USB RFID reader.
  final TagReader reader;

  /// Where the tags go, for the last button: "Add 3 to basket" / "to return" / "to order".
  final String target;

  /// One read round of the USB reader.
  final Duration round;

  /// Reading lasts at least this long after Scan is pressed.
  final Duration minRead;

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _beeper = Beeper();
  final Set<String> _tags = {}; // in the order read
  ScanPhase _phase = ScanPhase.ready;
  ReaderState _usb = ReaderState.none;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkReader();
  }

  Future<void> _checkReader() async {
    final s = await widget.reader.state();
    if (mounted) setState(() => _usb = s);
  }

  Future<void> _allowReader() async {
    final ok = await widget.reader.askPermission();
    if (!mounted) return;
    await _checkReader();
    if (!ok && mounted) {
      setState(
        () => _error = 'The reader was not allowed. Tap Allow to try again.',
      );
    }
  }

  /// USB reader: read round after round; stop after the minimum time once 2 rounds found nothing new.
  Future<void> _usbLoop() async {
    final reader = widget.reader;
    // Read time so far, counted in rounds (each round is one read of widget.round).
    var readTime = Duration.zero;
    var quietRounds = 0;
    while (mounted && _phase == ScanPhase.reading) {
      List<String> got;
      try {
        got = await reader.read(widget.round);
        readTime += widget.round;
      } on ReaderException catch (e) {
        if (!mounted) return;
        setState(() => _error = e.message);
        _finish();
        _checkReader();
        return;
      }
      if (!mounted) return;
      final added = _add(got); // keep what the last round read, even after Stop
      if (_phase != ScanPhase.reading) return;
      quietRounds = added ? 0 : quietRounds + 1;
      if (quietRounds >= 2 && readTime >= widget.minRead) _finish();
    }
  }

  /// Adds new tags; true if any was new.
  bool _add(Iterable<String> epcs) {
    final fresh = [
      for (final e in epcs)
        if (!_tags.contains(e)) e,
    ];
    if (fresh.isEmpty) return false;
    HapticFeedback.lightImpact();
    _beeper.ok();
    setState(() => _tags.addAll(fresh));
    return true;
  }

  @override
  void dispose() {
    _beeper.dispose();
    super.dispose();
  }

  Future<void> _scan({bool fresh = false}) async {
    if (_usb != ReaderState.ready) {
      if (_usb == ReaderState.needsPermission) await _allowReader();
      if (_usb == ReaderState.none) await _checkReader();
      if (!mounted) return;
      if (_usb != ReaderState.ready) {
        setState(
          () => _error =
              'No RFID reader. Plug the reader into the tablet, then tap Look again.',
        );
        return;
      }
    }
    setState(() {
      if (fresh) _tags.clear();
      _error = null;
      _phase = ScanPhase.reading;
    });
    _usbLoop();
  }

  void _finish() {
    if (mounted) setState(() => _phase = ScanPhase.done);
  }

  @override
  Widget build(BuildContext context) {
    final n = _tags.length;
    return Scaffold(
      appBar: AltaiAppBar(
        title: 'Scan items',
        onBack: () => Navigator.of(context).pop(),
      ),
      body: Center(
        // Scrolls on a short screen (portrait with a small window, big text).
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(D.space6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _readerLine(context),
                  const SizedBox(height: D.space4),
                  _steps(context),
                  const SizedBox(height: D.space6),
                  _status(context, n),
                  const SizedBox(height: D.space6),
                  ..._buttons(n),
                  if (_error case final e?) ...[
                    const SizedBox(height: D.space4),
                    AltaiNotice(e, warning: true),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Which reader this page uses.
  Widget _readerLine(BuildContext context) {
    final c = context.altai;
    final (icon, text, color) = switch (_usb) {
      ReaderState.ready => (
        Icons.usb_rounded,
        'USB reader connected',
        c.brandInk,
      ),
      ReaderState.needsPermission => (
        Icons.usb_rounded,
        'USB reader found: allow the app to use it',
        c.warning,
      ),
      ReaderState.none => (
        Icons.usb_off_rounded,
        'No RFID reader plugged in',
        c.warning,
      ),
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: D.space2),
        Flexible(
          child: Text(text, style: AltaiType.caption.copyWith(color: color)),
        ),
        if (_usb == ReaderState.needsPermission)
          TextButton(onPressed: _allowReader, child: const Text('Allow')),
        if (_usb == ReaderState.none)
          TextButton(onPressed: _checkReader, child: const Text('Look again')),
      ],
    );
  }

  Widget _steps(BuildContext context) {
    final c = context.altai;
    Widget step(String no, String text, bool on) => Row(
      children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: on ? c.brand : c.surfaceSunken,
          child: Text(
            no,
            style: AltaiType.label.copyWith(color: on ? c.onBrand : c.inkMuted),
          ),
        ),
        const SizedBox(width: D.space3),
        Expanded(
          child: Text(
            text,
            style: AltaiType.body.copyWith(color: on ? c.ink : c.inkMuted),
          ),
        ),
      ],
    );
    return Column(
      children: [
        step('1', 'Put all the items on the reader', _phase == ScanPhase.ready),
        const SizedBox(height: D.space2),
        step(
          '2',
          'Press Scan and keep them there',
          _phase == ScanPhase.reading,
        ),
        const SizedBox(height: D.space2),
        step(
          '3',
          'Check the count, then add them to the basket',
          _phase == ScanPhase.done,
        ),
      ],
    );
  }

  Widget _status(BuildContext context, int n) {
    final c = context.altai;
    final caption = switch (_phase) {
      ScanPhase.ready =>
        n == 0
            ? 'Nothing read yet'
            : 'already read, press Scan to read the rest',
      ScanPhase.reading => 'Reading… keep the items on the reader',
      ScanPhase.done => 'Done reading',
    };
    return Column(
      children: [
        Text(
          '$n',
          key: const ValueKey('scan-count'),
          style: AltaiType.qtyTotal.copyWith(
            fontSize: 72,
            height: 1,
            color: c.brandInk,
          ),
        ),
        Text(
          n == 1 ? 'pc' : 'pcs',
          style: AltaiType.label.copyWith(color: c.ink),
        ),
        const SizedBox(height: D.space3),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_phase == ScanPhase.reading) ...[
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: D.space2),
            ],
            if (_phase == ScanPhase.done) ...[
              Icon(Icons.check_circle_rounded, color: c.brandInk, size: 20),
              const SizedBox(width: D.space2),
            ],
            Flexible(
              child: Text(
                caption,
                style: AltaiType.body.copyWith(color: c.inkMuted),
              ),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _buttons(int n) => switch (_phase) {
    ScanPhase.ready => [
      AltaiButton(
        'Scan',
        onPressed: _scan,
        variant: AltaiButtonVariant.primary,
        icon: Icons.sensors_rounded,
        large: true,
        expand: true,
      ),
    ],
    ScanPhase.reading => [
      AltaiButton('Stop', onPressed: _finish, large: true, expand: true),
    ],
    ScanPhase.done => [
      AltaiButton(
        n == 0 ? 'Nothing read' : 'Add $n to ${widget.target}',
        onPressed: n == 0
            ? null
            : () => Navigator.of(context).pop(_tags.toList()),
        variant: AltaiButtonVariant.primary,
        icon: Icons.add_shopping_cart_rounded,
        large: true,
        expand: true,
      ),
      const SizedBox(height: D.space3),
      AltaiButton(
        'Scan again',
        onPressed: () => _scan(fresh: true),
        icon: Icons.refresh_rounded,
        expand: true,
      ),
    ],
  };
}
