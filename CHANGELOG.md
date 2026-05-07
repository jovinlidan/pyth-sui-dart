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
