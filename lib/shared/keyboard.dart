import 'package:flutter/services.dart';

/// Shows the on-screen keyboard.
///
/// The EPC boxes use TextInputType.none so the reader can type without a keyboard covering the
/// screen. Android can keep that "no keyboard" setting after leaving those screens, so a normal text
/// box (login, location, receipt) then gets focus but no keyboard. Calling this on tap fixes it.
void showKeyboard() => SystemChannels.textInput.invokeMethod<void>('TextInput.show');
