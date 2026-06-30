import 'dart:math' as math;

import 'package:decimal/decimal.dart';

/// A Pyth price with its confidence interval. `price`/`conf` are fixed-point
/// integers (as strings); the real value is the integer times 10^[expo].
class Price {
  final String conf;
  final int expo;
  final String price;
  final int publishTime;

  const Price({
    required this.conf,
    required this.expo,
    required this.price,
    required this.publishTime,
  });

  factory Price.fromJson(Map<String, dynamic> json) => Price(
    conf: json['conf'].toString(),
    expo: (json['expo'] as num).toInt(),
    price: json['price'].toString(),
    publishTime: (json['publish_time'] as num).toInt(),
  );

  /// Full-precision price. Prefer this over [getPriceAsNumberUnchecked]: a
  /// 64-bit price can exceed double's 52-bit mantissa.
  Decimal get priceAsDecimal =>
      Decimal.parse(price) * Decimal.fromInt(10).pow(expo).toDecimal();

  Decimal get confAsDecimal =>
      Decimal.parse(conf) * Decimal.fromInt(10).pow(expo).toDecimal();

  double getPriceAsNumberUnchecked() =>
      double.parse(price) * math.pow(10, expo);

  double getConfAsNumberUnchecked() => double.parse(conf) * math.pow(10, expo);
}

/// A price feed: current [price] plus its EMA, keyed by [id] (hex, no `0x`).
class PriceFeed {
  final String id;
  final Price price;
  final Price emaPrice;

  const PriceFeed({
    required this.id,
    required this.price,
    required this.emaPrice,
  });

  factory PriceFeed.fromJson(Map<String, dynamic> json) => PriceFeed(
    id: json['id'].toString(),
    price: Price.fromJson((json['price'] as Map).cast<String, dynamic>()),
    emaPrice: Price.fromJson(
      (json['ema_price'] as Map).cast<String, dynamic>(),
    ),
  );

  Price getPriceUnchecked() => price;
  Price getEmaPriceUnchecked() => emaPrice;
}
