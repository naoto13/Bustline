#!/usr/bin/env bash
# Crash / volatility demo on the LOCAL anvil fork (run scripts/dev-fork.sh first).
# Shows: house starts at 0 → winner is queued → crash liquidates leveraged longs → their margin repays the queue FIFO
#        → losers receive non-transferable rebate tokens → staking earns MUSD revenue share.
# SAFETY: anvil only (unlocked default accounts, no keys). Refuses to run against anything that is not anvil.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
RPC="${RPC:-http://127.0.0.1:8545}"
cast rpc --rpc-url "$RPC" anvil_nodeInfo >/dev/null 2>&1 || { echo "not an anvil node — abort"; exit 1; }
J=deployments/local.json
EX=$(jq -r .HouseExchange $J); OR=$(jq -r .MockOracle $J); RT=$(jq -r .RebateToken $J); ST=$(jq -r .RebateStaking $J); MUSD=$(jq -r .MUSD $J)
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ALICE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8; BOB=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
CAROL=0x90F79bf6EB2c4f870365E785982E1f101E93b906; DAVE=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
KEEPER="python3 -m perp_keeper --rpc $RPC --deployment $PWD/$J --execute-local --once --dry-run"

send() { local from=$1; shift; cast send --rpc-url "$RPC" --unlocked --from "$from" "$@" >/dev/null; }
u() { cast call --rpc-url "$RPC" "$@" | awk '{print $1}'; }
f() { python3 -c "import sys; print(f'{int(sys.argv[1])/1e18:,.2f}')" "$1"; }
price() { u "$OR" "priceValue()(uint256)"; }
set_price() { cast rpc --rpc-url "$RPC" evm_increaseTime 2 >/dev/null; send $OWNER "$OR" "setPrice(uint256)" "$1"; echo "   📈 oracle BTC/USD → \$$(f "$1")"; }
move_pct() { set_price "$(python3 -c "import sys; print(int(int(sys.argv[1])*(1+float(sys.argv[2])/100)))" "$(price)" "$1")"; }
keeper() { (cd keeper && $KEEPER | tail -1 | sed 's/^/   🤖 /'); }
open_() { send "$1" "$MUSD" "approve(address,uint256)" "$EX" "$3"; send "$1" "$EX" "requestOpen(bool,uint256,uint256,uint256)" "$2" "$3" "$4" 0; }
close_() { send "$1" "$EX" "requestClose(uint256,uint256)" "$2" 0; }
state() {
  echo "   🏦 house cash $(f "$(u "$EX" "houseCash()(uint256)")") MUSD | queued $(f "$(u "$EX" "queueTotal()(uint256)")") | equity $(cast call --rpc-url "$RPC" "$EX" "houseEquity()(int256)" | awk '{printf "%.2f", $1/1e18}') | accountingDelta $(cast call --rpc-url "$RPC" "$EX" "accountingDelta()(int256)" | awk '{print $1}')"
}
who() { for n in ALICE BOB CAROL DAVE; do a=${!n}; echo "   👤 $n MUSD $(f "$(u "$MUSD" "balanceOf(address)(uint256)" "$a")") | queued $(f "$(u "$EX" "queuedOf(address)(uint256)" "$a")") | rebate $(f "$(u "$RT" "balanceOf(address)(uint256)" "$a")") | staked $(f "$(u "$ST" "staked(address)(uint256)" "$a")") | pending $(f "$(u "$ST" "pending(address)(uint256)" "$a")")"; done; }

echo "══ 0. fresh house (no LP deposits — starts at 0 MUSD)"; state
echo "══ 1. requests: ALICE long 1,000×50 · BOB short 1,000×50 · CAROL long 200×100 · DAVE long 500×20"
open_ $ALICE true 1000000000000000000000 50
open_ $BOB false 1000000000000000000000 50
open_ $CAROL true 200000000000000000000 100
open_ $DAVE true 500000000000000000000 20
echo "   keeper before any new oracle update (2-step rule → must wait):"; keeper
set_price "$(price)"; keeper
for i in 0 1 2 3; do echo "   #$i bust price \$$(f "$(u "$EX" "bustPriceOf(uint256)(uint256)" $i)")"; done
echo "══ 2. BTC +1.0% → ALICE closes in profit; house is empty → profit goes to the FIFO payout queue"
move_pct 1.0; close_ $ALICE 0; set_price "$(price)"; keeper; state; who
echo "══ 3. CRASH −6% → CAROL (100x) and DAVE (20x) hard-bust; keeper liquidates; their margin repays ALICE first"
move_pct -6; keeper; state; who
echo "══ 4. BOB (short) closes in profit after the crash → paid from house cash or queued"
close_ $BOB 1; set_price "$(price)"; keeper; state
echo "══ 5. CAROL & DAVE stake their non-transferable rebate tokens (transfer to a wallet must revert)"
if cast send --rpc-url "$RPC" --unlocked --from $CAROL "$RT" "transfer(address,uint256)" $ALICE 1 >/dev/null 2>&1; then echo "   ❌ transfer succeeded?!"; exit 1; else echo "   ✅ wallet-to-wallet transfer reverted (NonTransferable)"; fi
for n in CAROL DAVE; do a=${!n}; b=$(u "$RT" "balanceOf(address)(uint256)" "$a"); send "$a" "$RT" "approve(address,uint256)" "$ST" "$b"; send "$a" "$ST" "stake(uint256)" "$b"; done
echo "══ 6. Volatility: ALICE re-enters long 2,000×25, BTC −4.5% → liquidated; margin repays BOB (liq fee waived while queue active)"
open_ $ALICE true 2000000000000000000000 25; set_price "$(price)"; keeper
move_pct -4.5; keeper; state; who
echo "══ 7. Queue is empty now: DAVE shorts 1,000×10, BTC +3% → losing close; 2% loss fee → stakers"
open_ $DAVE false 1000000000000000000000 10; set_price "$(price)"; keeper
move_pct 3; close_ $DAVE 5; set_price "$(price)"; keeper; state; who
echo "══ 8. stakers claim MUSD revenue share"
for n in CAROL DAVE; do send "${!n}" "$ST" "claim()"; done; who
echo "══ summary"; state
echo "   cumulative losses $(f "$(u "$EX" "cumulativeLosses()(uint256)")") | paid to winners $(f "$(u "$EX" "cumulativePaid()(uint256)")") | to stakers $(f "$(u "$EX" "totalToStakers()(uint256)")") | queue entries $(u "$EX" "queueLength()(uint256)") head $(u "$EX" "queueHead()(uint256)")"
