import 'package:flutter/material.dart';

import '../../shared/altai_theme.dart';
import '../../shared/altai_widgets.dart';
import '../../shared/rfid_reader.dart';
import '../catalog/data/catalog_api.dart';
import '../checkout/data/checkout_api.dart';
import '../checkout/data/store_tags.dart';
import '../checkout/presentation/basket_screen.dart';
import '../checkout/presentation/scan_page.dart';
import '../orders/data/orders_api.dart';
import '../returns/data/returns_api.dart';
import '../returns/presentation/return_screen.dart';

/// The first page after login: the cashier picks what to do.
///   - Scan for Checkout: scan the items, then the checkout opens with them.
///   - Return / Refund: items coming back into stock.
class HomeScreen extends StatelessWidget {
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

  Future<void> _checkout(BuildContext context) async {
    final tags = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => ScanPage(reader: tagReader, known: storeTags, inspector: api, title: 'Scan for checkout', autoStart: true),
      ),
    );
    if (tags == null || tags.isEmpty || !context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => BasketScreen(
          api: api,
          storeId: storeId,
          storeName: storeName,
          staffName: staffName,
          catalog: catalog,
          returns: returns,
          orders: orders,
          storeTags: storeTags,
          tagReader: tagReader,
          initialTags: tags,
          onBack: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  Future<void> _return(BuildContext context, ReturnsApi returns) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => ReturnScreen(
        inspector: api,
        api: returns,
        storeId: storeId,
        storeName: storeName,
        staffName: staffName,
        catalog: catalog,
        tagReader: tagReader,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final returns = this.returns;
    return Scaffold(
      appBar: AltaiAppBar(
        title: 'Altai POS',
        subtitle: storeName,
        actions: [
          AppBarText(staffName),
          AppBarIcon(Icons.logout_rounded, tooltip: 'Log out', onPressed: onLogout),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(D.space6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('What would you like to do?', style: AltaiType.title.copyWith(fontSize: 28, color: c.ink)),
                const SizedBox(height: D.space6),
                Wrap(
                  spacing: D.space6,
                  runSpacing: D.space6,
                  alignment: WrapAlignment.center,
                  children: [
                    _Choice(
                      icon: Icons.sensors_rounded,
                      title: 'Scan for Checkout',
                      body: 'Put the items on the reader and scan them. Then enter the StoreHub receipt.',
                      primary: true,
                      onTap: () => _checkout(context),
                    ),
                    if (returns != null)
                      _Choice(
                        icon: Icons.assignment_return_rounded,
                        title: 'Return / Refund',
                        body: 'Items coming back: they go back into stock. The money goes back on StoreHub.',
                        onTap: () => _return(context, returns),
                      ),
                  ],
                ),
              ],
            ),
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
    final (bg, fg, sub) = primary ? (c.brand, c.onBrand, c.onBrand) : (c.surfaceRaised, c.ink, c.inkMuted);
    return SizedBox(
      width: 380,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(D.radiusMd * 2),
        child: InkWell(
          borderRadius: BorderRadius.circular(D.radiusMd * 2),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 240), // grows with big text instead of overflowing
            padding: const EdgeInsets.all(D.space6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(D.radiusMd * 2),
              border: primary ? null : Border.all(color: c.borderStrong, width: 1.5),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 56, color: primary ? fg : c.brandInk),
                const SizedBox(height: D.space8),
                Text(title, style: AltaiType.title.copyWith(fontSize: 28, color: fg)),
                const SizedBox(height: D.space2),
                Text(body, style: AltaiType.body.copyWith(fontSize: 16, color: sub)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
