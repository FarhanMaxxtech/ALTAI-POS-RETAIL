import 'package:flutter/material.dart';

import '../../../shared/altai_theme.dart';
import '../../../shared/altai_widgets.dart';
import '../../../shared/pos_layout.dart';
import '../../../shared/rfid_reader.dart';
import '../../catalog/data/catalog_api.dart';
import '../../checkout/data/checkout_api.dart';
import '../../checkout/data/store_tags.dart';
import '../../checkout/presentation/basket_screen.dart';
import '../../returns/data/returns_api.dart';
import '../../returns/domain/exchange.dart';
import '../../returns/presentation/return_screen.dart';
import '../data/orders_api.dart';
import '../domain/order.dart';

/// Which days the history covers.
enum HistoryDays { today, yesterday, week, custom }

/// Order history: this store's completed StoreHub orders, filtered by date and time of day, where a
/// return or an exchange starts. Pick an order, then Return (the return screen opens with its
/// receipt no.) or Exchange (items back, then the new items). Typing the last 4 digits in the
/// search box finds an order too.
class OrderHistoryScreen extends StatefulWidget {
  const OrderHistoryScreen({
    super.key,
    required this.orders,
    required this.inspector,
    required this.storeId,
    required this.storeName,
    required this.staffName,
    this.returns,
    this.catalog,
    this.storeTags,
    this.tagReader = const UsbTagReader(),
    this.onReturned,
    this.onSold,
    this.clock = DateTime.now,
  });

  final OrdersApi orders;
  final CheckoutApi inspector;
  final String storeId;
  final String storeName;
  final String staffName;

  /// Null = no Return or Exchange (only the list).
  final ReturnsApi? returns;
  final CatalogApi? catalog;
  final StoreTags? storeTags;
  final TagReader tagReader;
  final void Function(int pieces)? onReturned;
  final void Function(int pieces)? onSold;
  final DateTime Function() clock;

  @override
  State<OrderHistoryScreen> createState() => _OrderHistoryScreenState();
}

class _OrderHistoryScreenState extends State<OrderHistoryScreen> {
  HistoryDays _days = HistoryDays.today;
  DateTimeRange? _custom; // when _days is custom
  TimeOfDay? _fromTime; // null = from midnight
  TimeOfDay? _toTime; // null = to the end of the day
  String _search = '';
  late Future<List<StoreHubOrder>> _future = _fetch();

  static DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  /// First and last day of the range.
  (DateTime, DateTime) get _range {
    final today = _dayOnly(widget.clock());
    final yesterday = today.subtract(const Duration(days: 1));
    return switch (_days) {
      HistoryDays.today => (today, today),
      HistoryDays.yesterday => (yesterday, yesterday),
      HistoryDays.week => (today.subtract(const Duration(days: 6)), today),
      HistoryDays.custom => (_custom!.start, _custom!.end),
    };
  }

  Future<List<StoreHubOrder>> _fetch() {
    final (first, last) = _range;
    return widget.orders.history(
      widget.storeId,
      from: first,
      to: last.add(const Duration(days: 1)).subtract(const Duration(milliseconds: 1)),
    );
  }

  Future<void> _reload() async {
    final next = _fetch();
    setState(() {
      _future = next;
    });
    try {
      await next;
    } catch (_) {
      // shown by the FutureBuilder
    }
  }

  Future<void> _pickDays(HistoryDays days) async {
    if (days == HistoryDays.custom) {
      final today = _dayOnly(widget.clock());
      final picked = await showDateRangePicker(
        context: context,
        firstDate: today.subtract(const Duration(days: 365)),
        lastDate: today,
        initialDateRange: _custom ?? DateTimeRange(start: today.subtract(const Duration(days: 6)), end: today),
      );
      if (picked == null) return;
      // At most 31 days at once, so the list stays quick to load.
      final start = picked.end.difference(picked.start).inDays > 30
          ? picked.end.subtract(const Duration(days: 30))
          : picked.start;
      _custom = DateTimeRange(start: start, end: picked.end);
    }
    _days = days;
    _reload();
  }

  /* ---------------- Time of day ---------------- */

  static int _minutes(TimeOfDay t) => t.hour * 60 + t.minute;

  bool _inTime(DateTime paid) {
    final m = paid.hour * 60 + paid.minute;
    if (_fromTime case final f? when m < _minutes(f)) return false;
    if (_toTime case final t? when m > _minutes(t)) return false;
    return true;
  }

  String get _timeLabel {
    final f = _fromTime, t = _toTime;
    if (f == null && t == null) return 'Any time';
    return '${f == null ? '00:00' : _hhmm(f)} – ${t == null ? '23:59' : _hhmm(t)}';
  }

