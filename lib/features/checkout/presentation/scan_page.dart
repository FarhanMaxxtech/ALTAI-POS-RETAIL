import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/altai_theme.dart';
import '../../../shared/altai_widgets.dart';
import '../../../shared/beeper.dart';
import '../../../shared/rfid_reader.dart';
import '../data/checkout_api.dart';
import '../data/store_tags.dart';

enum ScanPhase { ready, reading, done }

/// Put the items on the reader, press Scan, and every tag is read.
///
/// Scan starts the reader and it keeps reading until the cashier taps the same button again (Stop
/// scanning), so items can be added while it runs. Scans add up: Scan again adds its new tags to the
/// list (a tag read twice counts once). Remove all empties the list.
/// Returns the tags read (null = cancelled).
class ScanPage extends StatefulWidget {
  const ScanPage({
    super.key,
    required this.reader,
    this.known,
    this.inspector,
    this.target = 'basket',
    this.allowedSkus,
    this.title = 'Scan items',
    this.round = const Duration(milliseconds: 800),
  });

  /// The USB RFID reader.
  final TagReader reader;

  /// The store's tags kept on the tablet: shows each scanned tag's product. Null = EPCs only.
  final StoreTags? known;

  /// Asks the server about tags the store's list doesn't know, to show their product. Null = don't.
  final CheckoutApi? inspector;

  /// Where the tags go, for the last button: "Add 3 to basket" / "to return" / "to order".
  final String target;

  /// Scanning for one StoreHub order: only these SKUs belong. Other products are shown in red
  /// ("Not in this order") and left out. Null = any product.
  final Set<String>? allowedSkus;

  final String title;

