import 'dart:typed_data';

import 'package:bcs_dart/index.dart';
import 'package:sui_dart/sui.dart';

const int kMaxArgumentSize = 16 * 1024;

class SuiPythClient {
  final SuiClient provider;
  final String pythStateId;
  final String wormholeStateId;

  String? _pythPackageId;
  String? _wormholePackageId;
  ({String id, String fieldType})? _priceTableInfo;
  final Map<String, String> _priceFeedObjectIdCache = {};
  BigInt? _baseUpdateFee; // u64 fits in int

  SuiPythClient({required this.provider, required this.pythStateId, required this.wormholeStateId});

  Future<BigInt> getBaseUpdateFee() async {
    if (_baseUpdateFee == null) {
      final result = await provider.getObject(
        pythStateId,
        options: SuiObjectDataOptions(showContent: true),
      );
      final data = result.data;
      final content = data?.content;
      if (content == null || content.dataType != 'moveObject') {
        throw StateError('Unable to fetch pyth state object');
      }
      final fields = content.fields;
      _baseUpdateFee = (BigInt.parse(fields['base_update_fee']));
    }
    return _baseUpdateFee!;
  }

  /// getPackageId returns the latest package id that the object belongs to. Use this to
  /// fetch the latest package id for a given object id and handle package upgrades automatically.
  Future<String> getPackageId(String objectId) async {
    final result = await provider.getObject(
      objectId,
      options: SuiObjectDataOptions(showContent: true),
    );
    final content = result.data?.content;
    if (content?.dataType == 'moveObject') {
      final fields = content?.fields;
      if (fields.containsKey('upgrade_cap')) {
        final cap = fields['upgrade_cap'] as Map<String, dynamic>;
        final capFields = cap['fields'] as Map<String, dynamic>;
        return (capFields['package'] as String);
      }
    }
    throw StateError('Cannot fetch package id for object $String');
  }

  /// Adds the commands for calling wormhole and verifying the vaas and returns the verified vaas.
  Future<List<Map<String, Object>>> verifyVaas(List<Uint8List> vaas, Transaction tx) async {
    final wormholePackageId = await getWormholePackageId();
    final verifiedVaas = <Map<String, Object>>[];
    for (final vaa in vaas) {
      final argBytes = Bcs.vector(
        Bcs.u8(),
      ).serialize(List.from(vaa), options: BcsWriterOptions(maxSize: kMaxArgumentSize)).toBytes();

      final res = tx.moveCall(
        '$wormholePackageId::vaa::parse_and_verify',
        arguments: [tx.object(wormholeStateId), tx.pure(argBytes), tx.object(SUI_CLOCK_OBJECT_ID)],
      );
      verifiedVaas.add(res[0]);
    }
    return verifiedVaas;
  }

  /// Verifies a single accumulator message and returns a hot-potato handle.
  Future<TransactionResult> verifyVaasAndGetHotPotato({
    required Transaction tx,
    required List<Uint8List> updates,
    required String packageId,
  }) async {
    if (updates.length > 1) {
      throw ArgumentError(
        'SDK does not support sending multiple accumulator messages in a single transaction',
      );
    }
    final vaa = extractVaaBytesFromAccumulatorMessage(updates.first);
    final verifiedVaas = await verifyVaas([vaa], tx);

    final argBytes = Bcs.vector(Bcs.u8())
        .serialize(List.from(updates.first), options: BcsWriterOptions(maxSize: kMaxArgumentSize))
        .toBytes();

    final res = tx.moveCall(
      '$packageId::pyth::create_authenticated_price_infos_using_accumulator',
      arguments: [
        tx.object(pythStateId),
        tx.pure(argBytes),
        verifiedVaas.first,
        tx.object(SUI_CLOCK_OBJECT_ID),
      ],
    );

    return res;
  }

  Future<List<String>> executePriceFeedUpdates({
    required Transaction tx,
    required String packageId,
    required List<String> feedIds,
    required dynamic priceUpdatesHotPotato,
    required TransactionResult coins,
  }) async {
    final priceInfoObjects = <String>[];
    var coinId = 0;

    for (final feedId in feedIds) {
      final priceInfoObjectId = await getPriceFeedObjectId(feedId);
      if (priceInfoObjectId == null) {
        throw StateError('Price feed $feedId not found, please create it first');
      }
      priceInfoObjects.add(priceInfoObjectId);

      final res = tx.moveCall(
        '$packageId::pyth::update_single_price_feed',
        arguments: [
          tx.object(pythStateId),
          priceUpdatesHotPotato,
          tx.object(priceInfoObjectId),
          coins[coinId],
          tx.object(SUI_CLOCK_OBJECT_ID),
        ],
      );
      priceUpdatesHotPotato = res[0];
      coinId++;
    }

    tx.moveCall(
      '$packageId::hot_potato_vector::destroy',
      arguments: [priceUpdatesHotPotato],
      typeArguments: ['$packageId::price_info::PriceInfo'],
    );

    return priceInfoObjects;
  }

  /// Adds the necessary commands for updating the pyth price feeds to the transaction block.\
  /// [tx] transaction block to add commands to\
  /// [updates] array of price feed updates received from the price service\
  /// [feedIds] array of feed ids to update (in hex format)\
  Future<List<String>> updatePriceFeeds({
    required Transaction tx,
    required List<Uint8List> updates,
    required List<String> feedIds,
  }) async {
    final packageId = await getPythPackageId();

    final priceUpdatesHotPotato = await verifyVaasAndGetHotPotato(
      tx: tx,
      updates: updates,
      packageId: packageId,
    );

    final baseUpdateFee = await getBaseUpdateFee();
    final amounts = feedIds.map((_) => tx.pure.u64(baseUpdateFee)).toList();
    final coins = tx.splitCoins(tx.gas, amounts);

    return executePriceFeedUpdates(
      tx: tx,
      packageId: packageId,
      feedIds: feedIds,
      priceUpdatesHotPotato: priceUpdatesHotPotato,
      coins: coins,
    );
  }

