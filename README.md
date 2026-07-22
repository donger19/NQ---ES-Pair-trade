# NQ–ES Pair Trading Model (MATLAB, private/local)

Models NQ as a time-varying regression on ES:

```
NQ_t = alpha_t + beta_t * ES_t + e_t
```

| Term | Meaning | How it's computed |
|---|---|---|
| `alpha_t` | intercept / starting offset | Kalman filter state, updated every closed bar |
| `beta_t` | hedge ratio — how strongly NQ moves with ES | Kalman filter state, updated every closed bar |
| `e_t` | residual — the part of NQ the regression can't explain | innovation (actual NQ − predicted NQ), shown raw and as a rolling z-score |

A 2-state Markov-switching model (Econometrics Toolbox) classifies the market
regime — **Calm / mean-reverting** vs **Volatile / stressed** — from the
residual series, with a volatility-ratio fallback if estimation fails.

Data: TradingView websocket (`CME_MINI:NQ1!`, `CME_MINI:ES1!`), 1-minute bars,
via a small Python bridge (`python/tvfeed.py`). Everything runs locally.

## Run

```matlab
cd 'C:\Users\luuka\OneDrive\Desktop\NQ - ES Pair trade'
run_dashboard          % live dashboard (model outputs only, no signals)
replay_demo            % offline replay/validation on cached history
backtest_rules         % replay history through the v3 rule engine
sweep_params           % walk-forward sweep: entry z x confirmation window
runtests('tests')      % unit tests for every trading rule
```

Close the dashboard window to stop the feed cleanly.

## The v3 rule set (journaled 2026-07-20/21, encoded in Pine + SignalEngine)

The live trading surface is **`pine/nq_es_pair.pine` (v3)** on a 1-minute
chart. `src/SignalEngine.m` is a bar-close mirror of the same state machine
used only for backtesting and tests — the MATLAB dashboard still emits no
signals.

State machine:
`FLAT → CONVERGENCE_ARMED → SIGNAL_PENDING → IN_POSITION → TP_ZONE → FLAT`,
with `IN_POSITION → REVERSAL_ELIGIBLE → FLAT` on an adverse trend cross.
Direct z-spike fades enter at `SIGNAL_PENDING`; convergence arming is a
parallel path, not a prerequisite.

1. **Entry gate** — fades require |z| ≥ `entryZ` (default 2.0). Entries in
   the 1.5–1.97 band are structurally impossible.
2. **Spike confirmation & momentum veto** — never enter on the breach bar
   (hard-coded: minimum one-bar delay, so `confirmBars` 0 and 1 behave the
   same). Confirmation checks the stretch against the **fair value frozen at
   the breach bar** (`zHold`), because closed-bar Kalman innovations are
   near-white — the filter absorbs each spike on the next update, so the
   rolling z cannot "persist" by construction; the frozen-fair stretch is
   the same quantity the live forming-bar z shows. Entry additionally
   requires momentum to settle: |z velocity| ≤ `zVelMax` and |NQ ROC| ≤
   `rocMax`. Beyond `zHardStop` (±4) nothing arms — an extreme reading
   printed by a violent move is the move registering, not a fade signal.
3. **Chop filter** — ≥ `chopReversals` zero-crossings of z inside
   ±`chopBand` over `chopWindow` bars with no excursion beyond the band
   → no arming/entry; exit-flat if in position.
4. **Risk & exits** — position size derived from `maxRiskUSD` (default $500):
   `nNQ = floor(maxRisk / (stopPts × $20))`, `stopPts = stopZ × σ_resid`;
   ES hedge `nES = round(nNQ × β × 20/50)`; falls back to micros (MNQ/MES)
   when 1 NQ already exceeds the budget. TP mode: **2R runner** or
   **Quick 1R**. z-consolidation exit: rolling z inside ±`consolBand` for
   `consolBars` consecutive bars. R-multiples are logged **in pair price
   terms** (NQ leg − β·ES leg over the stop distance), i.e., real dollars,
   not z-units.
5. **Trend-cross entry / reversal** — convergence of the normalized trend
   lines arms a pending entry; the trigger cross is **directional**
   (bearish context: NQ crossing *up* into ES → short NQ / long ES).
   An adverse cross against an open position → `REVERSAL_ELIGIBLE`
   (flip toward the manual gap if aligned, else flatten).
6. **Intertwine** — trend gap pinned inside `intertwineBand` for
   `intertwineBars` bars counts as a setup (feeds rule 5) when regime
   context is defined; neutral regime (pVol 0.40–0.60) stands down.
7. **Latency** — Pine recalcs every tick of the chart feed. The dominant
   residual delay is the **anonymous TradingView feed (~10 min)**; fixing
   it requires a session token (see Config). Bars are 1-minute now.
