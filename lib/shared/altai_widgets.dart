import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'altai_theme.dart';

/// Building blocks of the Altai design system, shared by every screen.

/// "E280689400005012" → "E280 6894 0000 5012", easier to read and compare.
String formatEpc(String epc) {
  final e = epc.toUpperCase();
  return [
    for (var i = 0; i < e.length; i += 4)
      e.substring(i, (i + 4).clamp(0, e.length)),
  ].join(' ');
}

/// 1 → "1 SKU", 3 → "3 SKUs"
String plural(int n, String one, [String? many]) =>
    '$n ${n == 1 ? one : (many ?? '${one}s')}';

/* ---------------- Logo ---------------- */

/// The Altai mark (the "A"). [full] = with the word "altai" under it.
class AltaiLogo extends StatelessWidget {
  const AltaiLogo({
    super.key,
    required this.height,
    this.color,
    this.full = false,
  });

  final double height;
  final Color? color; // white by default
  final bool full;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    full ? 'assets/brand/altai_logo.svg' : 'assets/brand/altai_mark.svg',
    height: height,
    colorFilter: color == null
        ? null
        : ColorFilter.mode(color!, BlendMode.srcIn),
    semanticsLabel: 'Altai',
  );
}

/* ---------------- App bar ---------------- */

/// Green gradient bar with the Altai mark, a title and an optional subtitle.
class AltaiAppBar extends StatelessWidget implements PreferredSizeWidget {
  const AltaiAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.onSubtitleTap,
    this.onBack,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final VoidCallback?
  onSubtitleTap; // makes the subtitle a button (e.g. change store)
  final VoidCallback? onBack;
  final List<Widget> actions;

  @override
  Size get preferredSize => const Size.fromHeight(D.touchLg);

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final sub = (subtitle?.isEmpty ?? true) ? null : subtitle;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [c.logoGreenTop, c.logoGreenBottom],
        ),
      ),
      // Only keep clear of the status bar at the top. Left/right padding pushed the
      // icons towards the middle when the app runs in a window.
      child: SafeArea(
        left: false,
        right: false,
        bottom: false,
        child: SizedBox(
          height: D.touchLg,
          child: Row(
            children: [
              const SizedBox(width: D.space3),
              if (onBack != null)
                AppBarIcon(
                  Icons.arrow_back_rounded,
                  tooltip: 'Back',
                  onPressed: onBack,
                )
              else
                const SizedBox(width: D.space3),
              const AltaiLogo(height: 36),
              const SizedBox(width: D.space4),
              Text(
                title,
                style: AltaiType.title.copyWith(color: c.onLogoGreen),
                maxLines: 1,
              ),
              if (sub != null) ...[
                const SizedBox(width: D.space4),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: InkWell(
                      onTap: onSubtitleTap,
                      borderRadius: BorderRadius.circular(D.radiusSm),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: D.space2,
                          vertical: D.space2,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                sub,
                                style: AltaiType.body.copyWith(
                                  fontSize: AltaiType.label.fontSize,
                                  color: c.onLogoGreen.withValues(alpha: 0.92),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (onSubtitleTap != null)
                              Icon(
                                Icons.expand_more_rounded,
                                size: 22,
                                color: c.onLogoGreen.withValues(alpha: 0.92),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ] else
                const Spacer(),
              ...actions,
              const SizedBox(width: D.space3), // small gap from the screen edge
            ],
          ),
        ),
      ),
    );
  }
}

/// A white icon button for the app bar.
class AppBarIcon extends StatelessWidget {
  const AppBarIcon(
    this.icon, {
    super.key,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    tooltip: tooltip,
    iconSize: 28,
    color: context.altai.onLogoGreen,
    icon: Icon(icon),
  );
}

/// Text for the right side of the app bar, e.g. the staff name.
class AppBarText extends StatelessWidget {
  const AppBarText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: D.space2),
    child: Text(
      text,
      style: AltaiType.label.copyWith(color: context.altai.onLogoGreen),
    ),
  );
}

/* ---------------- Buttons ---------------- */

enum AltaiButtonVariant { primary, secondary, ghost, danger }

class AltaiButton extends StatelessWidget {
  const AltaiButton(
    this.text, {
    super.key,
    required this.onPressed, // null = disabled
    this.variant = AltaiButtonVariant.secondary,
    this.icon,
    this.large = false,
    this.expand = false, // fill the available width
  });

