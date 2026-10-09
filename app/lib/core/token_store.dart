import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Daemon base URL + device bearer token, persisted in the platform keystore.
/// The token is the long-lived credential minted by `POST /pair` (vibe-daemon
/// auth.ts); it never leaves secure storage except as an `Authorization` header.
class Creds {
  const Creds(this.baseUrl, this.token);
  final String baseUrl; // e.g. https://<machine>.<tailnet>.ts.net
  final String token;
}

class TokenStore {
  const TokenStore();

  static const _storage = FlutterSecureStorage();
  static const _kBase = 'vibe_base_url';
  static const _kToken = 'vibe_device_token';

  Future<Creds?> read() async {
    final base = await _storage.read(key: _kBase);
    final token = await _storage.read(key: _kToken);
    if (base == null || token == null) return null;
    return Creds(base, token);
  }

  Future<void> save(String baseUrl, String token) async {
    await _storage.write(key: _kBase, value: baseUrl);
    await _storage.write(key: _kToken, value: token);
  }

  Future<void> clear() async {
    await _storage.delete(key: _kBase);
    await _storage.delete(key: _kToken);
  }
}
