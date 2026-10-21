# Test fixtures

`pyth_btcusd_base_mainnet_1792544395.hex` — a real, public Pyth price update (PNAU / Wormhole-signed accumulator
message, Pyth **stable/mainnet** data source) for BTC/USD (`0xe62d…5b43`), publishTime `1792544395`
(2026-10-20 JST), price `8294363411393e-8`. Extracted from the calldata of Base mainnet tx
`0x4d4f7c5c712efce47296b969933c156777f71d6cc0d1dc442fe3a5572f6cf54f` (a public `updatePriceFeeds` call).
Used by `test/fork/PythFork.t.sol` to prove the Mezo testnet Pyth contract verifies mainnet-signed updates.
