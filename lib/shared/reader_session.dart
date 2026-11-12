import 'package:flutter/foundation.dart';

import 'rfid_reader.dart';

/// Drives the USB RFID reader for one screen (Checkout or Return): reads round after round and
/// hands each round's tags to [onTags], until [stop] or until the screen closes ([dispose]).
///
/// The screen calls [start] as soon as it opens and keeps it reading: the cashier never taps Scan. The screen's
/// own list (the basket, the return) decides what a tag is; a tag read on every round is the
/// screen's to ignore.
class ReaderSession extends ChangeNotifier {
  ReaderSession({required this.reader, required this.onTags, this.round = const Duration(milliseconds: 800)});

  final TagReader reader;

  /// The tags read in one round (upper-case hex), every round, even an empty one: the screen counts
  /// the rounds a removed item has been away. Called only while the screen is open.
  final void Function(List<String> epcs) onTags;

  /// One read round of the USB reader.
  final Duration round;

  /// Is the reader plugged in and allowed?
  ReaderState usb = ReaderState.none;

  /// True while the reader runs.
  bool reading = false;

  /// What went wrong with the reader, in words for the cashier. Null when nothing did.
  String? error;

  int _run = 0; // which reading loop is the current one (a quick Stop then Scan starts a new one)
  bool _closed = false;

  void _changed() {
    if (!_closed) notifyListeners();
  }

  /// Asks whether the reader is plugged in (and allowed).
  Future<void> checkReader() async {
    final s = await reader.state();
    if (_closed) return;
    usb = s;
    if (s == ReaderState.ready) error = null;
    _changed();
  }

  /// Shows Android's "allow access" box, then looks at the reader again.
  Future<void> allow() async {
    final ok = await reader.askPermission();
    if (_closed) return;
    await checkReader();
    if (!ok && !_closed) {
      error = 'The reader was not allowed. Tap Allow to try again.';
      _changed();
    }
  }

  /// Starts reading. False when there's no reader (then [error] says what to do).
  Future<bool> start() async {
    if (_closed) return false;
    if (reading) return true;
    if (usb != ReaderState.ready) {
      if (usb == ReaderState.needsPermission) {
        await allow();
      } else {
        await checkReader();
        if (usb == ReaderState.needsPermission) await allow();
      }
      if (_closed) return false;
      if (usb != ReaderState.ready) {
        error = 'No RFID reader. Plug the reader into the tablet, then tap Retry.';
        _changed();
        return false;
      }
    }
    error = null;
    reading = true;
    _changed();
    _loop(++_run);
    return true;
  }

  /// Stops reading. What the round in progress reads is dropped.
  void stop() {
    if (!reading) return;
    reading = false;
    _run++;
    _changed();
  }

  Future<void> _loop(int run) async {
    while (!_closed && reading && run == _run) {
      List<String> got;
      try {
        got = await reader.read(round);
      } on ReaderException catch (e) {
        if (_closed || run != _run) return;
        error = e.message;
        reading = false;
        _changed();
        checkReader();
        return;
      }
      // Stopped meanwhile (the confirm box, another screen): what's on screen stays as it is.
      if (_closed || run != _run) return;
      onTags(got);
    }
  }

  @override
  void dispose() {
    _closed = true;
    reading = false;
    _run++;
    super.dispose();
  }
}
