# VJ146A2 Eskom MLR Validation: Full-Year 2023 Calibration

**Date:** 2026-06-03
**Status:** Working validation note
**Workstream:** reliability-assessment
**Supersedes:** [[validation/eskom_mlr/reports/2026-06-03-vj-jan-jun-mlr-validation-comparison]]
**Related logs:** [[5-logs/shared/2026-06-03-1737-vj-prestage2-stage2-run]], [[5-logs/shared/2026-06-03-1708-vj-jan-jun-mlr-validation]]

## Purpose

This note records the full-year VJ146A2 Eskom MLR validation after July-December Stage 3 and Stage 3b were completed. It updates the Jan-June result to the full available 2023 VJ panel and checks whether the satellite darkness signal still calibrates against Eskom manual load reduction around the VJ local overpass window.

The answer is yes. The full-year validation strengthens the main result: higher Eskom shed share around the local overpass is strongly associated with higher VJ population-weighted settlement darkness.

## Pipeline Completion

Stage 2 had already produced all 12 monthly no-coverage-filter VJ panels. This run completed the second-half downstream stages:

```bash
VJ146A2_START_MONTH=2023-07 VJ146A2_END_MONTH=2023-12 Rscript Builder/settlement_day_coverage_filter_vj146a2.R
VJ146A2_START_MONTH=2023-07 VJ146A2_END_MONTH=2023-12 Rscript Builder/settlement_day_yearlykeep_filter_vj146a2.R
Rscript Builder/vj146a2_2023_mlr_validation.R
Rscript Visualizer/reliability_panel_build_yearlykeep_vj146a2.R
```

Full-year MLR output folder:

```text
6-codebases/repos/Reliability-Assessment/Map Data/settlement_day_outputs_vj146a2/mlr_validation_2023/
```

Full-year reliability output folder:

```text
6-codebases/repos/Reliability-Assessment/Map Data/reliability_outputs_vj146a2/
```

## Stage 3 and 3b Results

The July-December coverage filter retained most settlements at least once per month, but removed many settlement-day observations:

| Month   | Rows before | Rows after coverage | Settlements before | Settlements after | Settlements fully removed |
| ------- | ----------: | ------------------: | -----------------: | ----------------: | ------------------------: |
| 2023-07 |     428,699 |             315,501 |             13,829 |            13,828 |                         1 |
| 2023-08 |     428,699 |             308,787 |             13,829 |            13,827 |                         2 |
| 2023-09 |     401,041 |             251,836 |             13,829 |            13,829 |                         0 |
| 2023-10 |     414,870 |             241,800 |             13,829 |            13,829 |                         0 |
| 2023-11 |     414,870 |             207,027 |             13,829 |            13,828 |                         1 |
| 2023-12 |     428,699 |             199,352 |             13,829 |            13,829 |                         0 |

Stage 3b did not remove additional rows because Stage 2 was already run against the VJ annual-composite yearly keep list. It materialized the monthly `cov_yearlykeep` files needed by MLR validation and Stage 5.

Across the full-year coverage-filtered yearlykeep panel:

| Metric | Value |
|---|---:|
| Unique yearlykeep settlements | 13,829 |
| Retained settlement-days | 2,952,465 |
| Mean retained observation days per settlement | 213.5 |
| Median retained observation days per settlement | 227 |
| 25th percentile retained days | 180 |
| 75th percentile retained days | 245 |
| Minimum retained days | 18 |
| Maximum retained days | 316 |
| Settlements with at least 85 retained days | 13,816 |
| Settlements with at least 180 retained days | 10,416 |

This is enough support for full-year settlement-level reliability and national MLR validation. The full-year 85-day minimum is met by almost all yearlykeep settlements.

## Daily Panel and Date Alignment

The MLR validation keeps the established local-clock alignment:

```text
local_overpass_date = vj_product_date + 1
```

The primary Eskom exposure is the hour beginning `01:00 SAST`, interpreted as the `01:00-02:00` local overpass window.

The validation daily panel contains:

