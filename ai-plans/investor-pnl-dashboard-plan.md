# Investor P&L Dashboard in Superset (SQL-only, no Java changes)

## Context

Howard wants a Superset dashboard aimed at an investor audience: how is the strategy platform performing in terms of profit/loss, filterable by `strategy_execution_uid` like the existing drill-down dashboard. The catch: the schema has **no dollar-amount, position-size, or capital-allocation field anywhere** (confirmed by direct DB inspection — `trade_recommendation`/`recommendation_result` only carry per-share prices and percentage returns; every recommendation is implicitly priced per-share with no notional size). Howard resolved this by mapping a fixed notional investment to each recommendation's `confidence` level: **LOW=$80, MEDIUM=$100, HIGH=$120**. All dollar figures in this dashboard are therefore derived, not literal — clearly a deliberate, stated assumption, not a platform limitation.

Scope is **`trade_recommendation` only** (final-phase, real tradeable recommendations) — `analyst_opinion` (non-final-phase reasoning) is excluded entirely from P&L math, per Howard's explicit choice, to avoid overstating invested capital or double-counting symbols.

This is 100% a Superset-side change: one new virtual SQL dataset plus new charts, added to the existing `IDP-Tools/Docker/superset2/build_dashboard.py` script. No Java/IDP-Engine code changes.

## Confirmed schema (read directly from the live DB)

- `trade_recommendation`: id, execution_uid, stock_symbol, confidence (enum HIGH/MEDIUM/LOW), price_at_evaluation_time, stop_loss_price, hold_length_trading_hours, exchange, sell_time, created_at, rationale, response_id.
- `recommendation_result`: id, recommendation_id (→ trade_recommendation.id, no DB-level FK), symbol, start_price, end_price, difference (= end_price - start_price, per-share $), percentage_gain (= difference/start_price * 100), created_at. **18 rows today** — this is the evaluated-outcomes table (not named `evaluation_results` as originally assumed).
- `strategy_execution`: uid, strategy_name, status (COMPLETED/FAILED/RUNNING), started_at, finished_at, failure_phase/failure_analyst/failure_reason, strategy_content (json).
- Join path: `recommendation_result.recommendation_id → trade_recommendation.id → trade_recommendation.execution_uid → strategy_execution.uid`.

## Metrics (all derived via one new virtual SQL dataset)

New virtual dataset `pnl_result`, built from a SQL join of `recommendation_result` → `trade_recommendation` → `strategy_execution`, with two derived columns:

```sql
SELECT
  rr.id,
  rr.created_at,
  rr.symbol,
  rr.start_price,
  rr.end_price,
  rr.difference,
  rr.percentage_gain,
  tr.confidence,
  tr.exchange,
  tr.execution_uid AS strategy_execution_uid,
  se.strategy_name,
  se.started_at AS execution_started_at,
  CASE tr.confidence
    WHEN 'LOW' THEN 80 WHEN 'MEDIUM' THEN 100 WHEN 'HIGH' THEN 120
  END AS amount_invested,
  CASE tr.confidence
    WHEN 'LOW' THEN 80 WHEN 'MEDIUM' THEN 100 WHEN 'HIGH' THEN 120
  END * rr.percentage_gain / 100 AS amount_gained
FROM recommendation_result rr
JOIN trade_recommendation tr ON tr.id = rr.recommendation_id
JOIN strategy_execution se ON se.uid = tr.execution_uid
```

From this one dataset, Superset computes (as SIMPLE/metric aggregations in each chart, no further SQL needed):