  Future<void> _pickTime(String choice) async {
    switch (choice) {
      case 'any':
        setState(() => _fromTime = _toTime = null);
      case 'morning':
        setState(() {
          _fromTime = null;
          _toTime = const TimeOfDay(hour: 11, minute: 59);
        });
      case 'afternoon':
        setState(() {
          _fromTime = const TimeOfDay(hour: 12, minute: 0);
          _toTime = const TimeOfDay(hour: 17, minute: 59);
        });
      case 'evening':
        setState(() {
          _fromTime = const TimeOfDay(hour: 18, minute: 0);
          _toTime = null;
        });
      case 'pick':
        final from = await showTimePicker(
          context: context,
          initialTime: _fromTime ?? const TimeOfDay(hour: 10, minute: 0),
          helpText: 'FROM',
        );
        if (from == null || !mounted) return;
        final to = await showTimePicker(
          context: context,
          initialTime: _toTime ?? const TimeOfDay(hour: 22, minute: 0),
          helpText: 'TO',
        );
        if (to == null) return;
        setState(() {
          // Picked the wrong way round: swap them.
          final swap = _minutes(to) < _minutes(from);
          _fromTime = swap ? to : from;
          _toTime = swap ? from : to;
        });
    }
  }

  /* ---------------- Return and exchange ---------------- */

  Future<void> _return(StoreHubOrder o, ReturnsApi returns) async {
    await Navigator.of(context).push<void>(
      shellRoute(
        context,
        ReturnScreen(
          inspector: widget.inspector,
          api: returns,
          storeId: widget.storeId,
          storeName: widget.storeName,
          staffName: widget.staffName,
          catalog: widget.catalog,
          tagReader: widget.tagReader,
          order: o,
          orders: widget.orders,
          onReturned: widget.onReturned,
        ),
      ),
    );
    if (mounted) _reload(); // what came back is now on the order
  }

