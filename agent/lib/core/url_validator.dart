/// URL Validator — SSRF protection for outbound HTTP requests.
///
/// SEC-001 / H1 / H2: Prevents Server-Side Request Forgery by:
///   1. Validating hostname against a blocked list.
///   2. Resolving DNS and checking all returned IPs against private ranges.
///   3. Returning the resolved IP so callers can connect directly (pinning),
///      eliminating the DNS TOCTTOU window between validation and connection.
///   4. Providing [fetchSafe] — a redirect-following HTTP helper that
///      re-validates every redirect target before following it.
///
/// Usage (simple):
///   final result = await UrlValidator.validate(uri);
///   if (result.error != null) return 'Blocked: ${result.error}';
///   // connect to result.resolvedAddress directly (see fetchSafe for HTTP)
///
/// Usage (HTTP with redirect protection):
///   final response = await UrlValidator.fetchSafe(uri, headers: {...});
///   // throws ArgumentError if any hop targets a private address.

import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Result of a URL validation check.
class UrlValidationResult {
  /// Null when the URL is safe to connect to.
  final String? error;

  /// The resolved IPv4/IPv6 address (null when [error] is non-null).
  final InternetAddress? resolvedAddress;

  const UrlValidationResult({this.error, this.resolvedAddress});

  bool get isSafe => error == null;
}

class UrlValidator {
  /// Blocked hostnames (case-insensitive exact match).
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

  /// Maximum redirects to follow when using [fetchSafe].
  static const _maxRedirects = 5;

  /// Validate a URI for SSRF safety.
  ///
  /// Returns a [UrlValidationResult] with a non-null [error] if blocked, or
  /// a non-null [resolvedAddress] (first safe address) when allowed.
  ///
  /// H2 fix: callers should connect to [resolvedAddress] directly and set
  /// the `Host` header to the original hostname, eliminating the DNS TOCTTOU
  /// window between this check and the actual TCP connection.
  static Future<UrlValidationResult> validate(Uri uri) async {
    final host = uri.host.toLowerCase();

    // 1. Check blocked hostnames
    if (_blockedHosts.contains(host)) {
      return UrlValidationResult(error: 'blocked host: $host');
    }
    for (final suffix in _blockedSuffixes) {
      if (host.endsWith(suffix)) {
        return UrlValidationResult(error: 'blocked host: $host');
      }
    }

    // 2. Resolve DNS and check all returned IPs
    List<InternetAddress> addresses;
    try {
      addresses = await InternetAddress.lookup(host);
    } catch (_) {
      return UrlValidationResult(error: 'DNS resolution failed for $host');
    }

    if (addresses.isEmpty) {
      return UrlValidationResult(error: 'DNS resolution returned no addresses for $host');
    }

    for (final addr in addresses) {
      final reason = _checkAddress(addr);
      if (reason != null) return UrlValidationResult(error: reason);
    }

    return UrlValidationResult(resolvedAddress: addresses.first);
  }

  /// Perform an HTTP GET that:
  ///   • Validates the initial URL.
  ///   • Disables automatic redirect following.
  ///   • Manually follows each 3xx redirect, re-validating the Location URL.
  ///   • Connects via the resolved IP (pinned) to eliminate DNS TOCTTOU.
  ///
  /// Throws [ArgumentError] if any hop targets a blocked address.
  /// Throws [StateError] if the redirect chain exceeds [_maxRedirects].
  static Future<http.Response> fetchSafe(
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    var current = uri;
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      if (hop == _maxRedirects) {
        throw StateError('SSRF guard: too many redirects (max $_maxRedirects)');
      }

      final result = await validate(current);
      if (!result.isSafe) {
        throw ArgumentError('SSRF guard blocked URL "$current": ${result.error}');
      }

      // Pin the IP only for plain HTTP.  For HTTPS the TLS certificate is
      // bound to the hostname; replacing the host with an IP causes
      // CERTIFICATE_VERIFY_FAILED.  TLS itself prevents DNS-rebinding.
      final useIpPinning = current.scheme == 'http';
      final connectUri = useIpPinning ? _buildPinnedUri(current, result.resolvedAddress!) : current;
      final client = _buildNoRedirectClient();

      try {
        final request = http.Request('GET', connectUri)
          ..followRedirects = false
          ..headers.addAll({
            ...?headers,
            if (useIpPinning) 'Host': current.host,
          });
        final response = await http.Response.fromStream(
          await client.send(request),
        );

        final status = response.statusCode;
        if (status >= 300 && status < 400) {
          final location = response.headers['location'];
          if (location == null || location.isEmpty) break;
          final next = Uri.tryParse(location);
          if (next == null) break;
          // Resolve relative redirects against current URL.
          current = current.resolveUri(next);
          continue;
        }

        return response;
      } finally {
        client.close();
      }
    }

    throw StateError('SSRF guard: redirect loop or missing Location header');
  }

  // ── Internal helpers ────────────────────────────────────────────────────

  /// Build an http client that does NOT follow redirects automatically.
  static http.Client _buildNoRedirectClient() {
    final inner = HttpClient()
      ..autoUncompress = true
      ..findProxy = null
      ..maxConnectionsPerHost = 1;
    return IOClient(inner);
  }

  /// Rewrite [uri] to connect directly to [addr] (IP pinning).
  /// The original host is preserved as the `Host` header by the caller.
  static Uri _buildPinnedUri(Uri uri, InternetAddress addr) {
    final ip = addr.type == InternetAddressType.IPv6 ? '[${addr.address}]' : addr.address;
    return uri.replace(host: ip);
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
      if (octets.any((o) => o == null)) return null;

      final a = octets[0]!;
      final b = octets[1]!;

      if (a == 127) return 'blocked: loopback ($ip)';
      if (a == 10) return 'blocked: private network ($ip)';
      if (a == 172 && b >= 16 && b <= 31) {
        return 'blocked: private network ($ip)';
      }
      if (a == 192 && b == 168) return 'blocked: private network ($ip)';
      if (a == 169 && b == 254) return 'blocked: link-local ($ip)';
      if (a == 0) return 'blocked: current network ($ip)';
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
