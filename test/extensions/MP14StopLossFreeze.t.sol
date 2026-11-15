// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title M-P1-4 PoC — stop-loss high-watermark ratchets up on a transient
///         oracle spike, then freezes one swap direction (decay=0: indefinitely)
/// @notice The shipped `OracleValueStopLossExtension` (periphery-contracts)
///         ratchets each bin's high watermark UP on any metric increase and
///         NEVER lowers it (`_applyWatermark`); the only release is the
///         lazy linear decay (`_decayed`), and `decayPerSecondE18 == 0`
///         explicitly disables decay. So a permissionless swapper + an
///         ordinary oracle wick can brick one swap direction forever:
///           1. seed HWM at price P (first swap touching the bin),
///           2. oracle wicks to 2P; a small swap in the non-reverting
///              direction ratchets the rising metric's HWM up ~+50%,
///           3. oracle retraces fully to P; the same direction now reads
///              ~33% below its HWM — past a 10% drawdown — and EVERY swap
///              in that direction reverts `OracleStopLossTriggered`,
///           4. with decay = 0 the HWM never falls: still blocked +30 days
///              later, with no admin action. Only the pool admin's
///              timelocked HWM reset can repair it.
///         This is the FALSE POSITIVE: it differs from known Sept M-8
///         (a precision false NEGATIVE — the check MISSES a real 10%
///         drawdown). Different root cause, opposite direction.
/// @dev Test-only file. Run inside a copy of periphery-contracts whose
///      lib/metric-core is symlinked to the pinned pool-contracts repo
///      (ddf8ae0), exactly like the M-P1-3 PoC:
///         cp test/MP14StopLossFreeze.t.sol <copy>/test/extensions/
///         cd <copy> && forge test --match-contract MP14StopLossFreezeTest -vv
///      Local deployment of the exact repo code only. No fork, no RPC, no
///      mainnet state. Real factory + real extension + repo harness
///      (MockPriceProvider / MockERC20 / TestCaller).

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MetricOmmPoolBaseTest} from "@metric-core-test/MetricOmmPool.base.t.sol";
import {MetricOmmPoolFactory} from "@metric-core/MetricOmmPoolFactory.sol";
import {MetricOmmPoolDeployer} from "@metric-core/MetricOmmPoolDeployer.sol";
import {PoolParameters} from "@metric-core/types/FactoryOperation.sol";
import {ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {ExtensionOrderTestLib} from "@metric-core-test/ExtensionOrderTestLib.sol";
import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";
import {PoolStateTestLib} from "@metric-core-test/PoolStateTestLib.sol";
import {OracleValueStopLossExtension} from "../../periphery/extensions/OracleValueStopLossExtension.sol";
import {IOracleValueStopLossExtension} from "../../periphery/interfaces/extensions/IOracleValueStopLossExtension.sol";

contract MP14StopLossFreezeTest is MetricOmmPoolBaseTest {
  uint256 private constant Q64 = 2 ** 64;

  MetricOmmPoolFactory internal mp14Factory;
  OracleValueStopLossExtension internal stopLoss;

  int16 internal constant LO = -5;
  int16 internal constant HI = 4;
  uint104 internal constant SHARES = 10_000_000;
  uint80 internal constant SALT = 0;

  uint32 internal constant DRAWDOWN_10PCT = 100_000; // 10% in E6
  uint32 internal constant DRAWDOWN_5PCT = 50_000; // 5% in E6
  /// @dev ~5%/day linear decay (same constant as the repo's own stop-loss tests).
  uint64 internal constant DECAY_5PCT_PER_DAY = 58e10;

  function setUp() public override {
    super.setUp();
    mp14Factory = new MetricOmmPoolFactory(address(this), address(this), 0, 0, type(uint16).max);
    MetricOmmPoolDeployer deployer = new MetricOmmPoolDeployer(address(mp14Factory));
    mp14Factory.setPoolDeployer(address(deployer));
    stopLoss = new OracleValueStopLossExtension(address(mp14Factory));
  }

  function _createPool(uint32 drawdownE6, uint64 decayE18, bytes32 salt) internal returns (address poolAddr) {
    address[] memory extensions = new address[](1);
    extensions[0] = address(stopLoss);
    bytes[] memory initData = new bytes[](1);
    initData[0] = abi.encode(drawdownE6, decayE18, uint40(0)); // timelock 0: admin repair is immediate
    ExtensionOrders memory orders;
    orders.afterSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);
    PoolParameters memory params = PoolParameters({
      token0: address(token0),
      token1: address(token1),
      priceProvider: address(oracle),
      extensions: extensions,
      extensionOrders: orders,
      extensionInitData: initData,
      priceProviderTimelock: type(uint256).max,
      admin: address(this),
      initialScaledAmount0PerE18Shares: 1e18,
      initialScaledAmount1PerE18Shares: 1e18,
      minimalOperationalLiquidity: 1e6,
      protocolSpreadFeeE6: 0,
      adminSpreadFeeE6: ADMIN_FEE,
      protocolNotionalFeeE8: 0,
      adminNotionalFeeE8: 0,
      adminFeeDestination: makeAddr("adminFeeDest"),
      curBinDistFromProvidedPriceE6: 0,
      nonNegativeBinDataArray: _createBinDataArray(),
      negativeBinDataArray: _createBinDataArray(),
      salt: salt,
      bidAskRefAsymmetryX8: type(uint16).max
    });
    oracle.setTokens(params.token0, params.token1);
    poolAddr = mp14Factory.createPool(params);
    _approveUsersForPool(poolAddr);
  }

  function _addTo(address poolAddr, uint256 userIndex) internal returns (uint256 a0, uint256 a1) {
    LiquidityDelta memory deltas = _rangeDeltas(LO, HI, SHARES);
    vm.prank(users[userIndex]);
    return callers[userIndex].addLiquidity(poolAddr, SALT, deltas);
  }

  function _removeFrom(address poolAddr, uint256 userIndex, uint104 shares) internal returns (uint256 r0, uint256 r1) {
    LiquidityDelta memory deltas = _rangeDeltas(LO, HI, shares);
    vm.prank(users[userIndex]);
    return callers[userIndex].removeLiquidity(poolAddr, SALT, deltas);
  }

  /// @dev Move the mock oracle to Q64 * num / den with a 1-wei bid/ask
  ///      spread (the pool requires bid < ask; a clean wick, no spread blow-out).
  function _setPrice(uint256 num, uint256 den) internal {
    uint128 p = uint128(Q64 * num / den);
    oracle.setBidAndAskPrice(p, p + 1);
  }

  /// @dev Direction-aware swap: buys (price moves up) take a max limit,
  ///      sells (price moves down) take 0 — the repo's own convention
  ///      (a max limit on a sell stops the swap at zero movement).
  function _swap(address poolAddr, uint256 userIndex, bool zeroForOne, int128 amount)
    internal
    returns (int256 d0, int256 d1)
  {
    uint128 limit = zeroForOne ? uint128(0) : type(uint128).max;
    return _swapOnPool(poolAddr, userIndex, users[userIndex], zeroForOne, amount, limit);
  }

  function _hwm(address poolAddr, int16 bin) internal view returns (uint256 h0, uint256 h1) {
    return stopLoss.currentHighWatermarks(poolAddr, bin);
  }

  function _trySwap(address poolAddr, uint256 userIndex, bool zeroForOne, int128 amount) internal returns (bool ok) {
    uint128 limit = zeroForOne ? uint128(0) : type(uint128).max;
    vm.prank(users[userIndex]);
    try callers[userIndex].swap(poolAddr, users[userIndex], zeroForOne, amount, limit) returns (int256, int256) {
      ok = true;
    } catch {
      ok = false;
    }
  }

  /// @dev Expect the swap to revert with the extension's
  ///      `OracleStopLossTriggered` error (checked by 4-byte selector).
  ///      Note: a bare `vm.expectRevert(selector)` does NOT work here —
  ///      Foundry compares the full revert data, not just the selector —
  ///      so the check goes through try/catch. (An earlier run already
  ///      captured the exact revert data: bin 0, zeroForOne=false,
  ///      metric 1000050300000000000 vs threshold 1799910360000000000
  ///      for the 2x-spike case; bin -1, zeroForOne=true with the same
  ///      metric/threshold for the 0.5x-dip case.)
  function _swapExpectStopLoss(address poolAddr, uint256 userIndex, bool zeroForOne, int128 amount) internal {
    uint128 limit = zeroForOne ? uint128(0) : type(uint128).max;
    vm.prank(users[userIndex]);
    try callers[userIndex].swap(poolAddr, users[userIndex], zeroForOne, amount, limit) returns (int256, int256) {
      revert("swap must revert with OracleStopLossTriggered");
    } catch (bytes memory ret) {
      assertGe(ret.length, 4, "revert must carry an error selector");
      assertEq(
        bytes4(ret), IOracleValueStopLossExtension.OracleStopLossTriggered.selector, "revert must be OracleStopLossTriggered"
      );
    }
  }

  // (1) CORE CLAIM: 2x spike + full retrace freezes the buy direction
  //     indefinitely at decay = 0; the sell direction stays open.
  function test_1_spikeRetrace_freezesOneDirection_forever_decay0() public {
    address poolAddr = _createPool(DRAWDOWN_10PCT, 0, keccak256("MP14-1"));
    (uint256 a0, uint256 a1) = _addTo(poolAddr, 1);
    assertGt(a0, 0, "deposit token0");
    assertGt(a1, 0, "deposit token1");
    int16 bin = PoolStateTestLib.curBinIdx(poolAddr);
    (uint104 t0, uint104 t1,,,) = PoolStateTestLib.binState(poolAddr, bin);
    console.log("seed bin t0:");
    console.log(uint256(t0));
    console.log("seed bin t1:");
    console.log(uint256(t1));

    // Seed the HWM at P with a small buy (zeroForOne == false).
    (int256 d0,) = _swap(poolAddr, 1, false, int128(1000));
    assertLt(d0, 0, "seed swap must buy token0");
    (, uint256 hwm1Seed) = _hwm(poolAddr, bin);
    assertGt(hwm1Seed, 0, "HWM must seed on first touch");
    console.log("HWM1 seeded:");
    console.log(hwm1Seed);

    // Wick: oracle to 2P. A small buy ratchets HWM1 up (the metricT0
    // breach does not block this direction), and succeeds.
    _setPrice(2, 1);
    console.log("curBinIdx at 2P:");
    console.log(int256(PoolStateTestLib.curBinIdx(poolAddr)));
    (d0,) = _swap(poolAddr, 1, false, int128(1000));
    assertLt(d0, 0, "spike-leg swap must succeed");
    (, uint256 hwm1Spike) = _hwm(poolAddr, bin);
    console.log("HWM1 after 2x spike:");
    console.log(hwm1Spike);
    assertGt(hwm1Spike, hwm1Seed * 110 / 100, "HWM1 must ratchet >10% on a 2x spike");

    // Full retrace to P. The buy direction is now frozen.
    _setPrice(1, 1);
    _swapExpectStopLoss(poolAddr, 1, false, int128(1000));
    // The block is size-independent: a 100-unit and a 100_000-unit buy
    // revert the same way. (A 1-unit buy is not a valid probe: it reverts
    // with FinalAmountIsZero on ANY pool, frozen or not — dust output.)
    _swapExpectStopLoss(poolAddr, 1, false, int128(100));
    _swapExpectStopLoss(poolAddr, 1, false, int128(100_000));
    // +30 days later, still frozen (decay = 0: the HWM never falls).
    vm.warp(block.timestamp + 30 days);
    _swapExpectStopLoss(poolAddr, 1, false, int128(1000));
    (, uint256 hwm1Late) = _hwm(poolAddr, bin);
    assertEq(hwm1Late, hwm1Spike, "HWM must not decay at rate 0");
    console.log("HWM1 still frozen at:");
    console.log(hwm1Spike);

    // The opposite direction is untouched.
    (d0,) = _swap(poolAddr, 1, true, int128(1000));
    assertGt(d0, 0, "sell direction must stay open");
  }

  // (2) CALIBRATION: the leads.md numbers — 1.2x spike, 10% drawdown.
  //     Measures the actual ratchet on the real bin composition and whether
  //     the post-retrace buy is blocked. No hard assertion on the block
  //     itself: this test reports the threshold, test_1 proves the freeze.
  function test_2_calibration_1_2xSpike_10pctDrawdown() public {
    address poolAddr = _createPool(DRAWDOWN_10PCT, 0, keccak256("MP14-2"));
    _addTo(poolAddr, 1);
    int16 bin = PoolStateTestLib.curBinIdx(poolAddr);
    (uint104 t0, uint104 t1,,,) = PoolStateTestLib.binState(poolAddr, bin);
    console.log("calib bin t0:");
    console.log(uint256(t0));
    console.log("calib bin t1:");
    console.log(uint256(t1));

    _swap(poolAddr, 1, false, int128(1000));
    (, uint256 hwm1Seed) = _hwm(poolAddr, bin);
    _setPrice(12, 10); // 1.2x wick
    _swap(poolAddr, 1, false, int128(1000));
    (, uint256 hwm1Spike) = _hwm(poolAddr, bin);
    uint256 ratchetBps = hwm1Spike * 10000 / hwm1Seed;
    console.log("HWM1 ratchet, bps (10000 = no change):");
    console.log(ratchetBps);
    assertGt(hwm1Spike, hwm1Seed, "HWM must ratchet up on a spike");

    _setPrice(1, 1);
    bool blocked = !_trySwap(poolAddr, 1, false, int128(1000));
    console.log("post-retrace buy blocked (1 = yes):");
    console.log(blocked ? uint256(1) : uint256(0));
  }

  // (2b) Same 1.2x wick, tighter 5% drawdown: the ~+10% ratchet must
  //      exceed the floor and freeze the buy direction.
  function test_2b_calibration_1_2xSpike_5pctDrawdown() public {
    address poolAddr = _createPool(DRAWDOWN_5PCT, 0, keccak256("MP14-2b"));
    _addTo(poolAddr, 1);
    int16 bin = PoolStateTestLib.curBinIdx(poolAddr);
    _swap(poolAddr, 1, false, int128(1000));
    (, uint256 hwm1Seed) = _hwm(poolAddr, bin);
    _setPrice(12, 10);
    _swap(poolAddr, 1, false, int128(1000));
    (, uint256 hwm1Spike) = _hwm(poolAddr, bin);
    console.log("HWM1 ratchet bps at 5pct drawdown:");
    console.log(hwm1Spike * 10000 / hwm1Seed);
    _setPrice(1, 1);
    assertTrue(!_trySwap(poolAddr, 1, false, int128(1000)), "1.2x spike must freeze buys at 5% drawdown");
    vm.warp(block.timestamp + 30 days);
    assertTrue(!_trySwap(poolAddr, 1, false, int128(1000)), "still frozen +30d at decay 0");
  }

  // (3) CONTROL: no spike, both directions work forever.
  function test_3_noSpike_control_bothDirectionsWork() public {
    address poolAddr = _createPool(DRAWDOWN_10PCT, 0, keccak256("MP14-3"));
    _addTo(poolAddr, 1);
    for (uint256 i = 0; i < 5; i++) {
      _swap(poolAddr, 1, false, int128(1000));
      _swap(poolAddr, 1, true, int128(1000));
    }
    vm.warp(block.timestamp + 30 days);
    _swap(poolAddr, 1, false, int128(1000));
    _swap(poolAddr, 1, true, int128(1000));
  }

  // (4) DECAY CONTROL: same freeze at decay > 0, then it thaws.
  //     2x spike on this bin (all token0) ratchets HWM1 ~+100% (2.0x);
  //     the buy direction needs the HWM to fall ~44% to clear the 10%
  //     floor (2.0x -> <= 1.111x): at ~5%/day that is ~8.9 days.
  //     Blocked at +0d and +2d, open at +10d.
  function test_4_decayControl_thaws() public {
    address poolAddr = _createPool(DRAWDOWN_10PCT, DECAY_5PCT_PER_DAY, keccak256("MP14-4"));
    _addTo(poolAddr, 1);
    int16 bin = PoolStateTestLib.curBinIdx(poolAddr);
    _swap(poolAddr, 1, false, int128(1000));
    (, uint256 hwm1Seed) = _hwm(poolAddr, bin);
    _setPrice(2, 1);
    _swap(poolAddr, 1, false, int128(1000));
    (, uint256 hwm1Spike) = _hwm(poolAddr, bin);
    assertGt(hwm1Spike, hwm1Seed * 110 / 100, "HWM1 must ratchet >10% on a 2x spike");
    _setPrice(1, 1);
    _swapExpectStopLoss(poolAddr, 1, false, int128(1000));
    vm.warp(block.timestamp + 2 days);
    assertTrue(!_trySwap(poolAddr, 1, false, int128(1000)), "must still be blocked after 2d");
    vm.warp(block.timestamp + 8 days); // 10d total since the spike
    assertTrue(_trySwap(poolAddr, 1, false, int128(1000)), "must thaw after ~10d at 5%/day decay");
  }

  // (5) LP FUNDS ARE NOT FROZEN: removeLiquidity still exits in full
  //     after the freeze (the extension only hooks afterSwap).
  function test_5_lpCanStillExitAfterFreeze() public {
    address poolAddr = _createPool(DRAWDOWN_10PCT, 0, keccak256("MP14-5"));
    (uint256 a0, uint256 a1) = _addTo(poolAddr, 1);
    _swap(poolAddr, 1, false, int128(1000));
    _setPrice(2, 1);
    _swap(poolAddr, 1, false, int128(1000));
    _setPrice(1, 1);
    _swapExpectStopLoss(poolAddr, 1, false, int128(1000)); // freeze confirmed
    (uint256 r0, uint256 r1) = _removeFrom(poolAddr, 1, SHARES);
    assertGt(r0, 0, "exit must return token0");
    assertGt(r1, 0, "exit must return token1");
    assertEq(
      PoolStateTestLib.positionBinShares(poolAddr, address(callers[1]), SALT, LO), 0, "position must be emptied"
    );
    console.log("LP exit after freeze, token0 out / in:");
    console.log(r0);
    console.log(a0);
    console.log("LP exit after freeze, token1 out / in:");
    console.log(r1);
    console.log(a1);
  }

  // (6) ADMIN REPAIR: the pool admin's timelocked HWM reset is the only
  //     fix — resetting the watermarks to 0 re-seeds them on the next
  //     swap and unblocks the direction (timelock is 0 here, so immediate).
  function test_6_adminRepair_unblocks() public {
    address poolAddr = _createPool(DRAWDOWN_10PCT, 0, keccak256("MP14-6"));
    _addTo(poolAddr, 1);
    int16 bin = PoolStateTestLib.curBinIdx(poolAddr);
    _swap(poolAddr, 1, false, int128(1000));
    _setPrice(2, 1);
    _swap(poolAddr, 1, false, int128(1000));
    _setPrice(1, 1);
    _swapExpectStopLoss(poolAddr, 1, false, int128(1000)); // freeze confirmed
    stopLoss.proposeOracleStopLossHighWatermarks(poolAddr, bin, 0, 0);
    stopLoss.executeOracleStopLossHighWatermarks(poolAddr);
    (uint256 hwm0After,) = _hwm(poolAddr, bin);
    assertEq(hwm0After, 0, "admin reset must zero the watermarks");
    assertTrue(_trySwap(poolAddr, 1, false, int128(1000)), "admin HWM reset must unblock");
  }

  // (7) SYMMETRY: a downward wick freezes the opposite direction.
  //     Bin 0 holds only token0, so the sell leg draws token1 from bin -1:
  //     that bin's HWM0 (metricT0 = t0 + t1/bid) is the one that ratchets
  //     when the bid falls.
  function test_7_downwardSpike_freezesOppositeDirection() public {
    address poolAddr = _createPool(DRAWDOWN_10PCT, 0, keccak256("MP14-7"));
    _addTo(poolAddr, 1);
    int16 bin = -1;
    (uint104 t0m1, uint104 t1m1,,,) = PoolStateTestLib.binState(poolAddr, bin);
    console.log("bin -1 t0 / t1:");
    console.log(uint256(t0m1));
    console.log(uint256(t1m1));
    _swap(poolAddr, 1, true, int128(1000)); // seed via sell
    (uint256 hwm0Seed,) = _hwm(poolAddr, bin);
    assertGt(hwm0Seed, 0, "HWM0 must seed");
    _setPrice(1, 2); // 0.5x dip: metricT0 rises as the bid falls
    _swap(poolAddr, 1, true, int128(1000)); // ratchet leg
    (uint256 hwm0Spike,) = _hwm(poolAddr, bin);
    console.log("HWM0 ratchet bps (10000 = no change):");
    console.log(hwm0Spike * 10000 / hwm0Seed);
    assertGt(hwm0Spike, hwm0Seed * 110 / 100, "HWM0 must ratchet >10% on a 0.5x dip");
    _setPrice(1, 1);
    _swapExpectStopLoss(poolAddr, 1, true, int128(1000)); // sell direction now frozen
    vm.warp(block.timestamp + 30 days);
    _swapExpectStopLoss(poolAddr, 1, true, int128(1000));
    (int256 d0,) = _swap(poolAddr, 1, false, int128(1000));
    assertLt(d0, 0, "buy direction must stay open");
  }
}
