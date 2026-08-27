# NQ-ASIA-TRENDLINE-SHORT-001

> **Status: documentation only.** This entry is recorded for reference and is
> deliberately **not** wired into `src/SignalEngine.m`, `pine/nq_es_pair.pine`,
> `config.json`, or `tests/`. The `rule_candidates` block below is the trader's
> own wish-list, not an implementation backlog. Nothing here has been validated
> against the bar cache or the rule engine.

| | |
|---|---|
| Trade ID | `NQ-ASIA-TRENDLINE-SHORT-001` |
| Date (resolved) | **Mon 2026-08-03 → Tue 2026-08-04 ET** (see *Dating* below) |
| Session | Asia, 20:00–00:00 ET |
| Trade window | 23:45 ET → 00:20 ET (crosses midnight into Tuesday) |
| Instrument | NQ1! — NASDAQ 100 E-mini, CME |
| Timeframe | 1m, extended hours |
| Platform | Tradovate (account `LFE05068462550013`) |
| System | APEX v2 signal generator + NQ/ES pair trend lines |
| Direction | Short |
| Result | **+$245.00 — win** |
| Grade | C+ (analysis 7, emotions 5) |

## Dating

The submitted JSON carried `"date": null` with `"day_of_week": "Tuesday"`. The
screenshots resolve it: the chart clock reads `23:57:33 UTC-4 (ET)` on the
session of **Aug 3**, and the day divider immediately to its right is labelled
`TUESDAY` at the `4` axis tick. So the trade was entered late **Monday
2026-08-03 ET** and managed/exited in the first minutes of **Tuesday
2026-08-04 ET** — "Tuesday" in the journal refers to the exit side of midnight.

## The plan as written before the trade

- **Bias:** bearish.
- **Primary target:** 15m bullish gap below.
- **Break-even / trade-not-working level:** 3m bullish gap below.
- **Setup:** NQ/ES pair trend lines approaching the NQ line from below. Wait for
  the lines to **cross**, then enter short.
- **Entry trigger:** the trend-line cross — the first red down arrow marks the
  directional shift (long regime before, short regime after).
- **Exit trigger:** trend lines touch/merge again, **or** a break of structure
  to the upside on the trend lines.
- **Observed cycle length:** lines touched again ≈ **6 minutes** after the
  cross, marking the exit and the flip back to a long regime.
- **Re-entry condition:** wait for another cross before the next short.
- Targets in session: 5.

## During the trade

- Clean rejection at the internal high; price delivering lower.
- Lines merging or a break of structure would be the exit cue.
- **Management intent:** treat as a high-frequency trade — take the move, do not
  hold for the full target if the trend lines converge first.

## Exit

- **Signal given:** the NQ trend line broke above → exit.
- **What actually happened:** the signal was missed. The trend lines were not
  being monitored after entry, so the break was not acted on; the position was
  closed after the fact.
- **Result:** +$245.00.
- **Self-assessment:** take profit was set a little ambitiously; the marked
  levels correctly indicated the trade would not reach it.

## Emotional log (as submitted)

1. Hesitated on closing because price might sweep the Asia highs — but held.
2. Felt happy when price started dumping — reacting to open P&L, not to signal.
3. Got greedy expecting the dump to run all the way to take profit.
4. Greed caused a monitoring failure — stopped watching the trend lines that
   carried the exit signal.
5. Saw the lines cross and still did not exit, wanting more downside.
6. Exited only once price moved strongly to the upside — emotional, not planned.

## Lessons (as submitted)

- The trend-line cross is both the **entry AND the exit** signal — monitoring
  must continue after entry, not just before it.
- Ambitious take-profit targets create the greed that causes the monitoring
  failure.
- Reacting emotionally to open P&L (happiness on the dump) preceded the
  discipline breakdown.
- The marked levels (3m gap = BE, 15m gap = target) did their job; the analysis
  was sound, the execution was not.

## Rule candidates — NOT IMPLEMENTED

Recorded verbatim. None of these exist in the rule engine, and none were added.

| Candidate | Rationale |
|---|---|
| Exit on trend-line cross/merge, no discretion | Both journaled failures stem from overriding a mechanical exit signal |
| Set take profit at the nearest confirmed gap, not the most ambitious one | Ambitious TP was unreachable and drove the greed loop |
| Move to break-even when price reacts at the 3m bullish gap | Pre-defined BE signal from the pre-trade plan |
| Alert on trend-line cross post-entry | Automates the monitoring the trader failed to do manually |

## Screenshot evidence

Referenced in place (not copied into the repo):

1. `C:\Users\luuka\OneDrive\Pictures\Screenshots\Screenshot 2026-08-03 205739.png`
   — full chart, clock `23:57:33 UTC-4`, NQ1! 1m ETH.
   - Bar: `O 28,994.25  H 28,996.50  L 28,988.75  C 28,992.50  (−0.50, −0.00%)`
   - `SHORT NQ` label and a red down arrow near 23:30–23:32, with an `EXIT`
     marker at the same cluster.
   - APEX v2 panel: session `asia`, `bias bullish`, `LONG v1 (live)` /
     `SHORT v2 (shadow)`, HTF zone `4H 28628.00–28865.25`, targets in session
     `5` / `37`, R gate `−1 / +50.00 USD`, **SIGNAL: WAITING / WAITING**.
   - NQ-ES Pair panel: `beta 3.7928`, `alpha −0.03`, `z −0.07`,
     `fair NQ 28992.73`, `regime Calm 23%`.
   - Tradovate footer: Account Balance `50,058.25`, Equity `49,998.25`,
     Profit `+65.00`; Positions 1, Orders 2 (Buy Stop @ ~28,995, Buy Limit @
     ~28,955).
