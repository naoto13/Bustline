// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

/// @dev Minimal MUSD-side interfaces (mezo-org/musd @ da7888a). Only what this test calls.
interface IMusdPriceFeed {
    function fetchPrice() external view returns (uint256);
    function oracle() external view returns (address);
}

interface IMusdBorrowerOperations {
    function openTrove(uint256 debtAmount, address upperHint, address lowerHint) external payable;
    function minNetDebt() external view returns (uint256);
}

interface IMusdTroveManager {
    function getCurrentICR(address borrower, uint256 price) external view returns (uint256);
    function getTroveStatus(address borrower) external view returns (uint256);
    function getTroveDebt(address borrower) external view returns (uint256);
    function checkRecoveryMode(uint256 price) external view returns (bool);
}

interface IMusdStabilityPool {
    function provideToSP(uint256 amount) external;
    function withdrawFromSP(uint256 amount) external;
    function getCompoundedMUSDDeposit(address depositor) external view returns (uint256);
}

interface IMusdSortedTroves {
    function getLast() external view returns (address);
    function contains(address id) external view returns (bool);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice Chainlink-compatible stand-in for the Skip oracle precompile. Meant to be `vm.etch`-ed onto
///         0x7b7c…0015. `vm.etch` copies runtime code only: `DECIMALS` is an immutable (baked into the runtime
///         bytecode, so it survives the etch); the price lives in storage slot 0 and must be set via `setPrice`
///         on the etched address AFTER the etch. `updatedAt` is always `block.timestamp`, so PriceFeed's 60 s
///         staleness check can never trip regardless of warps.
contract MockSkipAggregator {
    uint8 public immutable DECIMALS;
    int256 public answer; // slot 0

    constructor(uint8 decimals_) {
        DECIMALS = decimals_;
    }

    function setPrice(int256 a) external {
        answer = a;
    }

    function decimals() external view returns (uint8) {
        return DECIMALS;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

/// @notice Wave 2 pre-check (spec 8.1): can the MUSD protocol (PriceFeed / BorrowerOperations / StabilityPool)
///         run on an anvil fork of Mezo testnet if the Skip precompile is replaced by a mock via `vm.etch`?
///         Run with MEZO_FORK_URL. Never broadcasts.
contract MezoPrimitivesForkTest is Test {
    address constant SKIP = 0x7b7c000000000000000000000000000000000015;
    address constant MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;
    address constant BORROWER_OPS = 0xCdF7028ceAB81fA0C6971208e83fa7872994beE5;
    address constant STABILITY_POOL = 0x1CCA7E410eE41739792eA0A24e00349Dd247680e;
    address constant PRICE_FEED = 0x86bCF0841622a5dAC14A313a15f96A95421b9366;
    address constant TROVE_MANAGER = 0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0;
    address constant SORTED_TROVES = 0x722E4D24FD6Ff8b0AC679450F3D91294607268fA;

    uint256 constant MCR = 1.1e18;

    IMusdPriceFeed pf = IMusdPriceFeed(PRICE_FEED);
    IMusdBorrowerOperations bo = IMusdBorrowerOperations(BORROWER_OPS);
    IMusdTroveManager tm = IMusdTroveManager(TROVE_MANAGER);
    IMusdStabilityPool sp = IMusdStabilityPool(STABILITY_POOL);
    IMusdSortedTroves st = IMusdSortedTroves(SORTED_TROVES);

    address borrower = makeAddr("borrower");

    function setUp() public {
        string memory url = vm.envOr("MEZO_FORK_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true);
        vm.createSelectFork(url);
        require(block.chainid == 31611, "not a Mezo testnet fork");
        vm.deal(borrower, 100 ether);
    }

    // --- helpers ---------------------------------------------------------------------------------------------

    function _etchSkip(uint8 decimals_, int256 price) internal {
        MockSkipAggregator m = new MockSkipAggregator(decimals_);
        vm.etch(SKIP, address(m).code);
        MockSkipAggregator(SKIP).setPrice(price);
    }

    /// @dev Price (18 dp) at which the currently-lowest trove sits exactly at `targetIcr`. ICR is linear in price.
    function _priceForLowestIcr(uint256 refPrice, uint256 targetIcr) internal view returns (uint256) {
        uint256 icrAtRef = tm.getCurrentICR(st.getLast(), refPrice);
        return refPrice * targetIcr / icrAtRef;
    }

    // --- 1. before etch --------------------------------------------------------------------------------------

    /// The RPC reports code at the precompile address, but it is a stub that STATICCALLs itself (only the native
    /// precompile on the real node intercepts it). In a fork the stub recurses and reverts.
    function test_fork_beforeEtch_fetchPriceReverts() public {
        assertEq(pf.oracle(), SKIP, "PriceFeed.oracle is the Skip precompile");
        assertGt(SKIP.code.length, 0, "stub code present on fork");
        vm.expectRevert();
        pf.fetchPrice();
    }

    function test_fork_beforeEtch_openTroveReverts() public {
        vm.prank(borrower);
        vm.expectRevert();
        bo.openTrove{ value: 1 ether }(2000e18, address(0), address(0));
    }

    // --- 2. fetchPrice after etch ----------------------------------------------------------------------------

    function test_fork_etch_fetchPrice_18dp() public {
        _etchSkip(18, 80_000e18);
        assertEq(pf.fetchPrice(), 80_000e18);
        vm.warp(block.timestamp + 3600); // updatedAt follows block.timestamp → never stale
        assertEq(pf.fetchPrice(), 80_000e18);
    }

    function test_fork_etch_fetchPrice_8dp_normalized() public {
        _etchSkip(8, 80_000e8);
        assertEq(pf.fetchPrice(), 80_000e18, "PriceFeed scales 8dp to 18dp");
    }

    // --- 3a. openTrove ---------------------------------------------------------------------------------------

    function test_fork_etch_openTrove() public {
        // Live testnet lowest trove is ~109% at the live price; use 2x to stay well clear of MCR / recovery mode.
        _etchSkip(18, 160_000e18);
        assertFalse(tm.checkRecoveryMode(160_000e18));

        uint256 before = IERC20Min(MUSD).balanceOf(borrower);
        vm.prank(borrower);
        bo.openTrove{ value: 1 ether }(2000e18, address(0), address(0));

        assertEq(tm.getTroveStatus(borrower), 1, "trove active");
        assertEq(IERC20Min(MUSD).balanceOf(borrower) - before, 2000e18, "borrower got MUSD");
        assertGe(tm.getTroveDebt(borrower), 2000e18 + 200e18, "debt incl. fee + gas comp");
        assertTrue(st.contains(borrower), "inserted into SortedTroves with (0,0) hints");
    }

    // --- 3b. provideToSP -> withdrawFromSP -------------------------------------------------------------------

    function test_fork_etch_stabilityPool_provideAndWithdraw() public {
        _etchSkip(18, 160_000e18);
        vm.startPrank(borrower);
        bo.openTrove{ value: 1 ether }(2000e18, address(0), address(0));
        IERC20Min(MUSD).approve(STABILITY_POOL, type(uint256).max);
        sp.provideToSP(1500e18);
        assertEq(sp.getCompoundedMUSDDeposit(borrower), 1500e18);
        assertEq(IERC20Min(MUSD).balanceOf(borrower), 500e18);

        sp.withdrawFromSP(600e18);
        assertEq(sp.getCompoundedMUSDDeposit(borrower), 900e18);
        assertEq(IERC20Min(MUSD).balanceOf(borrower), 1100e18);
        vm.stopPrank();
    }

    // --- 3c. withdraw blocked while lowest trove ICR < MCR ---------------------------------------------------

    function test_fork_etch_withdrawBlockedWhenLowestTroveUnderMcr() public {
        uint256 high = 160_000e18;
        _etchSkip(18, int256(high));
        vm.startPrank(borrower);
        bo.openTrove{ value: 1 ether }(2000e18, address(0), address(0));
        IERC20Min(MUSD).approve(STABILITY_POOL, type(uint256).max);
        sp.provideToSP(1500e18);
        vm.stopPrank();

        address lowest = st.getLast();
        assertGe(tm.getCurrentICR(lowest, high), MCR, "lowest trove healthy at high price");

        uint256 low = _priceForLowestIcr(high, 1.05e18);
        MockSkipAggregator(SKIP).setPrice(int256(low));
        assertEq(st.getLast(), lowest, "price change does not reorder (NICR-sorted)");
        assertLt(tm.getCurrentICR(lowest, low), MCR, "lowest trove now under MCR");
        assertFalse(tm.checkRecoveryMode(low), "still normal mode");

        vm.startPrank(borrower);
        vm.expectRevert(bytes("StabilityPool: Cannot withdraw while there are troves with ICR < MCR"));
        sp.withdrawFromSP(1);
        sp.withdrawFromSP(0); // collateral-gain claim is not gated
        assertEq(sp.getCompoundedMUSDDeposit(borrower), 1500e18);
        vm.stopPrank();

        // Restoring the price unblocks it again.
        MockSkipAggregator(SKIP).setPrice(int256(high));
        vm.prank(borrower);
        sp.withdrawFromSP(1);
    }

    /// Live-state observation: at the live price (read from the real node via the RPC, ~78.3k), the testnet's
    /// lowest trove is already under MCR, so `withdrawFromSP(amount > 0)` on the real testnet is blocked right now.
    function test_fork_etch_liveLikePrice_lowestTroveUnderMcr() public {
        uint256 live = 78_293e18;
        _etchSkip(18, int256(live));
        uint256 icr = tm.getCurrentICR(st.getLast(), live);
        emit log_named_uint("lowest trove ICR at ~live price (1e18=100%)", icr);
        assertLt(icr, MCR, "live testnet: SP withdrawals (amount>0) are currently blocked");
    }
}

// =============================================================================================================
// Trove adjust: withdrawMUSD / repayMUSD as the Bustline frontend calls them
// (frontend/src/lib/mezo.ts computeHints / withdrawQuote / repayQuote, frontend/src/components/Funding.tsx).
// =============================================================================================================

interface IMusdBorrowerOpsAdjust {
    function openTrove(uint256 debtAmount, address upperHint, address lowerHint) external payable;
    function withdrawMUSD(uint256 amount, address upperHint, address lowerHint) external;
    function repayMUSD(uint256 amount, address upperHint, address lowerHint) external;
    function borrowingRate() external view returns (uint256);
    function minNetDebt() external view returns (uint256);
}

interface IMusdTroveManagerAdjust {
    function getTroveStatus(address) external view returns (uint256);
    function getTroveDebt(address) external view returns (uint256);
    function getTrovePrincipal(address) external view returns (uint256);
    function getTroveInterestOwed(address) external view returns (uint256);
    function getTroveInterestRate(address) external view returns (uint16);
    function getTroveColl(address) external view returns (uint256);
    function getTroveMaxBorrowingCapacity(address) external view returns (uint256);
    function getTroveOwnersCount() external view returns (uint256);
    function getNominalICR(address) external view returns (uint256);
    function getCurrentICR(address, uint256 price) external view returns (uint256);
    function checkRecoveryMode(uint256 price) external view returns (bool);
    function getEntireDebtAndColl(address)
        external
        view
        returns (uint256 coll, uint256 principal, uint256 interest, uint256 pColl, uint256 pPrincipal, uint256 pInt);
}

interface IMusdHintHelpers {
    function computeNominalCR(uint256 coll, uint256 debt) external pure returns (uint256);
    function getApproxHint(uint256 cr, uint256 numTrials, uint256 seed)
        external
        view
        returns (address hint, uint256 diff, uint256 latestSeed);
}

interface IMusdSortedTrovesAdjust {
    function contains(address) external view returns (bool);
    function findInsertPosition(uint256 nicr, address prevId, address nextId) external view returns (address, address);
    function validInsertPosition(uint256 nicr, address prevId, address nextId) external view returns (bool);
    function getPrev(address) external view returns (address);
    function getNext(address) external view returns (address);
}

interface IAggregatorLike {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice open → withdrawMUSD → repayMUSD on a Mezo testnet fork, with hints and limits computed exactly the way the
///         frontend computes them. Run with MEZO_FORK_URL. Never broadcasts.
contract MezoTroveAdjustForkTest is Test {
    address constant SKIP = 0x7b7c000000000000000000000000000000000015;
    address constant MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;
    address constant BORROWER_OPS = 0xCdF7028ceAB81fA0C6971208e83fa7872994beE5;
    address constant TROVE_MANAGER = 0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0;
    address constant SORTED_TROVES = 0x722E4D24FD6Ff8b0AC679450F3D91294607268fA;
    address constant HINT_HELPERS = 0x4e4cBA3779d56386ED43631b4dCD6d8EacEcBCF6;

    uint256 constant WAD = 1e18;
    uint256 constant GAS_COMP = 200e18;
    uint256 constant SECONDS_IN_A_YEAR = 31_556_952; // InterestRateMath
    uint256 constant PRICE = 160_000e18; // well above the live ~78k: the live lowest trove is ~109% there
    uint256 constant COLL = 1 ether;
    uint256 constant OPEN_BORROW = 2000e18;
    uint256 constant SEED = 0xb057;

    string constant ERR_CAPACITY = "BorrowerOps: An operation that exceeds maxBorrowingCapacity is not permitted";
    string constant ERR_MCR = "BorrowerOps: An operation that would result in ICR < MCR is not permitted";
    string constant ERR_MIN_NET_DEBT = "BorrowerOps: Trove's net debt must be greater than minimum";

    IMusdBorrowerOpsAdjust bo = IMusdBorrowerOpsAdjust(BORROWER_OPS);
    IMusdTroveManagerAdjust tm = IMusdTroveManagerAdjust(TROVE_MANAGER);
    IMusdSortedTrovesAdjust st = IMusdSortedTrovesAdjust(SORTED_TROVES);
    IMusdHintHelpers hh = IMusdHintHelpers(HINT_HELPERS);
    IERC20Min musd = IERC20Min(MUSD);

    address borrower = makeAddr("adjust-borrower");
    uint256 rate; // borrowingRate, 1e18 = 100%
    uint256 minNetDebt;

    struct UiTrove {
        uint256 coll;
        uint256 principal;
        uint256 debt; // principal + interest, as readTrove() reports it
        uint256 cap;
    }

    struct Hints {
        address upper;
        address lower;
        uint256 nicr;
    }

    function setUp() public {
        string memory url = vm.envOr("MEZO_FORK_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true);
        vm.createSelectFork(url);
        require(block.chainid == 31611, "not a Mezo testnet fork");
        vm.deal(borrower, 100 ether);

        MockSkipAggregator m = new MockSkipAggregator(18);
        vm.etch(SKIP, address(m).code);
        MockSkipAggregator(SKIP).setPrice(int256(PRICE));
        assertFalse(tm.checkRecoveryMode(PRICE), "normal mode at the test price");

        rate = bo.borrowingRate();
        minNetDebt = bo.minNetDebt();
        assertEq(rate, 1e15, "borrowing fee 0.1%");
        assertEq(minNetDebt, 1800e18, "min net debt 1800");
    }

    // --- frontend mirrors (frontend/src/lib/mezo.ts) -------------------------------------------------------------

    /// readTrove(): coll / principal / debt from getEntireDebtAndColl (incl. pending), capacity from TroveManager.
    function _readTrove(address who) internal view returns (UiTrove memory t) {
        (uint256 coll, uint256 principal, uint256 interest,,,) = tm.getEntireDebtAndColl(who);
        t = UiTrove(coll, principal, principal + interest, tm.getTroveMaxBorrowingCapacity(who));
    }

    /// computeHints(): computeNominalCR → getApproxHint(nicr, clamp(ceil(15·√n), 15, 400), seed) →
    /// findInsertPosition(nicr, hint, hint). The frontend uses a random seed; a fixed one here.
    function _computeHints(uint256 coll, uint256 principal) internal view returns (Hints memory h) {
        h.nicr = hh.computeNominalCR(coll, principal);
        uint256 n = tm.getTroveOwnersCount();
        uint256 trials = _ceilSqrt(225 * n); // ceil(15·√n) = ceil(√(225n))
        if (trials < 15) trials = 15;
        if (trials > 400) trials = 400;
        (address hint,,) = hh.getApproxHint(h.nicr, trials, SEED);
        (h.upper, h.lower) = st.findInsertPosition(h.nicr, hint, hint);
    }

    /// withdrawQuote(): fee, principal after, and the "Max" amount = (cap − debt) · 1e18 / (1e18 + rate).
    function _withdrawQuote(UiTrove memory t, uint256 amount)
        internal
        view
        returns (uint256 fee, uint256 principalAfter, uint256 maxAmount)
    {
        fee = amount * rate / WAD;
        principalAfter = t.principal + amount + fee;
        uint256 room = t.cap > t.debt ? t.cap - t.debt : 0;
        maxAmount = room * WAD / (WAD + rate);
    }

    /// repayQuote(): maxRepay = debt − 200 − minNetDebt; interest is paid first, then principal.
    function _repayQuote(UiTrove memory t, uint256 amount) internal view returns (uint256 maxRepay, uint256 principalAfter) {
        uint256 floor = GAS_COMP + minNetDebt;
        maxRepay = t.debt > floor ? t.debt - floor : 0;
        uint256 interest = t.debt - t.principal;
        principalAfter = t.principal - (amount > interest ? amount - interest : 0);
    }

    function _ceilSqrt(uint256 x) internal pure returns (uint256 r) {
        if (x == 0) return 0;
        r = x;
        uint256 y = (x + 1) / 2;
        while (y < r) {
            r = y;
            y = (x / y + y) / 2;
        }
        if (r * r < x) r += 1;
    }

    // --- actions with frontend-computed hints --------------------------------------------------------------------

    function _open() internal returns (Hints memory h) {
        uint256 fee = OPEN_BORROW * rate / WAD;
        uint256 principal = OPEN_BORROW + fee + GAS_COMP; // openTroveQuote().principal
        h = _computeHints(COLL, principal);
        assertTrue(st.validInsertPosition(h.nicr, h.upper, h.lower), "open hints valid");
        vm.prank(borrower);
        bo.openTrove{ value: COLL }(OPEN_BORROW, h.upper, h.lower);
        assertEq(tm.getNominalICR(borrower), h.nicr, "on-chain NICR == frontend NICR (open)");
    }

    function _withdrawHints(uint256 amount) internal returns (Hints memory h) {
        (, uint256 principalAfter,) = _withdrawQuote(_readTrove(borrower), amount);
        h = _computeHints(COLL, principalAfter);
        _logSelfHint(h);
    }

    function _repayHints(uint256 amount) internal returns (Hints memory h) {
        (, uint256 principalAfter) = _repayQuote(_readTrove(borrower), amount);
        h = _computeHints(COLL, principalAfter);
        _logSelfHint(h);
    }

    /// computeHints() does not exclude the trove's own address. reInsert() removes the node first, so such a hint is
    /// invalid at insert time and SortedTroves falls back to a list walk (more gas, no revert). Logged, not asserted.
    function _logSelfHint(Hints memory h) internal {
        if (h.upper == borrower || h.lower == borrower) emit log("note: frontend hint contains the trove itself");
    }

    function _assertSortedAround(address who) internal view {
        uint256 nicr = tm.getNominalICR(who);
        address prev = st.getPrev(who);
        address next = st.getNext(who);
        if (prev != address(0)) assertGe(tm.getNominalICR(prev), nicr, "prev NICR >= self");
        if (next != address(0)) assertLe(tm.getNominalICR(next), nicr, "next NICR <= self");
    }

    // --- 1. open → withdrawMUSD → repayMUSD ---------------------------------------------------------------------

    function test_fork_trove_openWithdrawRepay_withFrontendHints() public {
        // open
        _open();
        uint256 openFee = OPEN_BORROW * rate / WAD;
        uint256 debt0 = OPEN_BORROW + openFee + GAS_COMP; // 2202e18
        assertEq(debt0, 2202e18);
        assertEq(tm.getTroveStatus(borrower), 1, "active");
        assertEq(tm.getTroveInterestRate(borrower), 100, "1%/yr fixed at open");
        assertEq(musd.balanceOf(borrower), OPEN_BORROW, "MUSD after open");
        assertEq(tm.getTroveDebt(borrower), debt0, "debt = principal + 0.1% fee + 200 gas comp");
        assertEq(tm.getTrovePrincipal(borrower), debt0, "principal == composite debt at open");
        uint256 icr0 = tm.getCurrentICR(borrower, PRICE);
        assertEq(icr0, COLL * PRICE / debt0, "ICR after open");
        assertEq(tm.getTroveMaxBorrowingCapacity(borrower), COLL * PRICE / 1.1e18, "capacity = coll*price/110%");

        // withdrawMUSD(x)
        uint256 x = 5000e18;
        Hints memory hw = _withdrawHints(x);
        uint256 bal1 = musd.balanceOf(borrower);
        vm.prank(borrower);
        bo.withdrawMUSD(x, hw.upper, hw.lower);
        uint256 fee1 = x * rate / WAD;
        uint256 debt1 = tm.getTroveDebt(borrower);
        assertEq(musd.balanceOf(borrower) - bal1, x, "MUSD +x (fee goes to PCV, not the borrower)");
        assertEq(debt1 - debt0, x + fee1, "debt +x +0.1%");
        assertEq(tm.getTrovePrincipal(borrower), debt0 + x + fee1, "principal +x +fee");
        uint256 icr1 = tm.getCurrentICR(borrower, PRICE);
        assertLt(icr1, icr0, "ICR down");
        assertEq(icr1, COLL * PRICE / debt1, "ICR after withdraw");
        assertTrue(st.contains(borrower), "still in SortedTroves");
        assertEq(tm.getNominalICR(borrower), hw.nicr, "on-chain NICR == frontend NICR (withdraw)");
        _assertSortedAround(borrower);

        // repayMUSD(y)
        uint256 y = 3000e18;
        Hints memory hr = _repayHints(y);
        uint256 bal2 = musd.balanceOf(borrower);
        vm.prank(borrower);
        bo.repayMUSD(y, hr.upper, hr.lower);
        uint256 debt2 = tm.getTroveDebt(borrower);
        assertEq(bal2 - musd.balanceOf(borrower), y, "MUSD -y");
        assertEq(debt1 - debt2, y, "debt -y");
        assertGe(debt2 - GAS_COMP, minNetDebt, "net debt stays >= 1800");
        assertGt(tm.getCurrentICR(borrower, PRICE), icr1, "ICR up");
        assertEq(tm.getNominalICR(borrower), hr.nicr, "on-chain NICR == frontend NICR (repay)");
        _assertSortedAround(borrower);

        // A repay that would push net debt under 1800 reverts.
        uint256 tooMuch = debt2 - GAS_COMP - minNetDebt + 1e18;
        vm.prank(borrower);
        vm.expectRevert(bytes(ERR_MIN_NET_DEBT));
        bo.repayMUSD(tooMuch, address(0), address(0));
    }

    // --- 2. repay limit: debt − 200 − minNetDebt ------------------------------------------------------------------

    function test_fork_trove_repayMax_matchesFrontendLimit() public {
        _open();
        UiTrove memory t = _readTrove(borrower);
        (uint256 maxRepay,) = _repayQuote(t, 0);
        assertEq(maxRepay, 202e18, "2202 - 200 - 1800");

        uint256 snap = vm.snapshotState();
        vm.prank(borrower);
        vm.expectRevert(bytes(ERR_MIN_NET_DEBT));
        bo.repayMUSD(maxRepay + 1, address(0), address(0));

        Hints memory h = _repayHints(maxRepay);
        vm.prank(borrower);
        bo.repayMUSD(maxRepay, h.upper, h.lower);
        assertEq(tm.getTroveDebt(borrower) - GAS_COMP, minNetDebt, "net debt exactly at the minimum");
        assertEq(tm.getNominalICR(borrower), h.nicr, "NICR (repay max)");
        vm.revertToState(snap);
    }

    // --- 3. withdraw limit: frontend "Max" vs maxBorrowingCapacity / MCR -----------------------------------------

    /// After the price rises, capacity (frozen at the open price) is the binding limit, not MCR. In the same block as
    /// the frontend's read, the frontend Max passes and the exact on-chain boundary + 1 reverts on capacity.
    function test_fork_trove_withdrawMax_capacityBound_sameBlock() public {
        _open();
        MockSkipAggregator(SKIP).setPrice(int256(PRICE * 2));

        UiTrove memory t = _readTrove(borrower);
        (,, uint256 uiMax) = _withdrawQuote(t, 0);
        uint256 room = t.cap - t.debt;
        // exact on-chain boundary: largest a with a + floor(a·rate/1e18) <= room
        uint256 b = uiMax;
        while ((b + 1) + (b + 1) * rate / WAD <= room) b++;
        emit log_named_uint("frontend Max (wei)", uiMax);
        emit log_named_uint("on-chain boundary - frontend Max (wei)", b - uiMax);
        assertLe(b - uiMax, 1, "frontend Max is at most 1 wei under the boundary");

        uint256 snap = vm.snapshotState();
        Hints memory h = _withdrawHints(uiMax);
        vm.prank(borrower);
        bo.withdrawMUSD(uiMax, h.upper, h.lower);
        assertLe(tm.getTroveDebt(borrower), t.cap, "debt within capacity");
        assertEq(tm.getNominalICR(borrower), h.nicr, "NICR (withdraw max)");
        vm.revertToState(snap);

        vm.prank(borrower);
        bo.withdrawMUSD(b, address(0), address(0)); // boundary itself passes
        vm.revertToState(snap);

        vm.prank(borrower);
        vm.expectRevert(bytes(ERR_CAPACITY));
        bo.withdrawMUSD(b + 1, address(0), address(0));
    }

    /// The frontend reads debt at block N; the tx lands at a later timestamp and interest (1%/yr) has grown the debt.
    /// When capacity binds, the frontend Max then exceeds capacity and reverts.
    function test_fork_trove_withdrawMax_capacityBound_revertsAfterInterestAccrues() public {
        _open();
        MockSkipAggregator(SKIP).setPrice(int256(PRICE * 2));

        UiTrove memory t = _readTrove(borrower);
        (,, uint256 uiMax) = _withdrawQuote(t, 0);
        vm.warp(block.timestamp + 12); // one or two blocks later
        assertGt(tm.getTroveDebt(borrower), t.debt, "interest accrued since the read");

        vm.prank(borrower);
        vm.expectRevert(bytes(ERR_CAPACITY));
        bo.withdrawMUSD(uiMax, address(0), address(0));
    }

    /// After the price falls, MCR (at the current price) binds before capacity: the frontend Max overshoots and reverts
    /// on MCR, and withdrawQuote().icr < 110% at the same amount (Funding.tsx icrCheck blocks submission).
    function test_fork_trove_withdrawMax_mcrBound_whenPriceFalls() public {
        _open();
        uint256 low = PRICE * 9 / 10;
        MockSkipAggregator(SKIP).setPrice(int256(low));

        UiTrove memory t = _readTrove(borrower);
        (uint256 fee,, uint256 uiMax) = _withdrawQuote(t, 0);
        fee = uiMax * rate / WAD;
        uint256 uiIcr = t.coll * low / (t.debt + uiMax + fee);
        assertLt(uiIcr, 1.1e18, "frontend shows ICR < 110% for its own Max -> blocked in the UI");

        vm.prank(borrower);
        vm.expectRevert(bytes(ERR_MCR));
        bo.withdrawMUSD(uiMax, address(0), address(0));
    }

    // --- 4. interest accrual (warp) then repay ---------------------------------------------------------------------

    function test_fork_trove_repayAfterWarp_interestPaidFirst() public {
        _open();
        uint256 principal0 = tm.getTrovePrincipal(borrower);
        uint256 interest;
        {
            uint256 icr0 = tm.getCurrentICR(borrower, PRICE);
            vm.warp(block.timestamp + SECONDS_IN_A_YEAR); // one year

            // the etched price source stays fresh across the warp (PriceFeed reverts on > 60 s staleness otherwise)
            (, int256 ans,, uint256 updatedAt,) = IAggregatorLike(SKIP).latestRoundData();
            assertEq(updatedAt, block.timestamp, "mock updatedAt == block.timestamp");
            assertEq(uint256(ans), PRICE);

            interest = principal0 * 100 * SECONDS_IN_A_YEAR / (10_000 * SECONDS_IN_A_YEAR);
            assertEq(interest, 22.02e18, "1% of 2202");
            assertEq(tm.getTroveDebt(borrower), principal0 + interest, "debt = principal + simple interest");
            assertEq(_readTrove(borrower).debt, principal0 + interest, "frontend readTrove debt includes interest");
            assertLt(tm.getCurrentICR(borrower, PRICE), icr0, "ICR fell with accrued interest");
            (uint256 maxRepay0,) = _repayQuote(_readTrove(borrower), 0);
            assertEq(maxRepay0, 202e18 + interest, "repay room grows with interest");
        }

        // repay y > interest: interest first, then principal
        uint256 y = 100e18;
        {
            Hints memory h = _repayHints(y);
            uint256 bal = musd.balanceOf(borrower);
            vm.prank(borrower);
            bo.repayMUSD(y, h.upper, h.lower);
            assertEq(bal - musd.balanceOf(borrower), y, "MUSD -y");
            assertEq(tm.getNominalICR(borrower), h.nicr, "NICR (repay after warp)");
        }
        assertEq(tm.getTroveDebt(borrower), principal0 + interest - y, "debt -y");
        assertEq(tm.getTroveInterestOwed(borrower), 0, "interest paid first");
        assertEq(tm.getTrovePrincipal(borrower), principal0 - (y - interest), "principal -(y - interest)");
        _assertSortedAround(borrower);

        // the frontend limit after interest is still exact
        (uint256 maxRepay,) = _repayQuote(_readTrove(borrower), 0);
        uint256 snap = vm.snapshotState();
        vm.prank(borrower);
        bo.repayMUSD(maxRepay, address(0), address(0));
        assertEq(tm.getTroveDebt(borrower) - GAS_COMP, minNetDebt);
        vm.revertToState(snap);
        vm.prank(borrower);
        vm.expectRevert(bytes(ERR_MIN_NET_DEBT));
        bo.repayMUSD(maxRepay + 1, address(0), address(0));
    }
}
