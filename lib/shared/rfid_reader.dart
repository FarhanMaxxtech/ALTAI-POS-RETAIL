import 'package:flutter/services.dart';

/// none = no USB reader plugged in, needsPermission = plugged in but Android hasn't allowed it yet.
enum ReaderState { none, needsPermission, ready }

class ReaderException implements Exception {
  ReaderException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The RFID reader the app drives: press Scan, it reads, it hands back the EPCs.
abstract class TagReader {
  Future<ReaderState> state();

  /// Shows Android's "allow access" box. True = allowed.
  Future<bool> askPermission();

  /// Reads for [time] and returns every EPC seen (upper-case hex, no duplicates).
  Future<List<String>> read(Duration time);
}

/// The Silion USB reader, through the Android code in SilionReader.kt.
class UsbTagReader implements TagReader {
  const UsbTagReader();

  static const _channel = MethodChannel('altai/rfid');

  @override
  Future<ReaderState> state() async {
    try {
      return switch (await _channel.invokeMethod<String>('status')) {
        'ready' => ReaderState.ready,
        'no-permission' => ReaderState.needsPermission,
        _ => ReaderState.none,
      };
    } on MissingPluginException {
      return ReaderState.none; // not on Android (tests, desktop)
    } on PlatformException {
      return ReaderState.none;
    }
  }

  @override
  Future<bool> askPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<List<String>> read(Duration time) async {
    try {
      final tags = await _channel.invokeListMethod<String>('inventory', {
        'ms': time.inMilliseconds,
      });
      return tags ?? const [];
    } on PlatformException catch (e) {
      throw ReaderException(e.message ?? 'Reader problem');
    } on MissingPluginException {
      throw ReaderException('No RFID reader on this device.');
    }
  }
}