  /// One read round of the USB reader (it reads round after round until stopped).
  final Duration round;

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _beeper = Beeper();
  final List<String> _tags = []; // in the order read, newest last
  final Map<String, KnownTag> _looked = {}; // what the server said about tags the list didn't know
  final Set<String> _asking = {}; // being looked up
  ScanPhase _phase = ScanPhase.ready;
  final Set<String> _unknown = {}; // tags with no product: dropped, and never added again
  int _run = 0; // which reading loop is the current one (a quick Stop then Scan starts a new one)
  ReaderState _usb = ReaderState.none;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkReader();
  }

  @override
  void dispose() {
    _beeper.dispose();
    super.dispose();
  }

  Future<void> _checkReader() async {
    final s = await widget.reader.state();
    if (mounted) setState(() => _usb = s);
  }

  Future<void> _allowReader() async {
    final ok = await widget.reader.askPermission();
    if (!mounted) return;
    await _checkReader();
    if (!ok && mounted) {
      setState(() => _error = 'The reader was not allowed. Tap Allow to try again.');
    }
  }

  /// Reads another batch. New tags are added to the list; nothing is replaced.
  Future<void> _scan() async {
    if (_usb != ReaderState.ready) {
      if (_usb == ReaderState.needsPermission) await _allowReader();
      if (_usb == ReaderState.none) await _checkReader();
      if (!mounted) return;
      if (_usb != ReaderState.ready) {
        setState(() => _error = 'No RFID reader. Plug the reader into the tablet, then tap Look again.');
        return;
      }
    }
    setState(() {
      _error = null;
      _phase = ScanPhase.reading;
    });
    _usbLoop();
  }

  /// Read round after round until the cashier taps Stop scanning (or leaves the page).
  Future<void> _usbLoop() async {
    final run = ++_run;
    while (mounted && _phase == ScanPhase.reading && run == _run) {
      List<String> got;
      try {
        got = await widget.reader.read(widget.round);
      } on ReaderException catch (e) {
        if (!mounted || run != _run) return;
        setState(() => _error = e.message);
        _stop();
        _checkReader();
        return;
      }
      if (!mounted) return;
      _add(got); // keep what the last round read, even after Stop scanning
    }
  }

  /// Adds new tags; true if any was new.
  bool _add(Iterable<String> epcs) {
    final fresh = [
      for (final e in epcs.toSet())
        if (!_tags.contains(e) && !_unknown.contains(e)) e, // a known-unknown tag read again stays out
    ];
    if (fresh.isEmpty) return false;
    HapticFeedback.lightImpact();
    _beeper.ok();
    setState(() => _tags.addAll(fresh));
    _lookUp(fresh);
    return true;
  }

  void _stop() {
    if (mounted) setState(() => _phase = ScanPhase.done);
  }

  Future<void> _removeAll() async {
    final c = context.altai;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove all ${_tags.length} scanned tags?', style: AltaiType.heading.copyWith(color: c.ink)),
        content: Text(
          'The list is emptied. Nothing has been sold or changed yet.',
          style: AltaiType.body.copyWith(color: c.inkMuted),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove all')),
        ],
      ),
    );
    if (ok == true && mounted) {
      setState(() {
        _tags.clear();
        _looked.clear();
        _unknown.clear();
        _phase = ScanPhase.ready;
        _error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final controls = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _readerLine(context),
        const SizedBox(height: D.space4),
        _count(context),
        const SizedBox(height: D.space6),
        ..._buttons(),
        if (_error case final e?) ...[const SizedBox(height: D.space4), AltaiNotice(e, warning: true)],
      ],
    );
    return Scaffold(
      appBar: AltaiAppBar(title: widget.title, onBack: () => Navigator.of(context).pop()),
      body: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 800;
          final list = _tagList(context);
          if (wide) {
            // Landscape: buttons on the left, the scanned tags on the right.
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 380,
                  child: SingleChildScrollView(padding: const EdgeInsets.all(D.space6), child: controls),
                ),
                VerticalDivider(width: 1, color: c.border),
                Expanded(child: list),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(padding: const EdgeInsets.all(D.space4), child: controls),
              Divider(height: 1, color: c.border),
              Expanded(child: list),
            ],
          );
        },
      ),
    );
  }

  /// Which reader this page uses.
  Widget _readerLine(BuildContext context) {
    final c = context.altai;
    final (icon, text, color) = switch (_usb) {
      ReaderState.ready => (Icons.usb_rounded, 'USB reader connected', c.brandInk),
      ReaderState.needsPermission => (Icons.usb_rounded, 'USB reader found: allow the app to use it', c.warning),
      ReaderState.none => (Icons.usb_off_rounded, 'No RFID reader plugged in', c.warning),
    };
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: D.space2),
        Flexible(child: Text(text, style: AltaiType.caption.copyWith(color: color))),
        if (_usb == ReaderState.needsPermission) TextButton(onPressed: _allowReader, child: const Text('Allow')),
        if (_usb == ReaderState.none) TextButton(onPressed: _checkReader, child: const Text('Look again')),
      ],
    );
  }

  /// A product that isn't on the StoreHub order being scanned.
  bool _notInOrder(String epc) {
    final allowed = widget.allowedSkus;
    final sku = _what(epc)?.sku;
    return allowed != null && sku != null && !allowed.contains(sku);
  }

  /// The tags that go on: everything scanned except products not in the order.
  List<String> get _keep => [
    for (final e in _tags)
      if (!_notInOrder(e)) e,
  ];

  Widget _count(BuildContext context) {
    final c = context.altai;
    final n = _keep.length;
    final notInOrder = _tags.length - n;
    final caption = switch (_phase) {
      ScanPhase.ready => n == 0 ? 'Put the items on the reader, then tap Scan.' : 'Tap Scan to read more.',
      ScanPhase.reading => 'Scanning… add or move items. Tap Stop scanning when all are read.',
      ScanPhase.done => 'Done. Scan again to add more items.',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '$n',
              key: const ValueKey('scan-count'),
              style: AltaiType.qtyTotal.copyWith(fontSize: 72, height: 1, color: c.brandInk),
            ),
            const SizedBox(width: D.space2),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(bottom: D.space2),
                child: Text(n == 1 ? 'pc scanned' : 'pcs scanned', style: AltaiType.label.copyWith(color: c.ink)),
              ),
            ),
          ],
        ),
        const SizedBox(height: D.space2),
        Text(caption, style: AltaiType.body.copyWith(color: c.inkMuted)),
        if (_unknown.isNotEmpty) ...[
          const SizedBox(height: D.space2),
          Text(
            '${_unknown.length == 1 ? '1 unknown tag' : '${_unknown.length} unknown tags'} ignored (no product).',
            key: const ValueKey('ignored-unknown'),
            style: AltaiType.caption.copyWith(color: c.inkMuted),
          ),
        ],
        if (notInOrder > 0) ...[
          const SizedBox(height: D.space2),
          AltaiNotice(
            '${notInOrder == 1 ? '1 item is' : '$notInOrder items are'} not in this order: '
            "shown in red, they won't be added. Take them off the reader.",
            warning: true,
          ),
        ],
      ],
    );
  }

  List<Widget> _buttons() {
    final n = _keep.length;
    final reading = _phase == ScanPhase.reading;
    return [
      if (reading) ...[
        // The same button: it spins while the reader runs; tapping it stops the scan.
        AltaiButton(
          'Stop scanning',
          onPressed: _stop,
          loading: true,
          variant: AltaiButtonVariant.primary,
          large: true,
          expand: true,
        ),
      ] else if (_tags.isEmpty) ...[
        AltaiButton(
          'Scan',
          onPressed: _scan,
          variant: AltaiButtonVariant.primary,
          icon: Icons.sensors_rounded,
          large: true,
          expand: true,
        ),
      ] else ...[
        // Done: the scan button becomes Remove all; Scan again adds another batch.
        AltaiButton(
          n == 0 ? 'Nothing to add' : 'Add $n to ${widget.target}',
          onPressed: n == 0 ? null : () => Navigator.of(context).pop(_keep),
          variant: AltaiButtonVariant.primary,
          icon: Icons.arrow_forward_rounded,
          large: true,
          expand: true,
        ),
        const SizedBox(height: D.space3),
        AltaiButton('Scan again', onPressed: _scan, icon: Icons.sensors_rounded, large: true, expand: true),
        const SizedBox(height: D.space2),
        AltaiButton(
          'Remove all',
          onPressed: _removeAll,
          variant: AltaiButtonVariant.ghost,
          icon: Icons.delete_sweep_rounded,
          expand: true,
        ),
      ],
    ];
  }

  /// What each scanned tag is: from the store's list, else from the server. Null = not known yet.
  KnownTag? _what(String epc) => widget.known?[epc] ?? _looked[epc];

  /// Asks the server about tags the store's list doesn't know (e.g. sold or moved since it loaded).
  Future<void> _lookUp(List<String> epcs) async {
    final inspector = widget.inspector;
    if (inspector == null) return;
    final ask = [
      for (final e in epcs)
        if (widget.known?[e] == null && !_looked.containsKey(e) && !_asking.contains(e)) e,
    ];
    if (ask.isEmpty) return;
    _asking.addAll(ask);
    for (var i = 0; i < ask.length; i += CheckoutApi.inspectLimit) {
      final batch = ask.sublist(i, (i + CheckoutApi.inspectLimit).clamp(0, ask.length));
      try {
        await inspector.inspect(
          batch,
          onEach: (t) {
            if (!mounted) return;
            final epc = t['epc'] as String;
            setState(() {
              _asking.remove(epc);
              if (t['found'] == true) {
                _looked[epc] = KnownTag(
                  sku: t['sku'] as String?,
                  productName: t['product_name'] as String?,
                  productCode: t['product_code'] as String?,
                  variation: t['variation'] as String?,
                );
              } else if (t['found'] == false && _tags.remove(epc)) {
                _unknown.add(epc); // no product behind this tag: not an item to sell or return
              }
            });
          },
        );
      } catch (_) {
        // No answer: those rows stay "Looking up…"; the checkout checks every tag again anyway.
      }
      if (mounted) setState(() => _asking.removeAll(batch));
    }
  }

  /// The scanned tags as product rows (same SKU together, with a quantity), newest first.
  Widget _tagList(BuildContext context) {
    final c = context.altai;
    if (_tags.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(D.space6),
          child: Text(
            'Scanned items show here.',
            style: AltaiType.body.copyWith(color: c.inkMuted),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    // Group: one row per SKU; a tag not known yet (or with no product) gets its own row.
    final groups = <String, ({KnownTag? what, String epc, int qty})>{};
    for (final epc in _tags.reversed) {
      final w = _what(epc);
      final key = w?.sku ?? w?.productName ?? 'epc:$epc';
      final g = groups[key];
      groups[key] = (what: w, epc: g?.epc ?? epc, qty: (g?.qty ?? 0) + 1);
    }
    final rows = groups.values.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(D.space4, D.space4, D.space4, D.space2),
          child: Text(
            'SCANNED ITEMS (${_tags.length})',
            style: AltaiType.label.copyWith(color: c.inkMuted),
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(D.space4, 0, D.space4, D.space4),
            itemCount: rows.length,
            separatorBuilder: (_, _) => Divider(height: 1, color: c.border),
            itemBuilder: (context, i) {
              final r = rows[i];
              final name = r.what?.productName;
              final looking = r.what == null && _asking.contains(r.epc);
              final title =
                  name ??
                  (looking
                      ? 'Looking up…'
                      : r.what == null
                      ? 'Item' // could not be looked up (no connection): checked at checkout
                      : 'Unknown tag: no product');
              final away = _notInOrder(r.epc);
              final sub = away ? 'Not in this order' : (name == null ? null : (r.what?.variation ?? r.what?.sku));
              return Padding(
                key: ValueKey('scanned-${r.what?.sku ?? r.epc}'),
                padding: const EdgeInsets.symmetric(vertical: D.space2),
                child: Row(
                  children: [
                    Icon(
                      away
                          ? Icons.block_rounded
                          : name == null
                          ? Icons.sell_outlined
                          : Icons.checkroom_rounded,
                      size: 22,
                      color: away
                          ? c.danger
                          : name == null
                          ? c.inkMuted
                          : c.brandInk,
                    ),
                    const SizedBox(width: D.space3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AltaiType.label.copyWith(
                              fontSize: 16,
                              color: away
                                  ? c.danger
                                  : name == null
                                  ? c.inkMuted
                                  : c.ink,
                            ),
                          ),
                          if (sub != null)
                            Text(
                              sub,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AltaiType.caption.copyWith(color: away ? c.danger : c.inkMuted),
                            ),
                        ],
                      ),
                    ),
                    Text('× ${r.qty}', style: AltaiType.bodyStrong.copyWith(color: c.ink)),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
