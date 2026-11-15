# M-P1-4 FINDINGS — stop-loss high-watermark freezes one swap direction after a fully-retraced oracle spike

## Verdict: FOUND

A transient oracle spike that fully retraces leaves one swap direction
permanently blocked when the stop-loss decay is 0. The trigger is a
permissionless swapper plus an ordinary oracle wick — no admin, no
fabricated or stale price. Measured end-to-end through real swaps on a
real factory-deployed pool with the real shipped extension.

## What was tested

Local deployment only (no fork, no RPC, no mainnet state):
- `pool-contracts` ddf8ae0, `periphery-contracts` 5ceaec3, Foundry 1.9.0,
  solc 0.8.35, via_ir + optimizer.
- Work copy: `work/periphery-contracts/` (verbatim copy of the pinned
  periphery repo) with `lib/metric-core` symlinked to the pinned
  `pool-contracts` repo. The pinned repos were not modified.
- Harness: the repos' own `MetricOmmPoolBaseTest` + `MockPriceProvider`
  (bid/ask set by `setBidAndAskPrice`) + `MockERC20` + `TestCaller`.
- Pool: real `MetricOmmPoolFactory.createPool` with the real
  `OracleValueStopLossExtension` ordered under `afterSwap` only,
  drawdown 10% (100_000 E6), decay 0, timelock 0; 10 bins (-5..4),
  10,000,000 shares/bin; 50,000,000 + 50,000,000 base units deposited.
- **8/8 tests pass** (`MP14StopLossFreezeTest`), re-run confirms.

## Measured evidence

### Bin composition (measured, not assumed)

The bins straddling the current price are single-sided:

| bin | token0 | token1 |
|-----|--------|--------|
| 0 (current) | 10,000,000 | 0 |
| -1 | 0 | 10,000,000 |

Consequence: the high watermark tracks the oracle price ~1:1, not ~half
as a balanced-bin model would predict. The freeze triggers on any wick
larger than the drawdown (approximately).

### Core sequence — 2x wick, 10% drawdown, decay 0 (test_1)

| step | observation |
|------|-------------|
| Seed swap at P (buy 1,000) | HWM1 seeded = 1.0000001e18 |
| Oracle wick to 2P, small buy 1,000 | succeeds; HWM1 = 1.9999004e18 (**+99.99%**) |
| Oracle retraces fully to P | buy 1,000 reverts `OracleStopLossTriggered(bin=0, zeroForOne=false, metric=1000050300000000000, threshold=1799910360000000000)` — metric **44.4% below** the threshold |
| Buy 100 and buy 100,000 | both revert the same way — the block is size-independent |
| Warp +30 days | buy still reverts; HWM1 unchanged at 1.9999004e18 |
| Sell direction after retrace | works (sell 1,000 succeeds) |

Note: a 1-unit buy reverts with `FinalAmountIsZero` on ANY pool,
frozen or not — dust output, not the stop-loss. It is not a valid probe
and is not used as evidence.

### Calibration — the leads.md numbers (test_2, test_2b)

- **1.2x wick, 10% drawdown:** HWM1 ratchet **11,999 bps (+19.99%)**;
  post-retrace buy **blocked**. The leads.md numbers hold exactly.
- **1.2x wick, 5% drawdown:** same +19.99% ratchet; post-retrace buy
  **blocked**, still blocked +30d.
- Threshold: freeze iff wick > drawdown (approx, single-sided bins).
  A 20% wick is routine in crypto/RWA markets.

### Symmetry — downward wick (test_7)

- 0.5x dip, sell leg: HWM0 in bin -1 ratchets **19,999 bps (+99.99%)**.
- Post-retrace sell reverts
  `OracleStopLossTriggered(bin=-1, zeroForOne=true, metric=1000050300000000000, threshold=1799910360000000000)`;
  still frozen +30d; buy direction works.

### Controls

- **No-spike control (test_3):** both directions work repeatedly, +30d.
  The freeze needs the spike.
- **Decay control, 5%/day (test_4):** blocked at +0d and +2d,
  **thawed at +10d**. (The 2.0x ratchet needs ~44% decay to clear the
  10% floor: ~8.9 days at 5%/day. An earlier 7-day guess was wrong;
  the measurement corrected it.)
- **LP exit after freeze (test_5):** full exit — token0
  49,998,502 / 50,000,000 (99.997%), token1 50,002,000 / 50,000,000
  (100.004%). **LP funds are NOT frozen** (deltas are swap/fee noise).
- **Admin repair (test_6):** pool admin resets the watermarks to 0
  (timelock 0 in this test) and the direction unblocks immediately.
  The timelocked HWM reset is the only repair path.

