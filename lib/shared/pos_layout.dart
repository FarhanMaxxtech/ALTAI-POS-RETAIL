import 'dart:async';

import 'package:flutter/material.dart';

import 'altai_theme.dart';
import 'altai_widgets.dart';
import 'keyboard.dart';

/// The layout every main screen shares (the Figma redesign, "New 01–11"):
/// a white top bar (logo, search, refresh, Wi-Fi, one action), a left menu, and the page.

/* ---------------- Sections and moving between them ---------------- */

/// The left menu's entries.
enum Section {
  home('Home', Icons.home_outlined),
  checkout('Checkout', Icons.shopping_bag_outlined),
  returns('Return', Icons.assignment_return_outlined),
  orders('Orders', Icons.receipt_long_outlined),
  history('History', Icons.manage_history_rounded),
  recent('Recent', Icons.history_rounded),
  settings('Settings', Icons.settings_outlined);

  const Section(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// What the left menu does. The start page makes one and hands it to every screen it opens.
class ShellNav {
  const ShellNav({required this.open, required this.logout, required this.staffName, this.hidden = const {}});

  /// Opens a section (from anywhere: the screens on top are closed first).
  final void Function(Section section) open;
  final VoidCallback logout;
  final String staffName;

  /// Sections this tablet doesn't have (e.g. no Orders without the StoreHub link).
  final Set<Section> hidden;
}

/// Hands the [ShellNav] down to a screen and everything it opens.
class ShellScope extends InheritedWidget {
  const ShellScope({super.key, required this.nav, required super.child});

  final ShellNav nav;

  static ShellNav? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ShellScope>()?.nav;

  @override
  bool updateShouldNotify(ShellScope old) => old.nav != nav;
}

/// A route for a screen opened from another one, keeping the left menu working on it.
Route<T> shellRoute<T>(BuildContext context, Widget child) {
  final nav = ShellScope.maybeOf(context);
  return MaterialPageRoute<T>(builder: (_) => nav == null ? child : ShellScope(nav: nav, child: child));
}

/// "Cashier 01" → "C0", "Aina" → "A".
String initials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  return words.take(2).map((w) => w[0].toUpperCase()).join();
}

/* ---------------- The shell ---------------- */

/// The top-right button of a screen ("Find receipt", "Demo order").
class ShellAction {
  const ShellAction(this.label, this.icon, this.onPressed);

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
}

/// Narrower than this (a phone, a small tablet held upright): no left menu, a menu button opens it
/// from the side instead, and the search gets its own row.
const compactWidth = 720.0;

bool isCompact(BuildContext context) => MediaQuery.sizeOf(context).width < compactWidth;

class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.section,
    required this.body,
    this.searchHint = 'Search…',
    this.onSearch,
    this.onSearchSubmit,
    this.onRefresh,
    this.refreshTooltip = 'Refresh',
    this.offline = false,
    this.action,
    this.beforeLeave,
    this.onBack,
    this.resizeToAvoidBottomInset = false,
  });

  final Section section;
  final Widget body;
  final String searchHint;
  final ValueChanged<String>? onSearch;
  final ValueChanged<String>? onSearchSubmit;
  final VoidCallback? onRefresh;
  final String refreshTooltip;

  /// No Wi-Fi or no internet: an "Offline" pill instead of the green Wi-Fi icon.
  final bool offline;
  final ShellAction? action;

  /// Asked before the menu leaves this screen (e.g. "Leave this checkout?"). False = stay.
  final Future<bool> Function()? beforeLeave;

  /// A screen opened on top of another: a back arrow before the logo.
  final VoidCallback? onBack;
  final bool resizeToAvoidBottomInset;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final compact = isCompact(context);
    final hasSearch = onSearch != null || onSearchSubmit != null;
    return Scaffold(
      backgroundColor: c.surface100,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      drawer: compact && ShellScope.maybeOf(context) != null ? _MenuDrawer(shell: this) : null,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(shell: this, compact: compact),
            if (compact && hasSearch)
              Container(
                decoration: BoxDecoration(
                  color: c.surfaceRaised,
                  border: Border(bottom: BorderSide(color: c.border)),
                ),
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: _SearchBox(hint: searchHint, onChanged: onSearch, onSubmitted: onSearchSubmit),
              ),
            Expanded(
              child: compact
                  ? body
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Rail(shell: this),
                        Expanded(child: body),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _go(BuildContext context, Section to) async {
    final nav = ShellScope.maybeOf(context);
    if (nav == null) return;
    if (to == Section.settings) return nav.open(to); // a box on top: nothing to leave
    if (to == section && onBack == null) return;
    if (beforeLeave case final ask? when !await ask()) return;
    nav.open(to);
  }

  Future<void> _logout(BuildContext context) async {
    final nav = ShellScope.maybeOf(context);
    if (nav == null) return;
    if (beforeLeave case final ask? when !await ask()) return;
    nav.logout();
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.shell, required this.compact});

  final AppShell shell;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final action = shell.action;
    final gap = compact ? 8.0 : 12.0;
    final hasMenu = compact && ShellScope.maybeOf(context) != null;
    final hasSearch = shell.onSearch != null || shell.onSearchSubmit != null;
    return Container(
      height: compact ? 64 : 76,
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        border: compact && hasSearch ? null : Border(bottom: BorderSide(color: c.border)),
      ),
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 22),
      child: Row(
        children: [
          if (shell.onBack case final back?) ...[
            IconButton(onPressed: back, tooltip: 'Back', icon: Icon(Icons.arrow_back_rounded, color: c.ink)),
            const SizedBox(width: D.space1),
          ] else if (hasMenu)
            Builder(
              builder: (context) => IconButton(
                key: const ValueKey('menu-button'),
                onPressed: () => Scaffold.of(context).openDrawer(),
                tooltip: 'Menu',
                icon: Icon(Icons.menu_rounded, color: c.ink),
              ),
            ),
          LogoTile(size: compact ? 36 : 40),
          const SizedBox(width: 12),
          Flexible(
            flex: compact ? 1 : 0,
            child: Text(
              'Altai POS',
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: AltaiType.title.copyWith(fontSize: compact ? 18 : null, fontWeight: FontWeight.w700, color: c.ink),
            ),
          ),
          if (!compact) ...[
            const SizedBox(width: 36),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: _SearchBox(hint: shell.searchHint, onChanged: shell.onSearch, onSubmitted: shell.onSearchSubmit),
              ),
            ),
            const Spacer(),
          ],
          SizedBox(width: compact ? 4 : D.space3),
          if (shell.onRefresh case final refresh?) ...[
            BoxIconButton(Icons.refresh_rounded, tooltip: shell.refreshTooltip, onPressed: refresh),
            SizedBox(width: gap),
          ],
          if (shell.offline)
            OfflinePill(short: compact)
          else
            Tooltip(
              message: 'Online',
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: c.surfaceRaised,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: c.border),
                ),
                child: Icon(Icons.wifi_rounded, size: 22, color: c.brand),
              ),
            ),
          if (action != null) ...[
            SizedBox(width: gap),
            if (compact)
              // Just the icon on a narrow screen; the name shows on a long press.
              Tooltip(
                message: action.label,
                child: Material(
                  color: action.onPressed == null ? c.surfaceSunken : c.brand,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: action.onPressed,
                    child: SizedBox(width: 44, height: 44, child: Icon(action.icon, size: 22, color: c.onBrand)),
                  ),
                ),
              )
            else
              ShellButton(action.label, icon: action.icon, onPressed: action.onPressed),
          ],
        ],
      ),
    );
  }
}

