import 'package:flutter/material.dart';

import 'core/api_client.dart';
import 'features/auth/data/auth_api.dart';
import 'features/auth/data/session_store.dart';
import 'features/auth/domain/staff.dart';
import 'features/auth/presentation/login_screen.dart';
import 'features/checkout/data/checkout_api.dart';
import 'features/checkout/data/store_tags.dart';
import 'features/checkout/presentation/basket_screen.dart';
import 'features/catalog/data/catalog_api.dart';
import 'features/orders/data/orders_api.dart';
import 'features/returns/data/returns_api.dart';
import 'shared/altai_theme.dart';
import 'shared/altai_widgets.dart';

void main() => runApp(const AltaiPosApp());

/// Log in → basket. The tablet's location (its store) is set once from the login screen and stays
/// when staff log out, so nobody picks a store. The login is remembered too, so reopening the app
/// goes straight to the basket.
class AltaiPosApp extends StatefulWidget {
  const AltaiPosApp({super.key});

  @override
  State<AltaiPosApp> createState() => _AltaiPosAppState();
}

class _AltaiPosAppState extends State<AltaiPosApp> {
  final _api = ApiClient();
  late final _auth = AuthApi(_api, SessionStore());
  late final _checkout = CheckoutApi(_api);
  late final _catalog = CatalogApi(_api);
  late final _returns = ReturnsApi(_api);
  final _orders = FakeOrdersApi(); // demo until the Altai server sends StoreHub orders
  Staff? _staff;
  Store? _location;
  bool _restoring = true; // checking the saved login when the app opens
  StoreTags? _storeTags; // the location's tags, kept on the tablet
  String? _storeTagsFor;

  /// The store's tag list for [storeId], loaded in the background (and refreshed) once logged in.
  StoreTags _tagsFor(String storeId) {
    if (_storeTagsFor != storeId || _storeTags == null) {
      _storeTags?.dispose();
      _storeTagsFor = storeId;
      _storeTags = StoreTags((page) => _checkout.storeTagPage(storeId, page))..start();
    }
    return _storeTags!;
  }

  @override
  void dispose() {
    _storeTags?.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final location = await _auth.location();
    final saved = location == null ? null : await _auth.restore();
    if (!mounted) return;
    setState(() {
      _location = location;
      if (saved != null) _staff = Staff(saved.staffName);
      _restoring = false;
    });
  }

  Future<void> _logout() async {
    await _auth.logout();
    setState(() => _staff = null);
  }

  @override
  Widget build(BuildContext context) {
    final staff = _staff;
    final location = _location;
    return MaterialApp(
      title: 'Altai POS',
      debugShowCheckedModeBanner: false,
      // Altai design system, light and dark (follows the tablet's setting).
      theme: altaiTheme(Brightness.light),
      darkTheme: altaiTheme(Brightness.dark),
      builder: aboveSystemBars,
      home: _restoring
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : staff == null || location == null
              ? LoginScreen(
                  auth: _auth,
                  location: location,
                  onLocationSet: (s) => setState(() => _location = s),
                  onLoggedIn: (s) => setState(() => _staff = s))
              : BasketScreen(
                  api: _checkout,
                  storeId: location.id,
                  storeName: location.name,
                  staffName: staff.name,
                  catalog: _catalog,
                  returns: _returns,
                  orders: _orders,
                  storeTags: _tagsFor(location.id),
                  onLogout: _logout),
    );
  }
}
