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

Data: TradingView websocket (`CME_MINI:NQ1!`, `CME_MINI:ES1!`), 3-minute bars,
via a small Python bridge (`python/tvfeed.py`). Everything runs locally.

## Run

```matlab
cd 'C:\Users\luuka\OneDrive\Desktop\NQ - ES Pair trade'
run_dashboard          % live dashboard
replay_demo            % offline replay/validation on cached history
```

Close the dashboard window to stop the feed cleanly.

## Files

- `run_dashboard.m` — entry point for the live dashboard
- `replay_demo.m` — offline replay of history through the model, with plots
- `config.json` — all tunables (see below)
- `src/TvFeed.m` — MATLAB↔Python bridge, aligns NQ/ES bars by timestamp
- `src/KalmanHedge.m` — online Kalman filter for `[alpha; beta]`
- `src/RegimeDetector.m` — Markov-switching regime detection
- `app/PairDashboard.m` — the uifigure dashboard
- `python/tvfeed.py` — TradingView websocket client (TViewAPI pattern)
- `data/history_cache.mat` — cached bars for offline replay (auto-created)

## Config (`config.json`)

- `resolution` — bar size in minutes (`"3"`)
- `historyBars` / `warmupBars` — history fetched at startup / OLS warm-up length
- `kalmanDelta` — state noise ratio; **larger = beta adapts faster** (default `1e-5`)
- `zWindow` — rolling window (bars) for the residual z-score (default 60)
- `regimeWindow` — residuals kept for live regime filtering (default 400)
- `pollSeconds` — dashboard poll period
- `tradingviewToken` — optional TradingView session token. Empty = anonymous
  (**delayed** CME data, ~10 min). To get real-time data per your TradingView
  plan: log in to tradingview.com in a browser, copy the `sessionid` cookie
  value, and paste it here. Keep this file private.

## Model notes

- The Kalman filter only updates on **closed** bars; a bar counts as closed
  once a bar with a newer timestamp arrives (robust for delayed feeds). The
  forming bar is shown in the tiles but never enters the filter.
- The residual z-score is computed against a rolling window of innovations
  (mean/std), so "stretched" readings (|z| ≥ 2) are relative to recent
  behavior.
- Regime shading/probability comes from the Markov-switching model's
  smoothed state probabilities over the recent residual window.
- Model outputs only — this tool intentionally generates **no trade signals**.

## Notes / limitations

- The TradingView websocket protocol is unofficial and may change without
  notice. All protocol logic is isolated in `python/tvfeed.py`.
- Requires: MATLAB R2026a (Econometrics Toolbox for regimes), Python 3.12 with
  `websocket-client` (auto-installed by `run_dashboard` if missing).
- Private/educational use.