1. **Total Amount Invested** ($) — `SUM(amount_invested)` — KPI tile
2. **Total Amount Gained** ($) — `SUM(amount_gained)` — KPI tile (net of losses, since gained is signed)
3. **Net P&L** ($) — same as #2 (gained already nets losses); shown as the headline KPI
4. **Overall Return %** — `SUM(amount_gained) / SUM(amount_invested) * 100` — KPI tile (capital-weighted, not a simple average of percentages)
5. **Win Rate %** — `COUNT(CASE WHEN percentage_gain > 0 THEN 1 END) / COUNT(*) * 100` — KPI tile
6. **Trades Evaluated** — `COUNT(*)` — KPI tile
7. **Cumulative P&L over time** — line chart, x=`created_at` (time grain: day), y=running/cumulative `SUM(amount_gained)`
8. **P&L by Stock Symbol** — bar chart, groupby `symbol`, metric `SUM(amount_gained)`, sorted descending
9. **P&L by Confidence Level** — bar chart, groupby `confidence`, metric `SUM(amount_gained)` (and a second bar chart: `AVG(percentage_gain)` by confidence, to show whether HIGH confidence really outperforms — validates the model's own confidence signal)
10. **Per-Execution Summary** — table, groupby `strategy_execution_uid`/`strategy_name`, metrics: `COUNT(*)` trades, `SUM(amount_invested)`, `SUM(amount_gained)`, `SUM(amount_gained)/SUM(amount_invested)*100` return%

All 10 driven from the single `pnl_result` dataset, so **one native filter** on `strategy_execution_uid` (matching the existing cross-filter pattern) applies to every chart.

## Implementation — extend `IDP-Tools/Docker/superset2/build_dashboard.py`

Reuse every existing building block; this is additive, not a rewrite:

1. **New virtual dataset**: add `PNL_RESULT_SQL` (the query above) as a new module-level constant, next to `RECOMMENDATION_RESULT_SQL`/`ANALYST_OPINION_SQL`. Create it via the existing `get_or_create_virtual_dataset(client, db_id, "pnl_result", PNL_RESULT_SQL)` — same function already used for the other two virtual datasets, no changes needed to that function.

2. **New chart-creation helpers** (new viz_types, following the exact `get_or_create_table_chart` pattern — same POST `params` + PUT `query_context` shape, just different `viz_type`/metric/groupby):
   - `get_or_create_big_number_chart(client, dataset_id, slice_name, metric, subheader)` → `viz_type: "big_number_total"` for metrics 1-6.
   - `get_or_create_timeseries_chart(client, dataset_id, slice_name, metric, time_column, groupby=None)` → `viz_type: "echarts_timeseries_line"` for metric 7 (cumulative — Superset's "Cumulative" post-processing option on the metric, or a `SUM` with an ECharts cumulative operator, applied to a running total of `amount_gained` over `created_at`).
   - `get_or_create_bar_chart(client, dataset_id, slice_name, metric, groupby, order_desc=True)` → `viz_type: "echarts_timeseries_bar"` for metrics 8 and 9.
   - Keep `get_or_create_table_chart` as-is, reused for metric 10 (per-execution summary), just pointed at `pnl_result` with aggregated columns instead of raw ones — actually table charts in `query_mode: "raw"` don't aggregate, so metric 10 needs `query_mode: "aggregate"` with `groupby`+`metrics` instead of `all_columns`; this is a small variant of the existing function, worth a `get_or_create_aggregate_table_chart` rather than overloading the raw one.

3. **Dashboard layout** (`build_position_json`): extend to support a top KPI row (metrics 1-6, 6 charts side by side, e.g. 2 rows of 3 at width 4 each) followed by the existing one-chart-per-row pattern for the line/bar/table charts. This needs minor generalization of `build_position_json` to accept a list of rows, each row being a list of chart_ids with explicit widths, rather than always one full-width chart per row.

4. **New dashboard**: either a second dashboard ("Investor P&L") separate from the existing drill-down dashboard, or a new tab/set of rows appended to the existing one. **Recommend a separate dashboard** — different audience (investor-facing summary vs. operational drill-down), different native filter scope, cleaner to reason about. Reuses `build_native_filter_config` exactly as-is, just pointed at the new dataset's `strategy_execution_uid` column.

5. **`main()`**: add the new dataset + chart + dashboard creation calls alongside the existing ones — same idempotent get-or-create pattern throughout, safe to rerun.

## Verification

1. Run `python3 -I build_dashboard.py` against the running `superset2` stack (already up) — confirm it creates (first run) or confirms-exists (idempotent rerun) the new `pnl_result` dataset, the ~10 new charts, and the new dashboard, printing its URL.
2. Open the dashboard URL and visually confirm: KPI tiles show sensible numbers (given 18 real `recommendation_result` rows today, expect small totals — e.g. total invested in the hundreds of dollars), the cumulative P&L line chart renders, the by-symbol and by-confidence bar charts render, the per-execution table lists real `strategy_execution_uid` values.
3. Select a `strategy_execution_uid` in the native filter and confirm every chart (KPIs included) updates to reflect just that execution's trades.
4. Spot-check one number by hand: pick one `strategy_execution_uid` with a known small number of trades, manually compute `SUM(amount_invested)`/`SUM(amount_gained)` from the confidence-to-dollar mapping and the real `percentage_gain` values already seen (e.g. NET: MEDIUM confidence unknown yet, need to check), and confirm it matches the KPI tile.
