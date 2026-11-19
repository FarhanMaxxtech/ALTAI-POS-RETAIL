import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/staff.dart';

/// What was saved on the tablet from the last time someone logged in.
class SavedSession {
  const SavedSession({
    required this.session,
    required this.merchantId,
    required this.staffName,
    this.loginId,
    this.password,
  });

  /// The team API's SESSION token.
  final String session;
  final String merchantId;
  final String staffName;

  /// What staff typed at login, so the app can log in again by itself after a restart (Altai
  /// sessions end after a minute or two of no use). Null for a login saved before this was kept.
  final String? loginId;
  final String? password;
}

/// Keeps the login and the tablet's location on the tablet.
///
/// The session and the login (ID + password) go in secure storage, encrypted by Android with a
/// key only this app can use, never in plain storage. The password is kept so the tablet stays
/// logged in when the app is closed: Altai ends a session after a minute or two of no use, and
/// the app logs in again by itself. Log out forgets all of it.
///
/// The location is set once per tablet (from the login screen) and stays when staff log out.
class SessionStore {
  SessionStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  // The names the values are saved under.
  static const _session = 'session';
  static const _merchantId = 'merchantId';
  static const _staffName = 'staffName';
  static const _loginId = 'loginId';
  static const _password = 'password';
  static const _locationId = 'locationStoreId';
  static const _locationName = 'locationStoreName';
  static const _rememberLoginId = 'rememberLoginId';
  static const _rememberPassword = 'rememberPassword';

  /// After a successful login (and each time the app logs in again by itself).
  Future<void> saveLogin(String session, String merchantId, String staffName,
      {String? loginId, String? password}) async {
    await _storage.write(key: _session, value: session);
    await _storage.write(key: _merchantId, value: merchantId);
    await _storage.write(key: _staffName, value: staffName);
    if (loginId != null && password != null) {
      await _storage.write(key: _loginId, value: loginId);
      await _storage.write(key: _password, value: password);
    }
  }

  /// When the app opens. Returns null if nobody is logged in.
  Future<SavedSession?> load() async {
    final session = await _storage.read(key: _session);
    final merchantId = await _storage.read(key: _merchantId);
    final staffName = await _storage.read(key: _staffName);
    if (session == null || merchantId == null || staffName == null) return null;
    return SavedSession(
      session: session,
      merchantId: merchantId,
      staffName: staffName,
      loginId: await _storage.read(key: _loginId),
      password: await _storage.read(key: _password),
    );
  }

  /// On log out, or when the saved session has expired. The location stays.
  Future<void> clear() async {
    await _storage.delete(key: _session);
    await _storage.delete(key: _merchantId);
    await _storage.delete(key: _staffName);
    await _storage.delete(key: _loginId);
    await _storage.delete(key: _password);
  }

  /// "Remember me" on the login screen: the login ID and password to fill in next time. Kept
  /// apart from the session, so they stay after log out (until someone logs in without ticking it).
  Future<({String loginId, String password})?> remembered() async {
    final id = await _storage.read(key: _rememberLoginId);
    final pw = await _storage.read(key: _rememberPassword);
    return id == null || pw == null ? null : (loginId: id, password: pw);
  }

  Future<void> remember(String loginId, String password) async {
    await _storage.write(key: _rememberLoginId, value: loginId);
    await _storage.write(key: _rememberPassword, value: password);
  }

  Future<void> forgetRemembered() async {
    await _storage.delete(key: _rememberLoginId);
    await _storage.delete(key: _rememberPassword);
  }

  /// The store this tablet is in, or null when it hasn't been set yet.
  Future<Store?> loadLocation() async {
    final id = await _storage.read(key: _locationId);
    final name = await _storage.read(key: _locationName);
    return id == null || name == null ? null : Store(id: id, name: name);
  }

  Future<void> saveLocation(Store store) async {
    await _storage.write(key: _locationId, value: store.id);
    await _storage.write(key: _locationName, value: store.name);
  }
}
