# pyth_sui_dart

A lightweight Dart SDK to fetch Pyth price updates and update Pyth price feeds on Sui. It wraps:

- Pyth Price Service (Hermes) for fetching the latest VAAs/accumulator messages.
- Sui client primitives to verify VAAs (via Wormhole) and update/create Pyth price feeds on-chain.

This is a Dart port inspired by the official Pyth cross-chain SDKs.

## Features

- Fetch latest price update data for specific Pyth feeds from Hermes.
- Verify Wormhole VAAs inside a Sui transaction.
- Create new Pyth price feeds on Sui.
- Update existing Pyth price feeds with fresh prices.
- Caches package IDs and dynamic field lookups to reduce RPC calls.

## Install

Add to your `pubspec.yaml`:

```yaml
dependencies:
  pyth_sui_dart: ^1.0.1
```

## Quick Start

1. Create a price service connection and fetch updates

```dart
import 'dart:typed_data';
import 'package:pyth_sui_dart/pyth_sui_dart.dart';

Future<List<Uint8List>> fetchUpdates() async {
  final conn = SuiPriceServiceConnection('https://hermes.pyth.network');
  // You can discover available feed IDs too:
  final ids = await conn.getPriceFeedIds();

  // Pick specific feed IDs you care about (hex string IDs)
  final updates = await conn.getPriceFeedsUpdateData([ids.first]);
  return updates; // List<Uint8List> containing VAA or accumulator message bytes
}
```

2. Prepare a Sui client and the Pyth client

```dart
import 'package:sui_dart/sui.dart';
import 'package:pyth_sui_dart/pyth_sui_dart.dart';

final provider = SuiClient(
  SuiClientOptions(
    fullnode: 'https://fullnode.mainnet.sui.io', // or testnet/devnet endpoint
  ),
);

// Replace with the on-chain state object IDs for your network
const pythStateId = '<PYTH_STATE_OBJECT_ID>';
const wormholeStateId = '<WORMHOLE_STATE_OBJECT_ID>';

final pyth = SuiPythClient(
  provider: provider,
  pythStateId: pythStateId,
  wormholeStateId: wormholeStateId,
);
```

3. Update price feeds on-chain

```dart
import 'dart:typed_data';
import 'package:sui_dart/sui.dart';
import 'package:pyth_sui_dart/pyth_sui_dart.dart';

Future<void> updateFeeds(List<String> feedIds, List<Uint8List> updates) async {
  final tx = Transaction();

  // Adds all necessary calls to the transaction:
  // - verify the Wormhole VAA
  // - pay fees
  // - update Pyth price feeds
  final updatedObjectIds = await pyth.updatePriceFeeds(
    tx: tx,
    updates: updates,
    feedIds: feedIds, // hex strings; either with or without 0x prefix
  );

  // Sign + execute per your wallet/integration
  // Example (pseudocode): await provider.signAndExecute(tx, signer: ...);

  print('Updated Pyth price objects: $updatedObjectIds');
}
```

4. Create a price feed if it does not exist yet

```dart
final tx = Transaction();
await pyth.createPriceFeed(tx: tx, updates: updates);
// Sign + execute the transaction after adding the call above.
```

## API Overview

- `SuiPriceServiceConnection` (extends `price_service_client`):

  - `getPriceFeedsUpdateData(List<String> priceIds) -> Future<List<Uint8List>>`
  - Also exposes helpers like `getPriceFeedIds()` to discover available feeds.

- `SuiPythClient`:
  - `getBaseUpdateFee() -> Future<BigInt>`: Reads fee from on-chain Pyth state.
  - `updatePriceFeeds({ tx, updates, feedIds }) -> Future<List<String>>`: Adds all calls to update multiple feeds.
  - `updatePriceFeedsWithCoins({ tx, updates, feedIds, coins })`: Same as above when you pre-split coins.
  - `createPriceFeed({ tx, updates })`: Adds calls to create feeds using accumulator messages.
  - `getPriceFeedObjectId(String feedId) -> Future<String?>`: Resolves the on-chain object id for a feed.

## Network, IDs, and Endpoints

- Hermes endpoint: `https://hermes.pyth.network` (public). You may use region-specific or authenticated endpoints as needed.
- `pythStateId` and `wormholeStateId` are on-chain object IDs and differ per network (mainnet/testnet/devnet). Obtain them from Pyth/Wormhole deployment docs or your Sui explorer.
- Feed IDs are 32-byte hex strings. You can fetch a list via `SuiPriceServiceConnection.getPriceFeedIds()` or from Pyth documentation.

## Development

- Run tests:

```bash
dart test
```

- Key source files:
  - `lib/src/client.dart`: Pyth Sui transaction helpers
  - `lib/src/sui_price_service_connection.dart`: Hermes integration
  - `lib/pyth_sui_dart.dart`: Library exports

## License

Apache-2.0. See `LICENSE`.

## Support

- Issues: open a ticket on the GitHub repository.
- For network IDs and deployment details, refer to the official Pyth Network and Wormhole documentation for Sui.
