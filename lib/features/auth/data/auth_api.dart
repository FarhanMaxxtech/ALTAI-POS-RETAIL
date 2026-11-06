import '../../../core/api_client.dart';
import '../domain/staff.dart';
import 'session_store.dart';

class AuthApi {
  AuthApi(this._api, this._session) {
    _api.onSessionExpired = _loginAgain;
  }

  final ApiClient _api;
  final SessionStore _session;

  // Kept in memory only (never saved), so an expired session can be renewed without
  // interrupting the cashier. After the app restarts, staff log in again when it expires.
  String? _loginId;
  String? _password;

  /// Merchant/Login at this tablet's [location]. Keeps the session on the API client and saves it
  /// on the tablet. Refused when the account can't see that store, so nobody sells in a store
  /// they don't belong to.
  Future<Staff> login(String loginId, String password, {required Store location}) async {
    final res = await _api.login({'loginId': loginId, 'password': password});
    _api.session = res.session;
    _api.merchantId = res.merchantId;
    try {
      final allowed = await stores();
      if (!allowed.any((s) => s.id == location.id)) {
        throw ApiException('This account can\'t use ${location.name}. Ask your manager.', refused: true);
      }
    } catch (_) {
      _api.session = null;
      _api.merchantId = null;
      rethrow;
    }
    _loginId = loginId;
    _password = password;
    await _use(res, fallbackName: loginId);
    return Staff(res.name.isEmpty ? loginId : res.name);
  }

  Future<void> _use(LoginResult res, {required String fallbackName}) async {
    _api.session = res.session;
    _api.merchantId = res.merchantId;
    await _session.saveLogin(res.session, res.merchantId, res.name.isEmpty ? fallbackName : res.name);
  }

  Future<bool> _loginAgain() async {
    final id = _loginId;
    final pw = _password;
    if (id == null || pw == null) return false;
    try {
      await _use(await _api.login({'loginId': id, 'password': pw}), fallbackName: id);
      return true;
    } on ApiException {
      return false;
    }
  }

  /// Forgets the login, in memory and on the tablet. The location stays.
  Future<void> logout() async {
    _api.session = null;
    _api.merchantId = null;
    _loginId = null;
    _password = null;
    await _session.clear();
  }

  /// The store this tablet is set to, or null before it's set.
  Future<Store?> location() => _session.loadLocation();

  Future<void> setLocation(Store store) => _session.saveLocation(store);

  /// The stores a manager's account can see, for setting the location from the login screen.
  /// Logs that account in only for this one call: nobody stays logged in.
  Future<List<Store>> storesFor(String loginId, String password) async {
    final res = await _api.login({'loginId': loginId, 'password': password});
    final session = _api.session;
    final merchantId = _api.merchantId;
    _api.session = res.session;
    _api.merchantId = res.merchantId;
    try {
      return await stores();
    } finally {
      _api.session = session;
      _api.merchantId = merchantId;
    }
  }

  /// When the app opens: is there a saved login, and is it still valid?
  /// Returns null when staff have to log in again.
  Future<SavedSession?> restore() async {
    final saved = await _session.load();
    if (saved == null) return null;

    _api.session = saved.session;
    _api.merchantId = saved.merchantId;
    try {
      await stores(); // any call will do: it fails with 440 when the session has expired
      return saved;
    } on ApiException catch (e) {
      if (e.sessionExpired) {
        await logout();
        return null;
      }
      return saved; // no Wi-Fi or another problem: keep the login, the next request shows the error
    }
  }

  /// Stock/StoreList: the stores this login can see.
  Future<List<Store>> stores() async {
    final res = await _api.get('Stock/StoreList');
    return (res['data'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .map((s) => Store(
              id: (s['id'] ?? s['storeId']).toString(),
              name: (s['name'] ?? s['storeName'] ?? '').toString(),
            ))
        .toList();
  }
}
