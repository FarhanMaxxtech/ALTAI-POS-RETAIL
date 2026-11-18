import 'package:flutter/material.dart';

import '../../../shared/altai_theme.dart';
import '../../../shared/altai_widgets.dart';
import '../../../shared/pos_layout.dart';
import '../../catalog/data/catalog_api.dart';
import '../data/checkout_api.dart';
import '../domain/checkout_summary.dart';
import 'checkout_detail_screen.dart';

/// Which days the list covers.
enum RecentRange { today, yesterday, week, custom }

/// The checkouts recorded in this store, newest first, with filters: days, cashier, transaction no.
/// Pull down to refresh. Tap one to see the items in it.
class RecentScreen extends StatefulWidget {
  const RecentScreen({super.key, required this.api, required this.storeId, this.storeName, this.catalog, this.initialSearch});

  final CheckoutApi api;
  final String storeId;
  final String? storeName;
  final CatalogApi? catalog; // pictures on the details screen

  /// Typed in the start page's search box.
  final String? initialSearch;

  @override
  State<RecentScreen> createState() => _RecentScreenState();
}

class _RecentScreenState extends State<RecentScreen> {
  RecentRange _range = RecentRange.today;
  DateTimeRange? _custom; // when _range is custom
  String? _cashier; // null = everyone
  late String _search = widget.initialSearch ?? '';
  late Future<List<CheckoutSummary>> _future = _fetch();

  static DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  /// First and last day for the current range.
  (DateTime, DateTime) get _days {
    final today = _dayOnly(DateTime.now());
    final yesterday = today.subtract(const Duration(days: 1));
    return switch (_range) {
      RecentRange.today => (today, today),
      RecentRange.yesterday => (yesterday, yesterday),
      RecentRange.week => (today.subtract(const Duration(days: 6)), today),
      RecentRange.custom => (_custom!.start, _custom!.end),
    };
  }

  Future<List<CheckoutSummary>> _fetch() {
    final (from, to) = _days;
    return widget.api.recent(widget.storeId, from: from, to: to);
  }

  Future<void> _reload() async {
    final next = _fetch();
    setState(() {
      _future = next; // a block, so setState gets nothing back (an arrow would hand it the Future)
    });
    try {
      await next;
    } catch (_) {
      // the error is shown by the FutureBuilder
    }
  }

  Future<void> _pickRange(RecentRange range) async {
    if (range == RecentRange.custom) {
      final today = _dayOnly(DateTime.now());
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
    _range = range;
    _cashier = null; // the cashiers can differ between days
    _reload();
  }

  void _open(CheckoutSummary checkout) {
    Navigator.of(context).push(
      shellRoute<void>(context, CheckoutDetailScreen(api: widget.api, checkout: checkout, catalog: widget.catalog)),
    );
  }

  String _customLabel() {
    String d(DateTime t) => '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')}';
    final custom = _custom;
    return custom == null ? 'Pick dates' : '${d(custom.start)} – ${d(custom.end)}';
  }

  List<CheckoutSummary> _filtered(List<CheckoutSummary> all) {
    final q = _search.trim().toLowerCase();
    return [
      for (final x in all)
        if ((_cashier == null || x.cashier == _cashier) &&
            (q.isEmpty ||
                (x.trxId ?? '').toLowerCase().contains(q) ||
                (x.receipt ?? '').toLowerCase().contains(q) ||
                (x.remark ?? '').toLowerCase().contains(q)))
          x,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      section: Section.recent,
      searchHint: 'Search transaction or receipt no.…',
      onSearch: (v) => setState(() => _search = v),
      onRefresh: _reload,
      body: FutureBuilder(
        future: _future,
        builder: (context, snap) {
          final loading = snap.connectionState != ConnectionState.done;
          final all = snap.data ?? const <CheckoutSummary>[];
          final cashiers = {for (final x in all) ?x.cashier}.toList()..sort();
          final list = _filtered(all);
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _filters(context, cashiers),
                const SizedBox(height: 12),
                if (!loading && !snap.hasError) ...[
                  Text(
                    '${plural(list.length, 'checkout')} shown',
                    style: AltaiType.caption.copyWith(fontWeight: FontWeight.w500, color: context.altai.inkMuted),
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

  Widget _filters(BuildContext context, List<String> cashiers) {
    final c = context.altai;
    FilterChoice chip(String label, RecentRange r) =>
        FilterChoice(label, selected: _range == r, onTap: () => _pickRange(r));
    return FilterBar(
      chips: [
        chip('Today', RecentRange.today),
        chip('Yesterday', RecentRange.yesterday),
        chip('Last 7 days', RecentRange.week),
        chip(_range == RecentRange.custom ? _customLabel() : 'Pick dates', RecentRange.custom),
      ],
      trailing: PopupMenuButton<String>(
        key: ValueKey(cashiers.join('|')),
        tooltip: 'Cashier',
        onSelected: (v) => setState(() => _cashier = v.isEmpty ? null : v),
        itemBuilder: (context) => [
          PopupMenuItem<String>(value: '', child: Text('All cashiers', style: AltaiType.body)),
          for (final name in cashiers) PopupMenuItem<String>(value: name, child: Text(name, style: AltaiType.body)),
        ],
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_cashier ?? 'All cashiers',
                style: AltaiType.caption.copyWith(fontWeight: FontWeight.w500, color: c.inkMuted)),
            Icon(Icons.arrow_drop_down_rounded, color: c.inkMuted),
          ],
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AsyncSnapshot<List<CheckoutSummary>> snap,
    List<CheckoutSummary> list,
    bool loading,
  ) {
    final c = context.altai;
    if (loading) return const Center(child: CircularProgressIndicator());
    if (snap.hasError) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(D.space6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AltaiNotice('Could not load the list.'),
                const SizedBox(height: D.space4),
                AltaiButton('Try again', onPressed: _reload, icon: Icons.refresh_rounded),
              ],
            ),
          ),
        ),
      );
    }
    if (list.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.receipt_long_outlined, size: 48, color: c.brandInk),
            const SizedBox(height: D.space2),
            Text(
              (snap.data ?? const []).isEmpty ? 'No checkouts on these days' : 'No checkouts match the filters',
              style: AltaiType.body.copyWith(color: c.inkMuted),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 24),
        child: TableCard(
          header: const Row(
            children: [
              SizedBox(width: _timeCol, child: ColumnTitle('Time')),
              SizedBox(width: _trxCol, child: ColumnTitle('Transaction')),
              Expanded(child: ColumnTitle('Receipt')),
              SizedBox(width: _cashierCol, child: ColumnTitle('Cashier')),
              SizedBox(width: _statusCol + _chevCol, child: ColumnTitle('Status')),
            ],
          ),
          rows: [for (final x in list) _CheckoutRow(x, onTap: () => _open(x), showDate: _range != RecentRange.today)],
        ),
      ),
    );
  }
}

