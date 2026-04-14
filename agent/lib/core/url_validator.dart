/// URL Validator — SSRF protection for outbound HTTP requests.
///
/// SEC-001: Prevents Server-Side Request Forgery by validating URLs
/// against internal/reserved IP ranges after DNS resolution.
///
/// Usage:
///   final error = await UrlValidator.validate(uri);
///   if (error != null) return 'Error: $error';
///   // ... proceed with HTTP request

import 'dart:io';

class UrlValidator {
  /// Blocked hostnames (case-insensitive check).
  static const _blockedHosts = [
    'localhost',
    'host.docker.internal',
    'kubernetes.default',
    'metadata.google.internal',
  ];

  /// Blocked hostname suffixes.
  static const _blockedSuffixes = [
    '.internal',
    '.local',
    '.localhost',
  ];

  /// Validate a URI for SSRF safety. Returns null if safe, or an error
  /// message if the URL targets a blocked network.
  ///
  /// Resolves DNS first to defeat DNS rebinding attacks.
  static Future<String?> validate(Uri uri) async {
    final host = uri.host.toLowerCase();

    // 1. Check blocked hostnames
    if (_blockedHosts.contains(host)) {
      return 'blocked host: $host';
    }
    for (final suffix in _blockedSuffixes) {
      if (host.endsWith(suffix)) {
        return 'blocked host: $host';
      }
    }

    // 2. Resolve DNS and check all returned IPs
    List<InternetAddress> addresses;
    try {
      addresses = await InternetAddress.lookup(host);
    } catch (_) {
      return 'DNS resolution failed for $host';
    }

    if (addresses.isEmpty) {
      return 'DNS resolution returned no addresses for $host';
    }

    for (final addr in addresses) {
      final reason = _checkAddress(addr);
      if (reason != null) return reason;
    }

    return null; // safe
  }

  /// Check a single resolved IP address against blocked ranges.
  static String? _checkAddress(InternetAddress addr) {
    final ip = addr.address;

    // IPv6 loopback
    if (ip == '::1') return 'blocked: IPv6 loopback';

    // IPv4
    final parts = ip.split('.');
    if (parts.length == 4) {
      final octets = parts.map(int.tryParse).toList();
      if (octets.any((o) => o == null)) return null; // not IPv4, let it pass

      final a = octets[0]!;
      final b = octets[1]!;

      // Loopback: 127.0.0.0/8
      if (a == 127) return 'blocked: loopback ($ip)';

      // RFC 1918 private ranges
      if (a == 10) return 'blocked: private network ($ip)';
      if (a == 172 && b >= 16 && b <= 31) {
        return 'blocked: private network ($ip)';
      }
      if (a == 192 && b == 168) return 'blocked: private network ($ip)';

      // Link-local: 169.254.0.0/16 (includes cloud metadata 169.254.169.254)
      if (a == 169 && b == 254) return 'blocked: link-local ($ip)';

      // Current network: 0.0.0.0/8
      if (a == 0) return 'blocked: current network ($ip)';

      // Shared address space: 100.64.0.0/10
      if (a == 100 && b >= 64 && b <= 127) {
        return 'blocked: shared address space ($ip)';
      }
    }

    // IPv6 private/link-local prefixes
    final ipLower = ip.toLowerCase();
    if (ipLower.startsWith('fc') || ipLower.startsWith('fd')) {
      return 'blocked: IPv6 unique local ($ip)';
    }
    if (ipLower.startsWith('fe80')) {
      return 'blocked: IPv6 link-local ($ip)';
    }

    return null; // safe
  }
}
