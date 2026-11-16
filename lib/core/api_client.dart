import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';

/// Anything that went wrong talking to the team's API.
class ApiException implements Exception {
  ApiException(this.message, {this.status, this.refused = false});

  final String message;

  /// HTTP status, or null when no answer arrived at all (no Wi-Fi, server down, timeout).
  final int? status;

  /// True when the API answered with { error }: it said no, so nothing changed.
  final bool refused;

  /// True when no answer arrived, so we can't know whether the request was processed.
  bool get noAnswer => status == null;

  /// The session ran out and logging in again didn't work: staff must log in.
  bool get sessionExpired => status == 440;

  @override
  String toString() => message;
}

/// What Merchant/Login gave back.
class LoginResult {
  const LoginResult({required this.session, required this.merchantId, required this.name});

  final String session;
  final String merchantId;
  final String name;
}

/// Calls the team's API and returns its JSON answer, or throws [ApiException].
///
/// How their API works (same as the rfid_counter app):
///   - headers: APIKEY always, SESSION + MERCHANTID after login
///   - the session comes back in the `session` response header of Merchant/Login
///   - status 440 = session expired
///   - a 200 answer can still be a refusal: { "error": "..." } or { "error": { "message": "..." } }
class ApiClient {
  ApiClient({http.Client? client, this.baseUrl = teamApiBaseUrl, this.apiKey = teamApiKey})
      : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final String apiKey;

  /// Set after login. Sent with every request.
  String? session;
  String? merchantId;

  /// Called once when the session expires. Returns true if it logged in again.
  Future<bool> Function()? onSessionExpired;

  // Many calls can hit an expired session at the same moment (a scan burst). Only one of them logs
  // in again; the others wait for that same attempt. Two logins at once would cancel each other.
  Future<bool>? _reLogin;

  static const _timeout = Duration(seconds: 25);

  Map<String, String> get _headers => {
        'APIKEY': apiKey,
        'Content-Type': 'application/json',
        'SESSION': ?session,
        'MERCHANTID': ?merchantId,
      };

  Future<Map<String, dynamic>> get(String path, [Map<String, String>? query]) => _call(
      () => _client.get(Uri.parse('$baseUrl/$path').replace(queryParameters: query), headers: _headers));

  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) => _call(
      () => _client.post(Uri.parse('$baseUrl/$path'), headers: _headers, body: jsonEncode(body)));

  /// Merchant/Login. Doesn't change [session]: the caller decides whether to use it.
  Future<LoginResult> login(Map<String, dynamic> body) async {
    final res = await _send(() => _client.post(Uri.parse('$baseUrl/Merchant/Login'),
        headers: {'APIKEY': apiKey, 'Content-Type': 'application/json'}, body: jsonEncode(body)));
    final json = _decode(res);
    final session = res.headers['session'];
    if (session == null || session.isEmpty) {
      throw ApiException('Login answered without a session.', status: res.statusCode);
    }
    return LoginResult(
      session: session,
      merchantId: json['merchantId']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
    );
  }

  Future<Map<String, dynamic>> _call(Future<http.Response> Function() call) async {
    var res = await _send(call);
    if (res.statusCode == 440 && await _tryReLogin()) {
      res = await _send(call); // the closure reads the new session from _headers
    }
    if (res.statusCode == 440) {
      throw ApiException('Session expired. Please log in again.', status: 440);
    }
    return _decode(res);
  }

  Future<bool> _tryReLogin() {
    final relogin = onSessionExpired;
    if (relogin == null) return Future.value(false);
    return _reLogin ??= relogin().catchError((_) => false).whenComplete(() => _reLogin = null);
  }

  Future<http.Response> _send(Future<http.Response> Function() call) async {
    if (apiKey.isEmpty) {
      throw ApiException('The app has no API key. Start it with --dart-define-from-file=altai.json.',
          status: 0);
    }
    try {
      return await call().timeout(_timeout);
    } on TimeoutException {
      throw ApiException('The server took too long to answer.');
    } catch (_) {
      throw ApiException('Could not reach the server. Check the Wi-Fi.');
    }
  }

  Map<String, dynamic> _decode(http.Response res) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException('Server error (${res.statusCode})', status: res.statusCode);
    }
    Object? decoded;
    try {
      decoded = jsonDecode(res.body);
    } on FormatException {
      throw ApiException('The server sent an answer the app cannot read.', status: res.statusCode);
    }
    if (decoded is! Map<String, dynamic>) {
      throw ApiException('The server sent an answer the app cannot read.', status: res.statusCode);
    }
    if (decoded.containsKey('error')) {
      throw ApiException(errorText(decoded['error']), status: res.statusCode, refused: true);
    }
    return decoded;
  }

  /// Their error is sometimes a string, sometimes { message: "..." }.
  static String errorText(Object? error) {
    if (error is String && error.isNotEmpty) return error;
    if (error is Map && error['message'] != null) return error['message'].toString();
    return 'The server refused the request.';
  }

  /// Their pictures come as paths ("/product/x.jpg"). Put the website in front of them.
  String imageUrl(String path) => Uri.parse(baseUrl).resolve(path).toString();
}