class _SearchBox extends StatelessWidget {
  const _SearchBox({required this.hint, this.onChanged, this.onSubmitted});

  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final none = OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none);
    return SizedBox(
      height: 44,
      child: TextField(
        key: const ValueKey('top-search'),
        onTap: showKeyboard,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        enabled: onChanged != null || onSubmitted != null,
        style: AltaiType.label.copyWith(fontSize: 15, color: c.ink),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: c.surfaceSunken,
          hintText: hint,
          hintStyle: AltaiType.label.copyWith(fontSize: 15, fontWeight: FontWeight.w400, color: c.inkMuted),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          suffixIcon: Icon(Icons.search_rounded, size: 22, color: c.ink),
          border: none,
          enabledBorder: none,
          disabledBorder: none,
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: c.brand, width: 1.5),
          ),
        ),
      ),
    );
  }
}

/// A 44×44 white button with a thin border (refresh).
class BoxIconButton extends StatelessWidget {
  const BoxIconButton(this.icon, {super.key, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: c.surfaceRaised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: c.border)),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onPressed,
          child: SizedBox(width: 44, height: 44, child: Icon(icon, size: 22, color: c.ink)),
        ),
      ),
    );
  }
}

/// The amber "Offline" pill in the top bar.
class OfflinePill extends StatelessWidget {
  const OfflinePill({super.key, this.short = false});

