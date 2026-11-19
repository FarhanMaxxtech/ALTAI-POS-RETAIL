import '../../../core/api_client.dart';
import '../domain/staff.dart';
import 'session_store.dart';

class AuthApi {
  AuthApi(this._api, this._session) {
    _api.onSessionExpired = _loginAgain;
  }

  final ApiClient _api;
  final SessionStore _session;

  // So an expired session can be renewed without interrupting the cashier. Also saved (encrypted)
  // with the session, so after the app restarts it can still log in again by itself.
  String? _loginId;
  String? _password;

  /// Merchant/Login. Keeps the session on the API client and saves it on the tablet. The store is
  /// picked next, from [stores]: only the stores this account can use are offered, so nobody sells
  /// in a store they don't belong to.
  ///
  /// [remember]: keep the login ID and password to fill in on the login screen next time (also after
  /// log out); without it, any remembered login is forgotten.
  Future<Staff> login(String loginId, String password, {bool remember = false}) async {
    final res = await _api.login({'loginId': loginId, 'password': password});
    _loginId = loginId;
    _password = password;
    await _use(res, fallbackName: loginId, loginId: loginId, password: password);
    try {
      remember ? await _session.remember(loginId, password) : await _session.forgetRemembered();
    } catch (_) {
      // Not being able to remember it doesn't stop the login.
    }
    ApiClient.sessionLog('login: got and saved ${ApiClient.tail(res.session)}');
    return Staff(res.name.isEmpty ? loginId : res.name);
  }

  Future<void> _use(LoginResult res, {required String fallbackName, String? loginId, String? password}) async {
    _api.session = res.session;
    _api.merchantId = res.merchantId;
    await _session.saveLogin(res.session, res.merchantId, res.name.isEmpty ? fallbackName : res.name,
        loginId: loginId, password: password);
  }

  Future<bool> _loginAgain() async {
    final id = _loginId;
    final pw = _password;
    if (id == null || pw == null) {
      ApiClient.sessionLog('can\'t log in again by itself: no saved login');
      return false;
    }
    try {
      final res = await _api.login({'loginId': id, 'password': pw});
      await _use(res, fallbackName: id);
      ApiClient.sessionLog('logged in again by itself: got and saved ${ApiClient.tail(res.session)}');
      return true;
    } on ApiException catch (e) {
      ApiClient.sessionLog('logging in again failed: ${e.message}');
      return false;
    }
  }

  /// The login ticked "Remember me" last, to fill in on the login screen; null when there's none.
  Future<({String loginId, String password})?> remembered() async {
    try {
      return await _session.remembered();
    } catch (_) {
      return null; // storage not there (tests) or unreadable: just an empty form
    }
  }

  /// Forgets the login, in memory and on the tablet. The last store is kept, to offer it first.
  Future<void> logout() async {
    ApiClient.sessionLog('logout: saved session cleared');
    _api.session = null;
    _api.merchantId = null;
    _loginId = null;
    _password = null;
    await _session.clear();
  }

  /// The store picked last on this tablet, or null. After a restart the tablet goes straight back
  /// to it; after a new login it's offered first.
  Future<Store?> location() => _session.loadLocation();

  Future<void> setLocation(Store store) => _session.saveLocation(store);

  /// When the app opens: is there a saved login, and is it still valid?
  /// Returns null when staff have to log in again.
  Future<SavedSession?> restore() async {
    final saved = await _session.load();
    ApiClient.sessionLog('app opened: saved session ${ApiClient.tail(saved?.session)}');
    if (saved == null) return null;

    _api.session = saved.session;
    _api.merchantId = saved.merchantId;
    // The saved login lets the first call below log in again by itself if the session has ended.
    _loginId = saved.loginId;
    _password = saved.password;
    try {
      await stores(); // any call will do: it fails with 440 when the session has expired
      ApiClient.sessionLog('app opened: saved session still valid');
      return saved;
    } on ApiException catch (e) {
      ApiClient.sessionLog('app opened: StoreList answered ${e.status} (${e.message})');
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
