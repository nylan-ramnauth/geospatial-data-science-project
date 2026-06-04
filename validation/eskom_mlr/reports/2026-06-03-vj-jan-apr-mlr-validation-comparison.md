# VJ146A2 Eskom MLR Validation: January-April 2023 Check

**Date:** 2026-06-03
**Status:** Working validation note
**Superseded by:** [[validation/eskom_mlr/reports/2026-06-03-vj-jan-jun-mlr-validation-comparison]]
**Workstream:** reliability-assessment
**Related logs:** [[5-logs/shared/2026-06-03-1637-vj-vnp-mlr-implications-report]]

## Purpose

After VJ pre-Stage 2 and Stage 2 completed for early 2023, this check runs the VJ Eskom MLR validation for January-April 2023 and compares the result to the existing October 2023 VJ validation. No matched VNP first-quarter MLR validation output was found in the repo, so this note compares VJ Jan-April against VJ October rather than claiming a final VJ-vs-VNP result.

## Inputs and Outputs

Stage 3 coverage filtering was run for `2023-01` through `2023-04`, followed by Stage 3b yearly-keep materialization. The MLR validation was run with:

```bash
VJ146A2_START_MONTH=2023-01 VJ146A2_END_MONTH=2023-04 Rscript Builder/vj146a2_2023_mlr_validation.R
```

Key output folder:

```text
6-codebases/repos/Reliability-Assessment/Map Data/settlement_day_outputs_vj146a2/mlr_validation_2023-01_to_2023-04/
```

The run produced `120` VJ product-date observation days, spanning `2023-01-01` to `2023-04-30`, with local overpass dates `2023-01-02` to `2023-05-01`.

## Methodology

The validation joins VJ product dates to Eskom local-clock exposure using the established date rule:

```text
local_overpass_date = vj_product_date + 1
```

The primary Eskom exposure is the hour beginning `01:00 SAST`, interpreted as the `01:00-02:00` local overpass window. The exposure variable is:

```text
legacy shed_share_1_2am_primary used a sum denominator; current validation uses MLR / RSA Contracted Demand
```

The report-facing satellite outcomes are population-weighted darkness shares among VJ yearly-keep settlements with population greater than `100`:

- strict dark: `p_lit_sett < 0.05`
- mostly dark: `p_lit_sett < 0.20`

The validation uses two complementary model families:

1. **Continuous daily association:** all 120 Jan-April VJ product dates are used. This estimates whether darker settlement outcomes rise linearly with the same day's local-overpass shed share. This is where the daily correlation `r`, R2, and p-value are most directly interpreted.
2. **Top-7 vs bottom-7 contrast:** the 120 days are ranked by `shed_share_1_2am_primary`. The top bin is the seven local-overpass dates with the highest shed share, i.e. the worst load-reduction nights in this Jan-April window. The bottom bin is the seven local-overpass dates with the lowest shed share, i.e. the best/no- or low-load-reduction comparison nights. The coefficient is the difference in population-weighted darkness between those two bins, in percentage points. This is an extreme-day contrast, not a claim about the day-by-day correlation across all 120 days.

This distinction matters: the Jan-April daily correlations are moderate, while the top-7 vs bottom-7 contrast is strong.

Because Jan-April has 120 days, the extreme-bin check does not need to rely only on 14 observations. A wider-bin sensitivity was also computed using top/bottom 14, 20, and 30 days. The effect remains positive and statistically significant as the bins widen, although it gets smaller because less-extreme days enter the comparison:

| Bin size per side | Total days | Outcome     | Bottom-bin mean | Top-bin mean | Difference, pp |        p |    R2 |
| ----------------: | ---------: | ----------- | --------------: | -----------: | -------------: | -------: | ----: |
|                 7 |         14 | Strict dark |          0.0041 |       0.0363 |           3.22 | 4.66e-05 | 0.761 |
|                 7 |         14 | Mostly dark |          0.0057 |       0.0600 |           5.43 | 4.54e-06 | 0.837 |
|                14 |         28 | Strict dark |          0.0072 |       0.0383 |           3.10 | 1.65e-06 | 0.593 |
|                14 |         28 | Mostly dark |          0.0115 |       0.0620 |           5.05 | 4.58e-07 | 0.630 |
|                20 |         40 | Strict dark |          0.0100 |       0.0352 |           2.52 | 1.71e-07 | 0.517 |
|                20 |         40 | Mostly dark |          0.0154 |       0.0575 |           4.21 | 2.65e-08 | 0.561 |
|                30 |         60 | Strict dark |          0.0145 |       0.0328 |           1.84 | 3.34e-06 | 0.313 |
|                30 |         60 | Mostly dark |          0.0237 |       0.0517 |           2.79 | 8.31e-06 | 0.292 |

This sensitivity supports the same interpretation as the top-7 result: the darkest population-weighted VJ outcomes occur on high-MLR nights, but the appropriate language is an extreme-bin contrast, not a high continuous daily correlation.

## Daily Correlation

The simple daily correlation with `shed_share_1_2am_primary` is positive but moderate. The relationship is statistically strong because the Jan-April sample has 120 observation days, not because the daily correlation is high.

