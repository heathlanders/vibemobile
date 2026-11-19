import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/pairing/domain/pairing_url.dart';

// Proposal 71 S4: the token is sent at pairing, so only https (plus local http in debug).
void main() {
  test('https is accepted', () {
    expect(pairingUrlError('https://box.tailnet.ts.net', debug: false), isNull);
    expect(pairingUrlError('https://box.tailnet.ts.net:8443/', debug: false), isNull);
  });

  test('http is refused in release, even for localhost', () {
    expect(pairingUrlError('http://box.tailnet.ts.net', debug: false), isNotNull);
    expect(pairingUrlError('http://box:8088', debug: false), isNotNull);
    expect(pairingUrlError('http://127.0.0.1:8787', debug: false), isNotNull);
  });

  test('debug builds may use http on this machine only', () {
    expect(pairingUrlError('http://127.0.0.1:8787', debug: true), isNull);
    expect(pairingUrlError('http://localhost:8787', debug: true), isNull);
    expect(pairingUrlError('http://box.tailnet.ts.net', debug: true), isNotNull);
  });

  test('garbage and other schemes are refused', () {
    for (final u in ['box.tailnet.ts.net', 'ftp://box', 'https://', 'javascript:alert(1)']) {
      expect(pairingUrlError(u, debug: false), isNotNull, reason: u);
    }
  });
}
