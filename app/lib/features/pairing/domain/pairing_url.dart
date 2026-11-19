import 'package:flutter/foundation.dart';

/// Why [url] can't be used to pair, or null if it can (proposal 71 S4). Pairing sends the
/// code and receives the device token, so only `https://` is accepted; debug builds may
/// also use `http://` to this machine (localhost / 127.0.0.1) for development.
String? pairingUrlError(String url, {bool debug = kDebugMode}) {
  final u = Uri.tryParse(url.trim());
  if (u == null || u.host.isEmpty || !(u.scheme == 'https' || u.scheme == 'http')) {
    return 'Enter the full address, starting with https://';
  }
  if (u.scheme == 'https') return null;
  if (debug && (u.host == 'localhost' || u.host == '127.0.0.1')) return null;
  return 'Use the https:// address: pairing sends your device token.';
}
