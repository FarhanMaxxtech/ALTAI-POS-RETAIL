import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/altai_theme.dart';
import '../../../shared/altai_widgets.dart';
import '../../../shared/beeper.dart';
import '../domain/basket.dart';

enum ScanPhase { ready, reading, done }

/// Put the items on the reader, press Scan, and every tag is read in one go.
///
/// The reader types each tag like a keyboard and presses Enter, so this page keeps a small box
/// focused the whole time. Reading stops by itself once no new tag has come for a moment.
/// Returns the tags read (null = cancelled).
class ScanPage extends StatefulWidget {
  const ScanPage({
    super.key,
    this.minRead = const Duration(seconds: 2),
    this.quiet = const Duration(milliseconds: 1500),
  });

  /// Reading lasts at least this long after Scan is pressed.
  final Duration minRead;

  /// ...and stops when no new tag came for this long.
  final Duration quiet;

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _beeper = Beeper();
  final Set<String> _tags = {}; // in the order read
  ScanPhase _phase = ScanPhase.ready;
  Timer? _stop;

  @override
  void dispose() {
    _stop?.cancel();
    _input.dispose();
    _focus.dispose();
    _beeper.dispose();
    super.dispose();
  }

  void _scan({bool fresh = false}) {
    setState(() {
      if (fresh) _tags.clear();
      _phase = ScanPhase.reading;
    });
    _stop?.cancel();
    _stop = Timer(widget.minRead, _finish);
    _focus.requestFocus();
  }

  void _finish() {
    _stop?.cancel();
    if (mounted) setState(() => _phase = ScanPhase.done);
  }

  /// The reader pressed Enter: take every tag in the box.
  void _read([String? _]) {
    final fresh = [
      for (final e in parseTags(_input.text).epcs)
        if (!_tags.contains(e)) e,
    ];
    _input.clear();
    _focus.requestFocus();
    if (fresh.isEmpty) return;
    HapticFeedback.lightImpact();
    _beeper.ok();
    setState(() => _tags.addAll(fresh));
    // A tag after reading ended (an item put down late) reopens the reading.
    if (_phase == ScanPhase.done) setState(() => _phase = ScanPhase.reading);
    if (_phase == ScanPhase.reading) {
      _stop?.cancel();
      _stop = Timer(widget.quiet, _finish);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final n = _tags.length;
    return Scaffold(
      appBar: AltaiAppBar(
        title: 'Scan items',
        onBack: () => Navigator.of(context).pop(),
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _focus.requestFocus, // keep the reader's typing landing here
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(D.space6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _steps(context),
                  const SizedBox(height: D.space6),
                  _status(context, n),
                  const SizedBox(height: D.space6),
                  ..._buttons(n),
                  const SizedBox(height: D.space6),
                  // Where the reader types. Small, but kept on screen so it can hold the focus.
                  SizedBox(
                    width: 260,
                    child: TextField(
                      controller: _input,
                      focusNode: _focus,
                      autofocus: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.none,
                      textAlign: TextAlign.center,
                      style: AltaiType.caption.copyWith(color: c.inkMuted),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Reader input',
                      ),
                      onSubmitted: _read,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
        n == 0 ? 'Nothing read' : 'Add $n to basket',
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
