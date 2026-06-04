# VJ146A2 Excess-Darkness Eskom MLR Validation: No-Control Exploratory Metric

**Date:** 2026-06-03
**Status:** Working validation note, not promoted as canonical method
**Workstream:** reliability-assessment
**Related logs:** [[5-logs/shared/2026-06-03-1755-vj-full-year-mlr-validation]], [[5-logs/shared/2026-06-03-1825-vnp-full-year-mlr-validation]]
**Related script:** [[6-codebases/repos/Reliability-Assessment/Builder/vj146a2_2023_excess_dark_mlr_validation.R]]

## Purpose

This note records a separate VJ-only validation script requested as a comparison against the current Ravi-style Eskom MLR validation. The goal was to test a cleaner metric without adding regression controls:

`population-weighted excess darkness = max(0, settlement expected lit share - observed lit share)`

The expected lit share is estimated settlement by settlement from no-MLR baseline nights.

## Method

The script uses:

- VJ yearly-keep daily panels from `settlement_day_vj146a2_cov_yearlykeep_2023-01.parquet` through `2023-12`;
- VJ annual settlement stats from `yearly_settlement_stats_2023.parquet`;
- Eskom hourly MLR from `eskom_2023_hourly_clean.csv`;
- date rule `local_overpass_date = product_date + 1`;
- primary exposure `01:00-02:00 SAST`;
- no controls, with every validation model of the form `outcome ~ Eskom shed share`.

Metric defaults:

- settlement population minimum: `100`;
- daily coverage minimum: `0.80`;
- baseline nights: `shed_share <= 0`;
- minimum no-MLR baseline days: `15`;
- fallback baseline: all-quality median lit share;
- eligible expected lit share minimum: `0.70`.

The headline metric uses a fixed eligible-population denominator so high-MLR days cannot mechanically inflate the outcome by dropping observed population support. The observed-denominator version is retained only as a sensitivity.

Outputs were written to:

`6-codebases/repos/Reliability-Assessment/Map Data/settlement_day_outputs_vj146a2/mlr_validation_excess_dark_2023/`

## Baseline Support

Eligible settlements: `5,025`
Eligible population: `54,217,158`

| Baseline method | Eligible | Settlements |
|---|---:|---:|
| no-MLR median | TRUE | 5,015 |
| all-quality median fallback | TRUE | 10 |
| no-MLR median | FALSE | 547 |

The fallback count is small, so the national metric is mainly anchored on settlement-specific no-MLR baselines.

## Headline Result

For the primary alignment, the no-control model is:

`popw_excess_dark ~ shed_share_product_date_plus1_primary`

| Outcome | Effect, pp excess dark per 10 pp shed | p | r | R2 | N |
|---|---:|---:|---:|---:|---:|
| population-weighted excess darkness | 2.45 | 8.55e-15 | 0.393 | 0.155 | 361 |

The 95 percent interval for the effect is approximately `1.86` to `3.04` pp excess darkness per 10 pp shed.

## Alignment Checks

| Eskom alignment | Effect, pp per 10 pp shed | p | r | R2 | N |
|---|---:|---:|---:|---:|---:|
| product date - 1 | 2.03 | 2.05e-10 | 0.327 | 0.107 | 361 |
| product date same | 2.39 | 3.21e-14 | 0.385 | 0.148 | 362 |
| product date + 1 primary | 2.45 | 8.55e-15 | 0.393 | 0.155 | 361 |
| product date + 2 | 1.71 | 1.31e-07 | 0.274 | 0.075 | 360 |

Grounded finding: the intended `product date + 1` alignment is strongest, but same-date exposure is close. The signal is not merely a one-day placebo artifact, but date separation remains less sharp than in the binary-darkness metric.

## Window Checks

| Eskom window | Effect, pp per 10 pp shed | p | r | R2 | N |
|---|---:|---:|---:|---:|---:|
| 00:00-01:00 | 2.54 | 1.21e-14 | 0.391 | 0.153 | 361 |
| 01:00-02:00 primary | 2.45 | 8.55e-15 | 0.393 | 0.155 | 361 |
| 02:00-03:00 | 2.50 | 8.62e-15 | 0.393 | 0.155 | 361 |
| 01:00-03:00 | 2.49 | 7.20e-15 | 0.394 | 0.155 | 361 |

Grounded finding: the result is robust across adjacent nighttime windows.

## Comparison With Current Ravi-Style Metrics

| Metric | Effect, pp per 10 pp shed | p | r | R2 | N |
|---|---:|---:|---:|---:|---:|
| New excess-dark metric | 2.45 | 8.55e-15 | 0.393 | 0.155 | 361 |
| Existing population-weighted strict-dark share | 2.72 | 1.00e-54 | 0.701 | 0.492 | 361 |
| Existing population-weighted mostly-dark share | 4.38 | 1.06e-54 | 0.701 | 0.492 | 361 |

Interpretation: the excess-dark metric is conceptually cleaner because it measures darkness relative to each settlement's own no-MLR baseline, but it is materially weaker as a simple daily no-control Eskom validation metric.

## Dose Response

| Shed-share quintile | Mean shed share | Mean excess darkness, pp | Mean observed population share |
|---:|---:|---:|---:|
| 1 | 0.000 | 1.13 | 0.644 |
| 2 | 0.023 | 1.21 | 0.493 |
| 3 | 0.061 | 2.50 | 0.474 |
| 4 | 0.085 | 2.79 | 0.406 |
| 5 | 0.112 | 3.81 | 0.403 |

The dose response is weak between the first two bins but becomes clear at higher MLR levels.

## Conclusion

This separate no-control script is useful as a diagnostic, but it should not replace the existing report-facing Ravi-style validation yet. The better current stance is:

- keep VJ as the primary product;
- keep the existing population-weighted strict and mostly-dark shares as the stronger validation metrics;
- use excess darkness as a sensitivity that tests whether the Eskom relationship survives settlement-specific no-MLR baseline adjustment;
- revisit controls or stable-sample restrictions later, because observed eligible-population support declines on high-MLR days.
