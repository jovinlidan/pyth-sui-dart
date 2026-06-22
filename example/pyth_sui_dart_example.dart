import 'dart:typed_data';

import 'package:pyth_sui_dart/pyth_sui_dart.dart';
import 'package:sui_dart/grpc/client.dart';
import 'package:sui_dart/sui.dart';

const pythStateId =
    '0x1f9310238ee9298fb703c3419030b35b22bb1cc37113e3bb5007c99aec79e5b8';
const wormholeStateId =
    '0xaeab97f96cf9877fee2883315d459552b2b921edc16d7ceac6eab944dd88919c';
const suiUsdFeedId =
    '0x23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744';

Future<void> main() async {
  final connection = SuiPriceServiceConnection('https://hermes.pyth.network');
  final List<Uint8List> updates = await connection.getPriceFeedsUpdateData([
    suiUsdFeedId,
  ]);

  final client = SuiGrpcClient(
    SuiGrpcClientOptions(baseUrl: 'fullnode.mainnet.sui.io', port: 443),
  );
  final pyth = SuiPythClient(
    client: client,
    pythStateId: pythStateId,
    wormholeStateId: wormholeStateId,
  );

  final tx = Transaction();
  final priceInfoObjectIds = await pyth.updatePriceFeeds(
    tx: tx,
    updates: updates,
    feedIds: [suiUsdFeedId],
  );

  print('Updated Pyth price info objects: $priceInfoObjectIds');
}
