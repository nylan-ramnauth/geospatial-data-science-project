# VJ146A2 Eskom MLR Validation: January-June 2023 Check

**Date:** 2026-06-03
**Status:** Working validation note
**Workstream:** reliability-assessment
**Superseded by:** [[validation/eskom_mlr/reports/2026-06-03-vj-full-year-mlr-validation-calibration]]
**Supersedes:** [[validation/eskom_mlr/reports/2026-06-03-vj-jan-apr-mlr-validation-comparison]]
**Related logs:** [[5-logs/shared/2026-06-03-1652-vj-jan-apr-mlr-validation]]

## Purpose

This note updates the VJ Eskom MLR validation after May and June 2023 VJ146A2 daily panels became available. It extends the earlier January-April check to January-June 2023 and compares the result against both the earlier Jan-April run and the existing October 2023 VJ diagnostic.

The main question is whether the VJ validation still holds, and whether adding two more months makes the evidence stronger. The answer is yes for the report-facing population-weighted validation. The Jan-June run gives stronger continuous population-weighted associations than Jan-April, and it now exceeds the October diagnostic on those population-weighted continuous models. It is still premature to claim that VJ is better than VNP without a matched VNP Jan-June validation run.

## Inputs and Outputs

Stage 3 coverage filtering and Stage 3b yearly-keep materialization were run for `2023-01` through `2023-06`. The MLR validation was run with:

```bash
VJ146A2_START_MONTH=2023-01 VJ146A2_END_MONTH=2023-06 Rscript Builder/vj146a2_2023_mlr_validation.R
```

Key output folder:

```text
6-codebases/repos/Reliability-Assessment/Map Data/settlement_day_outputs_vj146a2/mlr_validation_2023-01_to_2023-06/
```

The run produced `181` VJ product-date observation days, spanning `2023-01-01` to `2023-06-30`, with local overpass dates `2023-01-02` to `2023-07-01`.

Main generated files:

- `vj146a2_2023_mlr_validation_report.pdf`
- `vj146a2_2023_mlr_validation_daily_panel.csv`
- `vj146a2_2023_mlr_validation_ravi_style_table.csv`
- `vj146a2_janjun_vs_oct2023_ravi_style_comparison.csv`
- `vj146a2_janjun_vs_janapr_ravi_style_comparison.csv`
- `vj146a2_janjun_daily_correlation_comparison.csv`
- `vj146a2_janjun_ravi_extreme_bin_sensitivity.csv`

## Methodology

The validation keeps the same local-clock alignment as the October diagnostic:

```text
local_overpass_date = vj_product_date + 1
```

The primary Eskom exposure is the hour beginning `01:00 SAST`, interpreted as the `01:00-02:00` local overpass window. The exposure variable is:

```text
legacy shed_share_1_2am_primary used a sum denominator; current validation uses MLR / RSA Contracted Demand
```

The report-facing satellite outcomes use the VJ Stage 4 yearly-keep settlements and the Ravi-style `population > 100` settlement universe:

- strict dark: `p_lit_sett < 0.05`
- mostly dark: `p_lit_sett < 0.20`

Two related diagnostics are reported, and they should not be mixed:

1. **Ravi-style population-weighted validation:** population-weighted strict and mostly-dark shares among settlements with `population > 100`. This is the headline validation metric and is the right place to discuss the strongest correlation result.
2. **Large-settlement daily-panel diagnostics:** event counts and population-weighted outcomes using the `population >= 10,000` large-settlement threshold. These are useful supporting checks, but their correlations are lower and should not be the headline claim.

The top/bottom tables rank all Jan-June local-overpass dates by `shed_share_1_2am_primary`. "Top" means the worst load-reduction nights in the Jan-June window. "Bottom" means the best/no- or low-load-reduction comparison nights. Therefore, top 7 and bottom 7 are the seven worst and seven best nights by Eskom shed share, not the seven darkest satellite days.

## Jan-June Sample

The Jan-June validation panel contains:

