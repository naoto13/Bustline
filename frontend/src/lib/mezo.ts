import { parseAbi, type Address } from "viem";
import { publicClient } from "./chain";
import type { MezoProtocol } from "./config";

/**
 * Minimal ABIs for the Mezo MUSD protocol, checked against mezo-org/musd @ da7888a1
 * (solidity/contracts/{BorrowerOperations,TroveManager,HintHelpers,SortedTroves,InterestRateManager,PriceFeed}.sol).
 */
export const BorrowerOperationsAbi = parseAbi([
  "function openTrove(uint256 _debtAmount, address _upperHint, address _lowerHint) payable",
  "function withdrawMUSD(uint256 _amount, address _upperHint, address _lowerHint)",
  "function repayMUSD(uint256 _amount, address _upperHint, address _lowerHint)",
  "function borrowingRate() view returns (uint256)",
  "function minNetDebt() view returns (uint256)",
  "function interestRateManager() view returns (address)",
]);
export const TroveManagerAbi = parseAbi([
  "function getTroveStatus(address) view returns (uint8)",
  "function getEntireDebtAndColl(address) view returns (uint256 coll, uint256 principal, uint256 interest, uint256 pendingCollateral, uint256 pendingPrincipal, uint256 pendingInterest)",
  "function getTroveInterestRate(address) view returns (uint16)",
  "function getTroveMaxBorrowingCapacity(address) view returns (uint256)",
  "function getTroveOwnersCount() view returns (uint256)",
  "function checkRecoveryMode(uint256 _price) view returns (bool)",
  "function getTCR(uint256 _price) view returns (uint256)",
]);
export const HintHelpersAbi = parseAbi([
  "function getApproxHint(uint256 _CR, uint256 _numTrials, uint256 _inputRandomSeed) view returns (address hintAddress, uint256 diff, uint256 latestRandomSeed)",
  "function computeNominalCR(uint256 _coll, uint256 _debt) pure returns (uint256)",
]);
export const SortedTrovesAbi = parseAbi([
  "function findInsertPosition(uint256 _NICR, address _prevId, address _nextId) view returns (address, address)",
]);
const InterestRateManagerAbi = parseAbi(["function interestRate() view returns (uint16)"]);
const PriceFeedAbi = parseAbi(["function fetchPrice() view returns (uint256)"]);

/** LiquityBase constants (dependencies/LiquityBase.sol). */
export const WAD = 10n ** 18n;
export const MCR = 1_100_000_000_000_000_000n; // 110%
export const CCR = 1_500_000_000_000_000_000n; // 150%
export const GAS_COMPENSATION = 200n * WAD;
/** UI thresholds: recommended ICR for new troves, and the "too close to 110%" warning line. */
export const ICR_RECOMMENDED = CCR;
export const ICR_WARN = 1_250_000_000_000_000_000n; // 125%

export type TroveStatus = "nonExistent" | "active" | "closedByOwner" | "closedByLiquidation" | "closedByRedemption";
const STATUS: TroveStatus[] = ["nonExistent", "active", "closedByOwner", "closedByLiquidation", "closedByRedemption"];

export type Protocol = {
  price?: bigint; // PriceFeed.fetchPrice(), 18 decimals; undefined when the feed reverts (stale / local fork)
  recovery?: boolean;
  tcr?: bigint;
  borrowingRate: bigint; // 1e18 = 100%
  minNetDebt: bigint;
  interestBps: number; // InterestRateManager.interestRate(), bps per year (simple interest, fixed at open)
};

export async function readProtocol(m: MezoProtocol): Promise<Protocol> {
  const [borrowingRate, minNetDebt, irm] = await Promise.all([
    publicClient.readContract({ address: m.BorrowerOperations, abi: BorrowerOperationsAbi, functionName: "borrowingRate" }),
    publicClient.readContract({ address: m.BorrowerOperations, abi: BorrowerOperationsAbi, functionName: "minNetDebt" }),
    publicClient.readContract({ address: m.BorrowerOperations, abi: BorrowerOperationsAbi, functionName: "interestRateManager" }),
  ]);
  const interestBps = Number(await publicClient.readContract({ address: irm, abi: InterestRateManagerAbi, functionName: "interestRate" }));
  const price = await publicClient.readContract({ address: m.PriceFeed, abi: PriceFeedAbi, functionName: "fetchPrice" }).catch(() => undefined);
  if (price === undefined) return { borrowingRate, minNetDebt, interestBps };
  const [recovery, tcr] = await Promise.all([
    publicClient.readContract({ address: m.TroveManager, abi: TroveManagerAbi, functionName: "checkRecoveryMode", args: [price] }),
    publicClient.readContract({ address: m.TroveManager, abi: TroveManagerAbi, functionName: "getTCR", args: [price] }),
  ]);
  return { price, recovery, tcr, borrowingRate, minNetDebt, interestBps };
}

export type Trove = {
  status: TroveStatus;
  coll: bigint; // incl. pending redistribution
  principal: bigint; // incl. pending; this is what NICR (sorted list key) is computed from
  debt: bigint; // principal + accrued interest (what ICR and liquidation use)
  interestBps: number;
  maxBorrowingCapacity: bigint;
};

export async function readTrove(m: MezoProtocol, who: Address): Promise<Trove> {
  const tm = m.TroveManager;
  const [st, dc, rate, cap] = await Promise.all([
    publicClient.readContract({ address: tm, abi: TroveManagerAbi, functionName: "getTroveStatus", args: [who] }),
    publicClient.readContract({ address: tm, abi: TroveManagerAbi, functionName: "getEntireDebtAndColl", args: [who] }),
    publicClient.readContract({ address: tm, abi: TroveManagerAbi, functionName: "getTroveInterestRate", args: [who] }),
    publicClient.readContract({ address: tm, abi: TroveManagerAbi, functionName: "getTroveMaxBorrowingCapacity", args: [who] }),
  ]);
  const [coll, principal, interest] = dc;
  return { status: STATUS[st] ?? "nonExistent", coll, principal, debt: principal + interest, interestBps: Number(rate), maxBorrowingCapacity: cap };
}

