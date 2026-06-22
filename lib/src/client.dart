import 'dart:convert';
import 'dart:typed_data';

import 'package:bcs_dart/index.dart';
import 'package:sui_dart/grpc/client.dart';
import 'package:sui_dart/grpc/types.dart' as grpc_types;
import 'package:sui_dart/sui.dart';
import 'package:sui_dart/types/sui_bcs.dart' show StructTag;

const int kMaxArgumentSize = 16 * 1024;

/// Pyth Sui client. On-chain reads use [SuiGrpcClient] (sui.rpc.v2);
/// JSON-RPC is deprecated.
class SuiPythClient {
  final SuiGrpcClient client;
  final String pythStateId;
  final String wormholeStateId;

  String? _pythPackageId;
  String? _wormholePackageId;
  ({String id, String priceIdentifierType})? _priceTableInfo;
  final Map<String, String> _priceFeedObjectIdCache = {};
  BigInt? _baseUpdateFee;

  SuiPythClient({
    required this.client,
    required this.pythStateId,
    required this.wormholeStateId,
  });

  Future<BigInt> getBaseUpdateFee() async {
    if (_baseUpdateFee != null) return _baseUpdateFee!;
    final fields = await _fetchObjectFields(pythStateId);
    if (fields == null) {
      throw StateError('Unable to fetch pyth state object');
    }
    final raw = fields['base_update_fee'];
    _baseUpdateFee = BigInt.parse(raw.toString());
    return _baseUpdateFee!;
  }

  /// Returns the latest package id for [objectId]. Walks the upgrade cap
  /// so the latest published package is used after upgrades.
  Future<String> getPackageId(String objectId) async {
    final fields = await _fetchObjectFields(objectId);
    final upgradeCap = fields?['upgrade_cap'];
    if (upgradeCap is Map<String, dynamic>) {
      final pkg = upgradeCap['package'];
      if (pkg is String && pkg.isNotEmpty) return pkg;
    }
    throw StateError('Cannot fetch package id for $objectId');
  }

