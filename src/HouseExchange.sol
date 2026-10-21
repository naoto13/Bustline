// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";
import {IPyth} from "./interfaces/IPyth.sol";
import {ImpactLib} from "./libraries/ImpactLib.sol";
import {RebateToken} from "./RebateToken.sol";
import {RebateStaking} from "./RebateStaking.sol";

/// @title HouseExchange — single-market (BTC/USD) synthetic perp on Mezo, margined in MUSD.
/// @notice The house (counterparty) starts at 0 MUSD and is funded ONLY by trader losses (no external LP deposits).
///         Winners are paid from house cash; when the house cannot pay, the remainder joins a FIFO payout queue that
///         later losses repay (`harvest`). Realised losses mint a non-transferable rebate token that can be staked
///         for MUSD revenue share. No funding, no spread; winning closes pay an asymmetric impact haircut + win fee.
///         Orders are 2-step: a request escrows margin, and a keeper fills it at an oracle update strictly AFTER the
///         request (blocks "see the price, then trade at the stale oracle" attacks, cf. Mezo's Velar post-mortem).
/// @dev TESTNET DEMO / UNAUDITED. Independent implementation; mechanism inspired by public docs (see README).
contract HouseExchange is Ownable, ReentrancyGuard {
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
    IOracleAdapter public oracle;
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
    uint256 public houseCap = 5_000_000e18; // house cash above this (queue empty) can be swept to stakers
    ImpactLib.Params public impact = ImpactLib.Params(0.1e18, 15_000, 814.598e18, 100_000e18, 50_000);
    // ---- mint curve: flat rate while tracked house < threshold, then flat*(S/(S+H))^2 with ratcheting HWM H ----
    uint256 public mintFlatRate = 100e18; // tokens per 1 MUSD loss (WAD)
    uint256 public mintThreshold = 2_000_000e18;
    uint256 public mintDecayScale = 120_000_000e18;
    uint256 public mintHwm;
    // ---- optional Pyth deviation guard ----
    IPyth public pyth;
    bytes32 public pythFeedId;
    uint256 public pythMaxAge = 60;
    uint256 public maxDeviationBps = 100;

    mapping(address => bool) public isKeeper;

    // ---- state ----
    uint256 public houseCash; // free house MUSD (reserved for the queue first)
    uint256 public totalMargin; // margin locked in open positions
    uint256 public totalEscrow; // margin escrowed by pending open orders
    uint256 public longOi;
    uint256 public shortOi;
    uint256 public cumulativeLosses; // realised trader losses into the house
    uint256 public cumulativePaid; // paid to winners (direct + queue)
    uint256 public totalToStakers;

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
    event OrderRequested(uint256 indexed orderId, address indexed trader, OrderKind kind, bool isLong, uint256 margin, uint256 size, uint256 positionId);
    event OrderCancelled(uint256 indexed orderId, string reason);
    event PositionOpened(uint256 indexed positionId, address indexed owner, bool isLong, uint256 margin, uint256 size, uint256 entryPrice, uint256 orderId);
    event PositionClosed(uint256 indexed positionId, address indexed owner, uint256 exitPrice, int256 rawPnl, uint256 paidNow, uint256 queued, uint256 lossToHouse);
    event Liquidated(uint256 indexed positionId, address indexed owner, address indexed liquidator, uint256 price, uint256 margin, uint256 keeperReward);
    event Queued(uint256 indexed index, address indexed to, uint256 amount);
    event QueuePaid(uint256 indexed index, address indexed to, uint256 amount, bool fullyPaid);
    event RebateMinted(address indexed to, uint256 lossBasis, uint256 amount);
    event StakerRevenue(uint256 amount);
    event KeeperSet(address keeper, bool allowed);
    event ParamsUpdated();

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
    error PriceDeviation();
    error NotExpired();

    modifier onlyKeeper() {
        if (!isKeeper[msg.sender] && msg.sender != owner()) revert NotKeeper();
        _;
    }

    constructor(address musd_, address oracle_, address rebateToken_, address owner_) Ownable(owner_) {
        musd = IERC20(musd_);
        oracle = IOracleAdapter(oracle_);
        rebateToken = RebateToken(rebateToken_);
    }

    // ===================================================================== admin

    function setStaking(address s) external onlyOwner {
        staking = RebateStaking(s);
        emit ParamsUpdated();
    }

    function setOracle(address o) external onlyOwner {
        oracle = IOracleAdapter(o);
        emit ParamsUpdated();
    }

    function setKeeper(address k, bool allowed) external onlyOwner {
        isKeeper[k] = allowed;
        emit KeeperSet(k, allowed);
    }

    function setRisk(uint256 maxLev, uint256 minMargin_, uint256 maxPos, uint256 maxOi, uint256 bufferDiv, uint256 execDelay)
        external
        onlyOwner
    {
        require(maxLev >= 1 && maxLev <= 1000, "lev");
        maxLeverage = maxLev;
        minMargin = minMargin_;
        maxPositionSize = maxPos;
        maxOiPerSide = maxOi;
        bustBufferDiv = bufferDiv;
        maxExecDelay = execDelay;
        emit ParamsUpdated();
    }

    function setFees(uint256 winFee, uint256 lossFee, uint256 liqFee, uint256 liqKeeper, uint256 cap) external onlyOwner {
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

    function setPythGuard(address pyth_, bytes32 feedId, uint256 maxAge, uint256 maxDevBps) external onlyOwner {
        (pyth, pythFeedId, pythMaxAge, maxDeviationBps) = (IPyth(pyth_), feedId, maxAge, maxDevBps);
        emit ParamsUpdated();
    }

    // ===================================================================== price

    /// @notice Oracle price (WAD USD/BTC) + its update time; reverts if stale or if the optional Pyth guard deviates.
    function currentPrice() public view returns (uint256 p, uint256 updatedAt) {
        p = oracle.price();
        (,,, updatedAt,) = oracle.latestRoundData();
        if (address(pyth) != address(0)) {
            IPyth.Price memory q = pyth.getPriceUnsafe(pythFeedId);
            if (q.price > 0 && q.publishTime + pythMaxAge >= block.timestamp) {
                uint256 pp = _pythToWad(q);
                uint256 diff = pp > p ? pp - p : p - pp;
                if (diff * BPS > p * maxDeviationBps) revert PriceDeviation();
            }
        }
    }

    function _pythToWad(IPyth.Price memory q) internal pure returns (uint256) {
        uint256 v = uint256(uint64(q.price));
        int256 e = int256(q.expo) + 18;
        return e >= 0 ? v * 10 ** uint256(e) : v / 10 ** uint256(-e);
    }

    // ===================================================================== orders (step 1)

    /// @notice Request a market open. Escrows `margin` MUSD; notional = margin * leverage.
    function requestOpen(bool isLong, uint256 margin, uint256 leverage, uint256 acceptablePrice)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        if (leverage == 0 || leverage > maxLeverage) revert BadLeverage();
        if (margin < minMargin) revert MarginTooSmall();
        uint256 size = margin * leverage;
        if (size > maxPositionSize) revert SizeTooLarge();
        musd.safeTransferFrom(msg.sender, address(this), margin);
        totalEscrow += margin;
        orderId = _orders.length;
        _orders.push(Order(msg.sender, OrderKind.Open, OrderStatus.Pending, isLong, uint64(block.timestamp), margin, size, 0, acceptablePrice));
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
        _orders.push(Order(msg.sender, OrderKind.Close, OrderStatus.Pending, pos.isLong, uint64(block.timestamp), 0, pos.size, positionId, acceptablePrice));
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

    /// @notice Keeper fills a pending order at the current oracle price, which must be from an update strictly after
    ///         the request. Business-rule failures (slippage, OI cap, expiry) cancel + refund instead of reverting.
    function executeOrder(uint256 orderId) external nonReentrant onlyKeeper {
        Order storage o = _orders[orderId];
        if (o.status != OrderStatus.Pending) revert NotPending();
        if (block.timestamp > o.createdAt + maxExecDelay) return _cancel(orderId, "expired");
        (uint256 price, uint256 updatedAt) = currentPrice();
        if (updatedAt <= o.createdAt) revert NotYetFillable();

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
            uint256 fee = (gain * winFeeBps) / BPS;
            uint256 payout = gain - fee;
            (paidNow, queued) = _payWinner(to, payout, fee);
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

    function _payWinner(address to, uint256 payout, uint256 fee) internal returns (uint256 paidNow, uint256 queued) {
        if (_queueEmpty()) {
            paidNow = Math.min(payout, houseCash);
            houseCash -= paidNow;
            if (paidNow > 0) musd.safeTransfer(to, paidNow);
            cumulativePaid += paidNow;
            if (paidNow == payout && fee > 0 && _stakersActive() && houseCash >= fee) {
                houseCash -= fee;
                _toStakers(fee);
            }
        }
        queued = payout - paidNow;
        if (queued > 0) _enqueue(to, queued);
    }

    function _isBust(Position storage pos, uint256 price) internal view returns (bool) {
        uint256 b = ImpactLib.bustPrice(pos.isLong, pos.margin, pos.size, pos.entryPrice, bustBufferDiv);
        return pos.isLong ? price <= b : price >= b;
    }

    /// @notice Permissionless liquidation at the current oracle price once the bust trigger is crossed.
    function liquidate(uint256 positionId) external nonReentrant {
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
    function harvest(uint256 maxEntries) external nonReentrant returns (uint256 paid) {
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

    /// @notice Sweep house cash above `houseCap` to stakers (only when no winner is queued).
    function sweepExcess() external nonReentrant returns (uint256 amount) {
        if (!_queueEmpty() || houseCash <= houseCap) return 0;
        if (!_stakersActive()) return 0;
        amount = houseCash - houseCap;
        houseCash = houseCap;
        _toStakers(amount);
    }

    // ===================================================================== views

    /// @notice House cash minus queued claims. Negative = temporary insolvency (by design).
    function houseEquity() public view returns (int256) {
        return int256(houseCash) - int256(queueTotal);
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
        for (uint256 i; i < n; ++i) ids[i] = tmp[i];
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

    /// @notice Preview of a voluntary close at `price`: raw pnl, payout after haircut+fee (winners) or margin back (losers).
    function previewClose(uint256 id, uint256 price) external view returns (int256 raw, uint256 receive_) {
        Position storage p = _positions[id];
        raw = ImpactLib.rawPnl(p.isLong, p.size, p.entryPrice, price);
        if (raw >= 0) {
            uint256 g = ImpactLib.adjustedGain(impact, p.isLong, p.size, p.entryPrice, price);
            receive_ = p.margin + g - (g * winFeeBps) / BPS;
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
