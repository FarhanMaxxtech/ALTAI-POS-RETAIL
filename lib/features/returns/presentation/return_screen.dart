import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/altai_theme.dart';
import '../../../shared/altai_widgets.dart';
import '../../../shared/beeper.dart';
import '../../../shared/keyboard.dart';
import '../../../shared/rfid_reader.dart';
import '../../checkout/presentation/scan_page.dart';
import '../../catalog/data/catalog_api.dart';
import '../../checkout/data/checkout_api.dart';
import '../../checkout/domain/basket.dart';
import '../data/returns_api.dart';
import '../domain/exchange.dart';
import '../domain/return_controller.dart';

/// Return & refund: the items go back into this store's stock here; the money goes back on StoreHub.
///
/// With [exchange] it's step 1 of an exchange: once the items are back in stock the screen closes and
/// hands an [ExchangeReturn] to the checkout, where the new items are scanned.
///
/// The items coming back are read with the Scan page (the USB RFID reader), like at checkout.
class ReturnScreen extends StatefulWidget {
  const ReturnScreen({
    super.key,
    required this.inspector,
    required this.api,
    required this.storeId,
    required this.storeName,
    required this.staffName,
    this.catalog,
    this.exchange = false,
    this.tagReader = const UsbTagReader(),
  });

  final CheckoutApi inspector;
  final ReturnsApi api;
  final String storeId;
  final String storeName;
  final String staffName;
  final CatalogApi? catalog;

  /// Step 1 of an exchange: closes with an [ExchangeReturn] once the items are back in stock.
  final bool exchange;

  /// The USB RFID reader the Scan page drives.
  final TagReader tagReader;

  @override
  State<ReturnScreen> createState() => _ReturnScreenState();
}

class _ReturnScreenState extends State<ReturnScreen> {
  late final ReturnController _return = ReturnController(
      inspector: widget.inspector,
      api: widget.api,
      storeId: widget.storeId,
      staffName: widget.staffName,
      catalog: widget.catalog);
  final _receipt = TextEditingController();
  final _beeper = Beeper();
  int _lastCount = 0;
  bool _handedBack = false; // exchange: the result is passed back once

  bool get _showPrices => widget.catalog != null;

  @override
  void initState() {
    super.initState();
    _return.addListener(_onChanged);
  }

  @override
  void dispose() {
    _return.removeListener(_onChanged);
    _return.dispose();
    _receipt.dispose();
    _beeper.dispose();
    super.dispose();
  }