| Quantity | Value |
|---|---:|
| VJ product-date rows in daily panel | 362 |
| Product-date range | 2023-01-01 to 2023-12-31 |
| Local-overpass-date range | 2023-01-02 to 2024-01-01 |
| Regression days with non-missing primary Eskom exposure | 361 |
| Mean Eskom shed share, 01:00-02:00 | 0.0561 |
| Maximum Eskom shed share, 01:00-02:00 | 0.1496 |
| Zero-shed days | 99 |
| Mean population-weighted strict-dark share, >=10k diagnostic | 0.00725 |
| Mean population-weighted mostly-dark share, >=10k diagnostic | 0.01661 |

Three product dates are absent from the MLR daily panel:

- `2023-09-29`: present in Stage 2, but all settlement rows fail the `coverage >= 0.50` filter;
- `2023-09-30`: absent from Stage 2;
- `2023-10-01`: absent from Stage 2.

The full-year daily panel includes `2023-12-31`, but its local-overpass date is `2024-01-01`, so model rows using Eskom 2023 exposure use `361` complete observations.

## Headline Ravi-Style Population-Weighted Calibration

The report-facing calibration uses the Ravi-style settlement universe:

- VJ annual-composite yearlykeep settlements;
- `population > 100`;
- strict dark: `p_lit_sett < 0.05`;
- mostly dark: `p_lit_sett < 0.20`;
- exposure: Eskom `shed_share_1_2am_primary` on `local_overpass_date = vj_product_date + 1`.

| Specification | Outcome | Full-year effect, pp per 10 pp shed | p | R2 | r | Jan-Jun R2 | October R2 |
|---|---|---:|---:|---:|---:|---:|---:|
| Continuous shed share | Strict dark | 2.72 | 1.00e-54 | 0.492 | 0.701 | 0.412 | 0.331 |
| Continuous shed share | Mostly dark | 4.38 | 1.06e-54 | 0.492 | 0.701 | 0.437 | 0.289 |

Interpretation: the full-year population-weighted calibration is strong. A 10 percentage point increase in Eskom shed share around the local overpass is associated with a 2.72 percentage point increase in population-weighted strict darkness and a 4.38 percentage point increase in population-weighted mostly-darkness. Both outcomes have `r = 0.701` and extremely small p-values.

This is stronger than Jan-June and much stronger than the October-only diagnostic.

## Extreme-Day Sensitivity

The top 7 vs bottom 7 result is unchanged from Jan-June because the seven highest-shed-share days and the ordered seven lowest-shed-share days are already in the Jan-June window. The useful full-year result is the wider-bin sensitivity:

| Bin size per side | Total days | Outcome | Bottom mean | Top mean | Difference, pp | p | R2 |
|---:|---:|---|---:|---:|---:|---:|---:|
| 7 | 14 | Strict dark | 0.0018 | 0.0363 | 3.45 | 9.48e-06 | 0.816 |
| 7 | 14 | Mostly dark | 0.0026 | 0.0600 | 5.74 | 1.25e-06 | 0.868 |
| 30 | 60 | Strict dark | 0.0023 | 0.0328 | 3.05 | 3.87e-14 | 0.630 |
| 30 | 60 | Mostly dark | 0.0038 | 0.0531 | 4.93 | 2.40e-14 | 0.636 |
| 60 | 120 | Strict dark | 0.0019 | 0.0335 | 3.16 | 6.52e-25 | 0.595 |
| 60 | 120 | Mostly dark | 0.0035 | 0.0542 | 5.07 | 5.39e-25 | 0.596 |
| 90 | 180 | Strict dark | 0.0017 | 0.0303 | 2.86 | 2.04e-35 | 0.581 |
| 90 | 180 | Mostly dark | 0.0029 | 0.0496 | 4.67 | 1.40e-35 | 0.582 |
| 120 | 240 | Strict dark | 0.0027 | 0.0300 | 2.73 | 9.44e-43 | 0.547 |
| 120 | 240 | Mostly dark | 0.0046 | 0.0483 | 4.37 | 6.30e-44 | 0.557 |

Interpretation: the high-load-reduction nights remain much darker even when comparing the top 120 and bottom 120 days. This makes the result much less dependent on a small extreme-day sample.

## Large-Settlement Daily Diagnostics

The `population >= 10,000` daily-panel diagnostics also strengthen relative to Jan-June. They are now close to October for raw event counts and exceed October for population-weighted shares.