| Quantity | Value |
|---|---:|
| VJ product-date days | 181 |
| Product-date range | 2023-01-01 to 2023-06-30 |
| Local-overpass-date range | 2023-01-02 to 2023-07-01 |
| Mean Eskom shed share, 01:00-02:00 | 0.0712 |
| Maximum Eskom shed share, 01:00-02:00 | 0.1496 |
| Zero-shed days | 36 |
| Mean population-weighted strict-dark share, >=10k diagnostic | 0.0093 |
| Mean population-weighted mostly-dark share, >=10k diagnostic | 0.0205 |
| Total strict-dark events, >=10k diagnostic | 1,409 |
| Total mostly-dark events, >=10k diagnostic | 2,461 |

## Headline Population-Weighted Result

For the Ravi-style `population > 100` population-weighted validation, Jan-June is stronger than Jan-April and stronger than the October diagnostic.

| Specification | Outcome | Jan-June effect, pp per 10 pp shed | Jan-June p | Jan-June R2 | Jan-June r | Jan-April R2 | October R2 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Continuous shed share | Strict dark | 2.63 | 2.06e-22 | 0.412 | 0.642 | 0.269 | 0.331 |
| Continuous shed share | Mostly dark | 4.19 | 4.02e-24 | 0.437 | 0.661 | 0.285 | 0.289 |

Interpretation: this is the clearest validation improvement. The daily population-weighted relationship is no longer just moderate. On the Ravi-style population-weighted specification, the Jan-June correlation is about `0.64` for strict dark and `0.66` for mostly dark, with very strong p-values. Adding May and June materially improves the continuous validation result.

The effect sizes are also meaningful. A 10 percentage point increase in Eskom shed share around the VJ local overpass is associated with a `2.63` percentage point increase in population-weighted strict darkness and a `4.19` percentage point increase in population-weighted mostly-darkness.

## Extreme-Day Contrast

The top/bottom contrast also strengthens when May and June are added. The top 7 worst Eskom nights are much darker than the bottom 7 best Eskom nights, and this remains true when the bins are widened well beyond 14 total observations.

| Bin size per side | Total days | Outcome | Bottom-bin mean | Top-bin mean | Difference, pp | p | R2 |
|---:|---:|---|---:|---:|---:|---:|---:|
| 7 | 14 | Strict dark | 0.0046 | 0.0392 | 3.45 | 9.48e-06 | 0.816 |
| 7 | 14 | Mostly dark | 0.0067 | 0.0642 | 5.74 | 1.25e-06 | 0.868 |
| 14 | 28 | Strict dark | 0.0052 | 0.0396 | 3.44 | 3.70e-07 | 0.636 |
| 14 | 28 | Mostly dark | 0.0083 | 0.0638 | 5.55 | 9.56e-08 | 0.672 |
| 20 | 40 | Strict dark | 0.0075 | 0.0399 | 3.24 | 1.53e-10 | 0.664 |
| 20 | 40 | Mostly dark | 0.0112 | 0.0646 | 5.34 | 1.33e-11 | 0.704 |
| 30 | 60 | Strict dark | 0.0085 | 0.0396 | 3.11 | 5.26e-15 | 0.655 |
| 30 | 60 | Mostly dark | 0.0126 | 0.0617 | 4.91 | 1.71e-15 | 0.668 |
| 45 | 90 | Strict dark | 0.0096 | 0.0387 | 2.91 | 1.15e-16 | 0.544 |
| 45 | 90 | Mostly dark | 0.0140 | 0.0601 | 4.61 | 3.82e-17 | 0.555 |
| 60 | 120 | Strict dark | 0.0142 | 0.0383 | 2.41 | 2.28e-16 | 0.436 |
| 60 | 120 | Mostly dark | 0.0193 | 0.0571 | 3.78 | 3.34e-16 | 0.433 |

Interpretation: the extreme-bin validation no longer rests on only 14 observations. Even using top/bottom 60 days, or 120 of the 181 days in the sample, the contrast remains positive, statistically strong, and economically meaningful.

## Comparison to October

The Jan-June results improve on October in the headline population-weighted models:

