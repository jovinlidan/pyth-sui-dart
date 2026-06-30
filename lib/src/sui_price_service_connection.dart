import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'price_feed.dart';

/// Options for [SuiPriceServiceConnection].
class PriceServiceConnectionConfig {
  /// Per-request timeout. Defaults to 5s.
  final Duration? timeout;

  /// Times a failed request is retried before throwing. Defaults to 3.
  final int? httpRetries;

  const PriceServiceConnectionConfig({this.timeout, this.httpRetries});
}

/// Reads Pyth prices from a Hermes endpoint (`/v2/updates/price/latest`).
/// [endpoint] is a Hermes base URL, e.g. `https://hermes.pyth.network`.
class SuiPriceServiceConnection {
  final String _baseUrl;
  final Duration _timeout;
  final int _retries;

  SuiPriceServiceConnection(
    String endpoint, {
    PriceServiceConnectionConfig? config,
  }) : _baseUrl = endpoint.endsWith('/')
           ? endpoint.substring(0, endpoint.length - 1)
           : endpoint,
       _timeout = config?.timeout ?? const Duration(seconds: 5),
       _retries = config?.httpRetries ?? 3;

  /// Price update data — a single accumulator message bundling all [priceIds] —
  /// to submit on-chain via the Pyth contract.
  Future<List<Uint8List>> getPriceFeedsUpdateData(List<String> priceIds) async {
    final data = await _latest(priceIds, parsed: false);
    final binary = data['binary'] as Map<String, dynamic>?;
    final entries = (binary?['data'] as List?) ?? const [];
    return entries
        .map((e) => base64.decode(e as String))
        .toList(growable: false);
  }

  /// Latest parsed feeds for [priceIds].
  Future<List<PriceFeed>?> getLatestPriceFeeds(List<String> priceIds) async {
    if (priceIds.isEmpty) return const [];
    final data = await _latest(priceIds, parsed: true);
    final parsed = (data['parsed'] as List?) ?? const [];
    return parsed
        .map((e) => PriceFeed.fromJson((e as Map).cast<String, dynamic>()))
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> _latest(
    List<String> priceIds, {
    required bool parsed,
  }) async {
    final uri = Uri.parse('$_baseUrl/v2/updates/price/latest').replace(
      queryParameters: {
        'ids[]': priceIds.map(_normalizeId).toList(),
        'encoding': 'base64',
        'parsed': parsed.toString(),
      },
    );

    Object? lastError;
    for (var attempt = 0; attempt <= _retries; attempt++) {
      try {
        final resp = await http.get(uri).timeout(_timeout);
        if (resp.statusCode != 200) {
          throw http.ClientException('Hermes ${resp.statusCode}: ${resp.body}');
        }
        return jsonDecode(resp.body) as Map<String, dynamic>;
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError(
      'Hermes request failed after ${_retries + 1} attempts: $lastError',
    );
  }

  static String _normalizeId(String id) =>
      id.startsWith('0x') ? id.substring(2) : id;
}