  /// Just the icon (a narrow screen).
  final bool short;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(color: c.warningTint, borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_off_rounded, size: 22, color: c.warning, semanticLabel: short ? 'Offline' : null),
          if (!short) ...[
            const SizedBox(width: 6),
            Text('Offline', style: AltaiType.label.copyWith(fontWeight: FontWeight.w600, color: c.warning)),
          ],
        ],
      ),
    );
  }
}

/// The green 44-high button of the top bar.
class ShellButton extends StatelessWidget {
  const ShellButton(this.label, {super.key, required this.icon, required this.onPressed});

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 22),
      label: Text(label),
      style: TextButton.styleFrom(
        backgroundColor: c.brand,
        foregroundColor: c.onBrand,
        disabledBackgroundColor: c.surfaceSunken,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: AltaiType.label.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.shell});

  final AppShell shell;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final nav = ShellScope.maybeOf(context);
    final hidden = nav?.hidden ?? const <Section>{};
    return Container(
      width: 104,
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        border: Border(right: BorderSide(color: c.border)),
      ),
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
              child: Column(
                children: [
                  for (final s in Section.values)
                    if (!hidden.contains(s))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _RailItem(
                          section: s,
                          active: s == shell.section,
                          onTap: nav == null ? null : () => shell._go(context, s),
                        ),
                      ),
                ],
              ),
            ),
          ),
          if (nav != null)
            InkWell(
              onTap: () => shell._logout(context),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 14),
                child: Tooltip(
                  message: 'Log out',
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: 22,
                        backgroundColor: c.brandTint,
                        child: Text(
                          initials(nav.staffName),
                          style: AltaiType.label.copyWith(fontWeight: FontWeight.w600, color: c.brandInk),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text('Log out', style: AltaiType.caption.copyWith(fontSize: 12, color: c.inkMuted)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The left menu on a narrow screen: slides in from the side.
class _MenuDrawer extends StatelessWidget {
  const _MenuDrawer({required this.shell});

  final AppShell shell;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final nav = ShellScope.maybeOf(context)!;
    void go(VoidCallback then) {
      Navigator.of(context).pop(); // close the menu first
      then();
    }

    return Drawer(
      backgroundColor: c.surfaceRaised,
      width: 280,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Row(
                children: [
                  const LogoTile(),
                  const SizedBox(width: 12),
                  Text('Altai POS', style: AltaiType.title.copyWith(fontWeight: FontWeight.w700, color: c.ink)),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final s in Section.values)
                    if (!nav.hidden.contains(s))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: ListTile(
                          leading: Icon(s.icon, color: s == shell.section ? c.brandInk : c.inkMuted),
                          title: Text(s.label,
                              style: AltaiType.bodyStrong.copyWith(color: s == shell.section ? c.brandInk : c.ink)),
                          selected: s == shell.section,
                          selectedTileColor: c.brandTint,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          onTap: () => go(() => shell._go(context, s)),
                        ),
                      ),
                ],
              ),
            ),
            Divider(height: 1, color: c.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: c.brandTint,
                    child: Text(initials(nav.staffName),
                        style: AltaiType.label.copyWith(fontWeight: FontWeight.w600, color: c.brandInk)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(nav.staffName,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: AltaiType.bodyStrong.copyWith(color: c.ink)),
                  ),
                  TextButton.icon(
                    onPressed: () => go(() => shell._logout(context)),
                    icon: const Icon(Icons.logout_rounded, size: 20),
                    label: const Text('Log out'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({required this.section, required this.active, required this.onTap});

  final Section section;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final color = active ? c.brandInk : c.inkMuted;
    return Material(
      color: active ? c.brandTint : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: active ? BorderSide(color: c.brand, width: 1.5) : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 74),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(section.icon, size: 26, color: color),
              const SizedBox(height: 4),
              Text(section.label, style: AltaiType.caption.copyWith(fontSize: 13, fontWeight: FontWeight.w500, color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

/* ---------------- Page pieces ---------------- */

/// One chip of a [FilterBar].
class FilterChoice {
  const FilterChoice(this.label, {required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;
}

/// The white bar of chips over a page ("All 6 · Ready 5 · Needs attention 1"), with a note on the right.
class FilterBar extends StatelessWidget {
  const FilterBar({super.key, required this.chips, this.trailing});

  final List<FilterChoice> chips;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: c.surfaceRaised, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final chip in chips)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Material(
                        color: chip.selected ? c.brandTint : Colors.transparent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: chip.selected ? BorderSide(color: c.brand, width: 1.5) : BorderSide.none,
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: chip.onTap,
                          child: Container(
                            height: 40,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            alignment: Alignment.center,
                            child: Text(
                              chip.label,
                              style: AltaiType.label.copyWith(color: chip.selected ? c.brandInk : c.ink),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (trailing case final t?) Padding(padding: const EdgeInsets.only(left: 8, right: 8), child: t),
        ],
      ),
    );
  }
}

/// The note on the right of a [FilterBar]: "● Reader on", "Updated just now".
class BarNote extends StatelessWidget {
  const BarNote(this.text, {super.key, this.dot});

  final String text;
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dot != null) ...[
          Container(width: 10, height: 10, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          const SizedBox(width: 8),
        ],
        Text(text, style: AltaiType.caption.copyWith(fontWeight: FontWeight.w500, color: c.inkMuted)),
      ],
    );
  }
}

/// A full-width tinted message: amber (offline, demo) or red.
class PageNotice extends StatelessWidget {
  const PageNotice(this.text, {super.key, this.icon = Icons.wifi_off_rounded, this.danger = false, this.action});

  final String text;
  final IconData icon;
  final bool danger;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final fg = danger ? c.danger : c.warning;
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(color: danger ? c.dangerTint : c.warningTint, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(icon, size: 22, color: fg),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: AltaiType.caption.copyWith(fontWeight: FontWeight.w500, color: fg))),
          ?action,
        ],
      ),
    );
  }
}