  /// Exchange: step 1 the items coming back (on this order's receipt), step 2 the new items.
  Future<void> _exchange(StoreHubOrder o, ReturnsApi returns) async {
    final back = await Navigator.of(context).push<ExchangeReturn>(
      shellRoute(
        context,
        ReturnScreen(
          inspector: widget.inspector,
          api: returns,
          storeId: widget.storeId,
          storeName: widget.storeName,
          staffName: widget.staffName,
          catalog: widget.catalog,
          tagReader: widget.tagReader,
          order: o,
          orders: widget.orders,
          exchange: true,
        ),
      ),
    );
    if (mounted) _reload();
    if (back == null || !mounted) return;
    await Navigator.of(context).push<void>(
      shellRoute(
        context,
        BasketScreen(
          api: widget.inspector,
          storeId: widget.storeId,
          storeName: widget.storeName,
          staffName: widget.staffName,
          catalog: widget.catalog,
          returns: returns,
          orders: widget.orders,
          storeTags: widget.storeTags,
          tagReader: widget.tagReader,
          initialExchange: back,
          onSold: widget.onSold,
          onBack: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  /// One order's items, with Return and Exchange.
  Future<void> _details(StoreHubOrder o) async {
    final c = context.altai;
    final returns = widget.returns;
    final pick = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Order ${o.invoiceNumber}',
          style: AltaiType.title.copyWith(fontWeight: FontWeight.w700, color: c.ink),
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Paid ${_dateTime(o.paidAt)} · ${plural(o.totalQty, 'piece')}',
                style: AltaiType.label.copyWith(fontWeight: FontWeight.w400, color: c.inkMuted),
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < o.lines.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: PanelLine(
                    qty: o.lines[i].qty,
                    name: o.lines[i].name,
                    detail: [
                      ?o.lines[i].variation,
                      'SKU ${o.lines[i].sku}',
                      if (o.lines[i].exempt) 'no tag',
                    ].join(' · '),
                    shaded: i.isEven,
                  ),
                ),
            ],
          ),
        ),
        actions: [
          AltaiButton('Close', onPressed: () => Navigator.pop(context)),
          if (returns != null) ...[
            AltaiButton(
              'Exchange',
              onPressed: () => Navigator.pop(context, 'exchange'),
              icon: Icons.swap_horiz_rounded,
            ),
            AltaiButton(
              'Return',
              onPressed: () => Navigator.pop(context, 'return'),
              variant: AltaiButtonVariant.primary,
              icon: Icons.assignment_return_outlined,
            ),
          ],
        ],
      ),
    );
    if (!mounted || returns == null) return;
    if (pick == 'return') await _return(o, returns);
    if (pick == 'exchange') await _exchange(o, returns);
  }

  /* ---------------- The page ---------------- */

  List<StoreHubOrder> _filtered(List<StoreHubOrder> all) {
    final q = _search.replaceAll(RegExp(r'\s'), '');
    return [
      for (final o in all)
        if (_inTime(o.paidAt) && (q.isEmpty || o.invoiceNumber.contains(q))) o,
    ];
  }

  String _customLabel() {
    String d(DateTime t) => '${_two(t.day)}/${_two(t.month)}';
    final custom = _custom;
    return custom == null ? 'Pick dates' : '${d(custom.start)} – ${d(custom.end)}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return AppShell(
      section: Section.history,
      searchHint: 'Search receipt no. or its last 4 digits…',
      onSearch: (v) => setState(() => _search = v),
      onRefresh: _reload,
      body: FutureBuilder(
        future: _future,
        builder: (context, snap) {
          final loading = snap.connectionState != ConnectionState.done;
          final list = _filtered(snap.data ?? const []);
          final pieces = list.fold(0, (sum, o) => sum + o.totalQty);
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilterBar(
                  chips: [
                    for (final (label, d) in [
                      ('Today', HistoryDays.today),
                      ('Yesterday', HistoryDays.yesterday),
                      ('Last 7 days', HistoryDays.week),
                      (_days == HistoryDays.custom ? _customLabel() : 'Pick dates', HistoryDays.custom),
                    ])
                      FilterChoice(label, selected: _days == d, onTap: () => _pickDays(d)),
                  ],
                  trailing: PopupMenuButton<String>(
                    tooltip: 'Time of day',
                    onSelected: _pickTime,
                    itemBuilder: (context) => [
                      for (final (value, label) in [
                        ('any', 'Any time'),
                        ('morning', 'Morning (before 12:00)'),
                        ('afternoon', 'Afternoon (12:00 – 18:00)'),
                        ('evening', 'Evening (after 18:00)'),
                        ('pick', 'Pick times…'),
                      ])
                        PopupMenuItem(
                          value: value,
                          child: Text(label, style: AltaiType.body),
                        ),
                    ],
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.schedule_rounded, size: 18, color: c.inkMuted),
                        const SizedBox(width: 6),
                        Text(
                          _timeLabel,
                          style: AltaiType.caption.copyWith(fontWeight: FontWeight.w500, color: c.inkMuted),
                        ),
                        Icon(Icons.arrow_drop_down_rounded, color: c.inkMuted),
                      ],
                    ),
                  ),
                ),
                if (widget.orders.isDemo) ...[
                  const SizedBox(height: 12),
                  const PageNotice(
                    'Demo orders: the Altai server doesn\'t send StoreHub orders yet.',
                    icon: Icons.science_outlined,
                  ),
                ],
                const SizedBox(height: 12),
                if (!loading && !snap.hasError) ...[
                  Text(
                    '${plural(list.length, 'order')} · ${plural(pieces, 'piece')}',
                    style: AltaiType.caption.copyWith(fontWeight: FontWeight.w500, color: c.inkMuted),
                  ),
                  const SizedBox(height: 8),
                ],
                Expanded(child: _body(context, snap, list, loading)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _body(BuildContext context, AsyncSnapshot<List<StoreHubOrder>> snap, List<StoreHubOrder> list, bool loading) {
    final c = context.altai;
    if (loading) return const Center(child: CircularProgressIndicator());
    if (snap.hasError) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AltaiNotice('Could not load the orders. Check the connection.'),
            const SizedBox(height: D.space4),
            AltaiButton('Try again', onPressed: _reload, icon: Icons.refresh_rounded),
          ],
        ),
      );
    }
    if (list.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.manage_history_rounded, size: 48, color: c.brandInk),
            const SizedBox(height: D.space2),
            Text(
              (snap.data ?? const []).isEmpty ? 'No completed orders on these days' : 'No orders match the filters',
              style: AltaiType.body.copyWith(color: c.inkMuted),
            ),
          ],
        ),
      );
    }
    final returns = widget.returns;
    return RefreshIndicator(
      onRefresh: _reload,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 24),
        child: TableCard(
          header: Row(
            children: [
              const SizedBox(width: _paidCol, child: ColumnTitle('Paid')),
              const SizedBox(width: _receiptCol, child: ColumnTitle('Receipt no.')),
              const Expanded(child: ColumnTitle('Items')),
              if (returns != null) const SizedBox(width: _actionsCol),
            ],
          ),
          rows: [
            for (final o in list)
              InkWell(
                key: ValueKey('order-${o.invoiceNumber}'),
                onTap: () => _details(o),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 72),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: _paidCol,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _hhmm(TimeOfDay.fromDateTime(o.paidAt)),
                              style: AltaiType.heading.copyWith(fontWeight: FontWeight.w700, color: c.ink),
                            ),
                            Text(_date(o.paidAt), style: AltaiType.caption.copyWith(fontSize: 12, color: c.inkMuted)),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: _receiptCol,
                        child: Text(
                          o.invoiceNumber,
                          style: AltaiType.label.copyWith(fontSize: 16, fontWeight: FontWeight.w600, color: c.ink),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '${plural(o.totalQty, 'pc')} · ${{for (final l in o.lines) l.name}.join(', ')}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AltaiType.label.copyWith(fontWeight: FontWeight.w400, color: c.ink),
                        ),
                      ),
                      if (returns != null)
                        SizedBox(
                          width: _actionsCol,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Flexible(child: TintButton('Return', onPressed: () => _return(o, returns))),
                              const SizedBox(width: 8),
                              Flexible(child: TintButton('Exchange', onPressed: () => _exchange(o, returns))),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

const _paidCol = 120.0;
const _receiptCol = 220.0;
const _actionsCol = 230.0;

String _two(int n) => n.toString().padLeft(2, '0');
String _hhmm(TimeOfDay t) => '${_two(t.hour)}:${_two(t.minute)}';
String _date(DateTime t) => '${_two(t.day)}/${_two(t.month)}/${t.year}';
String _dateTime(DateTime t) => '${_date(t)} ${_hhmm(TimeOfDay.fromDateTime(t))}';
