import 'package:flutter/material.dart';

import 'altai_theme.dart';
import 'altai_widgets.dart';
import 'reader_session.dart';
import 'rfid_reader.dart';

/// The reader at a glance: a green dot while it reads, grey when it's off. The cashier doesn't
/// start or stop it; the screen does.
class ReaderDot extends StatelessWidget {
  const ReaderDot({super.key, required this.on, this.justRead = false});

  /// Is the reader reading?
  final bool on;

  /// A tag landed a moment ago.
  final bool justRead;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: on ? c.brand : c.inkMuted, shape: BoxShape.circle),
        ),
        const SizedBox(width: D.space2),
        Text(
          on ? (justRead ? 'Reading…' : 'Reader on') : 'Reader off',
          style: AltaiType.label.copyWith(color: c.ink),
        ),
      ],
    );
  }
}

/// What's wrong with the reader, and the one button that fixes it: Allow (Android's access box)
/// or Retry (after plugging it in). Nothing when the reader is fine.
class ReaderProblem extends StatelessWidget {
  const ReaderProblem({super.key, required this.session});

  final ReaderSession session;

  @override
  Widget build(BuildContext context) {
    final e = session.error;
    if (e == null) return const SizedBox.shrink();
    return Row(
      children: [
        Expanded(child: AltaiNotice(e, warning: true)),
        TextButton(
          onPressed: () => session.start(),
          child: Text(session.usb == ReaderState.needsPermission ? 'Allow' : 'Retry'),
        ),
      ],
    );
  }
}
