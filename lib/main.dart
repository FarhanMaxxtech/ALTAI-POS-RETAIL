import 'package:flutter/material.dart';

import 'core/api_client.dart';
import 'features/auth/data/auth_api.dart';
import 'features/auth/data/session_store.dart';
import 'features/auth/domain/staff.dart';
import 'features/auth/presentation/login_screen.dart';
import 'features/auth/presentation/store_screen.dart';
import 'features/checkout/data/checkout_api.dart';
import 'features/checkout/data/store_tags.dart';
import 'features/catalog/data/catalog_api.dart';
import 'features/home/home_screen.dart';
import 'features/orders/data/orders_api.dart';
import 'features/returns/data/returns_api.dart';
import 'shared/altai_theme.dart';
import 'shared/altai_widgets.dart';

void main() => runApp(const AltaiPosApp());

/// Log in → pick the store (from the stores the account can use; skipped when there's only one) →
/// the start page. The login and the store are remembered, so reopening the app goes straight back
/// in. After logging out, the next login offers the last store first.
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
  Store? _location; // the store picked for this login; null = the store picker shows
  Store? _lastStore; // picked last on this tablet: offered first
  bool _restoring = true; // checking the saved login when the app opens
  final _nav = GlobalKey<NavigatorState>();
  String? _loginNotice; // why the login screen came back
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
    _api.onSessionLost = _sessionLost;
    _restore();
  }

  /// The session ended and the app can't log in again by itself: back to the login screen, from
  /// wherever the cashier is (a basket that can't be checked is no use anyway).
  Future<void> _sessionLost() async {
    if (_staff == null || !mounted) return; // already logged out, or the login itself
    _nav.currentState?.popUntil((route) => route.isFirst);
    setState(() {
      _staff = null;
      _loginNotice = 'Your session ended. Please log in again.';
    });
    await _auth.logout();
  }

  Future<void> _restore() async {
    final last = await _auth.location();
    final saved = await _auth.restore();
    if (!mounted) return;
    setState(() {
      _lastStore = last;
      if (saved != null) {
        _staff = Staff(saved.staffName);
        _location = last; // still logged in: the same store as before (null = pick one)
      }
      _restoring = false;
    });
  }

  Future<void> _logout() async {
    await _auth.logout();
    setState(() {
      _staff = null;
      _location = null;
    });
  }

  Future<void> _pickStore(Store store) async {
    await _auth.setLocation(store);
    if (!mounted) return;
    setState(() {
      _location = store;
      _lastStore = store;
    });
  }

  /// Settings → Change store: back to the store picker, still logged in.
  void _changeStore() {
    _nav.currentState?.popUntil((route) => route.isFirst);
    setState(() => _location = null);
  }

  @override
  Widget build(BuildContext context) {
    final staff = _staff;
    final location = _location;
    return MaterialApp(
      title: 'Altai POS',
      debugShowCheckedModeBanner: false,
      navigatorKey: _nav,
      // Altai design system, light and dark (follows the tablet's setting).
      theme: altaiTheme(Brightness.light),
      darkTheme: altaiTheme(Brightness.dark),
      builder: aboveSystemBars,
      home: _restoring
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : staff == null
              ? LoginScreen(
                  auth: _auth,
                  notice: _loginNotice,
                  onLoggedIn: (s) => setState(() {
                        _staff = s;
                        _location = null; // pick the store next
                        _loginNotice = null;
                      }))
              : location == null
              ? StoreScreen(
                  loadStores: _auth.stores,
                  staffName: staff.name,
                  lastStore: _lastStore,
                  onPicked: _pickStore,
                  onLogout: _logout,
                )
              : HomeScreen(
                  key: ValueKey(location.id), // a new store starts a fresh start page
                  api: _checkout,
                  storeId: location.id,
                  storeName: location.name,
                  staffName: staff.name,
                  catalog: _catalog,
                  returns: _returns,
                  orders: _orders,
                  storeTags: _tagsFor(location.id),
                  onLogout: _logout,
                  onChangeStore: _changeStore),
    );
  }
}