  final String text;
  final VoidCallback? onPressed;
  final AltaiButtonVariant variant;
  final IconData? icon;
  final bool large;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final enabled = onPressed != null;
    final (bg, fg, side) = switch (variant) {
      AltaiButtonVariant.primary => (c.brand, c.onBrand, BorderSide.none),
      AltaiButtonVariant.secondary => (
        c.surfaceRaised,
        c.ink,
        BorderSide(color: c.borderStrong, width: 1.5),
      ),
      AltaiButtonVariant.ghost => (
        Colors.transparent,
        c.brandInk,
        BorderSide.none,
      ),
      AltaiButtonVariant.danger => (c.danger, c.onDanger, BorderSide.none),
    };
    final ghost = variant == AltaiButtonVariant.ghost;
    final button = TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        backgroundColor: bg,
        disabledBackgroundColor: ghost ? Colors.transparent : c.surfaceSunken,
        foregroundColor: fg,
        disabledForegroundColor: c.inkMuted,
        minimumSize: Size(0, large ? D.touchLg : D.touchMin),
        padding: EdgeInsets.symmetric(horizontal: large ? D.space8 : D.space6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(D.radiusMd),
        ),
        side: enabled
            ? side
            : (ghost
                  ? BorderSide.none
                  : BorderSide(color: c.border, width: 1.5)),
        textStyle: large
            ? AltaiType.title.copyWith(fontSize: 22)
            : AltaiType.bodyStrong.copyWith(fontSize: AltaiType.body.fontSize),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: large ? 28 : 24),
            const SizedBox(width: D.space2),
          ],
          Flexible(
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/* ---------------- Badges & notices ---------------- */

enum BadgeTone { neutral, brand, warning, danger }

class AltaiBadge extends StatelessWidget {
  const AltaiBadge(
    this.text, {
    super.key,
    this.tone = BadgeTone.neutral,
    this.icon,
  });

  final String text;
  final BadgeTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final (bg, fg) = switch (tone) {
      BadgeTone.neutral => (c.surfaceSunken, c.inkMuted),
      BadgeTone.brand => (c.brandTint, c.brandInk),
      BadgeTone.warning => (c.warningTint, c.warning),
      BadgeTone.danger => (c.dangerTint, c.danger),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: D.space2, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(D.radiusSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: D.space1),
          ],
          Text(
            text,
            style: AltaiType.caption.copyWith(
              fontWeight: FontWeight.w600,
              color: fg,
            ),
            maxLines: 1,
          ),
        ],
      ),
    );
  }
}

/// A red (or orange) message box.
class AltaiNotice extends StatelessWidget {
  const AltaiNotice(this.text, {super.key, this.warning = false});

  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final fg = warning ? c.warning : c.danger;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: D.space4,
        vertical: D.space3,
      ),
      decoration: BoxDecoration(
        color: warning ? c.warningTint : c.dangerTint,
        borderRadius: BorderRadius.circular(D.radiusMd),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 22, color: fg),
          const SizedBox(width: D.space2),
          Expanded(
            child: Text(
              text,
              style: AltaiType.body.copyWith(fontSize: 16, color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Ready to scan" pill. Shows "Reading…" with a blinking dot for a moment after each tag.
class ReaderStatusPill extends StatefulWidget {
  const ReaderStatusPill({super.key, required this.reading});

  final bool reading;

  @override
  State<ReaderStatusPill> createState() => _ReaderStatusPillState();
}

class _ReaderStatusPillState extends State<ReaderStatusPill>
    with SingleTickerProviderStateMixin {
  late final _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );

  @override
  void didUpdateWidget(ReaderStatusPill old) {
    super.didUpdateWidget(old);
    if (widget.reading) {
      _blink.repeat(reverse: true);
    } else {
      _blink
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: D.space4,
        vertical: D.space2,
      ),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: Tween(begin: 1.0, end: 0.25).animate(_blink),
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: c.brandInk,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: D.space2),
          Text(
            widget.reading ? 'Reading…' : 'Ready to scan',
            style: AltaiType.label.copyWith(color: c.ink),
          ),
        ],
      ),
    );
  }
}

/// A product picture in a rounded square, with a hanger icon when there's no picture.
class ProductThumb extends StatelessWidget {
  const ProductThumb({super.key, required this.url, this.size = 56});

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final placeholder = Container(
      width: size,
      height: size,
      color: c.surfaceSunken,
      child: Icon(
        Icons.checkroom_rounded,
        color: c.inkMuted,
        size: size * 0.45,
      ),
    );
    final link = url;
    return ClipRRect(
      borderRadius: BorderRadius.circular(D.radiusSm + 2),
      child: link == null
          ? placeholder
          : Image.network(
              link,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => placeholder,
            ), // bad link → placeholder, no crash
    );
  }
}

/// Big round icon used on the done / problem screens.
class StatusCircle extends StatelessWidget {
  const StatusCircle({
    super.key,
    required this.icon,
    required this.color,
    required this.onColor,
  });

  final IconData icon;
  final Color color;
  final Color onColor;

  @override
  Widget build(BuildContext context) => Container(
    width: 112,
    height: 112,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: Icon(icon, size: 56, color: onColor),
  );
}

/// MaterialApp.builder: keeps every screen above Android's navigation bar (back / home buttons).
/// Android draws the app under that bar, which hid the bottom of screens (e.g. "Confirm & submit").
Widget aboveSystemBars(BuildContext context, Widget? child) => ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(top: false, child: child ?? const SizedBox.shrink()),
    );