| Specification | Outcome | Jan-June effect, pp | October effect, pp | Delta effect, pp | Jan-June R2 | October R2 | Delta R2 |
|---|---|---:|---:|---:|---:|---:|---:|
| Continuous shed share | Strict dark | 2.63 | 2.20 | 0.44 | 0.412 | 0.331 | 0.082 |
| Continuous shed share | Mostly dark | 4.19 | 3.83 | 0.36 | 0.437 | 0.289 | 0.148 |
| Top 7 vs bottom 7 | Strict dark | 3.45 | 0.89 | 2.57 | 0.816 | 0.305 | 0.512 |
| Top 7 vs bottom 7 | Mostly dark | 5.74 | 1.42 | 4.32 | 0.868 | 0.329 | 0.539 |

This is stronger than the Jan-April conclusion. In Jan-April, the direction held and the top/bottom contrast strengthened, but continuous R2 was similar to or below October. With Jan-June, the continuous population-weighted R2 is higher than October for both strict and mostly-dark outcomes.

## Large-Settlement Daily-Panel Diagnostics

The `population >= 10,000` daily-panel diagnostics also improve relative to Jan-April, but they are still less clean than the Ravi-style population-weighted validation.

| Outcome, population >=10k diagnostic | Jan-June r | Jan-June R2 | Jan-April r | Jan-April R2 | October r | October R2 |
|---|---:|---:|---:|---:|---:|---:|
| Strict-dark events | 0.370 | 0.137 | 0.302 | 0.091 | 0.458 | 0.210 |
| Mostly-dark events | 0.371 | 0.138 | 0.303 | 0.092 | 0.468 | 0.219 |
| Strict-dark population | 0.347 | 0.120 | 0.284 | 0.081 | 0.437 | 0.191 |
| Population-weighted strict dark | 0.380 | 0.144 | 0.324 | 0.105 | 0.365 | 0.133 |
| Population-weighted mostly dark | 0.407 | 0.166 | 0.340 | 0.115 | 0.312 | 0.098 |

Interpretation: the large-settlement diagnostics improve when May and June are included. The population-weighted `>=10k` variants now exceed October's simple daily correlation, while raw event-count correlations remain below October. This reinforces the recommendation to keep the validation claim population-weighted, not event-count-first.

## Date-Alignment and Placebo Checks

The local-overpass alignment remains defensible for the population-weighted headline. For the `>=10k` population-weighted strict-dark diagnostic:

| Alignment | Effect | p | R2 |
|---|---:|---:|---:|
| Primary local-overpass date | 0.1169 | 1.36e-07 | 0.144 |
| Previous-day placebo | 0.1152 | 2.68e-07 | 0.138 |
| Next-day placebo | 0.1065 | 2.19e-06 | 0.119 |

The primary alignment is strongest for the population-weighted strict-dark diagnostic, but the previous-day placebo is close. For raw large-event counts, the previous-day placebo is slightly stronger than the primary date. That does not invalidate the validation, but it means raw event counts should remain supporting evidence rather than the main claim.

## Does the Result Hold?

Yes. The main VJ result holds through June:

- higher Eskom shed share around the local overpass is associated with higher VJ population-weighted settlement darkness;
- the Ravi-style `population > 100` daily population-weighted correlation is now strong, with `r = 0.642` for strict dark and `r = 0.661` for mostly dark;
- the top-vs-bottom shed-share contrast remains strong when expanded from top/bottom 7 days to top/bottom 60 days;
- the large-settlement diagnostics improve relative to Jan-April, although raw event counts remain less clean than population-weighted measures.

## Does VJ Look Better?

VJ looks more convincing after the Jan-June run than after Jan-April. The strongest evidence is the Ravi-style population-weighted result, where Jan-June improves over both Jan-April and October.

However, this report still cannot make a final "VJ is better than VNP" claim. The correct test is a matched VNP validation over the same Jan-June months, using the same yearly-keep restriction, same local-overpass date alignment, same Eskom exposure window, and same population-weighted outcomes.

Current practical conclusion: **VJ is the preferred candidate for continuing Eskom MLR validation. The Jan-June result strengthens the case, but the final VJ-over-VNP claim still requires a matched VNP Jan-June comparison.**
