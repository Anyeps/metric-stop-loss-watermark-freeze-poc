# DRAFT — Metric Immunefi Report: Stop-loss high watermark freezes one swap direction forever after a fully-retraced oracle spike (decay = 0)

**Status: DRAFT — submission-ready, NOT submitted.**
**Reason not submitted:** Immunefi Novice submission fee (100 credits, ~100 USDC).
Fah's account holds ~0 USDC; waiting for the Immunefi Studio wave, same as
the M-P1-3 and GMX drafts. This is a second/third report for the wave,
BEHIND M-P1-3 and the GMX reports — do NOT spend a fee on it first. Do NOT
submit until the Studio "Ready" verdict, and do NOT pay any fee from another
source without Fah's explicit approval.

- **Program:** Metric — https://immunefi.com/bug-bounty/metric/information/
- **Severity: Medium (honest central case); High is the optimistic case.**
  The frozen thing is a **swap direction, not funds at rest** — see the
  severity discussion in Part 2. Do not oversell this as "permanent
  freezing of funds".
- **Payout wallet:** `0x45859319d9a362f2146d0431dc30ab8f0ef1be73`
- **PoC repo:** https://github.com/Anyeps/metric-stop-loss-watermark-freeze-poc
  — verified from a fresh clone: `forge install` (pinned deps) +
  `forge test` → **8 passed, 0 failed**.
- **Code under test:** `pool-contracts` @ `ddf8ae0`, `periphery-contracts` @
  `5ceaec3` (exact repo code, local deploy, no fork — see below).

---

# Part 1 — 7-Question Gate (run before writing the report)

## Q1: Can an attacker use this RIGHT NOW, step by step? — PASS

Yes, with no privilege and no fabricated price:

1. A pool exists with the shipped `OracleValueStopLossExtension` ordered
   under `afterSwap`, drawdown 10%, decay 0 (decay is opt-in; 0 disables
   it — see Vulnerability details).
2. The oracle wicks up (an ordinary market event — a 20% wick is routine
   in crypto/RWA markets). At the wick extreme, anyone makes one small
   swap (1,000 base units in the PoC) in the direction whose metric is
   rising. The swap succeeds — and the extension ratchets that bin's
   high watermark up ~1:1 with the wick (+99.99% on a 2x wick).
3. The oracle price retraces fully to where it started. There is no
   drawdown anymore.
4. Every swap in that direction now reverts
   `OracleStopLossTriggered` — at any size, indefinitely (measured
   still frozen after +30 days at decay 0).

No admin role, no oracle manipulation, no stale or fabricated price, no
cooperation from anyone else. The "attacker" is a permissionless swapper
plus a normal market wick.

## Q2: Is the impact on the program's accepted impact list? — PARTIAL (honest)

The closest listed High impacts are:

> **Permanent freezing of funds**
> **Temporary freezing of funds**

The freeze here is of a **swap direction**, not of funds at rest. LPs
can still exit in full (measured 99.997% / 100.004% in the PoC), and a
swapper's transaction simply reverts — no funds are lost or locked in
the contract. So "Permanent freezing of funds" is a stretch, and this
draft does not claim it. "Temporary freezing of funds" is the more
honest listed fit — but even that is imperfect, because what is frozen
is the pool's ability to trade one way, not anyone's funds.

What IS true and measured: the freeze is permanent (decay 0, no admin
action), permissionless to trigger, and kills the pool's core function
in one direction; the only fix is a timelocked admin action. That is a
real availability impact on a live trading venue, and it is why the
central case is **Medium** rather than Low/Informational — with High
as the optimistic case if triage accepts a permanently one-way pool as
a freezing of funds.

## Q3: Is the root cause in an in-scope asset? — PASS

Yes — `periphery-contracts`, the shipped
`OracleValueStopLossExtension` (`contracts/extensions/
OracleValueStopLossExtension.sol`), specifically `_applyWatermark` /
`_decayed` and the `afterSwap` check. Periphery Contracts are listed
as bounty-eligible scope on the program page.

## Q4: Does it require privileged access that an attacker can't realistically get? — PASS

No privilege is needed for the trigger (Q1). Privilege enters only on
the repair side: the pool admin's timelocked HWM reset is the only
repair path. That asymmetry (permissionless to break, privileged to
fix) is part of the impact, not a barrier to the attack.