  /// Adds the commands for calling wormhole and verifying the vaas and returns the verified vaas.
  Future<List<Map<String, Object>>> verifyVaas(
    List<Uint8List> vaas,
    Transaction tx,
  ) async {
    final wormholePackageId = await getWormholePackageId();
    final verifiedVaas = <Map<String, Object>>[];
    for (final vaa in vaas) {
      final argBytes = Bcs.vector(Bcs.u8())
          .serialize(
            List.from(vaa),
            options: BcsWriterOptions(maxSize: kMaxArgumentSize),
          )
          .toBytes();

      final res = tx.moveCall(
        '$wormholePackageId::vaa::parse_and_verify',
        arguments: [
          tx.object(wormholeStateId),
          tx.pure(argBytes),
          tx.object(SUI_CLOCK_OBJECT_ID),
        ],
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
    if (updates.length != 1) {
      throw ArgumentError(
        'SDK requires exactly one accumulator message per transaction',
      );
    }
    final vaa = extractVaaBytesFromAccumulatorMessage(updates.first);
    final verifiedVaas = await verifyVaas([vaa], tx);

    final argBytes = Bcs.vector(Bcs.u8())
        .serialize(
          List.from(updates.first),
          options: BcsWriterOptions(maxSize: kMaxArgumentSize),
        )
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
    // Parallel: each feed lookup is one `getObjects` round-trip.
    final priceInfoObjects = await Future.wait(
      feedIds.map((feedId) async {
        final id = await getPriceFeedObjectId(feedId);
        if (id == null) {
          throw StateError(
            'Price feed $feedId not found, please create it first',
          );
        }
        return id;
      }),
    );

    for (var coinId = 0; coinId < feedIds.length; coinId++) {
      final res = tx.moveCall(
        '$packageId::pyth::update_single_price_feed',
        arguments: [
          tx.object(pythStateId),
          priceUpdatesHotPotato,
          tx.object(priceInfoObjects[coinId]),
          coins[coinId],
          tx.object(SUI_CLOCK_OBJECT_ID),
        ],
      );
      priceUpdatesHotPotato = res[0];
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

  Future<void> createPriceFeed({
    required Transaction tx,
    required List<Uint8List> updates,
  }) async {
    final packageId = await getPythPackageId();
    if (updates.length != 1) {
      throw ArgumentError(
        'SDK requires exactly one accumulator message per transaction',
      );
    }
    final vaa = extractVaaBytesFromAccumulatorMessage(updates.first);
    final verified = await verifyVaas([vaa], tx);

    final argBytes = Bcs.vector(Bcs.u8())
        .serialize(
          List.from(updates.first),
          options: BcsWriterOptions(maxSize: kMaxArgumentSize),
        )
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

  Future<String> getWormholePackageId() async =>
      _wormholePackageId ??= await getPackageId(wormholeStateId);

  Future<String> getPythPackageId() async =>
      _pythPackageId ??= await getPackageId(pythStateId);

  /// priceFeedObjectId for `feedId`. Single `getObjects` via derived UID.
  Future<String?> getPriceFeedObjectId(String feedId) async {
    final normalizedFeedId = feedId.replaceFirst('0x', '');
    final cached = _priceFeedObjectIdCache[normalizedFeedId];
    if (cached != null) return cached;

    final info = await getPriceTableInfo();
    final feedBytes = Uint8List.fromList(_hexToBytes(normalizedFeedId));

    // PriceIdentifier{bytes: vector<u8>}: single-field struct flattens
    // to the inner vector's BCS = ULEB128(len) + raw.
    final keyBcs = Bcs.struct('PriceIdentifier', {
      'bytes': Bcs.vector(Bcs.u8()),
    }).serialize({'bytes': feedBytes}).toBytes();

    final fieldId = deriveDynamicFieldId(
      parentObjectId: info.id,
      keyTypeTag: info.priceIdentifierType,
      keyBcs: keyBcs,
    );

    final fields = await _fetchObjectFields(fieldId);
    final value = fields?['value'];
    if (value is! String || value.isEmpty) return null;
    _priceFeedObjectIdCache[normalizedFeedId] = value;
    return value;
  }

  List<int> _hexToBytes(String hex) {
    final clean = hex.replaceFirst('0x', '');
    if (clean.length.isOdd) {
      throw ArgumentError(
        'feedId hex must have an even number of digits: $hex',
      );
    }
    final res = <int>[];
    for (var i = 0; i < clean.length; i += 2) {
      res.add(int.parse(clean.substring(i, i + 2), radix: 16));
    }
    return res;
  }

  /// Resolves the price table id + its `K` (PriceIdentifier) type tag.
  /// `b"price_info"` on the Pyth state is a `dynamic_object_field`, so we
  /// derive the wrapper UID, follow `value` to the table, then read its
  /// `Table<K, V>` type to get K.
  Future<({String id, String priceIdentifierType})> getPriceTableInfo() async {
    if (_priceTableInfo != null) return _priceTableInfo!;

    final nameBcs = Bcs.vector(
      Bcs.u8(),
    ).serialize(utf8.encode('price_info')).toBytes();

    final wrapperFieldId = deriveDynamicFieldId(
      parentObjectId: pythStateId,
      keyTypeTag: '0x2::dynamic_object_field::Wrapper<vector<u8>>',
      keyBcs: nameBcs,
    );
    final wrapperFields = await _fetchObjectFields(wrapperFieldId);
    final tableId = wrapperFields?['value'];
    if (tableId is! String || tableId.isEmpty) {
      throw StateError(
        'Price Table not found, contract may not be initialized',
      );
    }

    final results = await client.getObjects([
      tableId,
    ], include: const grpc_types.ObjectIncludeOptions(json: true));
    if (results.isEmpty || results.first is! grpc_types.ObjectSuccess) {
      throw StateError('Price Table object $tableId not found');
    }
    final tableObj = (results.first as grpc_types.ObjectSuccess).data;
    final tableTag = parseStructTag(tableObj.type);
    if (tableTag.typeParams.isEmpty) {
      throw StateError('Unexpected price-table type: ${tableObj.type}');
    }
    final keyTag = tableTag.typeParams.first;
    final priceIdentifierType = keyTag is StructTag
        ? normalizeStructTag(keyTag)
        : keyTag.toString();

    _priceTableInfo = (id: tableId, priceIdentifierType: priceIdentifierType);
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

  Future<Map<String, dynamic>?> _fetchObjectFields(String objectId) async {
    final results = await client.getObjects([
      objectId,
    ], include: const grpc_types.ObjectIncludeOptions(json: true));
    if (results.isEmpty) return null;
    final first = results.first;
    if (first is! grpc_types.ObjectSuccess) return null;
    return first.data.json;
  }
}
