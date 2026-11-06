import 'package:flutter/material.dart';

import '../../../shared/altai_theme.dart';
import '../../../shared/altai_widgets.dart';
import '../../../shared/keyboard.dart';
import '../../catalog/data/catalog_api.dart';
import '../data/checkout_api.dart';
import '../domain/checkout_summary.dart';
import 'checkout_detail_screen.dart';

/// Which days the list covers.
enum RecentRange { today, yesterday, week, custom }

/// The checkouts recorded in this store, newest first, with filters: days, cashier, transaction no.
/// Pull down to refresh. Tap one to see the items in it.
class RecentScreen extends StatefulWidget {
  const RecentScreen({super.key, required this.api, required this.storeId, this.storeName, this.catalog});

  final CheckoutApi api;
  final String storeId;
  final String? storeName;
  final CatalogApi? catalog; // pictures on the details screen

  @override
  State<RecentScreen> createState() => _RecentScreenState();
}

class _RecentScreenState extends State<RecentScreen> {
  RecentRange _range = RecentRange.today;
  DateTimeRange? _custom; // when _range is custom
  String? _cashier; // null = everyone
  String _search = '';
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
      MaterialPageRoute(
        builder: (_) => CheckoutDetailScreen(api: widget.api, checkout: checkout, catalog: widget.catalog),
      ),
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
            (q.isEmpty || (x.trxId ?? '').toLowerCase().contains(q) || (x.remark ?? '').toLowerCase().contains(q)))
          x,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Scaffold(
      appBar: AltaiAppBar(
        title: 'Recent checkouts',
        subtitle: widget.storeName,
        onBack: () => Navigator.of(context).pop(),
        actions: [AppBarIcon(Icons.refresh_rounded, tooltip: 'Refresh', onPressed: _reload)],
      ),
      body: FutureBuilder(
        future: _future,
        builder: (context, snap) {
          final loading = snap.connectionState != ConnectionState.done;
          final all = snap.data ?? const <CheckoutSummary>[];
          final cashiers = {for (final x in all) ?x.cashier}.toList()..sort();
          final list = _filtered(all);
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Column(
                children: [
                  _filters(
                    context,
                    cashiers,
                    loading || snap.hasError ? null : '${plural(list.length, 'checkout')} shown',
                  ),
                  Divider(height: 1, color: c.border),
                  Expanded(child: _body(context, snap, list, loading)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _filters(BuildContext context, List<String> cashiers, String? count) {
    final c = context.altai;
    ChoiceChip chip(String label, RecentRange r) => ChoiceChip(
      label: Text(label, style: AltaiType.label),
      selected: _range == r,
      onSelected: (_) => _pickRange(r),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(D.space6, D.space4, D.space6, D.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: D.space2,
            runSpacing: D.space2,
            children: [
              chip('Today', RecentRange.today),
              chip('Yesterday', RecentRange.yesterday),
              chip('Last 7 days', RecentRange.week),
              ChoiceChip(
                avatar: const Icon(Icons.date_range_rounded, size: 18),
                label: Text(_range == RecentRange.custom ? _customLabel() : 'Pick dates', style: AltaiType.label),
                selected: _range == RecentRange.custom,
                onSelected: (_) => _pickRange(RecentRange.custom),
              ),
            ],
          ),
          const SizedBox(height: D.space3),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  onTap: showKeyboard,
                  style: AltaiType.body.copyWith(color: c.ink),
                  decoration: const InputDecoration(
                    hintText: 'Search transaction or receipt no.',
                    prefixIcon: Icon(Icons.search_rounded),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
              const SizedBox(width: D.space3),
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<String?>(
                  key: ValueKey(cashiers.join('|')), // a new list of cashiers starts from "All cashiers"
                  initialValue: cashiers.contains(_cashier) ? _cashier : null,
                  isExpanded: true,
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.person_outline_rounded), isDense: true),
                  items: [
                    DropdownMenuItem<String?>(value: null, child: Text('All cashiers', style: AltaiType.body)),
                    for (final name in cashiers)
                      DropdownMenuItem<String?>(
                        value: name,
                        child: Text(name, style: AltaiType.body),
                      ),
                  ],
                  onChanged: (v) => setState(() => _cashier = v),
                ),
              ),
            ],
          ),
          if (count != null) ...[
            const SizedBox(height: D.space2),
            Text(count, style: AltaiType.caption.copyWith(color: c.inkMuted)),
          ],
        ],
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
      child: ListView.separated(
        padding: const EdgeInsets.all(D.space6),
        itemCount: list.length,
        separatorBuilder: (_, _) => const SizedBox(height: D.space3),
        itemBuilder: (context, i) => _CheckoutRow(list[i], onTap: () => _open(list[i])),
      ),
    );
  }
}

class _CheckoutRow extends StatelessWidget {
  const _CheckoutRow(this.checkout, {required this.onTap});

  final CheckoutSummary checkout;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final t = checkout.createdAt;
    String two(int n) => n.toString().padLeft(2, '0'); // 5 → "05"
    final hasTime = checkout.hasTime; // older sales and sales made elsewhere only have a date
    final trx = checkout.trxId;
    // "Aina · Receipt SH-0012", or the whole remark for sales made outside this app.
    final details = [
      ?checkout.cashier,
      if (checkout.receipt case final r?) 'Receipt $r',
      if (checkout.noReceiptReason case final r?) 'No receipt: $r',
      if (checkout.exchangeFor case final r?) 'Exchange for $r',
    ].join(' · ');
    return Material(
      color: c.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(D.radiusMd),
        side: BorderSide(color: c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: D.space6, vertical: D.space4),
          child: Row(
            children: [
              // Time, big, so staff can find "the one from 2:15".
              SizedBox(
                width: 150,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (hasTime)
                      Text(
                        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}',
                        style: AltaiType.qty.copyWith(fontSize: 26, color: c.ink),
                      ),
                    Text(
                      '${two(t.day)}/${two(t.month)}/${t.year}',
                      style: hasTime
                          ? AltaiType.caption.copyWith(color: c.inkMuted)
                          : AltaiType.label.copyWith(color: c.ink),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: D.space4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trx == null ? 'Transaction' : 'Transaction $trx',
                      style: AltaiType.label.copyWith(color: c.ink),
                    ),
                    if (details.isNotEmpty)
                      Text(details, style: AltaiType.caption.copyWith(color: c.inkMuted))
                    else if (checkout.remark != null && checkout.remark!.isNotEmpty)
                      Text(checkout.remark!, style: AltaiType.caption.copyWith(color: c.inkMuted)),
                  ],
                ),
              ),
              const AltaiBadge('Recorded', tone: BadgeTone.brand, icon: Icons.check_circle_rounded),
              const SizedBox(width: D.space2),
              Icon(Icons.chevron_right_rounded, size: 28, color: c.inkMuted),
            ],
          ),
        ),
      ),
    );
  }
}
