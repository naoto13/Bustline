#!/usr/bin/env bash
# Export contract ABIs from forge artifacts for frontend (TS) and keeper (JSON).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
forge build -q
mkdir -p frontend/src/abi keeper/abi
: > frontend/src/abi/index.ts
for c in HouseExchange RebateToken RebateStaking MockOracle MockERC20; do
  abi=$(forge inspect "$c" abi --json)
  echo "$abi" > "keeper/abi/${c}.json"
  printf 'export const %sAbi = %s as const;\n' "$c" "$abi" > "frontend/src/abi/${c}.ts"
  echo "export * from './${c}';" >> frontend/src/abi/index.ts
done
forge inspect HouseExchange methodIdentifiers --json > keeper/abi/HouseExchange.selectors.json
forge inspect MockOracle methodIdentifiers --json > keeper/abi/MockOracle.selectors.json