2. `...\Screenshot 2026-08-03 210519.png` — tight crop of the NQ-ES pair
   oscillator only; no readable scale.
3. `...\Screenshot 2026-08-03 211749.png` — zoomed trade window 23:45 → 00:20
   with the `TUESDAY` day divider. Pair panel values on the last bar:
   `28,988.02` / `28,997.94` / `28,979.50`.

## Discrepancies between the JSON and the screenshots

Recorded, not corrected — the JSON is preserved verbatim below.

- **Account balance:** JSON `50958.25` vs screenshot `50,058.25`. Likely a
  digit transposition in the JSON.
- **Equity:** JSON `49918.25` vs screenshot `49,998.25`.
- **Open P&L:** JSON `-65.00` vs screenshot `+65.00` (green). Sign is opposite.
- **Indicator build:** the pair panel shows `beta 3.7928`. The repo's current
  `pine/nq_es_pair.pine` v4 runs the **centered log-log** regression where beta
  is the return elasticity (~1.64). A beta near 3.8 means this chart was running
  a pre-centering build — worth remembering before anyone tries to reconcile
  these screenshots with today's engine output.
- **Signal state:** the APEX panel reads `WAITING` in the screenshot, i.e. the
  capture is from after the trade, consistent with
  `"signal_state_at_review": "WAITING"`.

## Source JSON (verbatim as submitted)

```json
{
  "trade_id": "NQ-ASIA-TRENDLINE-SHORT-001",
  "date": null,
  "day_of_week": "Tuesday",
  "session": "Asia",
  "session_window_et": "20:00-00:00",
  "trade_window_et": "23:45-00:20",
  "instrument": "NQ1! (NASDAQ 100 E-mini Futures, CME)",
  "chart_timeframe": "1m",
  "platform": "Tradovate",
  "system": "APEX v2 signal generator + NQ/ES pair trend lines",
  "direction": "short",
  "signal_state_at_review": "WAITING",

  "pre_trade": {
    "bias": "bearish",
    "htf_context": "15m bullish gap below = primary price target",
    "secondary_level": "3m bullish gap below = break-even / trade-not-working signal",
    "setup": "NQ/ES pair trend lines approaching the NQ line from below. Wait for the lines to cross, then enter short. Trade is held until the lines meet again, or until a dump followed by a break of structure to the upside on the trend lines.",
    "entry_trigger": "Trend line cross (first red down arrow marks the directional shift: long regime before, short regime after)",
    "exit_trigger": "Trend lines touch/merge again, or break of structure to the upside",
    "observed_cycle_length": "Lines touched approximately 6 minutes after the cross, marking the exit / change of direction and the switch back to a long regime",
    "re_entry_condition": "Wait for the trend lines to cross again before taking the next short",
    "targets_in_session": 5,
    "account_balance_at_open": 50958.25,
    "equity_at_open": 49918.25,
    "open_pl_at_screenshot": -65.00
  },

  "during_trade": {
    "observations": [
      "Clean rejection at the internal high; price delivering lower",
      "Lines merging or a break of structure would be the exit cue for a quick high-frequency trade"
    ],
    "management_plan": "Treat as a high-frequency trade — take the move, do not hold for the full target if the trend lines converge first"
  },

  "post_trade": {
    "exit_reason": "NQ trend line broke above, signalling exit",
    "execution_quality": "Missed the signal — was not monitoring the trend lines and did not exit at the break; exited after the close",
    "result_usd": 245.00,
    "outcome": "win",
    "notes": "Take profit was set a little ambitiously; the marked levels correctly indicated the trade was not going to reach it"
  },

  "grades": {
    "trade_grade": "C+",
    "analysis": 7,
    "emotions": 5
  },

  "emotional_log": [
    "Hesitated on closing because of the possibility that price would sweep the Asia highs — but held the position",
    "Felt happy when price started dumping (reacting to open P&L rather than to the signal)",
    "Got greedy expecting the dump to run all the way to take profit",
    "Greed caused a monitoring failure — stopped watching the trend lines that carried the exit signal",
    "Saw the lines cross and still did not exit, wanting more downside",
    "Exited only once price moved strongly to the upside — an emotional exit, not a planned one"
  ],

  "lessons": [
    "The trend-line cross is both the entry AND the exit signal — monitoring must continue after entry, not just before it",
    "Ambitious take-profit targets create the greed that causes signal-monitoring failure",
    "Reacting emotionally to open P&L (happiness on the dump) preceded the discipline breakdown",
    "The marked levels (3m gap = BE, 15m gap = target) did their job; the analysis was sound, the execution was not"
  ],

  "rule_candidates": [
    {
      "rule": "Exit on trend-line cross/merge, no discretion",
      "rationale": "Both journaled failures on this trade stem from overriding a mechanical exit signal"
    },
    {
      "rule": "Set take profit at the nearest confirmed gap, not the most ambitious one",
      "rationale": "Ambitious TP was unreachable and drove the greed loop"
    },
    {
      "rule": "Move to break-even when price reacts at the 3m bullish gap",
      "rationale": "Pre-defined BE signal from the pre-trade plan"
    },
    {
      "rule": "Alert on trend-line cross post-entry",
      "rationale": "Automates the monitoring the trader failed to do manually"
    }
  ]
}
```
