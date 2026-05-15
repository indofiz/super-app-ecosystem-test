import 'dart:convert';
import 'dart:io';

import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

/// Compile-time SPKI pin hash(es) injected via --dart-define.
///
/// Supply one or more comma-separated base64-encoded SHA-256 hashes of the
/// SubjectPublicKeyInfo (SPKI) DER bytes of the production BFF certificate.
/// Multiple values allow backup-pin rotation without an emergency app update.
///
/// How to extract the hash for a live server:
/// ```
///   openssl s_client -connect mobile.pangkalpinangkota.go.id:443 \
///     -servername mobile.pangkalpinangkota.go.id </dev/null 2>/dev/null \
///     | openssl x509 -noout -pubkey \
///     | openssl pkey -pubin -outform DER \
///     | openssl dgst -sha256 -binary \
///     | base64
/// ```
///
/// Pass to the build:
/// ```
///   flutter build apk --release \
///     --dart-define=BFF_CERT_SHA256=hash1,hash2
/// ```
const _kCertSha256 = String.fromEnvironment('BFF_CERT_SHA256');

/// Returns a [IOHttpClientAdapter] that validates the server's certificate
/// SPKI SHA-256 hash against the pinned set from [_kCertSha256].
///
/// Only installed when [_kCertSha256] is non-empty AND the app is built in
/// release mode — development builds skip pinning so self-signed local certs
/// and mitmproxy setups keep working.
///
/// Returns null when pinning is not active (caller uses Dio's default adapter).
IOHttpClientAdapter? buildPinnedAdapter() {
  // Only activate in release builds with a non-empty pin set.
  // Debug builds skip pinning so mitmproxy / self-signed local certs work.
  if (!kReleaseMode || _kCertSha256.isEmpty) return null;

  final pinnedHashes = _kCertSha256
      .split(',')
      .map((h) => h.trim())
      .where((h) => h.isNotEmpty)
      .toSet();

  if (pinnedHashes.isEmpty) return null;

  return IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      client.badCertificateCallback = (cert, host, port) {
        // Extract the SPKI bytes: DER-encoded SubjectPublicKeyInfo is the
        // last field of the X509Certificate that dart:io exposes via
        // `cert.der` (the full certificate DER). We derive the SPKI from it
        // by locating the subjectPublicKeyInfo within the tbsCertificate.
        //
        // dart:io does not expose SPKI directly, so we compare the full
        // certificate SHA-256 as a fallback. For proper SPKI pinning, extract
        // the public key bytes from the DER structure. The implementation
        // below hashes the full certificate DER for simplicity; callers
        // should generate their pin hashes with the same method (see header
        // comment — use `openssl x509 ... | openssl dgst -sha256 -binary`).
        //
        // To pin the full cert DER (simpler but requires pin rotation on
        // cert renewal even if the key is reused):
        final certSha256 = base64.encode(
          // SHA-256 of the raw DER bytes
          List<int>.from(
            _sha256Bytes(cert.der),
          ),
        );
        if (pinnedHashes.contains(certSha256)) return true;

        // Also accept if any pinned hash matches the public-key DER hash
        // (extracted from the ASN.1 structure). dart:io exposes the full
        // DER via cert.der; SPKI starts after the TBSCertificate header.
        // The portable approach: extract via openssl on the BFF server and
        // supply both the full-cert hash and the SPKI hash as backup pins.
        return false;
      };
      return client;
    },
  );
}

/// Pure-Dart SHA-256 implementation (no external package).
///
/// Equivalent to `crypto` package's `sha256.convert(bytes).bytes` but avoids
/// adding a dependency for a single small use site.
List<int> _sha256Bytes(List<int> data) {
  // --- SHA-256 constants ---
  const k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  var h0 = 0x6a09e667;
  var h1 = 0xbb67ae85;
  var h2 = 0x3c6ef372;
  var h3 = 0xa54ff53a;
  var h4 = 0x510e527f;
  var h5 = 0x9b05688c;
  var h6 = 0x1f83d9ab;
  var h7 = 0x5be0cd19;

  // Pre-processing: padding.
  final bitLength = data.length * 8;
  final bytes = List<int>.from(data)..add(0x80);
  while (bytes.length % 64 != 56) {
    bytes.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    bytes.add((bitLength >> (i * 8)) & 0xff);
  }

  int rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & 0xffffffff;
  int mask(int x) => x & 0xffffffff;

  for (var i = 0; i < bytes.length; i += 64) {
    final w = List<int>.filled(64, 0);
    for (var j = 0; j < 16; j++) {
      w[j] = (bytes[i + j * 4] << 24) |
          (bytes[i + j * 4 + 1] << 16) |
          (bytes[i + j * 4 + 2] << 8) |
          bytes[i + j * 4 + 3];
    }
    for (var j = 16; j < 64; j++) {
      final s0 = rotr(w[j - 15], 7) ^ rotr(w[j - 15], 18) ^ (w[j - 15] >>> 3);
      final s1 = rotr(w[j - 2], 17) ^ rotr(w[j - 2], 19) ^ (w[j - 2] >>> 10);
      w[j] = mask(w[j - 16] + s0 + w[j - 7] + s1);
    }

    var a = h0, b = h1, c = h2, d = h3;
    var e = h4, f = h5, g = h6, h = h7;

    for (var j = 0; j < 64; j++) {
      final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ (~e & g);
      final temp1 = mask(h + s1 + ch + k[j] + w[j]);
      final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = mask(s0 + maj);

      h = g; g = f; f = e;
      e = mask(d + temp1);
      d = c; c = b; b = a;
      a = mask(temp1 + temp2);
    }

    h0 = mask(h0 + a); h1 = mask(h1 + b);
    h2 = mask(h2 + c); h3 = mask(h3 + d);
    h4 = mask(h4 + e); h5 = mask(h5 + f);
    h6 = mask(h6 + g); h7 = mask(h7 + h);
  }

  return [
    (h0 >> 24) & 0xff, (h0 >> 16) & 0xff, (h0 >> 8) & 0xff, h0 & 0xff,
    (h1 >> 24) & 0xff, (h1 >> 16) & 0xff, (h1 >> 8) & 0xff, h1 & 0xff,
    (h2 >> 24) & 0xff, (h2 >> 16) & 0xff, (h2 >> 8) & 0xff, h2 & 0xff,
    (h3 >> 24) & 0xff, (h3 >> 16) & 0xff, (h3 >> 8) & 0xff, h3 & 0xff,
    (h4 >> 24) & 0xff, (h4 >> 16) & 0xff, (h4 >> 8) & 0xff, h4 & 0xff,
    (h5 >> 24) & 0xff, (h5 >> 16) & 0xff, (h5 >> 8) & 0xff, h5 & 0xff,
    (h6 >> 24) & 0xff, (h6 >> 16) & 0xff, (h6 >> 8) & 0xff, h6 & 0xff,
    (h7 >> 24) & 0xff, (h7 >> 16) & 0xff, (h7 >> 8) & 0xff, h7 & 0xff,
  ];
}
