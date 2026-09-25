## 4.3.0

### Changed

- Require `sui_dart` `^0.12.0`.

## 4.2.0

### Changed

- Require `sui_dart` `^0.11.0`.

## 4.1.0

### Changed

- Require `sui_dart` `^0.10.0`. Consumers on 0.9.x must upgrade alongside.
  `pyth_sui_dart`'s own API is unchanged; nothing here touches the APIs 0.10.0
  changed.

### Fixed

- The example imported `package:sui_dart/grpc/client.dart`, a path removed in
  `sui_dart` 0.9.0, so it had not analyzed since.

## 4.0.0

### Breaking

- Require `sui_dart` `^0.9.0`. Its transport refactor removed the JSON-RPC
  surface and renamed client methods, so consumers on `sui_dart` 0.8.x must
  migrate. `pyth_sui_dart`'s own API is unchanged.

## 3.0.1

### Changed

- Bump `bcs_dart` to `^0.2.1`.

## 3.0.0

### Breaking

- `SuiPriceServiceConnection` fetches from Hermes (`/v2/updates/price/latest`) directly and no longer extends `price_service_client`'s `PriceServiceConnection`; the inherited methods (`getLatestVaas`, `getVaa`, `getPriceFeed`, `getPriceFeedIds`, websocket subscriptions) are gone. `getPriceFeedsUpdateData` and `getLatestPriceFeeds` keep their signatures.
- `Price`, `PriceFeed`, and `PriceServiceConnectionConfig` are now defined and exported by this package instead of re-used from `price_service_client`.

### Changed

- Drop the `price_service_client` dependency; add `http` and `decimal`.
- Bump `sui_dart` to `^0.8.1` and `bcs_dart` to `^0.2.0`.

## 2.0.1

- Widen the `sui_dart` constraint to `^0.5.0`.
- Reject empty (and multiple) accumulator messages with a clear `ArgumentError` instead of crashing with `Bad state: No element`.
- Validate that a feed id has an even number of hex digits before decoding, instead of throwing `RangeError`.
- Fix the README quick-start to use the gRPC `SuiGrpcClient` / `client:` API and add a runnable `example/`.

## 2.0.0

- **BREAKING:** `SuiPythClient` now reads on-chain state via gRPC (`SuiGrpcClient` from `sui_dart`) instead of JSON-RPC `SuiClient`. Sui's JSON-RPC API is deprecated.
- Constructor parameter renamed: `provider: SuiClient` -> `client: SuiGrpcClient`.
- Dynamic field lookup is now implemented via `listDynamicFields` + client-side BCS name matching (paginated). Per-feed object IDs are still cached in-memory after the first lookup.

Migration guide:

```dart
// Before
final client = SuiPythClient(
  provider: SuiClient('https://fullnode.mainnet.sui.io:443'),
  pythStateId: '...',
  wormholeStateId: '...',
);

// After
final client = SuiPythClient(
  client: SuiGrpcClient(SuiGrpcClientOptions(
    baseUrl: 'fullnode.mainnet.sui.io',
    port: 443,
  )),
  pythStateId: '...',
  wormholeStateId: '...',
);
```

## 1.0.2

- Fix minor bugs

## 1.0.1

- Update transaction result types and method names

## 1.0.0

- Initial version.