## Q5: Is this already known or accepted behavior? — PASS (with a real intended-behaviour risk, disclosed)

Checked against the published known-issues repo and the Zellic (Jun +
Oct 2026) and Sherlock (Jul / Sep / Oct 2026) audit findings: no
finding covers the ratchet-up-only watermark freezing a direction at
decay 0.

- The closest relative, Sherlock contest **M-8**, is the OPPOSITE
  direction: a precision false NEGATIVE — the check MISSES a real
  10.025% drawdown because `_metrics` floors each component at 1e6
  scale. M-P1-4 is a false POSITIVE — the check BLOCKS after a
  fully-retraced spike. Different functions, opposite direction,
  different trigger (real drawdown vs transient wick). Not the same
  finding.
- **The intended-behaviour risk is real and is stated in the report
  itself (see Part 2).** A stop-loss cannot distinguish a spike from a
  real high — the ratchet is the documented design, and the freeze is
  arguably the stop-loss doing its job on stale information. The
  strongest reply: the price FULLY retraced — there is no drawdown
  anymore — yet the direction stays dead forever at decay 0 with no
  permissionless recovery, and decay is opt-in (0 disables it). The
  extension's own docs present decay as the release valve and then
  allow it to be switched off entirely.

## Q6: Can you prove impact beyond "technically possible"? — PASS (bounded, stated plainly)

Measured, not hypothetical (Part 2, Evidence):

- 2x wick → HWM +99.99%; buy reverts after a full retrace, still
  frozen at +30 days; sells keep working. 1.2x wick → +19.99%
  ratchet, direction blocked at 10% AND 5% drawdown. Downward wicks
  freeze the opposite direction symmetrically.
- The block is size-independent (100–100,000 base units tested) and
  time-independent at decay 0 (+30 days).
- The bound is also measured: LP exit is intact (test_5), and 5%/day
  decay thaws the direction at +10 days (test_4). So the impact is
  exactly as bad as stated — a permanently one-way pool at decay 0 —
  and no worse. No funds are lost; the harm is lost trading function
  and lost fee revenue in one direction, indefinitely.

## Q7: Is this a known-invalid bug class? — PASS (with the availability note)

No. It is not a duplicate of a known issue, not a front-running/MEV
observation, and not a finding that requires out-of-scope behaviour.
It is a logic gap in in-scope code with a real, measured, permanent
effect. The honest classification question is whether triage treats a
permanently one-way pool as a funds-freezing impact (High) or as an
availability impact (Medium). Either way it is a valid finding class;
the severity is the open question, not the validity.

## Gate result: CONDITIONAL PASS (Q2 partial — Medium central, High optimistic)

---

# Part 2 — Report (Immunefi submission draft)

## Title

Stop-loss high watermark freezes one swap direction forever after a
fully-retraced oracle spike (decay = 0)

## Severity: Medium

**Honest assessment (please read):** the central case is Medium. The
freeze is permanent and permissionless to trigger, but what is frozen
is one swap direction, not funds at rest — LPs exit in full and
swappers lose nothing but a reverted transaction. The closest listed
impacts are "Temporary freezing of funds" (listed High) and "Permanent
freezing of funds" (listed High); we claim the former as the nearest
fit and note the latter would be a stretch. **High is the optimistic
case** if triage accepts a permanently one-way pool as a freezing of
funds. Not Critical (no theft, no insolvency, LP exit intact). This
finding is weaker than M-P1-3 (which locks LP funds outright and maps
exactly onto "Permanent freezing of funds").

**A note on the dollar tier:** the High / Medium / Low dollar tiers were
NOT visible in the program-page text fetch (rendered as SVG images), so
this draft does not claim a dollar figure for any tier. Critical is 20%
of funds directly affected, max $500,000, min $50,000. Re-check the live
program page for the Medium tier before submitting.

## Summary

