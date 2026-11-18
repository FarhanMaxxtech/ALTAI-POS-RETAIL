import 'package:flutter/material.dart';

import '../../shared/altai_theme.dart';
import '../../shared/altai_widgets.dart';
import '../../shared/pos_layout.dart';
import '../../shared/rfid_reader.dart';
import '../catalog/data/catalog_api.dart';
import '../checkout/data/checkout_api.dart';
import '../checkout/data/store_tags.dart';
import '../checkout/presentation/basket_screen.dart';
import '../checkout/presentation/recent_screen.dart';
import '../orders/data/orders_api.dart';
import '../orders/presentation/order_history_screen.dart';
import '../orders/presentation/orders_screen.dart';
import '../returns/data/returns_api.dart';
import '../returns/presentation/return_screen.dart';

/// The first page after login (Figma "New 02 Home"): a greeting, the two big choices (Checkout,
/// Return & refund) and today's numbers. It also runs the left menu: every screen it opens gets a
/// [ShellNav] that switches between the sections.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.api,
    required this.storeId,
    required this.storeName,
    required this.staffName,
    required this.onLogout,
    this.catalog,
    this.returns,
    this.orders,
    this.storeTags,
    this.tagReader = const UsbTagReader(),
    this.clock = DateTime.now,
  });

  final CheckoutApi api;
  final String storeId;
  final String storeName;
  final String staffName;
  final VoidCallback onLogout;
  final CatalogApi? catalog;
  final ReturnsApi? returns;
  final OrdersApi? orders;
  final StoreTags? storeTags;
  final TagReader tagReader;
  final DateTime Function() clock;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final ShellNav _nav = ShellNav(
    open: _open,
    logout: _logout,
    staffName: widget.staffName,
    hidden: {
      if (widget.returns == null) Section.returns,
      if (widget.orders == null) Section.orders,
      if (widget.orders == null) Section.history,
    },
  );

  // Today's numbers. Pieces sold and returns are counted on this tablet (the team's list has no
  // piece counts); they start again each day.
  int? _checkoutsToday;
  int? _ordersWaiting;
  int _piecesSold = 0;
  int _returnsToday = 0;
  DateTime? _countedDay;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  DateTime get _today {
    final n = widget.clock();
    return DateTime(n.year, n.month, n.day);
  }

  void _newDay() {
    if (_countedDay != _today) {
      _countedDay = _today;
      _piecesSold = 0;
      _returnsToday = 0;
    }
  }

  Future<void> _loadStats() async {
    _newDay();
    final today = _today;
    try {
      final list = await widget.api.recent(widget.storeId, from: today, to: today);
      if (mounted) setState(() => _checkoutsToday = list.length);
    } catch (_) {
      // the card shows "–"
    }
    final orders = widget.orders;
    if (orders == null) return;
    try {
      final waiting = await orders.pending(widget.storeId);
      if (mounted) setState(() => _ordersWaiting = waiting.length);
    } catch (_) {
      // the card shows "–"
    }
  }

  void _sold(int pieces) => setState(() {
    _newDay();
    _piecesSold += pieces;
  });

  void _returned(int pieces) => setState(() {
    _newDay();
    _returnsToday++;
  });

  /* ---------------- The left menu ---------------- */

  void _open(Section to, {String? search}) {
    if (to == Section.settings) {
      _settings();
      return;
    }
    Navigator.of(context).popUntil((r) => r.isFirst);
    final returns = widget.returns;
    final orders = widget.orders;
    switch (to) {
      case Section.checkout:
        _push(BasketScreen(
          api: widget.api,
          storeId: widget.storeId,
          storeName: widget.storeName,
          staffName: widget.staffName,
          catalog: widget.catalog,
          returns: widget.returns,
          orders: widget.orders,
          storeTags: widget.storeTags,
          tagReader: widget.tagReader,
          onSold: _sold,
          onBack: () => Navigator.of(context).popUntil((r) => r.isFirst),
        ));
      case Section.returns when returns != null:
        _push(ReturnScreen(
          inspector: widget.api,
          api: returns,
          storeId: widget.storeId,
          storeName: widget.storeName,
          staffName: widget.staffName,
          catalog: widget.catalog,
          tagReader: widget.tagReader,
          onReturned: _returned,
          orders: widget.orders,
        ));
      case Section.orders when orders != null:
        _push(OrdersScreen(
          orders: orders,
          inspector: widget.api,
          storeId: widget.storeId,
          storeName: widget.storeName,
          staffName: widget.staffName,
          tagReader: widget.tagReader,
        ));
      case Section.history when orders != null:
        _push(OrderHistoryScreen(
          orders: orders,
          inspector: widget.api,
          storeId: widget.storeId,
          storeName: widget.storeName,
          staffName: widget.staffName,
          returns: widget.returns,
          catalog: widget.catalog,
          storeTags: widget.storeTags,
          tagReader: widget.tagReader,
          onReturned: _returned,
          onSold: _sold,
          clock: widget.clock,
        ));
      case Section.recent:
        _push(RecentScreen(
          api: widget.api,
          storeId: widget.storeId,
          storeName: widget.storeName,
          catalog: widget.catalog,
          initialSearch: search,
        ));
      default:
        _loadStats(); // Home
    }
  }

  /// Switching sections feels like tabs: no slide.
  void _push(Widget screen) {
    Navigator.of(context)
        .push(PageRouteBuilder<void>(
          pageBuilder: (_, _, _) => ShellScope(nav: _nav, child: screen),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
        ))
        .then((_) {
          if (mounted) _loadStats();
        });
  }

  void _logout() {
    Navigator.of(context).popUntil((r) => r.isFirst);
    widget.onLogout();
  }

  Future<void> _settings() async {
    final c = context.altai;
    final logout = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Settings', style: AltaiType.title.copyWith(color: c.ink)),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PanelRow('Location', widget.storeName),
              PanelRow('Cashier', widget.staffName),
              const PanelRow('Reader', 'USB desk reader'),
              const SizedBox(height: D.space3),
              Text(
                'The location is changed from the login screen.',
                style: AltaiType.caption.copyWith(color: c.inkMuted),
              ),
            ],
          ),
        ),
        actions: [
          AltaiButton('Log out', onPressed: () => Navigator.pop(context, true), icon: Icons.logout_rounded),
          AltaiButton('Close', onPressed: () => Navigator.pop(context, false), variant: AltaiButtonVariant.primary),
        ],
      ),
    );
    if (logout == true) _logout();
  }

  /* ---------------- The page ---------------- */

  String get _greeting {
    final h = widget.clock().hour;
    return h < 12 ? 'Good morning' : (h < 18 ? 'Good afternoon' : 'Good evening');
  }

  String get _date {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final d = widget.clock();
    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    String count(int? n) => n == null ? '–' : '$n';
    final tiles = [
      _Choice(
        icon: Icons.sensors_rounded,
        title: 'Checkout',
        body: 'Put the items near the reader. They come in on their own; then enter the StoreHub receipt.',
        primary: true,
        onTap: () => _open(Section.checkout),
      ),
      if (widget.returns != null)
        _Choice(
          icon: Icons.assignment_return_outlined,
          title: 'Return & refund',
          body: 'Items coming back go back into stock. The money goes back on StoreHub.',
          onTap: () => _open(Section.returns),
        ),
    ];
    final stats = [
      _Stat('Checkouts today', count(_checkoutsToday)),
      _Stat('Pieces sold', '$_piecesSold'),
      if (widget.returns != null) _Stat('Returns today', '$_returnsToday'),
      if (widget.orders != null) _Stat('Orders not scanned', count(_ordersWaiting), warn: (_ordersWaiting ?? 0) > 0),
    ];
    return ShellScope(
      nav: _nav,
      child: AppShell(
        section: Section.home,
        searchHint: 'Search receipts and orders…',
        onSearchSubmit: (q) => _open(Section.recent, search: q.trim().isEmpty ? null : q.trim()),
        onRefresh: _loadStats,
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('$_greeting, ${widget.staffName}',
                  style: AltaiType.title.copyWith(fontSize: 28, fontWeight: FontWeight.w700, color: c.ink)),
              const SizedBox(height: 4),
              Text('${widget.storeName} · $_date', style: AltaiType.body.copyWith(fontSize: 16, color: c.inkMuted)),
              const SizedBox(height: 24),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < 2; i++) ...[
                      if (i > 0) const SizedBox(width: 24),
                      Expanded(child: i < tiles.length ? tiles[i] : const SizedBox()),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  for (var i = 0; i < stats.length; i++) ...[
                    if (i > 0) const SizedBox(width: 16),
                    Expanded(child: stats[i]),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One big choice on the start page.
class _Choice extends StatelessWidget {
  const _Choice({required this.icon, required this.title, required this.body, required this.onTap, this.primary = false});

  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final (bg, fg, sub) = primary
        ? (c.brand, c.onBrand, c.onBrand.withValues(alpha: 0.9))
        : (c.surfaceRaised, c.ink, c.inkMuted);
    return Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: primary ? BorderSide.none : BorderSide(color: c.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 250), // grows with big text instead of overflowing
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: primary ? c.onBrand.withValues(alpha: 0.18) : c.brandTint,
                ),
                child: Icon(icon, size: 40, color: primary ? c.onBrand : c.brandInk),
              ),
              const SizedBox(height: 32),
              Text(title, style: AltaiType.title.copyWith(fontSize: 28, fontWeight: FontWeight.w700, color: fg)),
              const SizedBox(height: 8),
              Text(body, style: AltaiType.body.copyWith(fontSize: 16, height: 1.5, color: sub)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {this.warn = false});

  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Container(
      height: 104,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: c.surfaceRaised, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AltaiType.caption.copyWith(fontWeight: FontWeight.w500, color: c.inkMuted)),
          const Spacer(),
          Text(value, style: AltaiType.qty.copyWith(color: warn ? c.warning : c.ink)),
        ],
      ),
    );
  }
}
