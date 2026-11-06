import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/staff.dart';

/// What was saved on the tablet from the last time someone logged in.
class SavedSession {
  const SavedSession({
    required this.session,
    required this.merchantId,
    required this.staffName,
  });

  /// The team API's SESSION token.
  final String session;
  final String merchantId;
  final String staffName;
}

/// Keeps the login and the tablet's location on the tablet.
///
/// The session works like a password, so it goes in secure storage (encrypted by Android),
/// not in plain storage. The password itself is never saved.
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
  static const _locationId = 'locationStoreId';
  static const _locationName = 'locationStoreName';

  /// After a successful login.
  Future<void> saveLogin(String session, String merchantId, String staffName) async {
    await _storage.write(key: _session, value: session);
    await _storage.write(key: _merchantId, value: merchantId);
    await _storage.write(key: _staffName, value: staffName);
  }

  /// When the app opens. Returns null if nobody is logged in.
  Future<SavedSession?> load() async {
    final session = await _storage.read(key: _session);
    final merchantId = await _storage.read(key: _merchantId);
    final staffName = await _storage.read(key: _staffName);
    if (session == null || merchantId == null || staffName == null) return null;
    return SavedSession(session: session, merchantId: merchantId, staffName: staffName);
  }

  /// On log out, or when the saved session has expired. The location stays.
  Future<void> clear() async {
    await _storage.delete(key: _session);
    await _storage.delete(key: _merchantId);
    await _storage.delete(key: _staffName);
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