/// How a product card looks.
enum CardLook { ok, problem, checking }

/// One product on the scan screens: a round picture, the name, the colour/size and the price.
class ItemCard extends StatefulWidget {
  const ItemCard({
    super.key,
    required this.title,
    required this.subtitle,
    this.bottom,
    this.look = CardLook.ok,
    this.qty = 1,
    this.image,
    this.goesAwayAt,
    this.onTap,
  });

  final String title;
  final String subtitle;

  /// The price, or for a red card what's wrong. "Checking…" on a grey card.
  final String? bottom;
  final CardLook look;
  final int qty;
  final String? image;

  /// A red card's countdown: "Goes away in 4 s".
  final DateTime? goesAwayAt;
  final VoidCallback? onTap;

  @override
  State<ItemCard> createState() => _ItemCardState();
}

class _ItemCardState extends State<ItemCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _startTick();
  }

  @override
  void didUpdateWidget(ItemCard old) {
    super.didUpdateWidget(old);
    if (old.goesAwayAt != widget.goesAwayAt) _startTick();
  }

  void _startTick() {
    _tick?.cancel();
    _tick = widget.goesAwayAt == null
        ? null
        : Timer.periodic(const Duration(seconds: 1), (_) {
            if (mounted) setState(() {});
          });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final w = widget;
    final bad = w.look == CardLook.problem;
    final checking = w.look == CardLook.checking;
    final dangerBorder = c.danger.withValues(alpha: 0.35);
    final (ring, fill, icon, iconColor) = bad
        ? (dangerBorder, c.surfaceRaised, Icons.warning_amber_rounded, c.danger)
        : checking
        ? (c.border, c.surfaceSunken, Icons.sync_rounded, c.inkMuted)
        : (c.brandBorder, c.brandTint, Icons.checkroom_rounded, c.brandInk);
    final titleColor = bad ? c.danger : c.ink;

    String? countdown;
    if (w.goesAwayAt case final due?) {
      final s = due.difference(DateTime.now()).inMilliseconds / 1000;
      countdown = 'Goes away in ${s.ceil().clamp(1, 99)} s';
    }

    return Material(
      color: bad ? c.dangerTint : c.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: bad ? BorderSide(color: dangerBorder) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: w.onTap,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 18, 10, 10),
              child: Column(
                children: [
                  Container(
                    width: 108,
                    height: 108,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: ring),
                    padding: const EdgeInsets.all(4),
                    child: ClipOval(
                      child: Container(
                        color: fill,
                        child: w.image != null && !bad && !checking
                            ? Image.network(
                                w.image!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Icon(icon, size: 44, color: iconColor),
                              )
                            : Icon(icon, size: 44, color: iconColor),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          w.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: AltaiType.label.copyWith(fontSize: 15, height: 1.25, fontWeight: FontWeight.w600, color: titleColor),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          w.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: AltaiType.caption.copyWith(fontSize: 13, height: 1.3, color: bad ? c.danger : c.inkMuted),
                        ),
                        const SizedBox(height: 4),
                        if (checking)
                          Text('Checking…', style: AltaiType.caption.copyWith(fontWeight: FontWeight.w500, color: c.inkMuted))
                        else if (bad)
                          Text(
                            countdown ?? w.bottom ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AltaiType.caption.copyWith(fontSize: 13, fontWeight: FontWeight.w500, color: c.danger),
                          )
                        else if (w.bottom case final b?)
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(b, style: AltaiType.label.copyWith(fontSize: 16, fontWeight: FontWeight.w700, color: c.ink)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (w.qty > 1)
              Positioned(
                top: 10,
                right: 10,
                child: QtyPill(w.qty),
              ),
          ],
        ),
      ),
    );
  }
}

