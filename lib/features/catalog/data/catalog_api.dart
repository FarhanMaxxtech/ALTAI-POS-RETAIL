import '../../../core/api_client.dart';

/// What the team's catalogue knows about one SKU.
class SkuInfo {
  const SkuInfo({this.image, this.price});

  final String? image; // full link to the picture
  final String? price; // the team's selling price, e.g. "849.00"
}

/// Read-only product catalogue from the team's API (Product/List).
class CatalogApi {
  CatalogApi(this._api);

  final ApiClient _api;

  /// Picture and price of one SKU. Fields are null when the team has none.
  Future<SkuInfo> lookup(String sku) async {
    final res = await _api.post('Product/List', {
      'code': '',
      'name': '',
      'sku': sku,
      'active': '',
      'storeId': '',
      'includeSkus': 'Y',
      'page': 1,
      'pageSize': 5,
    });
    final products = (res['data'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    // `sku` matches PART of a SKU, so find the exact one.
    for (final p in products) {
      final skus = (p['skus'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
      for (final s in skus) {
        if (s['sku'] == sku) {
          return SkuInfo(
            image: _firstUrl(s['images']) ?? _firstUrl(p['images']),
            price: money(s['price']),
          );
        }
      }
    }
    // The SKU list didn't come back: if only one product matched, use that product's picture.
    if (products.length == 1) return SkuInfo(image: _firstUrl(products.first['images']));
    return const SkuInfo();
  }

  String? _firstUrl(dynamic images) {
    if (images is! List || images.isEmpty) return null;
    final first = images.first;
    return first is String && first.isNotEmpty ? _api.imageUrl(first) : null;
  }

  /// Their prices are plain numbers (849, 49.9). The basket wants "849.00", rounded to whole sen.
  static String? money(Object? v) {
    final n = v is num ? v : num.tryParse(v?.toString() ?? '');
    if (n == null || !n.isFinite) return null;
    final cents = (n * 100).round();
    return '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';
  }
}