| Outcome | Jan-April r | Jan-April R2 | October r | October R2 |
|---|---:|---:|---:|---:|
| Strict dark events >=10k | 0.302 | 0.091 | 0.458 | 0.210 |
| Mostly-dark events >=10k | 0.303 | 0.092 | 0.468 | 0.219 |
| Strict-dark population >=10k | 0.284 | 0.081 | 0.437 | 0.191 |
| Population-weighted strict dark | 0.324 | 0.105 | 0.365 | 0.133 |
| Population-weighted mostly dark | 0.340 | 0.115 | 0.312 | 0.098 |

Interpretation: the continuous Jan-April result is robust and positive, but it should not be described as a high-correlation daily relationship. A precise wording is: **moderate daily correlation, strong statistical evidence, positive association.**

## Headline Model Comparison to October

The Ravi-style population-weighted results still hold over January-April. The continuous population-weighted association remains positive and highly significant, and effect sizes are slightly larger than October.

| Specification         | Outcome     | Jan-April effect, pp | Jan-April p | Jan-April R2 | October effect, pp | October p | October R2 |
| --------------------- | ----------- | -------------------: | ----------: | -----------: | -----------------: | --------: | ---------: |
| Continuous shed share | Strict dark |                 2.56 |    1.28e-09 |        0.269 |               2.20 |  0.000888 |      0.331 |
| Continuous shed share | Mostly dark |                 4.12 |    3.39e-10 |        0.285 |               3.83 |   0.00220 |      0.289 |
| Top 7 vs bottom 7     | Strict dark |                 3.22 |    4.66e-05 |        0.761 |               0.89 |    0.0407 |      0.305 |
| Top 7 vs bottom 7     | Mostly dark |                 5.43 |    4.54e-06 |        0.837 |               1.42 |    0.0320 |      0.329 |

Interpretation: the four-month sample strengthens the statistical evidence and the extreme-day contrast. The continuous R2 is similar for mostly-dark and lower for strict-dark than October, which is expected when moving from a concentrated one-month diagnostic to a broader four-month period with more heterogeneity. The high R2 values in the last two rows belong to the **top-7 vs bottom-7 contrast**, not to the continuous daily correlation.

## Large-Event Count Models

For the `population >= 10,000` event-count diagnostics, Jan-April remains positive and significant:

| Outcome | Jan-April coefficient | Jan-April p | Jan-April R2 | October coefficient | October p | October R2 |
|---|---:|---:|---:|---:|---:|---:|
| Strict dark event count | 108.48 | 0.000793 | 0.091 | 85.65 | 0.01098 | 0.210 |
| Mostly-dark event count | 191.72 | 0.000764 | 0.092 | 159.87 | 0.00911 | 0.219 |
| Strict-dark population | 2.27M | 0.00167 | 0.081 | 1.71M | 0.01562 | 0.191 |
| Pop-weighted strict dark | 0.127 | 0.000304 | 0.105 | 0.108 | 0.04759 | 0.133 |

Interpretation: the direction holds and p-values improve because the sample grows to 120 days. The lower R2 for event counts means the first four months introduce more non-MLR variation in daily settlement darkness than October alone.

## Placebo and Window Checks

The corrected local-overpass alignment remains defensible for the population-weighted headline. For `popw_share_dark`, the primary `01:00-02:00` exposure has R2 `0.105`, higher than previous-day (`0.076`) and next-day (`0.064`) placebo comparisons.

For raw large-event counts, the previous-day placebo is competitive or slightly stronger than the primary date. This means the event-count result should not be oversold as a clean date-specific causal signal. It is better treated as supporting evidence behind the population-weighted validation.

Adjacent-hour robustness is strong: the `00-01`, `01-02`, `02-03`, and `01-03` windows all produce positive, significant associations over Jan-April. This is useful because the VIIRS local overpass is not a precise single clock minute for all pixels and all locations.

## Does the Result Hold?

Yes. The main VJ finding holds beyond October:

- higher Eskom shed share around the local overpass is associated with higher VJ population-weighted settlement darkness;
- the continuous daily relationship is moderate but statistically strong over 120 days;
- top shed-share nights are much darker than bottom shed-share nights in the VJ population-weighted metrics;
- the extreme-bin contrast remains positive and significant when widened from top/bottom 7 days to top/bottom 14, 20, and 30 days.

## Does It Improve?

Partly.

It improves in the strongest report-facing sense: population-weighted effects are larger and much more statistically precise, and the top-vs-bottom shed-share contrast is much stronger.

It does not improve uniformly on every diagnostic: the simple daily large-event count R2 is lower than October, continuous daily correlations are moderate rather than high, and event-count placebos are not clean enough to use as the sole validation claim.

## Recommendation

Use the Jan-April result as stronger evidence that the VJ path is viable for Eskom MLR validation, but frame the claim around population-weighted darkness rather than raw settlement event counts. The next decisive comparison is a matched VNP validation over the same January-April window, or the full-year VJ/VNP side-by-side if VNP outputs are already available.

Current practical conclusion: **VJ remains the preferred candidate for MLR validation, and the Jan-April run strengthens that view, but the final "better than VNP" claim still requires a matched VNP run.**