/// "× 2" in white on green.
class QtyPill extends StatelessWidget {
  const QtyPill(this.qty, {super.key});

  final int qty;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.brand, borderRadius: BorderRadius.circular(13)),
      child: Text('× $qty', style: AltaiType.caption.copyWith(fontSize: 13, fontWeight: FontWeight.w600, color: c.onBrand)),
    );
  }
}

/// Product cards in as many columns as fit (4 on the tablet next to the order panel).
class ItemGrid extends StatelessWidget {
  const ItemGrid({super.key, required this.children, this.padding = EdgeInsets.zero});

  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      const gap = 16.0, minWidth = 160.0;
      final cols = ((box.maxWidth + gap) / (minWidth + gap)).floor().clamp(1, 6);
      // 232 high as in the Figma; taller when the tablet's text size is turned up.
      final height = 232 * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
      return GridView.builder(
        padding: padding,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisExtent: height,
          crossAxisSpacing: gap,
          mainAxisSpacing: gap,
        ),
        itemCount: children.length,
        itemBuilder: (_, i) => children[i],
      );
    },
  );
}

/// A small coloured label: "Recorded", "Not scanned yet", "Receipt 2611…".
class StatusPill extends StatelessWidget {
  const StatusPill(this.text, {super.key, this.icon, this.tone = BadgeTone.brand});

