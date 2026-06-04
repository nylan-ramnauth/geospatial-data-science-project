# VJ146A2 PyPSA Uptime and Validation Target Alignment

Date: 2026-06-04
Actor: Codex
Workstream: reliability-assessment / PyPSA integration
Related report: [[validation/eskom_mlr/reports/2026-06-03-recommended-vj-eskom-validation-specification.Rmd]]

## Objective

The PyPSA-facing uptime metric should be constructed in the same way as the VJ/Eskom regression target, so the validation result applies directly to the annual LocalArea proxy used in the model.

The recommended VJ/Eskom validation report now shows that Eskom MLR is strongly associated with daily VJ darkness and not-up shares. The relevant thresholds are:

- `p_lit_sett < 0.05`: strict dark
- `p_lit_sett < 0.20`: mostly dark
- `p_lit_sett < 0.40`: relaxed / not-up

The main PyPSA ENS proxy should therefore be based on the same daily demand-weighted not-up construction, especially for the `p_lit_sett < 0.40` threshold.

The PyPSA-facing construction should also use the same standard cleaned daily universe as the regression:

- remove the annual-IQR excess-lit dates used in the recommended validation specification
- keep only LocalArea-days where at least 40% of assigned LocalArea demand is observed in the VJ settlement panel

## Best Regression Specification to Align With

The PyPSA-facing uptime repair should align most directly with the demand-weighted bridge regression in the recommended validation report:

```text
demandw_relaxed_dark_share_t ~ shed_share_1_2am_primary_t
```

where:

```text
demandw_relaxed_dark_share_t =
  national daily demand-weighted mean of 1[p_lit_i,t < 0.40]

shed_share_1_2am_primary_t =
  sum(Eskom MLR from 01:00-02:00 SAST) /
  sum(RSA Contracted Demand from 01:00-02:00 SAST)
```

The preferred validation sample keeps national dates that pass the VJ demand-support gate and removes dates flagged by the annual-IQR excess-lit screen. The PyPSA local-area metric should use the same date-removal logic and the same daily demand-weighted not-up object, localized to each Eskom LocalArea.

## Files to Read Before Implementation

An implementing agent should read only these core files before editing code:

### Core Validation Context

- `validation/eskom_mlr/reports/2026-06-03-recommended-vj-eskom-validation-specification.Rmd`
- `validation/eskom_mlr/data/vj146a2_2023_annual_iqr_excess_lit_day_flags.csv`

### Uptime Implementation Targets

- `validation/pypsa_uptime/scripts/build_vj146a2_pypsa_localarea_demand_weighted_uptime.R`
- `validation/pypsa_uptime/reports/2026-06-04-vj146a2-pypsa-demand-weighted-uptime.md`
- `validation/pypsa_uptime/reports/2026-06-04-vj146a2-localarea-uptime-excess-lit-exclusion.md`
- `validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_demand_weighted_uptime.csv`

### Minimum Upstream Inputs

- `6-codebases/repos/Reliability-Assessment/Builder/settlement_day_panel_build_vj146a2.R`
- `6-codebases/repos/Reliability-Assessment/Map Data/reliability_outputs_vj146a2/settlement_day_states_strict_yearlykeep_annual_excess_lit_iqr.parquet`
- `6-codebases/repos/Reliability-Assessment/Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_simplified_full_col.gpkg`
- `6-codebases/repos/Reliability-Assessment/Map Data/Local Area/LOCAL_AREA_GCCA2025.shp`

Optional, only if updating canonical docs after implementation:

- `3-wiki/reliability-assessment/architecture.md`
- `3-wiki/integration/data-interface.md`

## Current Uptime Construction

The current PyPSA uptime script uses a settlement-first construction:

```text
For each settlement i:
  uptime_i = mean over observed days of 1[p_lit_i,t >= 0.40]

For each LocalArea a:
  uptime_a = demand-weighted mean of uptime_i across settlements
```

Equivalently:

```text
LocalArea uptime =
  weighted_mean_i(mean_t(1[p_lit_i,t >= 0.40]), demand_i)
```

This is a valid settlement reliability summary, but it is not exactly the same object validated in the Eskom MLR regression.

The issue is aggregation order. The current construction averages over time first at settlement level, then demand-weights settlements. Because settlements have different observed days due to cloud cover, missing rasters, coverage filters, and support gates, this can differ from a daily demand-weighted target.

## Regression Target Construction

The validated regression target is daily-first:

```text
For each date t:
  target_t =
    demand-weighted mean of 1[p_lit_i,t < threshold]
    across observed settlements on that date
```

For the `0.40` not-up bridge:

```text
demandw_relaxed_dark_share_t =
  weighted_mean_i(1[p_lit_i,t < 0.40], demand_i)
```

