#!/usr/bin/env bash
# Local dev environment: anvil fork of Mezo testnet + HouseExchange deployment.
# SAFETY: all transactions go to http://127.0.0.1:${PORT} from anvil's *unlocked* default accounts
# (eth_sendTransaction) — no private key is read or used; https://rpc.test.mezo.org is only READ.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

FORK_URL="${MEZO_FORK_SOURCE:-https://rpc.test.mezo.org}"
PORT="${ANVIL_PORT:-8545}"
RPC="http://127.0.0.1:${PORT}"
MUSD=0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503
SKIP=0x7b7c000000000000000000000000000000000015
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 # anvil #0 (owner, keeper, mock-oracle owner)
TRADERS=(0x70997970C51812dc3A010C7d01b50e0d17dc79C8 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC 0x90F79bf6EB2c4f870365E785982E1f101E93b906 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65)

if [[ "${RESTART_ANVIL:-1}" == "1" ]]; then
  pkill -f "anvil .*--port ${PORT}" 2>/dev/null || true
  sleep 1
  echo "▶ starting anvil fork of ${FORK_URL} on ${RPC} (chainId 31611)"
  nohup anvil --fork-url "$FORK_URL" --chain-id 31611 --hardfork london --port "$PORT" --silent \
    > /tmp/mezo-perp-anvil.log 2>&1 &
  for _ in $(seq 1 30); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
fi
[[ "$(cast chain-id --rpc-url "$RPC")" == "31611" ]] || { echo "anvil not up"; exit 1; }
cast rpc --rpc-url "$RPC" anvil_nodeInfo >/dev/null || { echo "not an anvil node — abort"; exit 1; }

# Read-only: current Skip BTC/USD from the real testnet (the forked EVM cannot run the precompile)
P0=$(cast call "$SKIP" "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url "$FORK_URL" 2>/dev/null | sed -n 2p | awk '{print $1}' || true)
P0=${P0:-83000000000000000000000}
echo "▶ Skip BTC/USD (testnet, read-only) = $P0"

echo "▶ funding demo traders with MUSD via anvil_setStorageAt (MUSD balances mapping = slot 0)"
for who in "${TRADERS[@]}"; do
  SLOT=$(cast index address "$who" 0)
  cast rpc --rpc-url "$RPC" anvil_setStorageAt "$MUSD" "$SLOT" "$(cast to-uint256 100000000000000000000000)" >/dev/null # 100,000 MUSD
done

echo "▶ deploying HouseExchange stack (DeployLocal.s.sol, unlocked anvil #0)"
mkdir -p deployments
PERP_LOCAL_FORK=1 INITIAL_PRICE="$P0" forge script script/DeployLocal.s.sol --rpc-url "$RPC" --broadcast --unlocked \
  --sender "$DEPLOYER" -q >/dev/null
cat deployments/local.json; echo
bash scripts/export-abi.sh
mkdir -p frontend/public && cp deployments/local.json frontend/public/deployment.json 2>/dev/null || true
echo "✅ dev fork ready: ${RPC}"
