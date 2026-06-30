import 'package:pyth_sui_dart/pyth_sui_dart.dart';
import 'package:sui_dart/grpc/client.dart';
import 'package:test/test.dart';

void main() {
  group('Integration: SuiPriceServiceConnection (Hermes, mainnet)', () {
    late SuiPriceServiceConnection conn;

    // Well-known mainnet feeds.
    const suiUsd =
        '0x23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744';
    const usdcUsd =
        '0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a';

    setUp(() {
      conn = SuiPriceServiceConnection('https://hermes.pyth.network');
    });

    test(
      'getPriceFeedsUpdateData bundles feeds into one accumulator message',
      () async {
        final updates = await conn.getPriceFeedsUpdateData([suiUsd, usdcUsd]);
        // Hermes returns a single accumulator update bundling every feed.
        expect(updates, hasLength(1));
        // PNAU magic header (0x504e4155).
        expect(updates.first.sublist(0, 4), [0x50, 0x4e, 0x41, 0x55]);

        // The embedded Wormhole VAA must parse — this is the byte format the
        // on-chain update path consumes. (extract is pure; no RPC.)
        final pyth = SuiPythClient(
          client: SuiGrpcClient(
            SuiGrpcClientOptions(baseUrl: 'fullnode.mainnet.sui.io', port: 443),
          ),
          pythStateId: '0x0',
          wormholeStateId: '0x0',
        );
        final vaa = pyth.extractVaaBytesFromAccumulatorMessage(updates.first);
        expect(vaa.lengthInBytes, greaterThan(0));
      },
    );

    test('getLatestPriceFeeds returns prices at full precision', () async {
      final feeds = await conn.getLatestPriceFeeds([suiUsd]);
      expect(feeds, isNotNull);
      expect(feeds!, hasLength(1));
      final feed = feeds.first;
      // Hermes returns ids without the `0x` prefix.
      expect(suiUsd.toLowerCase(), contains(feed.id.toLowerCase()));
      final price = feed.getPriceUnchecked().priceAsDecimal.toDouble();
      expect(price, greaterThan(0));
    });

    test('getLatestPriceFeeds returns [] for no ids', () async {
      expect(await conn.getLatestPriceFeeds([]), isEmpty);
    });
  });

  // gRPC read-only smoke test against Sui mainnet. Exercises every
  // dynamic-field path the client uses to build a Pyth price-update PTB:
  //   - getBaseUpdateFee     -> getObjects(pythStateId)
  //   - getPythPackageId     -> reads pyth state's upgrade_cap.package
  //   - getWormholePackageId -> reads wormhole state's upgrade_cap.package
  //   - getPriceTableInfo    -> deriveDynamicFieldId + Wrapper<vector<u8>> indirection
  //   - getPriceFeedObjectId -> deriveDynamicFieldId on the price-info table
  //
  // No signing / no PTB execution; safe to run in CI as long as the test
  // host can reach `fullnode.mainnet.sui.io:443`.
  group('Integration: SuiPythClient (mainnet, read-only)', () {
    // Mainnet Pyth + Wormhole state object ids.
    const pythStateId =
        '0x1f9310238ee9298fb703c3419030b35b22bb1cc37113e3bb5007c99aec79e5b8';
    const wormholeStateId =
        '0xaeab97f96cf9877fee2883315d459552b2b921edc16d7ceac6eab944dd88919c';

    // Well-known Pyth price feed: SUI/USD.
    const suiUsdFeedId =
        '0x23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744';

    late SuiPythClient pyth;

    setUp(() {
      final grpc = SuiGrpcClient(
        SuiGrpcClientOptions(baseUrl: 'fullnode.mainnet.sui.io', port: 443),
      );
      pyth = SuiPythClient(
        client: grpc,
        pythStateId: pythStateId,
        wormholeStateId: wormholeStateId,
      );
    });

    test('getBaseUpdateFee returns a non-zero u64', () async {
      final fee = await pyth.getBaseUpdateFee();
      expect(fee, isA<BigInt>());
      expect(fee, greaterThan(BigInt.zero));
    });

    test('getPythPackageId returns a hex address', () async {
      final pkg = await pyth.getPythPackageId();
      expect(pkg, startsWith('0x'));
      expect(pkg.length, greaterThan(2));
    });

    test('getWormholePackageId returns a hex address', () async {
      final pkg = await pyth.getWormholePackageId();
      expect(pkg, startsWith('0x'));
      expect(pkg.length, greaterThan(2));
    });

    test(
      'getPriceTableInfo resolves table id + PriceIdentifier type',
      () async {
        final info = await pyth.getPriceTableInfo();
        expect(info.id, startsWith('0x'));
        expect(
          info.priceIdentifierType,
          contains('::price_identifier::PriceIdentifier'),
        );
      },
    );

    test(
      'getPriceFeedObjectId resolves SUI/USD via deterministic UID',
      () async {
        final id = await pyth.getPriceFeedObjectId(suiUsdFeedId);
        expect(id, isNotNull);
        expect(id!, startsWith('0x'));
      },
    );

    test('getPriceFeedObjectId is cached on second call (no RPC)', () async {
      final id1 = await pyth.getPriceFeedObjectId(suiUsdFeedId);
      final stopwatch = Stopwatch()..start();
      final id2 = await pyth.getPriceFeedObjectId(suiUsdFeedId);
      stopwatch.stop();
      expect(id2, equals(id1));
      // Cache hit: should be effectively instant. Allow 50ms slack for
      // event-loop scheduling on slow hosts.
      expect(stopwatch.elapsedMilliseconds, lessThan(50));
    });

    test('getPriceFeedObjectId returns null for an unknown feed', () async {
      // Random 32-byte hex that's almost certainly not a registered feed.
      const bogus =
          '0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef';
      final id = await pyth.getPriceFeedObjectId(bogus);
      expect(id, isNull);
    });
  });
}