  final String text;
  final IconData? icon;
  final BadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final (bg, fg) = switch (tone) {
      BadgeTone.neutral => (c.surfaceSunken, c.inkMuted),
      BadgeTone.brand => (c.brandTint, c.logoGreenBottom),
      BadgeTone.warning => (c.warningTint, c.warning),
      BadgeTone.danger => (c.dangerTint, c.danger),
    };
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(13)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 16, color: fg), const SizedBox(width: 4)],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AltaiType.caption.copyWith(fontSize: 13, fontWeight: FontWeight.w600, color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

/* ---------------- The order panel on the right ---------------- */

/// The white panel on the right of the scan screens.
class SidePanel extends StatelessWidget {
  const SidePanel({super.key, required this.child, this.width = 380});

  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        border: Border(left: BorderSide(color: c.border)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: child,
    );
  }
}

/// One line of the order panel: "2  HOUNDSTOOTH Cushion Cover / Brown · 45cm   118.00".
class PanelLine extends StatelessWidget {
  const PanelLine({super.key, required this.qty, required this.name, this.detail, this.amount, this.shaded = false});

  final int qty;
  final String name;
  final String? detail;
  final String? amount;
  final bool shaded;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(color: shaded ? c.surfaceSunken : null, borderRadius: BorderRadius.circular(10)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Text('$qty', style: AltaiType.label.copyWith(fontWeight: FontWeight.w700, color: c.brandInk)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AltaiType.label.copyWith(fontWeight: FontWeight.w600, color: c.ink)),
                if (detail != null && detail!.isNotEmpty)
                  Text(detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AltaiType.caption.copyWith(fontSize: 13, color: c.inkMuted)),
              ],
            ),
          ),
          if (amount != null) ...[
            const SizedBox(width: 8),
            Text(amount!, style: AltaiType.label.copyWith(fontWeight: FontWeight.w600, color: c.ink)),
          ],
        ],
      ),
    );
  }
}

/// "Pieces ........ 7" in the order panel.
class PanelRow extends StatelessWidget {
  const PanelRow(this.label, this.value, {super.key, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: AltaiType.label.copyWith(fontWeight: FontWeight.w400, color: c.inkMuted))),
          Text(value, style: AltaiType.label.copyWith(fontWeight: FontWeight.w600, color: valueColor ?? c.ink)),
        ],
      ),
    );
  }
}

/// "Total ...... RM 1,184.80" in the order panel.
class PanelTotal extends StatelessWidget {
  const PanelTotal(this.label, this.value, {super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Text(label, style: AltaiType.heading.copyWith(fontWeight: FontWeight.w700, color: c.ink)),
          const SizedBox(width: 12),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(value, style: AltaiType.title.copyWith(fontSize: 22, fontWeight: FontWeight.w700, color: c.ink)),
            ),
          ),
        ],
      ),
    );
  }
}

/// The two buttons at the bottom of the order panel: red Clear, green Confirm.
class PanelButtons extends StatelessWidget {
  const PanelButtons({
    super.key,
    required this.clear,
    required this.onClear,
    required this.confirm,
    required this.onConfirm,
    this.confirmIcon,
  });

  final String clear;
  final VoidCallback? onClear;
  final String confirm;
  final VoidCallback? onConfirm;
  final IconData? confirmIcon;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        flex: 2,
        child: AltaiButton(clear, onPressed: onClear, variant: AltaiButtonVariant.danger, expand: true),
      ),
      const SizedBox(width: 12),
      Expanded(
        flex: 3,
        child: AltaiButton(confirm,
            onPressed: onConfirm, variant: AltaiButtonVariant.primary, icon: confirmIcon, expand: true),
      ),
    ],
  );
}