  void _onChanged() {
    final count = _return.items.length;
    if (count > _lastCount) {
      HapticFeedback.lightImpact();
      _beeper.ok();
    }
    _lastCount = count;

    if (widget.exchange && _return.phase == ReturnPhase.done && !_handedBack) {
      _handedBack = true;
      final result = ExchangeReturn(
        receiptNo: _return.receiptNo.trim(),
        pieces: _return.okCount,
        refundCents: _showPrices ? _return.refundCents : 0,
        trxId: _return.trxId ?? '',
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop(result);
      });
    }
  }

  /// The Scan page: the returned items on the reader, Scan, and they all come back here.
  Future<void> _scanItems() async {
    final tags = await Navigator.of(context).push<List<String>>(
        MaterialPageRoute(builder: (_) => ScanPage(reader: widget.tagReader, inspector: widget.inspector, target: 'return', autoStart: true)));
    if (!mounted) return;
    if (tags != null && tags.isNotEmpty) _return.addText(tags.join(' '));
  }

  void _newReturn() {
    _return.reset();
    _receipt.clear();
    _lastCount = 0;
  }

  /// A return that may be half done stays on screen until it's finished.
  void _leave() {
    final phase = _return.phase;
    if (phase == ReturnPhase.scanning || phase == ReturnPhase.done) {
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Finish this return first: tap Try again.')));
    }
  }

  /// Last look: this changes live stock and can't be undone from the tablet.
  Future<void> _confirm() async {
    final c = context.altai;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.exchange ? 'Confirm exchange: items back' : 'Confirm return',
            style: AltaiType.title.copyWith(color: c.ink)),
        content: Text(
          widget.exchange
              ? '${plural(_return.okCount, 'pc')} go back into stock at ${widget.storeName}. '
                  'Next, scan the new items the customer takes.'
              : '${plural(_return.okCount, 'pc')} go back into stock at ${widget.storeName}.'
                  '${_showPrices ? ' Refund RM ${formatRm(_return.refundCents)} on StoreHub.' : ''}',
          style: AltaiType.body.copyWith(color: c.inkMuted),
        ),
        actions: [
          AltaiButton('Back', onPressed: () => Navigator.of(context).pop(false)),
          AltaiButton('Submit',
              onPressed: () => Navigator.of(context).pop(true),
              variant: AltaiButtonVariant.primary,
              icon: Icons.check_rounded),
        ],
      ),
    );
    if (ok == true) _return.submit();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AltaiAppBar(
        title: widget.exchange ? 'Exchange · 1 of 2: items back' : 'Return & refund',
        subtitle: widget.storeName,
        onBack: _leave,
        actions: [AppBarText(widget.staffName)],
      ),
      body: ListenableBuilder(
        listenable: _return,
        builder: (context, _) => switch (_return.phase) {
          ReturnPhase.scanning => _scanning(context),
          ReturnPhase.sending => _sending(context),
          ReturnPhase.done => widget.exchange ? _sending(context) : _done(context), // closes by itself
          ReturnPhase.retry => _Problem(
              icon: Icons.wifi_off_rounded,
              title: 'No confirmation yet',
              body: '${_return.message} It is safe to try again: this return can only be saved once.',
              onRetry: _return.submit),
          ReturnPhase.notApproved => _Problem(
              icon: Icons.hourglass_top_rounded,
              title: 'Saved, but stock isn\'t back yet',
              body: '${_return.message} Try again approves the same return.',
              onRetry: _return.submit),
        },
      ),
    );
  }

  /* ---------------- Scanning ---------------- */

  Widget _scanning(BuildContext context) {
    final c = context.altai;
    final items = _return.items.reversed.toList();
    final missing = _return.missing;
    return Column(children: [
      Expanded(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: ListView(padding: const EdgeInsets.all(D.space6), children: [
              // 1. Which sale: the receipt no., order no. or ID, typed from the iPad.
              TextField(
                onTap: showKeyboard,
                controller: _receipt,
                style: AltaiType.body.copyWith(color: c.ink),
                decoration: InputDecoration(
                  labelText: 'StoreHub receipt no., order no. or ID',
                  hintText: 'Type it from the iPad',
                  prefixIcon: const Icon(Icons.receipt_long_rounded),
                ),
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                onChanged: _return.setReceipt,
              ),
              const SizedBox(height: D.space4),
              // 2. The items coming back: read with the Scan page.
              Row(children: [
                Icon(Icons.sell_outlined, color: c.brandInk),
                const SizedBox(width: D.space3),
                Expanded(
                  child: Text('Items coming back: put them on the reader, then tap Scan.',
                      style: AltaiType.body.copyWith(color: c.ink)),
                ),
                const SizedBox(width: D.space3),
                AltaiButton('Scan',
                    onPressed: _scanItems,
                    variant: AltaiButtonVariant.primary,
                    icon: Icons.sensors_rounded,
                    large: true),
              ]),
              if (_return.message != null) ...[
                const SizedBox(height: D.space3),
                AltaiNotice(_return.message!),
              ],
              const SizedBox(height: D.space4),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: D.space6),
                  child: Text('No items yet. Put the returned items on the reader and tap Scan.',
                      style: AltaiType.body.copyWith(color: c.inkMuted), textAlign: TextAlign.center),
                ),
              for (final i in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: D.space2),
                  child: _ItemRow(
                    item: i,
                    image: _return.imageOf(i),
                    price: _showPrices ? _return.priceOf(i) : null,
                    onRemove: () => _return.remove(i.epc),
                  ),
                ),
              const SizedBox(height: D.space4),
              Text('Reason', style: AltaiType.label.copyWith(color: c.inkMuted)),
              const SizedBox(height: D.space2),
              Wrap(spacing: D.space2, runSpacing: D.space2, children: [
                for (final r in returnReasons)
                  ChoiceChip(
                    label: Text(r, style: AltaiType.body),
                    selected: _return.reason == r,
                    onSelected: (_) => _return.setReason(r),
                  ),
              ]),
            ]),
          ),
        ),
      ),
      Divider(height: 1, color: c.border),
      Container(
        color: c.surfaceRaised,
        padding: const EdgeInsets.all(D.space4),
        child: SafeArea(
          top: false,
          child: Row(children: [
            Text('${_return.okCount}', style: AltaiType.qty.copyWith(color: c.brandInk)),
            const SizedBox(width: D.space1),
            Text('pcs', style: AltaiType.label.copyWith(color: c.inkMuted)),
            if (_showPrices) ...[
              const SizedBox(width: D.space4),
              Text('Refund RM ${formatRm(_return.refundCents)}', style: AltaiType.heading.copyWith(color: c.ink)),
            ],
            const SizedBox(width: D.space4),
            Expanded(
              child: Text(missing ?? '', style: AltaiType.caption.copyWith(color: c.inkMuted)),
            ),
            AltaiButton('Clear', onPressed: _return.items.isEmpty ? null : _newReturn),
            const SizedBox(width: D.space3),
            AltaiButton(widget.exchange ? 'Return & next' : 'Return items',
                onPressed: _return.canSubmit ? _confirm : null,
                variant: AltaiButtonVariant.primary,
                icon: widget.exchange ? Icons.arrow_forward_rounded : Icons.assignment_return_rounded),
          ]),
        ),
      ),
    ]);
  }

  /* ---------------- Other phases ---------------- */

  Widget _sending(BuildContext context) {
    final c = context.altai;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(width: 56, height: 56, child: CircularProgressIndicator(strokeWidth: 5)),
        const SizedBox(height: D.space4),
        Text('Putting the items back in stock…', style: AltaiType.heading.copyWith(color: c.ink)),
      ]),
    );
  }

  Widget _done(BuildContext context) {
    final c = context.altai;
    final unpriced = _return.unpricedCount;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(D.space6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(children: [
            StatusCircle(icon: Icons.check_rounded, color: c.brand, onColor: c.onBrand),
            const SizedBox(height: D.space4),
            Text('Back in stock', style: AltaiType.title.copyWith(fontSize: 32, color: c.ink)),
            Text(
              '${plural(_return.okCount, 'pc')} · Receipt ${_return.receiptNo.trim()} · Adjustment ${_return.trxId}',
              style: AltaiType.body.copyWith(color: c.inkMuted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: D.space6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(D.space6),
              decoration: BoxDecoration(color: c.brandTint, borderRadius: BorderRadius.circular(D.radiusMd)),
              child: Column(children: [
                Text('NOW REFUND ON STOREHUB', style: AltaiType.label.copyWith(color: c.inkMuted)),
                if (_showPrices)
                  Text('RM ${formatRm(_return.refundCents)}',
                      style: AltaiType.qtyTotal.copyWith(fontSize: 48, color: c.brandInk)),
                Text(
                  unpriced > 0
                      ? '${plural(unpriced, 'item')} had no price here: check the receipt.'
                      : 'Use the amount on the receipt if it differs (discounts).',
                  style: AltaiType.caption.copyWith(color: c.ink),
                  textAlign: TextAlign.center,
                ),
              ]),
            ),
            const SizedBox(height: D.space6),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              AltaiButton('Back to checkout', onPressed: () => Navigator.of(context).pop(), large: true),
              const SizedBox(width: D.space3),
              AltaiButton('New return',
                  onPressed: _newReturn,
                  variant: AltaiButtonVariant.primary,
                  icon: Icons.assignment_return_rounded,
                  large: true),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, required this.image, required this.price, required this.onRemove});

  final BasketItem item;
  final String? image;
  final String? price;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final problem = item.state == ItemState.problem;
    final checking = item.state == ItemState.checking;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: D.space4, vertical: D.space3),
      decoration: BoxDecoration(
        color: problem ? c.dangerTint : c.surfaceRaised,
        borderRadius: BorderRadius.circular(D.radiusMd),
        border: Border.all(color: c.border),
      ),
      child: Row(children: [
        ProductThumb(url: image, size: 48),
        const SizedBox(width: D.space3),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              checking ? 'Checking…' : item.productName ?? 'Unknown item',
              style: AltaiType.bodyStrong.copyWith(color: c.ink),
            ),
            if (problem)
              Text(item.problem ?? '', style: AltaiType.caption.copyWith(color: c.danger))
            else if (item.variation ?? item.sku case final sub?)
              Text(sub, style: AltaiType.caption.copyWith(color: c.inkMuted)),
          ]),
        ),
        if (price != null) Text('RM $price', style: AltaiType.bodyStrong.copyWith(color: c.ink)),
        IconButton(tooltip: 'Remove', onPressed: onRemove, icon: const Icon(Icons.close_rounded)),
      ]),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({required this.icon, required this.title, required this.body, required this.onRetry});

  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(D.space6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            StatusCircle(icon: icon, color: c.warningTint, onColor: c.warning),
            const SizedBox(height: D.space4),
            Text(title, style: AltaiType.title.copyWith(fontSize: 28, color: c.ink), textAlign: TextAlign.center),
            const SizedBox(height: D.space2),
            Text(body, style: AltaiType.body.copyWith(color: c.inkMuted), textAlign: TextAlign.center),
            const SizedBox(height: D.space6),
            AltaiButton('Try again', onPressed: onRetry, variant: AltaiButtonVariant.primary, large: true),
          ]),
        ),
      ),
    );
  }
}
