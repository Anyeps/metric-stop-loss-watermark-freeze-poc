# Metric — Stop-loss high watermark freezes one swap direction after a fully-retraced oracle spike (decay = 0)

**Finding:** the shipped `OracleValueStopLossExtension` ratchets each
bin's high watermark UP on any metric increase and never lowers it; the
only release is lazy linear decay, and `decayPerSecondE18 == 0`
explicitly disables decay. A permissionless swapper plus an ordinary
oracle wick can therefore brick one swap direction forever: seed the
watermark at price P, wick the oracle to 2P (a small swap at the extreme
ratchets the rising metric's watermark up ~1:1 with the wick), let the
price retrace fully to P — and every swap in that direction now reverts
`OracleStopLossTriggered`, indefinitely at decay 0, with no admin
action. Only the pool admin's timelocked watermark reset repairs it.

**Severity: Medium (honest central case); High is the optimistic case**
if triage accepts a permanently one-way pool as a freezing of funds.
The frozen thing is a **swap direction, not funds at rest**: LPs can
still exit in full (measured 99.997% / 100.004%), and a swapper's
transaction simply reverts — no funds are lost. So "Permanent freezing
of funds" is a stretch; the honest impact fit is closer to "Temporary
freezing of funds" (also a listed High impact) or Medium. See
`REPORT-DRAFT.md` for the full honest assessment, including the
intended-behaviour risk (a stop-loss cannot distinguish a spike from a
real high) and the open questions (do live stop-loss pools actually use
decay 0? how long are the live timelocks?).

**Measured (local deploy of the exact repo code, no fork):** 2x wick →
watermark +99.99%; buy reverts `OracleStopLossTriggered` after a full
retrace, still frozen after +30 days; sells keep working. A 1.2x wick
also freezes the direction (+19.99% ratchet vs a 10% drawdown — and a
5% drawdown). Downward wicks freeze the opposite direction
symmetrically. With 5%/day decay the direction thaws at +10 days.
Admin watermark reset unblocks immediately.

The trigger needs no admin, no fabricated or stale price, no
manipulation: one tiny swap at the wick extreme (1,000 base units) plus
an ordinary market wick. A 20% wick is routine in crypto/RWA markets.

## Files

- `REPORT-DRAFT.md` — full Immunefi report draft (severity Medium,
  High optimistic), incl. the 7-question gate, the honest severity
  discussion, and the suggested fix.
- `FINDINGS.md` — verdict + measured evidence (8/8 tests).
- `test/extensions/MP14StopLossFreeze.t.sol` — Foundry tests (8 tests).
- `contracts/` — `pool-contracts` @ `ddf8ae0`, vendored verbatim.
- `periphery/` — `periphery-contracts` @ `5ceaec3`, vendored verbatim.
- `test/MetricOmmPool.base.t.sol`, `test/PoolStateTestLib.sol`,
  `test/ExtensionOrderTestLib.sol`, `test/FactoryFeeCapsStub.sol`,
  `test/PoolInitPreprocessor.sol`, `test/mocks/` — the repo's own test
  harness, vendored verbatim.

Note: the test file's two relative imports were adapted for this
layout (`../../contracts/...` → `../../periphery/...`); everything
else is verbatim. The upstream file lives at
`periphery-contracts/test/extensions/` in the pinned repo.

## Reproduce

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

## Notes

- The vendored Metric code retains its original SPDX headers and
  licenses (see `licenses/`). Upstream repos:
  `pool-contracts` @ `ddf8ae0`, `periphery-contracts` @ `5ceaec3`.
- This differs from the known September Sherlock M-8 (a precision
  false NEGATIVE — the check MISSES a real 10% drawdown). M-P1-4 is a
  false POSITIVE — the check BLOCKS after a fully-retraced spike.
  Different root cause, opposite direction.
- The High / Medium / Low dollar tiers were not visible on the Metric
  program page at research time (rendered as SVG); the draft claims the
  listed impact, not a dollar figure.
- Metric program: https://immunefi.com/bug-bounty/metric/information/
  (KYC not required; PoC required; no mainnet testing).

## Status

Report draft prepared 2026-11-15. **NOT submitted** — this is a
second/third report for the Studio wave, behind M-P1-3 and the GMX
reports; submission is blocked by the Immunefi Novice 100-credit fee.