/// The receipt box of the order panel: a label, the field, and a line under it.
class ReceiptField extends StatelessWidget {
  const ReceiptField({
    super.key,
    required this.controller,
    required this.label,
    required this.onChanged,
    this.hint = 'Scan or type the receipt no.',
    this.onSubmitted,
    this.suffix,
    this.error,
    this.warning,
    this.ok,
    this.keyboardType = TextInputType.number,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final ValueChanged<String> onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffix;
  final String? error;
  final String? warning;

  /// A green line under the field, e.g. "Today's sale found".
  final String? ok;
  final TextInputType keyboardType;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final note = error ?? warning ?? ok;
    final noteColor = error != null ? c.danger : (warning != null ? c.warning : c.brandInk);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final filled = value.text.isNotEmpty;
        OutlineInputBorder border(Color color, double w) =>
            OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: color, width: w));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: AltaiType.caption.copyWith(fontSize: 13, fontWeight: FontWeight.w500, color: c.inkMuted)),
            const SizedBox(height: 6),
            TextField(
              key: const ValueKey('receipt-field'),
              controller: controller,
              onTap: showKeyboard,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              keyboardType: keyboardType,
              style: AltaiType.label.copyWith(fontWeight: FontWeight.w600, color: c.ink),
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              decoration: InputDecoration(
                isDense: true,
                labelText: null,
                hintText: hint,
                hintStyle: AltaiType.label.copyWith(fontWeight: FontWeight.w400, color: c.inkMuted),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                prefixIcon: Icon(Icons.receipt_long_outlined, size: 22, color: filled ? c.brandInk : c.inkMuted),
                suffixIcon: suffix,
                enabledBorder: border(error != null ? c.danger : (filled ? c.brand : c.border), filled ? 1.5 : 1),
                focusedBorder: border(c.brand, 1.5),
              ),
            ),
            if (note != null) ...[
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(error != null || warning != null ? Icons.error_outline_rounded : Icons.check_circle_rounded,
                      size: 16, color: noteColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(note,
                        style: AltaiType.caption.copyWith(fontSize: 13, fontWeight: FontWeight.w500, color: noteColor)),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

/// A light green button in the order panel ("No receipt", "Exchange").
class TintButton extends StatelessWidget {
  const TintButton(this.label, {super.key, required this.onPressed, this.tooltip});

  final String label;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final button = TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        backgroundColor: c.brandTint,
        foregroundColor: c.brandInk,
        minimumSize: const Size(0, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: AltaiType.caption.copyWith(fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// A white card of rows with a header (Orders, Recent): the table look of the Figma.
class TableCard extends StatelessWidget {
  const TableCard({super.key, required this.header, required this.rows, this.minWidth = 760});

  final Widget header;
  final List<Widget> rows;

  /// Narrower than this (a phone): the table keeps this width and slides sideways.
  final double minWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => box.maxWidth >= minWidth
        ? _table(context)
        : SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: minWidth, child: _table(context)),
          ),
  );

  Widget _table(BuildContext context) {
    final c = context.altai;
    return Container(
      decoration: BoxDecoration(color: c.surfaceRaised, borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
            child: header,
          ),
          for (var i = 0; i < rows.length; i++)
            ColoredBox(color: i.isOdd ? const Color(0x05000000) : Colors.transparent, child: rows[i]),
        ],
      ),
    );
  }
}

/// Column title of a [TableCard].
class ColumnTitle extends StatelessWidget {
  const ColumnTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: AltaiType.caption.copyWith(fontSize: 13, fontWeight: FontWeight.w600, color: context.altai.inkMuted));
}

/// The two steps of an exchange, over the cards: 1 items coming back, 2 new items.
class ExchangeSteps extends StatelessWidget {
  const ExchangeSteps({super.key, required this.step, required this.title, required this.note, this.action});

