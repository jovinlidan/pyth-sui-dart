import 'package:pyth_sui_dart/pyth_sui_dart.dart';
import 'package:test/test.dart';

void main() {
  group('Integration: SuiPriceServiceConnection', () {
    late SuiPriceServiceConnection conn;

    setUp(() {
      conn = SuiPriceServiceConnection('https://hermes.pyth.network');
    });

    test('fetches latest VAA update data', () async {
      final ids = await conn.getPriceFeedIds();
      expect(ids, isNotEmpty);

      final updates = await conn.getPriceFeedsUpdateData([ids.first]);
      expect(updates, isNotEmpty);

      expect(updates.first.lengthInBytes, greaterThan(0));
    });
  });
}
