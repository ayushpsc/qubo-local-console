import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const firebaseProjectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
const firebaseWebApiKey = String.fromEnvironment('FIREBASE_WEB_API_KEY');

bool get firebaseLiveAuthConfigured =>
    firebaseProjectId.isNotEmpty && firebaseWebApiKey.isNotEmpty;

class FirebaseLiveUser {
  final String uid;
  final String email;

  const FirebaseLiveUser({required this.uid, required this.email});
}

class LiveAuthException implements Exception {
  final String message;
  const LiveAuthException(this.message);

  @override
  String toString() => message;
}

abstract class LiveAuthController extends ChangeNotifier {
  FirebaseLiveUser? get user;
  bool get restoring;
  Future<void> restore();
  Future<void> signIn(String email, String password);
  Future<String> idToken();
  Future<void> signOut();
}

class FirebaseLiveAuth extends LiveAuthController {
  static const _refreshKey = 'firebase_live_refresh_token';
  static const _emailKey = 'firebase_live_email';

  final http.Client client;
  final SharedPreferencesAsync preferences;
  final bool _ownsClient;
  FirebaseLiveUser? _user;
  String? _idToken;
  String? _refreshToken;
  DateTime? _expiresAt;
  Future<String>? _refreshing;
  bool _restoring = true;

  FirebaseLiveAuth({http.Client? client, SharedPreferencesAsync? preferences})
    : client = client ?? http.Client(),
      preferences = preferences ?? SharedPreferencesAsync(),
      _ownsClient = client == null;

  @override
  FirebaseLiveUser? get user => _user;

  @override
  bool get restoring => _restoring;

  @override
  Future<void> restore() async {
    try {
      final refresh = await preferences.getString(_refreshKey);
      if (refresh == null || refresh.isEmpty) return;
      _refreshToken = refresh;
      await _refresh();
    } catch (_) {
      await _clear();
    } finally {
      _restoring = false;
      notifyListeners();
    }
  }

  @override
  Future<void> signIn(String email, String password) async {
    _requireConfiguration();
    final normalized = email.trim().toLowerCase();
    if (normalized.isEmpty || password.isEmpty) {
      throw const LiveAuthException('Enter your email and password.');
    }
    final response = await client
        .post(
          Uri.parse(
            'https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=$firebaseWebApiKey',
          ),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'email': normalized,
            'password': password,
            'returnSecureToken': true,
          }),
        )
        .timeout(const Duration(seconds: 25));
    final data = _json(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LiveAuthException(_friendlyError(_errorCode(data)));
    }
    await _accept(
      idToken: data['idToken']?.toString() ?? '',
      refreshToken: data['refreshToken']?.toString() ?? '',
      uid: data['localId']?.toString() ?? '',
      email: data['email']?.toString() ?? normalized,
      expiresIn: data['expiresIn'],
    );
    notifyListeners();
  }

  @override
  Future<String> idToken() async {
    final token = _idToken;
    final expiry = _expiresAt;
    if (token != null &&
        expiry != null &&
        DateTime.now().isBefore(expiry.subtract(const Duration(minutes: 5)))) {
      return token;
    }
    if (_refreshToken == null) {
      throw const LiveAuthException(
        'Sign in with Firebase to view the camera.',
      );
    }
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<String> _refresh() async {
    _requireConfiguration();
    final refresh = _refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw const LiveAuthException('Your Firebase session has ended.');
    }
    final response = await client
        .post(
          Uri.parse(
            'https://securetoken.googleapis.com/v1/token?key=$firebaseWebApiKey',
          ),
          headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {'grant_type': 'refresh_token', 'refresh_token': refresh},
        )
        .timeout(const Duration(seconds: 25));
    final data = _json(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await _clear();
      notifyListeners();
      throw LiveAuthException(_friendlyError(_errorCode(data)));
    }
    final email = await preferences.getString(_emailKey) ?? _user?.email ?? '';
    await _accept(
      idToken: data['id_token']?.toString() ?? '',
      refreshToken: data['refresh_token']?.toString() ?? refresh,
      uid: data['user_id']?.toString() ?? '',
      email: email,
      expiresIn: data['expires_in'],
    );
    notifyListeners();
    return _idToken!;
  }

  Future<void> _accept({
    required String idToken,
    required String refreshToken,
    required String uid,
    required String email,
    required dynamic expiresIn,
  }) async {
    final seconds = int.tryParse('$expiresIn') ?? 3600;
    if (idToken.isEmpty || refreshToken.isEmpty || uid.isEmpty) {
      throw const LiveAuthException(
        'Firebase returned an incomplete authentication response.',
      );
    }
    _idToken = idToken;
    _refreshToken = refreshToken;
    _expiresAt = DateTime.now().add(Duration(seconds: seconds));
    _user = FirebaseLiveUser(uid: uid, email: email);
    await preferences.setString(_refreshKey, refreshToken);
    await preferences.setString(_emailKey, email);
  }

  @override
  Future<void> signOut() async {
    await _clear();
    notifyListeners();
  }

  Future<void> _clear() async {
    _user = null;
    _idToken = null;
    _refreshToken = null;
    _expiresAt = null;
    await preferences.remove(_refreshKey);
    await preferences.remove(_emailKey);
  }

  static Map<String, dynamic> _json(String body) {
    try {
      return Map<String, dynamic>.from(jsonDecode(body) as Map);
    } catch (_) {
      return const {};
    }
  }

  static String _errorCode(Map<String, dynamic> data) {
    final error = data['error'];
    return error is Map ? '${error['message'] ?? ''}' : '';
  }

  static String _friendlyError(String code) => switch (code) {
    'INVALID_LOGIN_CREDENTIALS' ||
    'EMAIL_NOT_FOUND' ||
    'INVALID_PASSWORD' => 'The email or password is incorrect.',
    'USER_DISABLED' => 'This Firebase account has been disabled.',
    'TOO_MANY_ATTEMPTS_TRY_LATER' =>
      'Too many sign-in attempts. Wait a while and try again.',
    'OPERATION_NOT_ALLOWED' =>
      'Firebase email/password sign-in is not enabled.',
    'TOKEN_EXPIRED' ||
    'INVALID_REFRESH_TOKEN' ||
    'USER_NOT_FOUND' => 'Your Firebase session ended. Sign in again.',
    _ => 'Firebase sign-in failed${code.isEmpty ? '.' : ' ($code).'}',
  };

  static void _requireConfiguration() {
    if (!firebaseLiveAuthConfigured) {
      throw const LiveAuthException(
        'Firebase live view is not configured. Build with '
        'FIREBASE_PROJECT_ID and FIREBASE_WEB_API_KEY.',
      );
    }
  }

  @override
  void dispose() {
    if (_ownsClient) client.close();
    super.dispose();
  }
}

class BypassLiveAuth extends LiveAuthController {
  static const _userValue = FirebaseLiveUser(
    uid: 'test-user',
    email: 'viewer@example.test',
  );

  @override
  FirebaseLiveUser? get user => _userValue;

  @override
  bool get restoring => false;

  @override
  Future<String> idToken() async => 'test-firebase-id-token';

  @override
  Future<void> restore() async {}

  @override
  Future<void> signIn(String email, String password) async {}

  @override
  Future<void> signOut() async {}
}
