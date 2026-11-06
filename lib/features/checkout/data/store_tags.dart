import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

/// What the store's tag list says about one tag.
class KnownTag {
  const KnownTag({this.sku, this.productName, this.productCode, this.variation});

  final String? sku;
  final String? productName;
  final String? productCode;
  final String? variation;
}

/// One page of the store's tag list: the rows, and how many there are in all.
typedef StoreTagPage = Future<({List<Map<String, dynamic>> rows, int total})> Function(int page);

/// The store's tags, kept on the tablet so a scanned piece shows its name at once.
///
/// Only for showing: every tag is still checked with the server before the sale (still in the
/// store, not sold, not held by a transfer or count). Refreshed in the background.
class StoreTags {
  StoreTags(this._loadPage, {this.refreshEvery = const Duration(minutes: 10), this.maxPages = 200});

  final StoreTagPage _loadPage;
  final Duration refreshEvery;

  /// A safety stop: never more pages than this in one refresh.
  final int maxPages;

  Map<String, KnownTag> _byEpc = const {};
  Timer? _timer;
  bool _loading = false;

  /// When the list was last loaded in full. Null = not yet.
  DateTime? loadedAt;

  int get count => _byEpc.length;

  KnownTag? operator [](String epc) => _byEpc[epc.toUpperCase()];

  /// Loads now, then again every [refreshEvery].
  void start() {
    load();
    _timer?.cancel();
    _timer = Timer.periodic(refreshEvery, (_) => load());
  }

  void dispose() => _timer?.cancel();

  /// Reads every page; the old list stays in use until the new one is complete.
  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    final watch = Stopwatch()..start();
    try {
      final next = <String, KnownTag>{};
      for (var page = 1; page <= maxPages; page++) {
        final p = await _loadPage(page);
        for (final r in p.rows) {
          final epc = r['epc']?.toString().toUpperCase();
          if (epc == null || epc.isEmpty) continue;
          next[epc] = KnownTag(
            sku: _text(r['sku']),
            productName: _text(r['productName']),
            productCode: _text(r['productCode']),
            variation: _text(r['varLabel']),
          );
        }
        if (p.rows.isEmpty || next.length >= p.total) break;
      }
      _byEpc = next;
      loadedAt = DateTime.now();
      debugPrint('StoreTags: ${next.length} tags in ${watch.elapsedMilliseconds} ms');
    } catch (e) {
      debugPrint('StoreTags: could not load ($e)');
      // No list (offline, server error): scanning still works, names just come from the check.
    } finally {
      _loading = false;
    }
  }

  static String? _text(Object? v) {
    final s = v?.toString().trim();
    return s == null || s.isEmpty ? null : s;
  }
}
