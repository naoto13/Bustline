import type { Abi, Address } from "viem";
import { HouseExchangeAbi, RebateStakingAbi } from "@/abi";
import { publicClient } from "./chain";

/**
 * Optional reads (HouseExchange v3 / v3.1, RebateStaking v3) through the regenerated ABIs. Each read is independent and
 * returns `undefined` when the DEPLOYED contract lacks the function (e.g. `paused()` / `protocolFeeBps()` revert on
 * v3), so one missing function never fails the whole market query.
 */
const HouseExtraAbi = HouseExchangeAbi as Abi;
const StakingAbi = RebateStakingAbi as Abi;

const opt = <T,>(address: Address, abi: Abi, functionName: string, args: readonly unknown[] = []) =>
  (publicClient.readContract({ address, abi, functionName, args }) as Promise<T>).then(
    (v) => v,
    () => undefined,
  );

export type HouseExtra = {
  paused?: boolean;
  guardian?: Address;
  treasury?: Address;
  protocolFeeBps?: bigint;
  winFeeBps?: bigint;
  totalProtocolFees?: bigint;
  spDeposit?: bigint;
  spEnabled?: boolean;
  spMinLiquid?: bigint;
  spMaxShareBps?: bigint;
  totalBtcToStakers?: bigint;
};

export async function readHouseExtra(x: Address): Promise<HouseExtra> {
  const A = HouseExtraAbi;
  const [paused, guardian, treasury, protocolFeeBps, winFeeBps, totalProtocolFees, spDeposit, spEnabled, spMinLiquid, spMaxShareBps, totalBtcToStakers] =
    await Promise.all([
      opt<boolean>(x, A, "paused"), opt<Address>(x, A, "guardian"), opt<Address>(x, A, "treasury"),
      opt<bigint>(x, A, "protocolFeeBps"), opt<bigint>(x, A, "winFeeBps"), opt<bigint>(x, A, "totalProtocolFees"),
      opt<bigint>(x, A, "spDeposit"), opt<boolean>(x, A, "spEnabled"), opt<bigint>(x, A, "spMinLiquid"),
      opt<bigint>(x, A, "spMaxShareBps"), opt<bigint>(x, A, "totalBtcToStakers"),
    ]);
  return { paused, guardian, treasury, protocolFeeBps, winFeeBps, totalProtocolFees, spDeposit, spEnabled, spMinLiquid, spMaxShareBps, totalBtcToStakers };
}

export const readPendingBtc = (staking: Address, who: Address) => opt<bigint>(staking, StakingAbi, "pendingBtc", [who]);

/** "2%" from 200 bps; trims trailing zeros ("1.5%"). */
export const bpsPct = (b: bigint) => `${(Number(b) / 100).toFixed(2).replace(/\.?0+$/, "")}%`;