  /// Same as above but coins are provided externally (already split).
  Future<List<String>> updatePriceFeedsWithCoins({
    required Transaction tx,
    required List<Uint8List> updates,
    required List<String> feedIds,
    required TransactionResult coins,
  }) async {
    final packageId = await getPythPackageId();
    final hotPotato = await verifyVaasAndGetHotPotato(
      tx: tx,
      updates: updates,
      packageId: packageId,
    );

    return executePriceFeedUpdates(
      tx: tx,
      packageId: packageId,
      feedIds: feedIds,
      priceUpdatesHotPotato: hotPotato,
      coins: coins,
    );
  }

  Future<void> createPriceFeed({required Transaction tx, required List<Uint8List> updates}) async {
    final packageId = await getPythPackageId();
    if (updates.length > 1) {
      throw ArgumentError(
        'SDK does not support sending multiple accumulator messages in a single transaction',
      );
    }
    final vaa = extractVaaBytesFromAccumulatorMessage(updates.first);
    final verified = await verifyVaas([vaa], tx);

    final argBytes = Bcs.vector(Bcs.u8())
        .serialize(List.from(updates.first), options: BcsWriterOptions(maxSize: kMaxArgumentSize))
        .toBytes();
    tx.moveCall(
      '$packageId::pyth::create_price_feeds_using_accumulator',
      arguments: [
        tx.object(pythStateId),
        tx.pure(argBytes),
        verified.first,
        tx.object(SUI_CLOCK_OBJECT_ID),
      ],
    );
  }

  /// Get the packageId for the wormhole package if not already cached
  Future<String> getWormholePackageId() async {
    _wormholePackageId ??= await getPackageId(wormholeStateId);
    return _wormholePackageId!;
  }

  /// Get the packageId for the pyth package if not already cached
  Future<String> getPythPackageId() async {
    _pythPackageId ??= await getPackageId(pythStateId);
    return _pythPackageId!;
  }

  /// Get the priceFeedObjectId for a given feedId if not already cached
  Future<String?> getPriceFeedObjectId(String feedId) async {
    final normalizedFeedId = feedId.replaceFirst('0x', '');
    if (!_priceFeedObjectIdCache.containsKey(normalizedFeedId)) {
      final info = await getPriceTableInfo();

      final result = await provider.getDynamicFieldObject(
        info.id,
        '${info.fieldType}::price_identifier::PriceIdentifier',
        {'bytes': _hexToBytes(normalizedFeedId)},
      );

      final data = result.data;
      final content = data?.content;
      if (content == null) return null;
      if (content.dataType != 'moveObject') {
        throw StateError('Price feed type mismatch');
      }
      final fields = content.fields as Map<String, dynamic>;
      final value = fields['value'] as String;
      _priceFeedObjectIdCache[normalizedFeedId] = value;
    }
    return _priceFeedObjectIdCache[normalizedFeedId];
  }

  /// Fetches the price table object id for the current state id if not cached
  Future<({String id, String fieldType})> getPriceTableInfo() async {
    if (_priceTableInfo == null) {
      final result = await provider.getDynamicFieldObject(pythStateId, 'vector<u8>', "price_info");

      final data = result.data;
      String? typeStr = data?.type;
      final objectId = data?.objectId;
      if (typeStr == null || objectId == null) {
        throw StateError('Price Table not found, contract may not be initialized');
      }

      typeStr = typeStr.replaceFirst('0x2::table::Table<', '');
      typeStr = typeStr.replaceFirst('::price_identifier::PriceIdentifier, 0x2::object::ID>', '');

      _priceTableInfo = (id: objectId, fieldType: typeStr);
    }
    return _priceTableInfo!;
  }

  /// Obtains the vaa bytes embedded in an accumulator message.
  Uint8List extractVaaBytesFromAccumulatorMessage(Uint8List acc) {
    // the first 6 bytes in the accumulator message encode the header, major, and minor bytes
    // we ignore them, since we are only interested in the VAA bytes
    final trailingPayloadSize = acc[6];
    final vaaSizeOffset =
        7 + // header bytes (header(4) + major(1) + minor(1) + trailing payload size(1))
        trailingPayloadSize + // trailing payload (variable number of bytes)
        1; // proof_type (1 byte)

    final bd = ByteData.sublistView(acc, vaaSizeOffset, vaaSizeOffset + 2);
    final vaaSize = bd.getUint16(0, Endian.big);
    final vaaOffset = vaaSizeOffset + 2;

    return Uint8List.sublistView(acc, vaaOffset, vaaOffset + vaaSize);
  }

  List<int> _hexToBytes(String hex) {
    final clean = (hex).replaceFirst('0x', '');
    final res = <int>[];
    for (var i = 0; i < clean.length; i += 2) {
      res.add(int.parse(clean.substring(i, i + 2), radix: 16));
    }
    return res;
  }

  // List<int> _uleb128(int value) {
  //   final bytes = <int>[];
  //   var v = value;
  //   do {
  //     var b = v & 0x7f;
  //     v >>= 7;
  //     if (v != 0) b |= 0x80;
  //     bytes.add(b);
  //   } while (v != 0);
  //   return bytes;
  // }
}
