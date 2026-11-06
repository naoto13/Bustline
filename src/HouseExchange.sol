// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IPriceOracle } from "./interfaces/IPriceOracle.sol";
import { IMezoStabilityPool, IMezoPriceFeed, IMezoSortedTroves, IMezoTroveManager } from "./interfaces/IMezo.sol";
import { ImpactLib } from "./libraries/ImpactLib.sol";
import { RebateToken } from "./RebateToken.sol";
import { RebateStaking } from "./RebateStaking.sol";

/// @title HouseExchange — single-market (BTC/USD) synthetic perp on Mezo, margined in MUSD.
/// @notice The house (counterparty) starts at 0 MUSD and is funded ONLY by trader losses (no external LP deposits).
///         Winners are paid from house cash; when the house cannot pay, the remainder joins a FIFO payout queue that
///         later losses repay (`harvest`). Realised losses mint a non-transferable rebate token that can be staked
///         for MUSD revenue share. No funding, no spread; winning closes pay an asymmetric impact haircut + win fee.
///         Orders are 2-step: a request escrows margin, and a keeper fills it at an oracle update strictly AFTER the
///         request (blocks "see the price, then trade at the stale oracle" attacks, cf. Mezo's Velar post-mortem).
///         v3: idle house MUSD (`houseCash` only — never margin/escrow) can be deposited into MUSD's Stability Pool
///         (`rebalance`); winners are topped up from it; its BTC collateral gains go to stakers (`forwardBtc`).
///         v3.1: emergency pause + a protocol fee on winning profit to `treasury`.
///         PAUSE — `pause()` by `guardian` or owner (immediate); `unpause()` by owner only (= the timelock).
///           Blocked while paused (everything that consumes the exchange oracle price or adds risk / moves house cash
///           out to stakers): `requestOpen`, `executeOrder` (all fills, incl. queued closes), `liquidate`,
///           `sweepExcess`, and Stability Pool DEPOSITS (`rebalanceAction` never returns action 1, so `rebalance`
///           only withdraws or no-ops).
///           Allowed while paused: `requestClose` (queued; filled only after unpause — if it expires meanwhile it can
///           be cleared with `cancelExpired` and the position stays open), `cancelExpired` (refunds), `harvest`
///           (pays the queue from cash / SP withdrawals; never reads the exchange oracle), `rebalance` withdrawals,
///           `forwardBtc`, `pushPrice`, all views, all owner admin functions, and RebateStaking stake/unstake/claim.
///         PROTOCOL FEE — on a winning close: `gain` = impact-adjusted gain (the win-fee base);
///           winFee = gain*winFeeBps/BPS (stakers), protocolFee = gain*protocolFeeBps/BPS (treasury),
///           winner gets margin + gain − winFee − protocolFee. Fees are charged only on an immediate full settlement
///           (queue empty and house cash — topped up from the Stability Pool if needed — covers payout + both fees).
///           Otherwise no fee at all: the winner is owed the whole gain (paid what cash allows, the rest queued) and
///           queued amounts are never charged later at harvest.
/// @dev TESTNET DEMO / UNAUDITED. Independent implementation; mechanism inspired by public docs (see README).
contract HouseExchange is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    enum OrderKind {
        Open,
        Close
    }

    enum OrderStatus {
        None,
        Pending,
        Executed,
        Cancelled
    }

    struct Order {
        address trader;
        OrderKind kind;
        OrderStatus status;
        bool isLong;
        uint64 createdAt;
        uint256 margin; // Open: escrowed MUSD
        uint256 size; // Open: notional USD (WAD)
        uint256 positionId; // Close
        uint256 acceptablePrice; // 0 = any
    }

    struct Position {
        address owner;
        bool isLong;
        bool open;
        uint64 openedAt;
        uint256 margin;
        uint256 size;
        uint256 entryPrice;
    }

    struct QueueEntry {
        address to;
        uint256 amount; // remaining owed
    }

    IERC20 public immutable musd;
    IPriceOracle public oracle;
    RebateToken public immutable rebateToken;
    RebateStaking public staking;

    // ---- risk params ----
    uint256 public maxLeverage = 100; // x
    uint256 public minMargin = 10e18;
    uint256 public maxPositionSize = 1_000_000e18; // notional
    uint256 public maxOiPerSide = 10_000_000e18;
    uint256 public bustBufferDiv = 2_000; // entry/2000 = 5 bps
    uint256 public maxExecDelay = 300; // s; older pending orders can be cancelled
    // ---- fees (bps) ----
    uint256 public winFeeBps = 200; // on scaled gain
    uint256 public lossFeeBps = 200; // carved from loss (queue empty only)
    uint256 public liqFeeBps = 200; // of margin, to stakers (queue empty only)
    uint256 public liqKeeperBps = 50; // of margin, to liquidator (always)
    uint256 public protocolFeeBps = 100; // v3.1: on the same scaled gain, to `treasury`
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 500;
    address public treasury;
    address public guardian; // v3.1: may pause (not unpause)
    uint256 public houseCap = 5_000_000e18; // house cash above this (queue empty) can be swept to stakers
    ImpactLib.Params public impact = ImpactLib.Params(0.1e18, 15_000, 814.598e18, 100_000e18, 50_000);
    // ---- mint curve: flat rate while tracked house < threshold, then flat*(S/(S+H))^2 with ratcheting HWM H ----
    uint256 public mintFlatRate = 100e18; // tokens per 1 MUSD loss (WAD)
    uint256 public mintThreshold = 2_000_000e18;
    uint256 public mintDecayScale = 120_000_000e18;
    uint256 public mintHwm;

    mapping(address => bool) public isKeeper;

    // ---- Mezo Stability Pool (v3) ----
    uint256 internal constant MCR = 1.1e18; // MUSD LiquityBase.MCR
    /// @dev Gas stipend for StabilityPool.withdrawFromSP (PriceFeed + ICR check + snapshots + MUSD/BTC transfers).
    uint256 public constant SP_WITHDRAW_GAS = 1_000_000;
    /// @dev Gas stipend for each external view used in decisions (PriceFeed / SortedTroves / TroveManager / deposit).
    uint256 internal constant SP_VIEW_GAS = 300_000;
    IMezoStabilityPool public stabilityPool;
    IMezoPriceFeed public spPriceFeed;
    IMezoSortedTroves public spSortedTroves;
    IMezoTroveManager public spTroveManager;
    bool public spEnabled;
    uint256 public spMinLiquid = 50e18; // house MUSD kept on hand
    uint256 public spMaxShareBps = 5_000; // SP deposit <= this share of (houseCash + SP deposit)
    uint256 public spBandBps = 2_000; // hysteresis around spMinLiquid
    uint256 public totalBtcToStakers;

    // ---- state ----
    uint256 public houseCash; // free house MUSD (reserved for the queue first)
    uint256 public totalMargin; // margin locked in open positions
    uint256 public totalEscrow; // margin escrowed by pending open orders
    uint256 public longOi;
    uint256 public shortOi;
    uint256 public cumulativeLosses; // realised trader losses into the house
    uint256 public cumulativePaid; // paid to winners (direct + queue)
    uint256 public totalToStakers;
    uint256 public totalProtocolFees; // MUSD sent to `treasury`

    Order[] internal _orders;
    Position[] internal _positions;
    uint256[] internal _openIds;
    mapping(uint256 => uint256) internal _openIdx; // positionId => index+1 in _openIds
    mapping(uint256 => uint256) public pendingCloseOrder; // positionId => orderId+1

    QueueEntry[] internal _queue;
    uint256 public queueHead;
    uint256 public queueTotal;
    mapping(address => uint256) public queuedOf;

    // ---- events ----
    event OrderRequested(
        uint256 indexed orderId,
        address indexed trader,
        OrderKind kind,
        bool isLong,
        uint256 margin,
        uint256 size,
        uint256 positionId
    );
    event OrderCancelled(uint256 indexed orderId, string reason);
    event PositionOpened(
        uint256 indexed positionId,
        address indexed owner,
        bool isLong,
        uint256 margin,
        uint256 size,
        uint256 entryPrice,
        uint256 orderId
    );
    event PositionClosed(
        uint256 indexed positionId,
        address indexed owner,
        uint256 exitPrice,
        int256 rawPnl,
        uint256 paidNow,
        uint256 queued,
        uint256 lossToHouse
    );
    event Liquidated(
        uint256 indexed positionId,
        address indexed owner,
        address indexed liquidator,
        uint256 price,
        uint256 margin,
        uint256 keeperReward
    );
    event Queued(uint256 indexed index, address indexed to, uint256 amount);
    event QueuePaid(uint256 indexed index, address indexed to, uint256 amount, bool fullyPaid);
    event RebateMinted(address indexed to, uint256 lossBasis, uint256 amount);
    event StakerRevenue(uint256 amount);
    event KeeperSet(address keeper, bool allowed);
    event ParamsUpdated();
    event StabilityPoolSet(address stabilityPool, address priceFeed, address sortedTroves, address troveManager);
    event SpDeposited(uint256 amount);
    event SpWithdrawn(uint256 requested, uint256 received);
    event SpWithdrawBlocked(uint256 requested);
    event BtcForwarded(uint256 amount);
    event GuardianSet(address oldGuardian, address newGuardian);
    event TreasurySet(address oldTreasury, address newTreasury);
    event ProtocolFeeSet(uint256 bps);
    event ProtocolFee(uint256 amount);

    error NotKeeper();
    error BadLeverage();
    error MarginTooSmall();
    error SizeTooLarge();
    error NotPending();
    error NotYetFillable();
    error NotOwner();
    error PositionNotOpen();
    error CloseAlreadyPending();
    error NotLiquidatable();
    error UnexpectedValue();
    error NotExpired();
    error NotStabilityPool();
    error SpDepositOutstanding();
    error InsufficientGasForSp();
    error SpDepositMismatch();
    error NotGuardian();
    error BadTreasury(); // zero or this contract
    error FeeTooHigh();

    modifier onlyKeeper() {
        if (!isKeeper[msg.sender] && msg.sender != owner()) revert NotKeeper();
        _;
    }

    constructor(address musd_, address oracle_, address rebateToken_, address owner_) Ownable(owner_) {
        musd = IERC20(musd_);
        oracle = IPriceOracle(oracle_);
        rebateToken = RebateToken(rebateToken_);
        if (owner_ == address(this)) revert BadTreasury(); // treasury defaults to owner_; never this contract
        treasury = owner_;
    }

    // ===================================================================== admin

    function setStaking(address s) external onlyOwner {
        staking = RebateStaking(s);
        emit ParamsUpdated();
    }

    function setOracle(address o) external onlyOwner {
        oracle = IPriceOracle(o);
        emit ParamsUpdated();
    }

    function setKeeper(address k, bool allowed) external onlyOwner {
        isKeeper[k] = allowed;
        emit KeeperSet(k, allowed);
    }

    function setRisk(
        uint256 maxLev,
        uint256 minMargin_,
        uint256 maxPos,
        uint256 maxOi,
        uint256 bufferDiv,
        uint256 execDelay
    ) external onlyOwner {
        require(maxLev >= 1 && maxLev <= 1000, "lev");
        maxLeverage = maxLev;
        minMargin = minMargin_;
        maxPositionSize = maxPos;
        maxOiPerSide = maxOi;
        bustBufferDiv = bufferDiv;
        maxExecDelay = execDelay;
        emit ParamsUpdated();
    }

    function setFees(uint256 winFee, uint256 lossFee, uint256 liqFee, uint256 liqKeeper, uint256 cap)
        external
        onlyOwner
    {
        require(winFee <= 2_000 && lossFee <= 2_000 && liqFee + liqKeeper <= 5_000, "fee");
        (winFeeBps, lossFeeBps, liqFeeBps, liqKeeperBps, houseCap) = (winFee, lossFee, liqFee, liqKeeper, cap);
        emit ParamsUpdated();
    }

    function setImpact(ImpactLib.Params calldata p) external onlyOwner {
        require(p.baseRate < WAD, "base");
        impact = p;
        emit ParamsUpdated();
    }

    function setMintCurve(uint256 flat, uint256 threshold, uint256 decayScale) external onlyOwner {
        (mintFlatRate, mintThreshold, mintDecayScale) = (flat, threshold, decayScale);
        emit ParamsUpdated();
    }

    /// @notice Wire the MUSD Stability Pool and the contracts used for the "withdrawals blocked?" check.
    ///         Refused while this contract still has a deposit in the current pool.
    function setStabilityPool(address sp, address priceFeed_, address sortedTroves_, address troveManager_)
        external
        onlyOwner
    {
        if (spDeposit() != 0) revert SpDepositOutstanding();
        if (address(stabilityPool) != address(0) && stabilityPool.getDepositorCollateralGain(address(this)) != 0) {
            revert SpDepositOutstanding(); // call forwardBtc() first, or the old pool's BTC could not be received
        }
        stabilityPool = IMezoStabilityPool(sp);
        spPriceFeed = IMezoPriceFeed(priceFeed_);
        spSortedTroves = IMezoSortedTroves(sortedTroves_);
        spTroveManager = IMezoTroveManager(troveManager_);
        emit StabilityPoolSet(sp, priceFeed_, sortedTroves_, troveManager_);
    }

    function setSpParams(bool enabled, uint256 minLiquid, uint256 maxShareBps, uint256 bandBps) external onlyOwner {
        require(maxShareBps <= BPS && bandBps < BPS, "sp");
        (spEnabled, spMinLiquid, spMaxShareBps, spBandBps) = (enabled, minLiquid, maxShareBps, bandBps);
        emit ParamsUpdated();
    }

    /// @notice Address allowed to `pause()` (besides the owner). address(0) = none.
    function setGuardian(address g) external onlyOwner {
        emit GuardianSet(guardian, g);
        guardian = g;
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0) || t == address(this)) revert BadTreasury();
        emit TreasurySet(treasury, t);
        treasury = t;
    }

    function setProtocolFee(uint256 bps) external onlyOwner {
        if (bps > MAX_PROTOCOL_FEE_BPS) revert FeeTooHigh();
        protocolFeeBps = bps;
        emit ProtocolFeeSet(bps);
    }

    /// @notice Emergency stop, effective immediately (guardian or owner). See the contract NatSpec for the list.
    function pause() external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        _pause();
    }

    /// @notice Resume trading — owner only (the timelock in deployment), so a guardian key cannot undo a pause.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ===================================================================== price

    /// @notice Verified oracle price (WAD USD/BTC) + its publish time; reverts if stale / out of the Skip sanity bound.
    ///         Primary source: Pyth BTC/USD (PythPullOracle); fallback: SignedPriceOracle. See README "Oracle".
    function currentPrice() public view returns (uint256 p, uint256 publishTime) {
        return oracle.latest();
    }

    /// @notice Last stored price without checks (UI display only; never used for settlement).
    function lastPrice() external view returns (uint256 p, uint256 publishTime) {
        return oracle.peek();
    }

    /// @notice Push a price update (Pyth update data / signed report) without trading. msg.value pays the oracle fee.
    function pushPrice(bytes[] calldata priceUpdate) external payable {
        _pushPrice(priceUpdate);
    }

    function _pushPrice(bytes[] calldata priceUpdate) internal {
        if (priceUpdate.length == 0) {
            if (msg.value != 0) revert UnexpectedValue();
            return;
        }
        oracle.update{ value: msg.value }(priceUpdate);
    }

    // ===================================================================== orders (step 1)

    /// @notice Request a market open. Escrows `margin` MUSD; notional = margin * leverage.
    function requestOpen(bool isLong, uint256 margin, uint256 leverage, uint256 acceptablePrice)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 orderId)
    {
        if (leverage == 0 || leverage > maxLeverage) revert BadLeverage();
        if (margin < minMargin) revert MarginTooSmall();
        uint256 size = margin * leverage;
        if (size > maxPositionSize) revert SizeTooLarge();
        musd.safeTransferFrom(msg.sender, address(this), margin);
        totalEscrow += margin;
        orderId = _orders.length;
        _orders.push(
            Order(
                msg.sender,
                OrderKind.Open,
                OrderStatus.Pending,
                isLong,
                uint64(block.timestamp),
                margin,
                size,
                0,
                acceptablePrice
            )
        );
        emit OrderRequested(orderId, msg.sender, OrderKind.Open, isLong, margin, size, 0);
    }

    /// @notice Request a market close of an open position you own.
    function requestClose(uint256 positionId, uint256 acceptablePrice) external returns (uint256 orderId) {
        Position storage pos = _positions[positionId];
        if (pos.owner != msg.sender) revert NotOwner();
        if (!pos.open) revert PositionNotOpen();
        uint256 prev = pendingCloseOrder[positionId];
        if (prev != 0 && _orders[prev - 1].status == OrderStatus.Pending) revert CloseAlreadyPending();
        orderId = _orders.length;
        _orders.push(
            Order(
                msg.sender,
                OrderKind.Close,
                OrderStatus.Pending,
                pos.isLong,
                uint64(block.timestamp),
                0,
                pos.size,
                positionId,
                acceptablePrice
            )
        );
        pendingCloseOrder[positionId] = orderId + 1;
        emit OrderRequested(orderId, msg.sender, OrderKind.Close, pos.isLong, 0, pos.size, positionId);
    }

    /// @notice Cancel a pending order that the keepers did not fill within `maxExecDelay` (anyone; refunds trader).
    function cancelExpired(uint256 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        if (o.status != OrderStatus.Pending) revert NotPending();
        if (block.timestamp <= o.createdAt + maxExecDelay) revert NotExpired();
        _cancel(orderId, "expired");
    }

    function _cancel(uint256 orderId, string memory reason) internal {
        Order storage o = _orders[orderId];
        o.status = OrderStatus.Cancelled;
        if (o.kind == OrderKind.Open) {
            totalEscrow -= o.margin;
            musd.safeTransfer(o.trader, o.margin);
        }
        emit OrderCancelled(orderId, reason);
    }

    // ===================================================================== fills (step 2)

    /// @notice Keeper fills a pending order at the oracle price, which must have been PUBLISHED strictly after the
    ///         request (Pyth publishTime / signed-report time). `priceUpdate` (may be empty) is pushed to the oracle first,
    ///         in the same tx; msg.value pays its fee. Business-rule failures (slippage, OI cap, expiry) cancel + refund.
    function executeOrder(uint256 orderId, bytes[] calldata priceUpdate)
        external
        payable
        nonReentrant
        whenNotPaused
        onlyKeeper
    {
        _pushPrice(priceUpdate);
        Order storage o = _orders[orderId];
        if (o.status != OrderStatus.Pending) revert NotPending();
        if (block.timestamp > o.createdAt + maxExecDelay) return _cancel(orderId, "expired");
        (uint256 price, uint256 publishTime) = currentPrice();
        if (publishTime <= o.createdAt) revert NotYetFillable();

        if (o.acceptablePrice != 0) {
            bool bad = (o.kind == OrderKind.Open) == o.isLong ? price > o.acceptablePrice : price < o.acceptablePrice;
            if (bad) return _cancel(orderId, "slippage");
        }

        if (o.kind == OrderKind.Open) {
            if ((o.isLong ? longOi : shortOi) + o.size > maxOiPerSide) return _cancel(orderId, "oi cap");
            o.status = OrderStatus.Executed;
            totalEscrow -= o.margin;
            totalMargin += o.margin;
            if (o.isLong) longOi += o.size;
            else shortOi += o.size;
            uint256 pid = _positions.length;
            _positions.push(Position(o.trader, o.isLong, true, uint64(block.timestamp), o.margin, o.size, price));
            _openIds.push(pid);
            _openIdx[pid] = _openIds.length;
            emit PositionOpened(pid, o.trader, o.isLong, o.margin, o.size, price, orderId);
        } else {
            Position storage pos = _positions[o.positionId];
            if (!pos.open) return _cancel(orderId, "closed");
            o.status = OrderStatus.Executed;
            if (_isBust(pos, price)) {
                _liquidate(o.positionId, price, address(0)); // crossing the bust price forfeits margin (hard bust)
            } else {
                _settleClose(o.positionId, price);
            }
        }
    }

    // ===================================================================== settlement

    function _removeOpen(uint256 pid) internal {
        Position storage pos = _positions[pid];
        pos.open = false;
        totalMargin -= pos.margin;
        if (pos.isLong) longOi -= pos.size;
        else shortOi -= pos.size;
        uint256 idx = _openIdx[pid] - 1;
        uint256 lastId = _openIds[_openIds.length - 1];
        _openIds[idx] = lastId;
        _openIdx[lastId] = idx + 1;
        _openIds.pop();
        delete _openIdx[pid];
    }

    function _settleClose(uint256 pid, uint256 price) internal {
        Position storage pos = _positions[pid];
        address to = pos.owner;
        uint256 margin = pos.margin;
        int256 raw = ImpactLib.rawPnl(pos.isLong, pos.size, pos.entryPrice, price);
        uint256 gain = raw > 0 ? ImpactLib.adjustedGain(impact, pos.isLong, pos.size, pos.entryPrice, price) : 0;
        _removeOpen(pid);

        uint256 paidNow;
        uint256 queued;
        uint256 lossToHouse;
        if (raw >= 0) {
            // margin always returned immediately; only the profit depends on house solvency
            musd.safeTransfer(to, margin);
            (paidNow, queued) = _payWinner(to, gain);
        } else {
            uint256 loss = Math.min(uint256(-raw), margin);
            uint256 back = margin - loss;
            if (back > 0) musd.safeTransfer(to, back);
            uint256 fee = _queueEmpty() && _stakersActive() ? (loss * lossFeeBps) / BPS : 0; // waived while queue active
            lossToHouse = loss - fee;
            houseCash += lossToHouse;
            cumulativeLosses += lossToHouse;
            _toStakers(fee);
            _mintRebate(to, lossToHouse);
            _harvest(16);
        }
        emit PositionClosed(pid, to, price, raw, paidNow, queued, lossToHouse);
    }

    /// @dev Fees are charged ONLY on an immediate full settlement: queue empty and the house (cash, topped up from the
    ///      SP if needed) covers `need` = payout + protocol fee + (win fee if stakers are active). Then the winner gets
    ///      gain − winFee − protocolFee now; the win fee goes to stakers (no stakers: it stays with the house) and the
    ///      protocol fee to `treasury`. Otherwise NO fee is charged: the winner is owed the whole `gain`, gets whatever
    ///      cash there is now and the rest (`gain − paidNow`) is queued — never charged later at harvest.
    function _payWinner(address to, uint256 gain) internal returns (uint256 paidNow, uint256 queued) {
        uint256 owed = gain;
        if (_queueEmpty()) {
            uint256 fee = (gain * winFeeBps) / BPS;
            uint256 pFee = (gain * protocolFeeBps) / BPS;
            bool st = _stakersActive();
            uint256 payout = gain - fee - pFee;
            uint256 need = payout + pFee + (st ? fee : 0);
            if (houseCash < need) _spPull(need - houseCash); // best effort: blocked withdrawals → fee-free + queue
            if (houseCash >= need) {
                owed = payout;
                paidNow = payout;
                houseCash -= need;
                if (st) _toStakers(fee);
                if (pFee > 0) {
                    totalProtocolFees += pFee;
                    musd.safeTransfer(treasury, pFee);
                    emit ProtocolFee(pFee);
                }
            } else {
                paidNow = houseCash; // < need <= gain
                houseCash = 0;
            }
            if (paidNow > 0) musd.safeTransfer(to, paidNow);
            cumulativePaid += paidNow;
        }
        queued = owed - paidNow;
        if (queued > 0) _enqueue(to, queued);
    }

    function _isBust(Position storage pos, uint256 price) internal view returns (bool) {
        uint256 b = ImpactLib.bustPrice(pos.isLong, pos.margin, pos.size, pos.entryPrice, bustBufferDiv);
        return pos.isLong ? price <= b : price >= b;
    }

    /// @notice Permissionless liquidation at the current oracle price once the bust trigger is crossed.
    ///         `priceUpdate` (may be empty) is pushed to the oracle first; msg.value pays its fee.
    function liquidate(uint256 positionId, bytes[] calldata priceUpdate) external payable nonReentrant whenNotPaused {
        _pushPrice(priceUpdate);
        Position storage pos = _positions[positionId];
        if (!pos.open) revert PositionNotOpen();
        (uint256 price,) = currentPrice();
        if (!_isBust(pos, price)) revert NotLiquidatable();
        _liquidate(positionId, price, msg.sender);
    }

    function _liquidate(uint256 pid, uint256 price, address liquidator) internal {
        Position storage pos = _positions[pid];
        address to = pos.owner;
        uint256 margin = pos.margin;
        _removeOpen(pid);
        uint256 reward = liquidator == address(0) ? 0 : (margin * liqKeeperBps) / BPS;
        uint256 fee = _queueEmpty() && _stakersActive() ? (margin * liqFeeBps) / BPS : 0;
        uint256 toHouse = margin - reward - fee;
        if (reward > 0) musd.safeTransfer(liquidator, reward);
        _toStakers(fee);
        houseCash += toHouse;
        cumulativeLosses += toHouse;
        _mintRebate(to, margin); // full lost margin is the mint basis on liquidation
        _harvest(16);
        emit Liquidated(pid, to, liquidator, price, margin, reward);
    }

    // ===================================================================== queue

    function _queueEmpty() internal view returns (bool) {
        return queueHead == _queue.length;
    }

    function _enqueue(address to, uint256 amount) internal {
        _queue.push(QueueEntry(to, amount));
        queueTotal += amount;
        queuedOf[to] += amount;
        emit Queued(_queue.length - 1, to, amount);
    }

    /// @notice Pay queued winners FIFO from house cash (anyone can call).
    ///         v3: if cash is short of the queue, first tries to top up from the Stability Pool (best effort).
    function harvest(uint256 maxEntries) external nonReentrant returns (uint256 paid) {
        if (!_queueEmpty() && houseCash < queueTotal) _spPull(queueTotal - houseCash);
        return _harvest(maxEntries);
    }

    function _harvest(uint256 maxEntries) internal returns (uint256 paid) {
        uint256 n;
        while (queueHead < _queue.length && n < maxEntries && houseCash > 0) {
            QueueEntry storage e = _queue[queueHead];
            uint256 amt = Math.min(e.amount, houseCash);
            e.amount -= amt;
            houseCash -= amt;
            queueTotal -= amt;
            queuedOf[e.to] -= amt;
            cumulativePaid += amt;
            paid += amt;
            musd.safeTransfer(e.to, amt);
            bool full = e.amount == 0;
            emit QueuePaid(queueHead, e.to, amt, full);
            if (!full) break;
            ++queueHead;
            ++n;
        }
    }

    // ===================================================================== rebate token + stakers

    function _mintRebate(address to, uint256 lossBasis) internal {
        if (lossBasis == 0) return;
        uint256 amt = Math.mulDiv(lossBasis, mintRate(), WAD);
        // ratchet the high-water-mark of house equity above the threshold
        int256 eq = houseEquity();
        if (eq > int256(mintThreshold)) {
            uint256 h = uint256(eq) - mintThreshold;
            if (h > mintHwm) mintHwm = h;
        }
        if (amt > 0) {
            rebateToken.mint(to, amt);
            emit RebateMinted(to, lossBasis, amt);
        }
    }

    /// @notice Current mint rate (tokens per 1 MUSD of loss, WAD).
    function mintRate() public view returns (uint256) {
        if (houseEquity() < int256(mintThreshold) && mintHwm == 0) return mintFlatRate;
        uint256 s = mintDecayScale;
        uint256 r = Math.mulDiv(s, WAD, s + mintHwm);
        return Math.mulDiv(Math.mulDiv(mintFlatRate, r, WAD), r, WAD);
    }

    function _stakersActive() internal view returns (bool) {
        return address(staking) != address(0) && staking.totalStaked() > 0;
    }

    function _toStakers(uint256 amount) internal {
        if (amount == 0) return;
        if (!_stakersActive()) {
            houseCash += amount; // nobody to pay: stays with the house
            cumulativeLosses += amount;
            return;
        }
        musd.safeTransfer(address(staking), amount);
        staking.notifyReward(amount);
        totalToStakers += amount;
        emit StakerRevenue(amount);
    }

    /// @notice Sweep house assets (cash + SP deposit) above `houseCap` to stakers (only when no winner is queued).
    ///         Only on-hand `houseCash` is sent; the SP deposit is never withdrawn for this. While the house has an SP
    ///         deposit, the sweep never takes `houseCash` below `spMinLiquid` (the liquid floor that pays winners when
    ///         SP withdrawals are blocked). With no SP deposit, all cash above the cap may be swept.
    function sweepExcess() external nonReentrant whenNotPaused returns (uint256 amount) {
        if (!_queueEmpty()) return 0;
        uint256 dep = spDeposit();
        uint256 assets = houseCash + dep;
        if (assets <= houseCap) return 0;
        if (!_stakersActive()) return 0;
        uint256 sendable = houseCash;
        if (dep > 0) sendable = houseCash > spMinLiquid ? houseCash - spMinLiquid : 0;
        amount = Math.min(assets - houseCap, sendable);
        if (amount == 0) return 0;
        houseCash -= amount;
        _toStakers(amount);
    }

    // ===================================================================== Stability Pool (v3)

    /// @notice Only the Stability Pool may send BTC (its collateral gains). No state change, no reentrancy guard:
    ///         the BTC arrives in the middle of our own nonReentrant calls (provideToSP / withdrawFromSP).
    receive() external payable {
        if (msg.sender != address(stabilityPool)) revert NotStabilityPool();
    }

    /// @notice This contract's actual MUSD in the Stability Pool (after liquidation losses). 0 if unset/unreadable.
    function spDeposit() public view returns (uint256) {
        if (address(stabilityPool) == address(0)) return 0;
        // guard: an under-gassed caller must not be able to make the deposit read as 0 (it feeds houseEquity/mint)
        if (gasleft() < (SP_VIEW_GAS * 64) / 63 + 5_000) revert InsufficientGasForSp();
        try stabilityPool.getCompoundedMUSDDeposit{ gas: SP_VIEW_GAS }(address(this)) returns (uint256 d) {
            return d;
        } catch {
            return 0;
        }
    }

    /// @notice True if `withdrawFromSP(amount > 0)` would currently pass MUSD's gate: PriceFeed answers and the lowest
    ///         trove's ICR >= MCR. Any failure reads as "blocked".
    function spWithdrawable() public view returns (bool) {
        if (address(spPriceFeed) == address(0)) return false;
        uint256 price;
        address last;
        try spPriceFeed.fetchPrice{ gas: SP_VIEW_GAS }() returns (uint256 p) {
            price = p;
        } catch {
            return false;
        }
        try spSortedTroves.getLast{ gas: SP_VIEW_GAS }() returns (address l) {
            last = l;
        } catch {
            return false;
        }
        if (last == address(0)) return true;
        try spTroveManager.getCurrentICR{ gas: SP_VIEW_GAS }(last, price) returns (uint256 icr) {
            return icr >= MCR;
        } catch {
            return false;
        }
    }

    /// @notice What `rebalance()` would do now: action 0 = nothing, 1 = deposit `amount`, 2 = withdraw `amount`.
    ///         Bands: deposit when cash > min*(1+band), down to `spMinLiquid` (capped so the SP deposit stays <=
    ///         `spMaxShareBps` of cash+deposit); withdraw when cash < min*(1-band) or a winner is queued, up to
    ///         `spMinLiquid + queueTotal`. Disabled → withdraw everything. Deposits need an empty queue and an
    ///         unblocked SP (so the house never deposits into a pool it cannot leave), and no pause (v3.1).
    function rebalanceAction() public view returns (uint8 action, uint256 amount) {
        if (address(stabilityPool) == address(0)) return (0, 0);
        uint256 dep = spDeposit();
        if (!spEnabled) return dep > 0 ? (2, dep) : (0, 0);
        uint256 cash = houseCash;
        uint256 target = spMinLiquid + queueTotal;
        if (dep > 0 && (cash < (spMinLiquid * (BPS - spBandBps)) / BPS || (queueTotal > 0 && cash < target))) {
            return (2, Math.min(target - cash, dep));
        }
        if (!paused() && _queueEmpty() && cash > (spMinLiquid * (BPS + spBandBps)) / BPS) {
            uint256 cap = ((cash + dep) * spMaxShareBps) / BPS;
            uint256 amt = Math.min(cash - spMinLiquid, cap > dep ? cap - dep : 0);
            if (amt > 0 && spWithdrawable()) return (1, amt);
        }
        return (0, 0);
    }

    /// @notice Move idle house MUSD into / out of the Stability Pool (anyone; the keeper calls it periodically).
    ///         A blocked withdrawal emits SpWithdrawBlocked and returns normally.
    function rebalance() external nonReentrant returns (uint8 action, uint256 amount) {
        (action, amount) = rebalanceAction();
        if (action == 1) {
            houseCash -= amount;
            uint256 b0 = musd.balanceOf(address(this));
            musd.forceApprove(address(stabilityPool), amount);
            stabilityPool.provideToSP(amount); // also sends pending BTC gains → receive()
            if (b0 - musd.balanceOf(address(this)) != amount) revert SpDepositMismatch();
            emit SpDeposited(amount);
        } else if (action == 2) {
            amount = _spWithdraw(amount);
            _harvest(16);
        }
    }

    /// @notice Collect the SP's BTC gains and forward all BTC held to stakers (anyone). Keeps it if nobody stakes.
    function forwardBtc() external nonReentrant returns (uint256 amount) {
        if (address(stabilityPool) != address(0)) {
            _spGuardGas();
            uint256 b0 = musd.balanceOf(address(this));
            // withdrawFromSP(0) is not gated by the ICR check; it reverts only without a deposit (then: skip)
            try stabilityPool.withdrawFromSP{ gas: SP_WITHDRAW_GAS }(0) {
                houseCash += musd.balanceOf(address(this)) - b0; // normally 0
            } catch { }
        }
        amount = address(this).balance;
        if (amount == 0 || !_stakersActive()) return 0;
        staking.notifyRewardBtc{ value: amount }();
        totalBtcToStakers += amount;
        emit BtcForwarded(amount);
    }

    /// @notice BTC the stakers would get from `forwardBtc()` now (0 if nobody stakes).
    function forwardableBtc() external view returns (uint256) {
        if (!_stakersActive()) return 0;
        uint256 gain;
        if (address(stabilityPool) != address(0)) {
            try stabilityPool.getDepositorCollateralGain{ gas: SP_VIEW_GAS }(address(this)) returns (uint256 g) {
                gain = g;
            } catch { }
        }
        return address(this).balance + gain;
    }

    /// @dev Best-effort top-up of `want` MUSD from the SP. Never reverts on SP failure.
    function _spPull(uint256 want) internal returns (uint256 got) {
        if (address(stabilityPool) == address(0) || want == 0) return 0;
        uint256 dep = spDeposit();
        if (dep == 0) return 0;
        return _spWithdraw(Math.min(want, dep));
    }

    /// @dev withdrawFromSP with the received MUSD measured by balance delta. On revert: event, no state change.
    function _spWithdraw(uint256 amount) internal returns (uint256 got) {
        _spGuardGas();
        uint256 b0 = musd.balanceOf(address(this));
        try stabilityPool.withdrawFromSP{ gas: SP_WITHDRAW_GAS }(amount) {
            got = musd.balanceOf(address(this)) - b0;
            houseCash += got;
            emit SpWithdrawn(amount, got);
        } catch {
            emit SpWithdrawBlocked(amount);
        }
    }

    /// @dev The SP call must really get its stipend; otherwise a caller could choose a gas limit that makes only the
    ///      inner call fail (→ catch) and e.g. push a winner into the queue. Not enough gas → revert the whole tx.
    function _spGuardGas() internal view {
        if (gasleft() < (SP_WITHDRAW_GAS * 64) / 63 + 50_000) revert InsufficientGasForSp();
    }

    // ===================================================================== views

    /// @notice House cash + Stability Pool deposit minus queued claims. Negative = temporary insolvency (by design).
    function houseEquity() public view returns (int256) {
        return int256(houseCash + spDeposit()) - int256(queueTotal);
    }

    function getOrder(uint256 id) external view returns (Order memory) {
        return _orders[id];
    }

    function getPosition(uint256 id) external view returns (Position memory) {
        return _positions[id];
    }

    function orderCount() external view returns (uint256) {
        return _orders.length;
    }

    function positionCount() external view returns (uint256) {
        return _positions.length;
    }

    function openPositionIds() external view returns (uint256[] memory) {
        return _openIds;
    }

    function queueLength() external view returns (uint256) {
        return _queue.length;
    }

    function queueEntry(uint256 i) external view returns (address to, uint256 amount) {
        QueueEntry storage e = _queue[i];
        return (e.to, e.amount);
    }

    /// @notice Pending order ids in [from, to) — keeper helper.
    function pendingOrderIds(uint256 from, uint256 to) external view returns (uint256[] memory ids) {
        if (to > _orders.length) to = _orders.length;
        uint256 n;
        uint256[] memory tmp = new uint256[](to > from ? to - from : 0);
        for (uint256 i = from; i < to; ++i) {
            if (_orders[i].status == OrderStatus.Pending) tmp[n++] = i;
        }
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = tmp[i];
        }
    }

    function bustPriceOf(uint256 id) public view returns (uint256) {
        Position storage p = _positions[id];
        return ImpactLib.bustPrice(p.isLong, p.margin, p.size, p.entryPrice, bustBufferDiv);
    }

    function isLiquidatable(uint256 id) external view returns (bool) {
        Position storage p = _positions[id];
        if (!p.open) return false;
        (uint256 price,) = currentPrice();
        return _isBust(p, price);
    }

    /// @notice Preview of a voluntary close at `price`: raw pnl, payout after haircut + win fee + protocol fee (winners,
    ///         assuming an immediate full settlement; if the house cannot settle in full, no fee is charged and the
    ///         winner is owed margin + gain, partly queued) or margin back (losers).
    function previewClose(uint256 id, uint256 price) external view returns (int256 raw, uint256 receive_) {
        Position storage p = _positions[id];
        raw = ImpactLib.rawPnl(p.isLong, p.size, p.entryPrice, price);
        if (raw >= 0) {
            uint256 g = ImpactLib.adjustedGain(impact, p.isLong, p.size, p.entryPrice, price);
            receive_ = p.margin + g - (g * winFeeBps) / BPS - (g * protocolFeeBps) / BPS;
        } else {
            uint256 loss = Math.min(uint256(-raw), p.margin);
            receive_ = p.margin - loss;
        }
    }

    function impactScale(uint256 move) external view returns (uint256) {
        return ImpactLib.scale(impact, move);
    }

    /// @notice Accounting identity: MUSD held == houseCash + totalMargin + totalEscrow.
    function accountingDelta() external view returns (int256) {
        return int256(musd.balanceOf(address(this))) - int256(houseCash + totalMargin + totalEscrow);
    }
}
