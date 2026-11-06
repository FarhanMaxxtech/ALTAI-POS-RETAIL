import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../shared/altai_theme.dart';
import '../../../shared/altai_widgets.dart';
import '../../catalog/data/catalog_api.dart';
import '../data/checkout_api.dart';
import '../domain/checkout_summary.dart';

/// What was in one recorded checkout: each SKU, its picture and how many pieces.
class CheckoutDetailScreen extends StatefulWidget {
  const CheckoutDetailScreen({super.key, required this.api, required this.checkout, this.catalog});

  final CheckoutApi api;
  final CheckoutSummary checkout;

  /// Pictures. Null = no pictures.
  final CatalogApi? catalog;

  @override
  State<CheckoutDetailScreen> createState() => _CheckoutDetailScreenState();
}

class _CheckoutDetailScreenState extends State<CheckoutDetailScreen> {
  late Future<CheckoutDetail> _future = _load();
  final Map<String, String?> _images = {}; // sku → picture

  Future<CheckoutDetail> _load() async {
    final id = widget.checkout.id;
    if (id == null) throw ApiException('This checkout has no id to look up.');
    final detail = await widget.api.detail(id);
    _loadImages(detail);
    return detail;
  }

  /// Pictures come one SKU at a time, after the list is on screen.
  Future<void> _loadImages(CheckoutDetail detail) async {
    final c = widget.catalog;
    if (c == null) return;
    for (final l in detail.lines) {
      if (_images.containsKey(l.sku)) continue;
      try {
        _images[l.sku] = (await c.lookup(l.sku)).image;
      } on ApiException {
        _images[l.sku] = null; // no picture is fine
      }
      if (mounted) setState(() {});
    }
  }

  void _retry() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final trx = widget.checkout.trxId;
    return Scaffold(
      appBar: AltaiAppBar(
        title: trx == null ? 'Checkout' : 'Transaction $trx',
        subtitle: [?widget.checkout.cashier, if (widget.checkout.receipt case final r?) 'Receipt $r'].join(' · '),
        onBack: () => Navigator.of(context).pop(),
      ),
      body: FutureBuilder(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            final e = snap.error;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Padding(
                  padding: const EdgeInsets.all(D.space6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AltaiNotice(e is ApiException ? e.message : 'Could not load this checkout.'),
                      const SizedBox(height: D.space4),
                      AltaiButton('Try again', onPressed: _retry, icon: Icons.refresh_rounded),
                    ],
                  ),
                ),
              ),
            );
          }
          final d = snap.data!;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: ListView(
                padding: const EdgeInsets.all(D.space6),
                children: [
                  // Totals first: what staff compare with the StoreHub receipt.
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: D.space6, vertical: D.space4),
                    decoration: BoxDecoration(color: c.brandTint, borderRadius: BorderRadius.circular(D.radiusMd)),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('${d.totalQty}', style: AltaiType.qtyTotal.copyWith(fontSize: 48, color: c.brandInk)),
                        const SizedBox(width: D.space2),
                        Padding(
                          padding: const EdgeInsets.only(bottom: D.space2),
                          child: Text(
                            'pcs · ${plural(d.lines.length, 'SKU')}',
                            style: AltaiType.heading.copyWith(fontWeight: FontWeight.w400, color: c.ink),
                          ),
                        ),
                        const SizedBox(width: D.space4),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: D.space2),
                            child: Text(
                              [d.storeName, _when(widget.checkout)].whereType<String>().join(' · '),
                              textAlign: TextAlign.end,
                              style: AltaiType.caption.copyWith(color: c.inkMuted),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (d.remark != null && d.remark!.isNotEmpty) ...[
                    const SizedBox(height: D.space2),
                    Text(d.remark!, style: AltaiType.caption.copyWith(color: c.inkMuted)),
                  ],
                  const SizedBox(height: D.space4),
                  if (d.lines.isEmpty)
                    const AltaiNotice('The team\'s system sent no items for this checkout.', warning: true),
                  for (final l in d.lines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: D.space3),
                      child: _LineRow(line: l, image: _images[l.sku]),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// "03/11/2026 14:32:05", or just the date when the time isn't known.
String _when(CheckoutSummary s) {
  final t = s.createdAt;
  String two(int n) => n.toString().padLeft(2, '0');
  final date = '${two(t.day)}/${two(t.month)}/${t.year}';
  return s.hasTime ? '$date ${two(t.hour)}:${two(t.minute)}:${two(t.second)}' : date;
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.line, required this.image});

  final CheckoutLine line;
  final String? image;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: D.space4, vertical: D.space3),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(D.radiusMd),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          ProductThumb(url: image, size: 64),
          const SizedBox(width: D.space4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.productName ?? line.sku, style: AltaiType.bodyStrong.copyWith(color: c.ink)),
                if (line.variation != null && line.variation!.isNotEmpty)
                  Text(line.variation!, style: AltaiType.body.copyWith(color: c.ink)),
                Text(
                  ['SKU ${line.sku}', if (line.productCode != null) 'Code ${line.productCode}'].join(' · '),
                  style: AltaiType.caption.copyWith(color: c.inkMuted),
                ),
              ],
            ),
          ),
          Text('× ${line.qty}', style: AltaiType.qty.copyWith(fontSize: 28, color: c.ink)),
        ],
      ),
    );
  }
}