This is the object shown to move with Eskom MLR. Therefore, the PyPSA annual uptime proxy should be the annual aggregation of the same daily demand-weighted object.

## Recommended Updated Construction

For each threshold, construct the LocalArea metric daily first, then average over the year.

```text
Start from VJ146A2 daily settlement states:
  remove annual-IQR excess-lit dates used in the regression
  keep observed settlement-days with non-missing p_lit_i,t
  keep electrified/post-DOE settlement-days
  keep settlement-days with positive demand and assigned LocalArea

For each LocalArea a and date t:
  observed_demand_share_a,t =
    sum(demand_i for observed eligible settlements in LocalArea a on date t) /
    sum(demand_i for all eligible settlements in LocalArea a)

  keep the LocalArea-day only if observed_demand_share_a,t >= 0.40

  not_up_share_a,t =
    demand-weighted mean of 1[p_lit_i,t < threshold]
    across observed electrified settlements in LocalArea a

For each LocalArea a and year:
  annual_not_up_share_a =
    mean_t(not_up_share_a,t)

  annual_availability_a =
    1 - annual_not_up_share_a
```

In compact notation:

```text
annual_not_up_share_a =
  mean_t(weighted_mean_i(1[p_lit_i,t < threshold], demand_i))

annual_availability_a =
  1 - annual_not_up_share_a
```

This aligns the PyPSA-facing metric with the validated regression target.

## National Gate Versus LocalArea Gate

The regression uses a national daily demand-support gate to decide whether a VJ product date enters the validation sample. The PyPSA-facing metric should use the LocalArea analogue:

```text
LocalArea-day observed_demand_share >= 0.40
```

This means different LocalAreas may retain different dates in the annual average. That is intentional. The regression establishes the national daily signal under the standard national support screen; the PyPSA metric localizes the same support logic so each LocalArea annual metric is averaged only over days with enough observed LocalArea demand.

## Recommended Output Columns

The updated PyPSA-facing file should include three threshold-specific metrics for sensitivity analysis:

| Threshold | Annual not-up/dark metric | Availability complement |
|---|---|---|
| `p_lit < 0.05` | `strict_dark_005_share_demandw` | `availability_005_demandw` |
| `p_lit < 0.20` | `mostly_dark_020_share_demandw` | `availability_020_demandw` |
| `p_lit < 0.40` | `not_up_040_share_demandw` | `availability_040_demandw` |

The preferred PyPSA ENS proxy should be:

```text
not_up_040_share_demandw
```

with:

```text
availability_040_demandw = 1 - not_up_040_share_demandw
```

## Backward Compatibility

The current settlement-first `uptime_demandw` should be retained as a diagnostic or compatibility column, but it should not be treated as the main validated PyPSA proxy.

Suggested naming:

```text
uptime_demandw_settlement_first
```

Alternatively, keep the old name with a clear note:

```text
uptime_demandw = settlement-first legacy availability metric
```

The main model-facing columns should be the daily-first threshold-specific metrics above.

The output should also include direct comparison fields so the construction change is auditable:

```text
uptime_demandw_settlement_first
availability_040_demandw_daily_first
delta_availability_040_daily_minus_settlement_first
```

The old settlement-first value is useful for continuity checks, while the daily-first availability and not-up columns should be treated as the validated PyPSA-facing construction.

## Daily Audit Output

Implementation should emit a LocalArea-day diagnostic file in addition to the annual PyPSA-facing file. Recommended columns:

```text
area_name
date
observed_demand
area_demand
observed_demand_share
localarea_demand_gate
strict_dark_005_share_demandw_day
mostly_dark_020_share_demandw_day
not_up_040_share_demandw_day
availability_005_demandw_day
availability_020_demandw_day
availability_040_demandw_day
n_observed_settlements
n_eligible_settlements
excess_lit_screen
```

This daily file is the audit bridge between the validated daily regression target and the annual LocalArea PyPSA input.

## Interpretation

The updated construction makes the validation claim cleaner:

```text
The regression validates daily demand-weighted not-up shares.
The PyPSA input is the annual average of those same daily demand-weighted not-up shares.
```

This gives a direct bridge from the VJ/Eskom validation exercise to the spatial annual ENS-proxy input used in PyPSA.

## Implementation Implication

The uptime builder should change the main aggregation order from:

```text
settlement annual mean -> LocalArea demand-weighted mean
```

to:

```text
same regression date screen -> LocalArea-day observed-demand gate ->
LocalArea daily demand-weighted mean -> LocalArea annual mean
```

The old settlement-first metric should remain in the output for comparison. The new daily-first `not_up_040_share_demandw` should be the preferred model-facing ENS proxy, with `strict_dark_005_share_demandw` and `mostly_dark_020_share_demandw` used as sensitivity cases.
