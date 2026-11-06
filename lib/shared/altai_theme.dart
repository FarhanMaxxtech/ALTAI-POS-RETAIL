import 'package:flutter/material.dart';

/// The Altai design system for the tablet: colours, type and sizes.
/// Values mirror the Altai design tokens (same as the Kotlin "altai-checkout-android" app).

/// Colour tokens. Reach them with `context.altai`.
@immutable
class AltaiColors extends ThemeExtension<AltaiColors> {
  const AltaiColors({
    required this.logoGreenTop,
    required this.logoGreenBottom,
    required this.onLogoGreen,
    required this.brand,
    required this.onBrand,
    required this.brandInk,
    required this.brandTint,
    required this.surface100,
    required this.surfaceRaised,
    required this.surfaceSunken,
    required this.border,
    required this.borderStrong,
    required this.ink,
    required this.inkMuted,
    required this.warning,
    required this.warningTint,
    required this.danger,
    required this.dangerTint,
    required this.onDanger,
    required this.focus,
    required this.scrim,
  });

  final Color logoGreenTop, logoGreenBottom, onLogoGreen;
  final Color brand, onBrand, brandInk, brandTint;
  final Color surface100, surfaceRaised, surfaceSunken;
  final Color border, borderStrong;
  final Color ink, inkMuted;
  final Color warning, warningTint, danger, dangerTint, onDanger;
  final Color focus, scrim;

  static const light = AltaiColors(
    logoGreenTop: Color(0xFF3B6D11),
    logoGreenBottom: Color(0xFF27500A),
    onLogoGreen: Color(0xFFFFFFFF),
    brand: Color(0xFF3B6D11),
    onBrand: Color(0xFFFFFFFF),
    brandInk: Color(0xFF3B6D11),
    brandTint: Color(0xFFE5EFD9),
    surface100: Color(0xFFF4F6F0),
    surfaceRaised: Color(0xFFFFFFFF),
    surfaceSunken: Color(0xFFE9EEE2),
    border: Color(0xFFDCE3D3),
    borderStrong: Color(0xFF7D8A73),
    ink: Color(0xFF18220F),
    inkMuted: Color(0xFF556150),
    warning: Color(0xFF8A5300),
    warningTint: Color(0xFFFBEFD9),
    danger: Color(0xFFB3261E),
    dangerTint: Color(0xFFFBE4E2),
    onDanger: Color(0xFFFFFFFF),
    focus: Color(0xFF1B5FB8),
    scrim: Color(0x8F0F150B),
  );

  static const dark = AltaiColors(
    logoGreenTop: Color(0xFF2E5A0C),
    logoGreenBottom: Color(0xFF1F4208),
    onLogoGreen: Color(0xFFFFFFFF),
    brand: Color(0xFF8CC455),
    onBrand: Color(0xFF10200A),
    brandInk: Color(0xFF9FD06A),
    brandTint: Color(0xFF22351A),
    surface100: Color(0xFF0F150B),
    surfaceRaised: Color(0xFF182112),
    surfaceSunken: Color(0xFF0A0F07),
    border: Color(0xFF2B3623),
    borderStrong: Color(0xFF6F7F63),
    ink: Color(0xFFEDF2E6),
    inkMuted: Color(0xFFA9B59E),
    warning: Color(0xFFF2B45C),
    warningTint: Color(0xFF3A2A10),
    danger: Color(0xFFFF8A80),
    dangerTint: Color(0xFF3D1714),
    onDanger: Color(0xFF3A0906),
    focus: Color(0xFF8AB4F8),
    scrim: Color(0xA3000000),
  );

  // Required by ThemeExtension. The app never changes single colours at runtime.
  @override
  AltaiColors copyWith() => this;

