import 'package:audioplayers/audioplayers.dart';

/// Short sounds for the cashier, so they know a scan worked (or didn't) without looking.
///
/// Plays our own sound files at the tablet's media volume. The built-in click sound depends on
/// the tablet's "Touch sounds" setting, which is usually off.
class Beeper {
  Beeper() {
    // Low-latency mode: made for short sounds that must play straight away.
    _ok.setPlayerMode(PlayerMode.lowLatency);
    _error.setPlayerMode(PlayerMode.lowLatency);
  }

  final _ok = AudioPlayer();
  final _error = AudioPlayer();

  /// A short high beep: an item was added.
  Future<void> ok() => _play(_ok, 'sounds/beep_ok.wav');

  /// Two low beeps: something needs the cashier's attention.
  Future<void> error() => _play(_error, 'sounds/beep_error.wav');

  Future<void> _play(AudioPlayer player, String asset) async {
    try {
      await player.stop(); // restart the sound if it's still playing from the last scan
      await player.play(AssetSource(asset));
    } catch (_) {
      // A missing sound must never stop a sale.
    }
  }

  void dispose() {
    _ok.dispose();
    _error.dispose();
  }
}