The shipped `OracleValueStopLossExtension` ratchets each bin's high
watermark UP on any metric increase and never lowers it. The only
release is lazy linear decay, and `decayPerSecondE18 == 0` explicitly
disables decay. A permissionless swapper plus an ordinary oracle wick
can therefore brick one swap direction forever: seed the watermark at
price P, wick the oracle to 2P (a small swap at the extreme ratchets
the rising metric's watermark up ~1:1 with the wick), let the price
retrace fully to P — and every swap in that direction now reverts
`OracleStopLossTriggered`, indefinitely at decay 0, with no admin
action. Only the pool admin's timelocked watermark reset repairs it.

LP funds are NOT frozen — exits work in full. The frozen thing is one
swap direction, so the pool goes one-way forever: buy-side fee revenue
goes to zero indefinitely, and any new LP depositing into the bin
inherits the stale watermark.

## Impact

- **One swap direction permanently blocked (decay 0, no admin
  action).** Measured: after a fully-retraced 2x wick, every buy
  reverts `OracleStopLossTriggered(bin=0, zeroForOne=false,
  metric=1000050300000000000, threshold=1799910360000000000)` — the
  metric is 44.4% below the threshold, i.e. far past the 10% drawdown
  — at all tested sizes (100–100,000 base units) and still blocked
  after +30 days. The sell direction keeps working; a downward wick
  freezes the opposite direction symmetrically.
- **Swappers lose 100% of flow in one direction, indefinitely.** No
  funds are lost — the transaction reverts — but the direction is
  dead. A 20% wick is routine in crypto/RWA markets, and the freeze
  triggers on any wick larger than the drawdown (approximately, given
  the single-sided bins around the reference price).
- **LPs are harmed indirectly, not by locked funds.** Full exit works
  (measured 49,998,502 / 50,000,000 token0 = 99.997% and 50,002,000 /
  50,000,000 token1 = 100.004% — the deltas are swap/fee noise). The
  harm is the pool going one-way: buy-side fee revenue goes to zero
  indefinitely, and any new LP depositing into the bin inherits the
  stale watermark (the extension never clears it on remove/re-add
  without an empty-bin crossing — see the repo's own
  `test_remintWithoutEmptyCrossingKeepsStaleHwm`).
- **The only repair is a timelocked admin action.** The pool admin
  resets the watermarks to 0 (tested: direction unblocks immediately).
  With timelock 0 in the test this is instant; live timelocks may be
  long, so the freeze lasts at least that long even with an active
  admin — and forever if the admin is inactive. There is no
  permissionless recovery.
- **Trigger cost is trivial.** One tiny swap at the wick extreme
  (1,000 base units + gas + spread fee). The wick itself is a normal
  market event; no manipulation, no privileged role, no stale or
  fabricated price.

### What this is NOT (for triage — please read)

- **Not a freezing of funds at rest.** LP funds are not locked in the
  contract. We do not claim "Permanent freezing of funds"; the honest
  listed fit is "Temporary freezing of funds" (the freeze lasts until
  an admin acts, which at decay 0 with an inactive admin is
  indefinite) or a Medium availability impact.
- **Not the known M-8.** Sherlock contest M-8 is a false NEGATIVE
  (the check misses a real drawdown). This is a false POSITIVE (the
  check blocks after a fully-retraced spike). Different root cause,
  opposite direction.
- **Not Critical.** No theft, no insolvency, LP exit intact.

### Intended-behaviour risk (disclosed plainly)

A stop-loss cannot distinguish a spike from a real high — the ratchet
is the documented design, and the freeze is arguably the stop-loss
doing its job on stale information. Our reply: the price FULLY
retraced — there is no drawdown anymore — yet the direction stays
dead forever at decay 0 with no permissionless recovery, and decay is
opt-in (0 disables it). The extension's own docs present decay as the
release valve and then allow it to be switched off entirely. A
stop-loss that can never un-trip is a liveness bug, not a safety
feature.

## Vulnerability details

### Root cause

`OracleValueStopLossExtension._applyWatermark`
(`periphery-contracts/contracts/extensions/
OracleValueStopLossExtension.sol:358`): `metric >= HWM` ratchets the
HWM up; `metric < HWM` keeps the HWM and reports a breach below the
drawdown floor. There is no path that lowers a watermark except
`_decayed` (`:349`), and `_decayed` returns the HWM unchanged when
`decayPerSecondE18 == 0` — explicitly allowed ("0 disables decay").
The check runs in `afterSwap` on every bin the swap crosses, so the
first swap after the retrace reverts the whole transaction.

`initialize` (`:59-79`) takes `abi.encode(uint32 drawdownE6, uint64
decayPerSecondE18, uint40 timelockSeconds)` and applies immediately
with no timelock; `timelockSeconds` is not validated and may be 0, and
`decayPerSecondE18` is validated by `_validateDecay` (`:338`) which
permits 0.

### Why the watermark tracks the wick ~1:1

The bins straddling the current price are single-sided (measured):

| bin | token0 | token1 |
|-----|--------|--------|
| 0 (current) | 10,000,000 | 0 |
| -1 | 0 | 10,000,000 |

Consequence: the high watermark tracks the oracle price ~1:1, not
~half as a balanced-bin model would predict. The freeze triggers on
any wick larger than the drawdown (approximately).

### Code paths (repo `pool-contracts` @ `ddf8ae0`, `periphery-contracts` @ `5ceaec3`)

- `periphery/contracts/extensions/OracleValueStopLossExtension.sol:358`
  — `_applyWatermark` (ratchet up only).
- Same file `:349` — `_decayed` (returns HWM unchanged at decay 0).
- Same file `:201-224` — `afterSwap` / `_afterSwapOracleStopLoss`
  (check runs on every bin crossed).
- Same file `:59-79` — `initialize` (decay 0 explicitly allowed).
- Same file `:84` — `currentHighWatermarks(pool, binIdx)` (public
  view; useful for verifying a live pool's state).
- Same file `:49` — `oracleStopLossConfig` public mapping (per-pool
  drawdown / decay / timelock).
- Same file `:172-184` — admin HWM reset (timelocked; the only
  repair path).

### Why this is not a known issue

Checked against the published known-issues repo and the Zellic (Jun +
Oct 2026) and Sherlock (Jul / Sep / Oct 2026) audit findings: no
finding covers the ratchet-up-only watermark freezing a direction at
decay 0. M-8 is the opposite direction (see above). The extension's
own docs describe decay as the release mechanism without warning that
disabling it makes a transient wick a permanent one-way freeze.

### Open questions (not answered before drafting)

1. **Do live stop-loss pools actually use decay 0?** If every live
   pool has decay > 0, the impact shrinks to a bounded freeze (the
   direction thaws once enough decay accrues — e.g. ~9 days at
   5%/day for a 2x wick against a 10% drawdown). The extension's
   public `oracleStopLossConfig(pool)` getter returns
   `(drawdownE6, decayPerSecondE18, timelock, initialized)` per pool
   and would answer this with a single read-only call per pool —
   **but no published factory address or live pool list was found**
   in the repos or docs, so no live pool could be identified and
   read in this round. Triage can answer this in one call once a
   live stop-loss pool address is known.
2. **How long are the live timelocks?** Same getter, same blocker.
   The test used timelock 0; a long live timelock lengthens the
   freeze even with an active admin.

## Steps to reproduce

### 1. Clone the PoC and run the tests

```bash
git clone https://github.com/Anyeps/metric-stop-loss-watermark-freeze-poc
cd metric-stop-loss-watermark-freeze-poc
forge install foundry-rs/forge-std@0e44f85 --no-commit
forge install OpenZeppelin/openzeppelin-contracts@dde766bd --no-commit
forge test --match-contract MP14StopLossFreezeTest -vv
```

Expected: **8 passed, 0 failed.** No fork URL, no RPC, no mainnet
state: the bug is pure extension logic, tested by local deployment of
the exact repo code with the repo's own harness (`MockPriceProvider` /
`MockERC20` / `TestCaller`). First build is slow (`via_ir` +
optimizer); later runs take ~1 min. Requires Foundry (`forge`) and
solc 0.8.35 (set in `foundry.toml`).

### 2. What the tests show

`test/extensions/MP14StopLossFreeze.t.sol` (`MP14StopLossFreezeTest`),
real factory-deployed pool with the real shipped
`OracleValueStopLossExtension` ordered under `afterSwap` only,
drawdown 10% (100_000 E6), decay 0, timelock 0; 10 bins (-5..4),
10,000,000 shares/bin; 50,000,000 + 50,000,000 base units deposited:

1. `test_1_spikeRetrace_freezesOneDirection_forever_decay0` — seed
   swap at P (HWM1 = 1.0000001e18); oracle wick to 2P, small buy 1,000
   succeeds, HWM1 = 1.9999004e18 (+99.99%); oracle retraces fully to
   P; buy 1,000 reverts `OracleStopLossTriggered(bin=0,
   zeroForOne=false, metric=1000050300000000000,
   threshold=1799910360000000000)`; buy 100 and buy 100,000 revert the
   same way; warp +30 days, buy still reverts, HWM1 unchanged;
   sell direction works.
2. `test_2_calibration_1_2xSpike_10pctDrawdown` — 1.2x wick ratchets
   HWM1 +19.99%; post-retrace buy blocked. The leads.md numbers hold
   exactly.
3. `test_2b_calibration_1_2xSpike_5pctDrawdown` — same +19.99%
   ratchet; post-retrace buy blocked, still blocked +30d.
4. `test_3_noSpike_control_bothDirectionsWork` — both directions work
   repeatedly, +30d. The freeze needs the spike.
5. `test_4_decayControl_thaws` — 5%/day decay: blocked at +0d and
   +2d, thawed at +10d. (The 2.0x ratchet needs ~44% decay to clear
   the 10% floor: ~8.9 days at 5%/day.)
6. `test_5_lpCanStillExitAfterFreeze` — full LP exit after the freeze:
   token0 49,998,502 / 50,000,000 (99.997%), token1 50,002,000 /
   50,000,000 (100.004%). LP funds are NOT frozen.
7. `test_6_adminRepair_unblocks` — pool admin resets the watermarks
   to 0 and the direction unblocks immediately. The timelocked HWM
   reset is the only repair path.
8. `test_7_downwardSpike_freezesOppositeDirection` — 0.5x dip: HWM0
   in bin -1 ratchets +99.99%; post-retrace sell reverts
   `OracleStopLossTriggered(bin=-1, zeroForOne=true, ...)`; still
   frozen +30d; buy direction works.

Note: a 1-unit buy reverts with `FinalAmountIsZero` on ANY pool,
frozen or not — dust output, not the stop-loss. It is not used as
evidence.

### 3. Minimal manual repro (no test file needed)

1. Deploy `MetricOmmPoolFactory` + `MetricOmmPoolDeployer` (or use
   the repo harness) and the shipped `OracleValueStopLossExtension`.
2. `createPool` with the extension ordered under `afterSwap`,
   `drawdownE6 = 100_000` (10%), `decayPerSecondE18 = 0`,
   `timelockSeconds = 0`.
3. Deposit liquidity; seed a swap at price P.
4. Move the mock oracle to 2P and make a small buy — succeeds, HWM
   ratchets to ~2P.
5. Move the mock oracle back to P and buy any amount — reverts
   `OracleStopLossTriggered`, forever (warp +30 days to confirm).

## Suggested fix

- **Enforce a minimum decay > 0 at `initialize`** (or default decay
  when 0 is passed): the extension's own design treats decay as the
  release valve; allowing it to be disabled entirely turns a
  transient wick into a permanent freeze. A protocol-level floor
  (e.g. enough decay to clear a 2x ratchet within days) bounds the
  worst case.
- **Permissionless recovery when the condition no longer holds:**
  allow anyone to reset a bin's watermark when the live metric is
  back below the watermark minus the drawdown — i.e. the stop-loss
  condition has demonstrably cleared. This keeps the safety property
  (a real drawdown still blocks) while removing the permanent
  one-way freeze.
- **Alternatively, cap the watermark** at the current metric plus the
  drawdown on each check, so a fully-retraced price can never leave
  the watermark stranded above the live price.

## PoC repository

https://github.com/Anyeps/metric-stop-loss-watermark-freeze-poc

Contents: this report draft (`REPORT-DRAFT.md`), findings
(`FINDINGS.md`), the Foundry test suite, and the exact repo code under
test vendored verbatim — `contracts/` is `pool-contracts` @ `ddf8ae0`,
`periphery/` is `periphery-contracts` @ `5ceaec3`. No fork, no mainnet
interaction, no secrets. The test file's two relative imports were
adapted for this layout (`../../contracts/...` →
`../../periphery/...`); everything else is verbatim.

## Payout

- **Wallet:** `0x45859319d9a362f2146d0431dc30ab8f0ef1be73`
- **Program:** Metric (Immunefi) — KYC not required.
- **Severity claimed:** Medium (central case); High optimistic if
  triage accepts a permanently one-way pool as a freezing of funds.
  Dollar tier for Medium was not visible on the program page at
  research time (SVG); triage to confirm against the live tier table.

---

*Draft prepared 2026-11-15. NOT submitted. Second/third report for the
Studio wave, behind M-P1-3 (High, permanent freezing of funds) and the
GMX reports. Submission blocked by the Immunefi Novice 100-credit fee;
waiting for the Studio wave verdict.*