| Outcome, population >=10k diagnostic | Full-year r | Full-year R2 | Jan-Jun r | Jan-Jun R2 | October r | October R2 |
|---|---:|---:|---:|---:|---:|---:|
| Strict-dark events | 0.454 | 0.206 | 0.370 | 0.137 | 0.458 | 0.210 |
| Mostly-dark events | 0.454 | 0.207 | 0.371 | 0.138 | 0.468 | 0.219 |
| Strict-dark population | 0.430 | 0.185 | 0.347 | 0.120 | 0.437 | 0.191 |
| Population-weighted strict dark | 0.466 | 0.217 | 0.380 | 0.144 | 0.365 | 0.133 |
| Population-weighted mostly dark | 0.479 | 0.230 | 0.407 | 0.166 | 0.312 | 0.098 |

Interpretation: the large-settlement diagnostic is no longer just moderate. It is still weaker than the Ravi-style population-weighted `population > 100` calibration, but the full-year event-count and population-weighted diagnostics now provide consistent supporting evidence.

## Event Counts

| Population threshold | Strict-dark events | Mostly-dark events | Max daily strict events | Max daily mostly-dark events |
|---:|---:|---:|---:|---:|
| >=5,000 | 5,146 | 8,065 | 121 | 177 |
| >=10,000 | 2,528 | 4,452 | 66 | 107 |
| >=50,000 | 99 | 437 | 5 | 15 |
| >=100,000 | 3 | 75 | 1 | 3 |

These are candidate settlement-day dark events, not confirmed outages. The pixel-level notebook workflow remains necessary before interpreting individual events operationally.

## Date-Alignment and Robustness

The primary same-day local-overpass alignment remains the best or near-best alignment.

For the `population >= 10,000` population-weighted strict-dark diagnostic:

| Alignment | Effect | Effect per 10 pp shed, pp | p | R2 |
|---|---:|---:|---:|---:|
| Primary local-overpass date | 0.127 | 1.27 | 7.17e-21 | 0.217 |
| Previous-day placebo | 0.115 | 1.15 | 3.11e-17 | 0.180 |
| Next-day placebo | 0.109 | 1.09 | 3.93e-15 | 0.159 |

For adjacent windows, the relationship is stable:

| Window | Outcome | R2 |
|---|---|---:|
| 00-01 | Population-weighted strict dark | 0.219 |
| 01-02 primary | Population-weighted strict dark | 0.217 |
| 02-03 | Population-weighted strict dark | 0.204 |
| 01-03 | Population-weighted strict dark | 0.212 |

Interpretation: the exact hour is not fragile. The `00-01`, `01-02`, `02-03`, and `01-03` windows all show strong positive association. The previous-day placebo is weaker than the primary alignment for the population-weighted diagnostic, which supports the local-overpass date rule.

## Stage 5 Reliability Outputs

VJ Stage 5 completed in yearlykeep mode:

- monthly reliability: 144,955 settlement-period rows, 365 local-area rows, 111 supply-area rows;
- quarterly reliability: 45,496 settlement-period rows, 113 local-area rows, 37 supply-area rows;
- yearly reliability: 13,740 settlement rows, 33 local-area rows, 10 supply-area rows;
- DOE confirmation: 13,804 confirmed out of 13,829 yearlykeep settlements;
- national DOE-confirmed population share: 99.97%.

Key outputs include:

- `settlement_reliability_{monthly|quarterly|yearly}_strict_yearlykeep_postdoe.parquet`
- `localarea_reliability_{monthly|quarterly|yearly}_strict_yearlykeep_postdoe.parquet`
- `supplyarea_reliability_{monthly|quarterly|yearly}_strict_yearlykeep_postdoe.parquet`
- `settlement_day_states_strict_yearlykeep.parquet`
- `diagnostic_dashboard_2023-01_to_2023-12_strict_yearlykeep_postdoe.{csv,parquet}`
- `end_of_year_electrification_2023_*`

## Conclusion

The full-year VJ MLR calibration is the strongest result so far. The headline Ravi-style population-weighted validation reaches `r = 0.701` and `R2 = 0.492` for both strict and mostly-dark outcomes, with effects in the expected direction and very strong p-values.

The practical conclusion is stronger than Jan-June: **VJ146A2 is now well supported as the preferred satellite path for Eskom MLR calibration and reliability metric construction.** The final "VJ is better than VNP" claim still requires a matched full-year VNP validation under the same yearlykeep restriction and date-alignment rule, but the full-year VJ evidence is internally strong and operationally usable.