8. **Manual ICT gap bias** — indicator inputs: gap direction, level, and
   policy (`block` / `half` / `off`) for counter-gap entries.

Note: the old v2 "calm regime only" alert gate is now **off by default** —
z spikes coincide with the volatile regime flag almost by definition, so it
blocked every fade; the rule-2 momentum veto replaces it.

## Files

- `run_dashboard.m` — entry point for the live dashboard
- `replay_demo.m` — offline replay of history through the model, with plots
- `backtest_rules.m` — v3 rule backtest; validates the two journaled trades
  (Trade 1 filtered, Trade 2 taken with confirmation delay) by matching z
  excursions, and logs every closed trade with its R-multiple
- `sweep_params.m` — walk-forward grid: entryZ 1.8–2.5 × confirmBars 0–3
- `config.json` — all tunables incl. the `signal` block (see below)
- `src/TvFeed.m` — MATLAB↔Python bridge, aligns NQ/ES bars by timestamp
- `src/KalmanHedge.m` — online Kalman filter for `[alpha; beta]`
- `src/RegimeDetector.m` — Markov-switching regime detection
- `src/SignalEngine.m` — bar-close mirror of the Pine v3 state machine
- `src/computeFeatures.m` — per-bar features (Kalman, trends, regime) for backtests
- `src/loadPairHistory.m` — resolution-keyed history cache
- `app/PairDashboard.m` — the uifigure dashboard (unchanged, no signals)
- `pine/nq_es_pair.pine` — **v3 indicator: the live trading surface**
- `tests/` — `runtests('tests')`: unit tests for every rule + sizing
- `data/history_cache_*.mat` — cached bars per resolution (auto-created)

## Config (`config.json`)

- `resolution` — bar size in minutes (`"1"`)
- `historyBars` / `warmupBars` — history fetched at startup / OLS warm-up length
- `kalmanDelta` — state noise ratio; **larger = beta adapts faster** (default `1e-5`)
- `zWindow` — rolling window (bars) for the residual z-score (default 60)
- `regimeWindow` — residuals kept for live regime filtering (default 400)
- `pollSeconds` — dashboard poll period
- `tradingviewToken` — optional TradingView session token. Empty = anonymous
  (**delayed** CME data, ~10 min). To get real-time data per your TradingView
  plan: log in to tradingview.com in a browser, copy the `sessionid` cookie
  value, and paste it here. Keep this file private.
- `signal.*` — every v3 rule threshold (names mirror the Pine inputs):
  `entryZ`, `confirmBars`, `velBars`, `zVelMax`, `rocMax`, `chopBand`,
  `chopReversals`, `chopWindow`, `consolBand`, `consolBars`, `maxRiskUSD`,
  `tpMode` (`"2R"`/`"1R"`), `stopZ`, `zExit`, `zHardStop`, `armDist`,
  `convBars`, `intertwineBand`, `intertwineBars`, `gapDir`, `gapPolicy`,
  `calmOnly`, `ptValue*` (NQ/ES/MNQ/MES $ per point).

## Model notes

- The Kalman filter only updates on **closed** bars; the forming bar is
  shown in the tiles but never enters the filter.
- Closed-bar innovations are ~white by construction. Anything that needs a
  *persistent* stretch (spike confirmation, reversion exit) is therefore
  measured against the fair value **frozen at the spike bar**, which is what
  the forming-bar display shows live.
- Regime shading/probability comes from the Markov-switching model's
  smoothed state probabilities over the recent residual window.
- The MATLAB dashboard emits **no trade signals**; signals live in the Pine
  indicator, and `SignalEngine` exists to test/backtest the same rules.

## Notes / limitations

- **Delayed data**: without a session token, live signals run ~10 min behind
  the market. The rules are consistent in chart time, but live execution
  timing inherits the delay.
- **Confirmation granularity**: Pine cannot confirm on wall-clock seconds
  without repainting, so the "~30 s" journal rule is implemented as
  confirmed bars (1 bar @ 1-min ≈ 30–60 s). The state machine never enters
  on the breach bar, so the minimum effective delay is one bar.
- **Backtest stops are evaluated at bar close**, so a fast adverse bar can
  log worse than −1R (e.g., −1.9R). Live, a resting stop order would cap
  this; treat backtest stop-losses as pessimistic.
- **Prop-firm rules**: none are encoded here. The $500/trade cap is enforced
  by sizing, but check the worst-case loss in the size table against your
  account's daily-drawdown rules yourself.
- The TradingView websocket protocol is unofficial and may change without
  notice. All protocol logic is isolated in `python/tvfeed.py`.
- Requires: MATLAB R2026a (Econometrics Toolbox for regimes), Python 3.12 with
  `websocket-client` (auto-installed by `run_dashboard` if missing).
- Private/educational use.