const _timeCol = 126.0;
const _trxCol = 160.0;
const _cashierCol = 120.0;
const _statusCol = 130.0;
const _chevCol = 32.0;

class _CheckoutRow extends StatelessWidget {
  const _CheckoutRow(this.checkout, {required this.onTap, required this.showDate});

  final CheckoutSummary checkout;
  final VoidCallback onTap;
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final t = checkout.createdAt;
    String two(int n) => n.toString().padLeft(2, '0'); // 5 → "05"
    final hasTime = checkout.hasTime; // older sales and sales made elsewhere only have a date
    final trx = checkout.trxId;
    final date = '${two(t.day)}/${two(t.month)}/${t.year}';
    final receipt = [
      if (checkout.receipt case final r?) 'Receipt $r',
      if (checkout.noReceiptReason case final r?) 'No receipt: $r',
      if (checkout.exchangeFor case final r?) 'Exchange for $r',
    ].join(' · ');
    final other = checkout.cashier == null ? (checkout.remark ?? '') : '';
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 68),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Row(
          children: [
            // Time, big, so staff can find "the one from 2:15".
            SizedBox(
              width: _timeCol,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hasTime ? '${two(t.hour)}:${two(t.minute)}:${two(t.second)}' : date,
                    style: AltaiType.heading.copyWith(fontWeight: FontWeight.w700, color: c.ink),
                  ),
                  if (hasTime && showDate) Text(date, style: AltaiType.caption.copyWith(fontSize: 12, color: c.inkMuted)),
                ],
              ),
            ),
            SizedBox(
              width: _trxCol,
              child: Text(
                trx == null ? 'Transaction' : 'Transaction $trx',
                style: AltaiType.label.copyWith(fontSize: 16, fontWeight: FontWeight.w600, color: c.ink),
              ),
            ),
            Expanded(
              child: Text(
                receipt.isNotEmpty ? receipt : other,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AltaiType.label.copyWith(fontWeight: FontWeight.w400, color: c.ink),
              ),
            ),
            SizedBox(
              width: _cashierCol,
              child: Text(checkout.cashier ?? '–',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AltaiType.label.copyWith(fontWeight: FontWeight.w400, color: c.inkMuted)),
            ),
            const SizedBox(
              width: _statusCol,
              child: Align(
                alignment: Alignment.centerLeft,
                child: StatusPill('Recorded', icon: Icons.check_circle_rounded),
              ),
            ),
            SizedBox(width: _chevCol, child: Icon(Icons.chevron_right_rounded, size: 26, color: c.inkMuted)),
          ],
        ),
      ),
    );
  }
}