  final int step; // 1 or 2
  final String title;
  final String note;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    Widget dot(int n, String label) {
      final done = n < step, now = n == step;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: done || now ? c.brand : c.surfaceRaised,
            child: done
                ? Icon(Icons.check_rounded, size: 16, color: c.onBrand)
                : Text('$n',
                    style: AltaiType.caption.copyWith(
                        fontWeight: FontWeight.w700, color: now ? c.onBrand : c.inkMuted)),
          ),
          const SizedBox(width: 6),
          Text(label,
              style: AltaiType.caption.copyWith(
                  fontWeight: now ? FontWeight.w700 : FontWeight.w500, color: now ? c.brandInk : c.inkMuted)),
        ],
      );
    }

    final heading = Row(
      children: [
        Icon(Icons.swap_horiz_rounded, color: c.brandInk),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AltaiType.label.copyWith(fontWeight: FontWeight.w600, color: c.ink)),
              Text(note, style: AltaiType.caption.copyWith(color: c.inkMuted)),
            ],
          ),
        ),
      ],
    );
    final steps = [
      dot(1, 'Items back'),
      Container(width: 24, height: 2, margin: const EdgeInsets.symmetric(horizontal: 8), color: c.brandBorder),
      dot(2, 'New items'),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: BoxDecoration(color: c.brandTint, borderRadius: BorderRadius.circular(12)),
      child: LayoutBuilder(
        // Narrow: the steps go under the title.
        builder: (context, box) => box.maxWidth < 560
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  heading,
                  const SizedBox(height: 8),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runSpacing: 4,
                    children: [Row(mainAxisSize: MainAxisSize.min, children: steps), ?action],
                  ),
                ],
              )
            : Row(
                children: [
                  Expanded(child: heading),
                  const SizedBox(width: 12),
                  ...steps,
                  if (action != null) ...[const SizedBox(width: 8), action!],
                ],
              ),
      ),
    );
  }
}

/// The StoreHub order a checkout or return is for, at the top of the order panel.
class OrderBox extends StatelessWidget {
  const OrderBox({super.key, required this.title, required this.subtitle, this.onChange});

  final String title; // "Order 0022…"
  final String subtitle; // "Paid 17/11/2026 14:02 · 5 pcs"
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: c.brandTint,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.brand, width: 1.5),
      ),
      child: Row(
        children: [
          Icon(Icons.receipt_long_outlined, color: c.brandInk),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    key: const ValueKey('order-box'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AltaiType.label.copyWith(fontWeight: FontWeight.w700, color: c.ink)),
                Text(subtitle, style: AltaiType.caption.copyWith(fontSize: 13, color: c.brandInk)),
              ],
            ),
          ),
          if (onChange != null)
            TextButton(
              onPressed: onChange,
              style: TextButton.styleFrom(
                textStyle: AltaiType.label.copyWith(fontWeight: FontWeight.w600),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 40),
              ),
              child: const Text('Change'),
            ),
        ],
      ),
    );
  }
}

/// One item of an order with its progress: "Classic Tee · Black / M ....... 1 / 2". Green with a
/// tick once complete ([full]), light green while in progress, grey before the first piece.
class OrderProgressLine extends StatelessWidget {
  const OrderProgressLine({
    super.key,
    required this.name,
    required this.count,
    this.detail,
    this.started = false,
    this.full = false,
    this.dim = false,
  });

  final String name;
  final String? detail;
  final String count; // "1 / 2"
  final bool started;
  final bool full;
  final bool dim; // nothing left to do on this line
  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final on = started || full;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: on ? c.brandTint : c.surfaceSunken,
        borderRadius: BorderRadius.circular(10),
        border: full ? Border.all(color: c.brand) : (on ? Border.all(color: c.brandBorder) : null),
      ),
      child: Row(
        children: [
          Icon(
            full ? Icons.check_circle_rounded : (on ? Icons.timelapse_rounded : Icons.radio_button_unchecked_rounded),
            size: 20,
            color: on ? c.brandInk : c.inkMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AltaiType.label.copyWith(fontWeight: FontWeight.w600, color: dim ? c.inkMuted : c.ink)),
                if (detail != null && detail!.isNotEmpty)
                  Text(detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AltaiType.caption.copyWith(fontSize: 13, color: c.inkMuted)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(count, style: AltaiType.label.copyWith(fontWeight: FontWeight.w700, color: on ? c.brandInk : c.inkMuted)),
        ],
      ),
    );
  }
}

/// "Paid 17/11/2026 14:02".
String paidText(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'Paid ${two(t.day)}/${two(t.month)}/${t.year} ${two(t.hour)}:${two(t.minute)}';
}
