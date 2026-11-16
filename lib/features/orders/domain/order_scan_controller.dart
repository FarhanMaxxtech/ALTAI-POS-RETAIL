import 'package:flutter/foundation.dart';

import '../../checkout/data/checkout_api.dart';
import '../../checkout/domain/basket.dart';
import '../data/orders_api.dart';
import 'order.dart';

enum OrderScanPhase { scanning, sending, done }

/// A tag that can't go on the order, and why.
class RejectedTag {
  const RejectedTag(this.epc, this.reason, {this.name});

  final String epc;
  final String reason;
  final String? name; // product name, when the tag is known
}

/// Scanning the items of one StoreHub order. Each tag must be in this store, its SKU must be on the
/// order, and no SKU may get more tags than the order's quantity. When every tagged line is full the
/// order can be completed: the server then marks those tags Sold, so the gate lets them out.
class OrderScanController extends ChangeNotifier {
  OrderScanController({
    required this.order,
    required this.inspector,
    required this.orders,
    required this.storeId,
    required this.staffName,
  });

  final StoreHubOrder order;
  final CheckoutApi inspector; // the tag checks (read only)
  final OrdersApi orders;
  final String storeId;
  final String staffName;

  OrderScanPhase phase = OrderScanPhase.scanning;
  String? message;

  final Map<String, List<String>> _accepted = {}; // sku → tags, in scan order
  /// Tags with no product, left out.
  int ignoredUnknown = 0;

  final List<RejectedTag> rejected = [];
  final Set<String> _checking = {};
  Future<void> _queue = Future.value(); // checks run one batch after another, so counts stay right

  int scannedOf(String sku) => _accepted[sku]?.length ?? 0;
  List<String> tagsOf(String sku) => List.unmodifiable(_accepted[sku] ?? const <String>[]);
  int get scannedQty => _accepted.values.fold(0, (sum, t) => sum + t.length);
  int get checkingCount => _checking.length;
  List<String> get epcs => [for (final t in _accepted.values) ...t];

  bool get allMatched => _checking.isEmpty && order.lines.every((l) => l.exempt || scannedOf(l.sku) == l.qty);

  bool _seen(String epc) =>
      _checking.contains(epc) || _accepted.values.any((t) => t.contains(epc)) || rejected.any((r) => r.epc == epc);

  /// Text from the reader or the keyboard. Tags read again are ignored.
  void addText(String text) {
    if (phase != OrderScanPhase.scanning) return;
    final parsed = parseTags(text);
    final fresh = [
      for (final e in parsed.epcs)
        if (!_seen(e)) e,
    ];
    message = parsed.invalid > 0 ? '${parsed.invalid} entry not recognised as a tag.' : null;
    if (fresh.isNotEmpty) {
      _checking.addAll(fresh);
      _queue = _queue.then((_) => _check(fresh));
    }
    notifyListeners();
  }

  Future<void> _check(List<String> epcs) async {
    for (var i = 0; i < epcs.length; i += CheckoutApi.inspectLimit) {
      final batch = epcs.sublist(i, (i + CheckoutApi.inspectLimit).clamp(0, epcs.length));
      List<Map<String, dynamic>> found;
      try {
        found = await inspector.inspect(batch);
      } catch (_) {
        found = [
          for (final e in batch) {'epc': e, 'found': null},
        ];
      }
      for (final t in found) {
        final item = itemFromInspection(t, storeId);
        _checking.remove(item.epc);
        if (t['found'] == false) {
          ignoredUnknown++; // no product behind this tag: not an item of any order
          continue;
        }
        if (item.state != ItemState.ok) {
          rejected.insert(0, RejectedTag(item.epc, item.problem ?? 'Could not check this tag', name: item.productName));
          continue;
        }
        final reason = rejectReason(order, item.sku, scannedOf(item.sku ?? ''));
        if (reason != null) {
          rejected.insert(0, RejectedTag(item.epc, reason, name: item.productName));
        } else {
          (_accepted[item.sku!] ??= []).add(item.epc);
        }
      }
      notifyListeners();
    }
  }

  /// A wrongly rejected tag can be read again after clearing the list.
  void clearRejected() {
    rejected.clear();
    notifyListeners();
  }

  /// Marks the tags Sold against the order. Only when every tagged line is full.
  Future<void> complete() async {
    if (phase != OrderScanPhase.scanning || !allMatched) return;
    phase = OrderScanPhase.sending;
    message = null;
    notifyListeners();
    try {
      await orders.complete(order, epcs, staffName: staffName);
      phase = OrderScanPhase.done;
    } catch (e) {
      phase = OrderScanPhase.scanning;
      message = 'Could not complete the order. Check the connection and try again.';
    }
    notifyListeners();
  }
}