## Who is harmed, and how much

- **Swappers: 100% of flow in one direction, indefinitely** (decay 0,
  no admin action). No funds are lost — the tx reverts — but the
  direction is dead. All sizes (100–100,000 base units tested).
- **LPs: funds NOT frozen** (exit in full, test_5). Harm is the pool
  going one-way: buy-side fee revenue goes to zero indefinitely, and
  any new LP depositing into the bin inherits the stale HWM (the
  extension never clears it on remove/re-add without an empty-bin
  crossing — see the repo's own
  `test_remintWithoutEmptyCrossingKeepsStaleHwm`).
- **Attacker cost:** one tiny swap at the wick extreme (1,000 base
  units + gas + spread fee). The wick itself is a normal market event;
  no manipulation, no privileged role, no stale/fabricated price.

## Root cause

`OracleValueStopLossExtension._applyWatermark`: metric >= HWM ratchets
the HWM up; metric < HWM keeps the HWM and reports breach below the
drawdown floor. There is no path that lowers a watermark except
`_decayed`, and `_decayed` returns the HWM unchanged when
`decayPerSecondE18 == 0` — explicitly allowed ("0 disables decay").
The check runs in `afterSwap` on every bin the swap crosses, so the
first swap after the retrace reverts the whole transaction.

## Differs from known Sept M-8 (false negative)

M-8 (Sherlock contest, verified from the contest report text): the
check **misses** a real 10.025% drawdown because `_metrics` floors
each component at 1e6 scale — a precision false NEGATIVE. Root cause:
flooring in `_metrics` / `_applyWatermark` threshold.
M-P1-4: the check **blocks** after a fully-retraced spike — a false
POSITIVE. Root cause: ratchet-up-only watermark + zero decay. Different
functions, opposite direction, different trigger (real drawdown vs
transient wick). Not the same finding.

## Severity / impact fit (honest assessment)

- Closest listed High impacts: "Permanent freezing of funds" /
  "Temporary freezing of funds". The freeze here is of a **swap
  direction**, not of funds at rest: no funds are locked in the
  contract (LPs exit in full; a swapper's tx just reverts). So
  "permanent freezing of funds" is a stretch — triage may reasonably
  say the funds are not frozen, the pool just will not trade one way.
- Counter: the freeze is permanent (decay 0, no admin action),
  permissionless to trigger, and kills the pool's core function in one
  direction; the only fix is a timelocked admin action (live timelocks
  may be long, so the freeze lasts at least that long even with an
  active admin).
- **Intended-behaviour risk is real.** A stop-loss cannot distinguish
  a spike from a real high — the ratchet is the documented design, and
  the freeze is arguably the stop-loss doing its job on stale
  information. The strongest reply: the price FULLY retraced — there
  is no drawdown anymore — yet the direction stays dead forever at
  decay 0 with no permissionless recovery, and decay is opt-in (0
  disables it).
- **Assessment: Medium is the honest central case; High is the
  optimistic case** if triage accepts a permanently one-way pool as
  freezing of funds. **Not Critical** (no theft, no insolvency, LP
  exit intact). **Weaker than M-P1-3**, which locks LP funds outright
  and maps exactly onto "Permanent freezing of funds".
- **Report-worthiness: candidate for the Studio wave as a second/third
  report, not a lead report.** Do not spend a 100-credit fee on it
  before M-P1-3 / the GMX reports. Open questions before submitting:
  (a) do live stop-loss pools actually use decay 0? (check live
  configs — if all live pools have decay > 0, the impact shrinks to a
  bounded freeze); (b) live timelock lengths.

## Test list (8/8 pass)

| # | Test | Result |
|---|------|--------|
| 1 | `test_1_spikeRetrace_freezesOneDirection_forever_decay0` | PASS — 2x wick freezes buys, +30d, sells open |
| 2 | `test_2_calibration_1_2xSpike_10pctDrawdown` | PASS — +19.99% ratchet, buy blocked |
| 2b | `test_2b_calibration_1_2xSpike_5pctDrawdown` | PASS — blocked, +30d |
| 3 | `test_3_noSpike_control_bothDirectionsWork` | PASS — control |
| 4 | `test_4_decayControl_thaws` | PASS — blocked +0d/+2d, thawed +10d |
| 5 | `test_5_lpCanStillExitAfterFreeze` | PASS — full LP exit |
| 6 | `test_6_adminRepair_unblocks` | PASS — admin HWM reset unblocks |
| 7 | `test_7_downwardSpike_freezesOppositeDirection` | PASS — symmetric freeze, +30d |

## Reproduce

See `README.md` in this folder.