/** Collateral ratio, 1e18 = 100% (LiquityMath._computeCR). */
export const icr = (coll: bigint, debt: bigint, price: bigint) => (debt === 0n ? 0n : (coll * price) / debt);
/** Price at which the trove hits MCR (110%) and becomes liquidatable, 18 decimals. */
export const troveLiqPrice = (coll: bigint, debt: bigint) => (coll === 0n ? 0n : (MCR * debt) / coll);
/** Collateral needed for a target ICR, rounded up to 1e12 wei (0.000001 BTC). */
export const collForIcr = (debt: bigint, price: bigint, target: bigint) => {
  if (price === 0n) return 0n;
  const raw = (debt * target + price - 1n) / price;
  const step = 10n ** 12n;
  return ((raw + step - 1n) / step) * step;
};

/** openTrove economics (BorrowerOperations._openTrove): the fee is skipped in recovery mode. */
export function openTroveQuote(p: Protocol, borrow: bigint, coll: bigint) {
  const fee = p.recovery ? 0n : (borrow * p.borrowingRate) / WAD;
  const netDebt = borrow + fee;
  const debt = netDebt + GAS_COMPENSATION; // composite debt = principal at open
  const ratio = p.price ? icr(coll, debt, p.price) : undefined;
  return { fee, netDebt, debt, principal: debt, icr: ratio, liq: troveLiqPrice(coll, debt) };
}

const SECONDS_PER_YEAR = 31_556_952n; // InterestRateMath.SECONDS_IN_A_YEAR (365.2425 days)
const MAX_ACCRUAL_SECONDS = 3_600n; // headroom for interest accrued between reading the trove and the tx landing

/** withdrawMUSD economics (BorrowerOperations._adjustTrove, debt increase). Not allowed in recovery mode unless ICR rises,
 *  which a pure debt increase can never do. */
export function withdrawQuote(p: Protocol, t: Trove, amount: bigint) {
  const fee = p.recovery ? 0n : (amount * p.borrowingRate) / WAD;
  const debt = t.debt + amount + fee;
  const principal = t.principal + amount + fee;
  // Max must survive the gap between this read and inclusion: interest accrues on-chain before the capacity check
  // (debt grows ~principal·rate per second), so budget one hour of interest. It must also keep ICR ≥ MCR at the
  // current price, because maxBorrowingCapacity is fixed at the open-time price and does not track a falling price.
  const projected = t.debt + (t.principal * BigInt(t.interestBps) * MAX_ACCRUAL_SECONDS) / (10_000n * SECONDS_PER_YEAR);
  const capRoom = t.maxBorrowingCapacity > projected ? t.maxBorrowingCapacity - projected : 0n; // capacity >= debt + amount + fee
  const mcrDebt = p.price ? (t.coll * p.price) / MCR : undefined;
  const mcrRoom = mcrDebt === undefined ? capRoom : mcrDebt > projected ? mcrDebt - projected : 0n;
  const room = capRoom < mcrRoom ? capRoom : mcrRoom;
  const maxAmount = (room * WAD) / (WAD + p.borrowingRate);
  return { fee, debt, principal, maxAmount, icr: p.price ? icr(t.coll, debt, p.price) : undefined, liq: troveLiqPrice(t.coll, debt) };
}

/** repayMUSD limits: net debt after repay (debt − 200 − repay) must stay ≥ minNetDebt; closing needs closeTrove. */
export function repayQuote(p: Protocol, t: Trove, amount: bigint) {
  const floor = GAS_COMPENSATION + p.minNetDebt;
  const maxRepay = t.debt > floor ? t.debt - floor : 0n;
  const interest = t.debt - t.principal; // repay pays accrued interest first (InterestRateMath.calculateDebtAdjustment)
  const principal = t.principal - (amount > interest ? amount - interest : 0n);
  return { maxRepay, debt: t.debt - amount, principal };
}

export type Hints = { upper: Address; lower: Address; nicr: bigint };

/** Insert-position hints for SortedTroves, computed client-side: HintHelpers.getApproxHint → SortedTroves.findInsertPosition.
 *  NICR = coll × 1e20 / principal (HintHelpers.computeNominalCR). numTrials ≈ 15·√n per the Liquity guidance. */
export async function computeHints(m: MezoProtocol, coll: bigint, principal: bigint): Promise<Hints> {
  const nicr = await publicClient.readContract({ address: m.HintHelpers, abi: HintHelpersAbi, functionName: "computeNominalCR", args: [coll, principal] });
  const n = await publicClient.readContract({ address: m.TroveManager, abi: TroveManagerAbi, functionName: "getTroveOwnersCount" });
  const trials = BigInt(Math.min(400, Math.max(15, Math.ceil(15 * Math.sqrt(Number(n))))));
  const seed = BigInt(Math.floor(Math.random() * 2 ** 48));
  const [hint] = await publicClient.readContract({ address: m.HintHelpers, abi: HintHelpersAbi, functionName: "getApproxHint", args: [nicr, trials, seed] });
  const [upper, lower] = await publicClient.readContract({ address: m.SortedTroves, abi: SortedTrovesAbi, functionName: "findInsertPosition", args: [nicr, hint, hint] });
  return { upper, lower, nicr };
}