  @override
  AltaiColors lerp(AltaiColors? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

/// `context.altai.brand` instead of `Theme.of(context).extension<AltaiColors>()!.brand`.
extension AltaiContext on BuildContext {
  AltaiColors get altai => Theme.of(this).extension<AltaiColors>()!;
}

/// Spacing, sizes and corner radii (logical pixels).
abstract final class D {
  static const space1 = 4.0;
  static const space2 = 8.0;
  static const space3 = 12.0;
  static const space4 = 16.0;
  static const space6 = 24.0;
  static const space8 = 32.0;
  static const touchMin = 56.0; // smallest button height
  static const touchLg = 72.0; // large buttons, app bar
  static const radiusSm = 6.0;
  static const radiusMd = 12.0;
  static const radiusLg = 20.0;
}

/// Type scale. Saira for the UI, Roboto Mono for EPCs. Add a colour with `.copyWith(color: ...)`.
abstract final class AltaiType {
  static const _tabular = [FontFeature.tabularFigures()]; // numbers line up in columns

  static const qtyTotal = TextStyle(fontFamily: 'Saira', fontSize: 64, height: 68 / 64, fontWeight: FontWeight.w700, fontFeatures: _tabular);
  static const title = TextStyle(fontFamily: 'Saira', fontSize: 24, height: 30 / 24, fontWeight: FontWeight.w600);
  static const heading = TextStyle(fontFamily: 'Saira', fontSize: 20, height: 26 / 20, fontWeight: FontWeight.w600);
  static const bodyStrong = TextStyle(fontFamily: 'Saira', fontSize: 20, height: 26 / 20, fontWeight: FontWeight.w600);
  static const body = TextStyle(fontFamily: 'Saira', fontSize: 18, height: 26 / 18, fontWeight: FontWeight.w400);
  static const label = TextStyle(fontFamily: 'Saira', fontSize: 15, height: 20 / 15, fontWeight: FontWeight.w500, letterSpacing: 0.3);
  static const caption = TextStyle(fontFamily: 'Saira', fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w400);
  static const qty = TextStyle(fontFamily: 'Saira', fontSize: 32, height: 36 / 32, fontWeight: FontWeight.w700, fontFeatures: _tabular);
  static const epc = TextStyle(fontFamily: 'RobotoMono', fontSize: 16, height: 22 / 16, fontWeight: FontWeight.w400);
}

/// The whole app's theme, so stock Material widgets (text fields, dialogs, snack bars) also look Altai.
ThemeData altaiTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? AltaiColors.dark : AltaiColors.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.brand,
    onPrimary: c.onBrand,
    primaryContainer: c.brandTint,
    onPrimaryContainer: c.ink,
    secondary: c.brand,
    onSecondary: c.onBrand,
    surface: c.surfaceRaised,
    onSurface: c.ink,
    surfaceContainerHighest: c.surfaceSunken,
    onSurfaceVariant: c.inkMuted,
    outline: c.borderStrong,
    outlineVariant: c.border,
    error: c.danger,
    onError: c.onDanger,
    errorContainer: c.dangerTint,
    onErrorContainer: c.danger,
    scrim: c.scrim,
  );
  OutlineInputBorder border(Color color, [double width = 1.5]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(D.radiusMd),
        borderSide: BorderSide(color: color, width: width),
      );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: 'Saira',
    scaffoldBackgroundColor: c.surface100,
    dividerColor: c.border,
    extensions: [c],
    textTheme: TextTheme(
      titleLarge: AltaiType.title.copyWith(color: c.ink),
      titleMedium: AltaiType.heading.copyWith(color: c.ink),
      bodyLarge: AltaiType.body.copyWith(color: c.ink),
      bodyMedium: AltaiType.body.copyWith(color: c.ink),
      bodySmall: AltaiType.caption.copyWith(color: c.inkMuted),
      labelLarge: AltaiType.bodyStrong.copyWith(color: c.ink),
      labelMedium: AltaiType.label.copyWith(color: c.inkMuted),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surfaceRaised,
      contentPadding: const EdgeInsets.symmetric(horizontal: D.space4, vertical: 20),
      labelStyle: AltaiType.body.copyWith(color: c.inkMuted),
      hintStyle: AltaiType.body.copyWith(color: c.inkMuted),
      border: border(c.borderStrong),
      enabledBorder: border(c.borderStrong),
      focusedBorder: border(c.focus, 2),
      errorBorder: border(c.danger),
    ),
    dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.ink,
      contentTextStyle: AltaiType.body.copyWith(color: c.surfaceRaised),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(D.radiusMd)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surfaceRaised,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(D.radiusLg)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.brand),
  );
}
