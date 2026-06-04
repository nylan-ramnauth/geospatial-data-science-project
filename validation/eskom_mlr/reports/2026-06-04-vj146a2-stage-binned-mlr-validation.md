# VJ146A2 Stage-Binned Eskom MLR Validation

Date: 2026-06-04
Actor: Codex
Scope: standalone analysis; the current recommended validation Rmd was not edited.

## Question

Nylan asked whether the validation could be expressed not only as a continuous regression against Eskom MLR, but also as a categorical regression against load-shedding stages. The motivation is the stage table in `[[1-sources/web-clips/2026-06-04 WIKI South African energy crisis]]`, which reports approximate shares of grid users without power by stage.

## Method

The analysis uses the existing VJ146A2 validation panel:

- Keep `gate_tier == "pass"`.
- Remove annual-IQR excess-lit dates under `annual_q3_plus_1p5_iqr`.
- Use the established 01:00-02:00 SAST Eskom MLR exposure.
- Define implied stage from MLR MW:
  - Stage 0 if MLR is zero.
  - Otherwise `ceiling(MLR MW / 1000)`, capped at Stage 8.

This is an implied MLR stage, not an official Eskom stage history. In this validation sample, the observed range reaches Stage 4 because the overpass-window MLR maximum is about 3,958 MW.

## Stage Means

| Implied stage | Nights | Mean MLR MW | Strict dark | Mostly dark | Demand strict dark | Demand mostly dark | Down-only dimming z | Wiki user-off share |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Stage 0 | 74 | 0.0 | 0.16% | 0.30% | 0.27% | 0.48% | 0.280 | 0.0% |
| Stage 1 | 30 | 726.3 | 0.95% | 1.61% | 1.39% | 2.20% | 0.317 | 6.0% |
| Stage 2 | 89 | 1472.8 | 1.70% | 2.78% | 2.50% | 3.82% | 0.402 | 12.5% |
| Stage 3 | 68 | 2487.4 | 2.98% | 5.06% | 4.28% | 6.69% | 0.463 | 19.0% |
| Stage 4 | 6 | 3381.4 | 3.27% | 5.70% | 4.46% | 7.18% | 0.425 | 25.0% |

The binary darkness metrics increase monotonically from Stage 0 through Stage 4. Stage 4 has only six validation nights, so its exact mean should be treated cautiously.

## Regression Results

Ordinal Newey-West regressions, without fixed effects:

| Outcome | Effect per implied stage | Newey-West SE | 95% CI | R2 |
|---|---:|---:|---:|---:|
| Population strict dark share | +0.893 pp | 0.054 | [0.788, 0.999] | 0.544 |
| Population mostly dark share | +1.505 pp | 0.097 | [1.314, 1.696] | 0.525 |
| Demand strict dark share | +1.268 pp | 0.072 | [1.128, 1.409] | 0.577 |
| Demand mostly dark share | +1.959 pp | 0.114 | [1.735, 2.182] | 0.573 |
| Demand down-only dimming z | +0.058 | 0.014 | [0.032, 0.085] | 0.077 |

With month and day-of-week fixed effects:

| Outcome | Effect per implied stage | Newey-West SE | 95% CI | R2 |
|---|---:|---:|---:|---:|
| Population strict dark share | +0.816 pp | 0.068 | [0.682, 0.949] | 0.626 |
| Population mostly dark share | +1.375 pp | 0.137 | [1.106, 1.644] | 0.620 |
| Demand strict dark share | +1.166 pp | 0.088 | [0.993, 1.339] | 0.656 |
| Demand mostly dark share | +1.792 pp | 0.155 | [1.488, 2.096] | 0.665 |
| Demand down-only dimming z | +0.111 | 0.019 | [0.073, 0.148] | 0.181 |

Categorical stage effects relative to Stage 0 are also monotonic for strict and mostly-dark shares. For population strict darkness, the Stage 1, 2, 3, and 4 effects are `+0.79`, `+1.53`, `+2.82`, and `+3.11` percentage points. For population mostly-darkness, they are `+1.31`, `+2.48`, `+4.76`, and `+5.40` percentage points.

## Interpretation

This is a useful communication and validation layer. It supports the same conclusion as the continuous MLR regression: VJ146A2 darkness increases when Eskom load reduction is higher.

The stage analysis is easier to explain than the continuous MLR slope because South African load shedding is publicly understood through stages. It lets us say that nights in higher implied load-shedding stages have systematically higher NTL darkness and dimming.

The NTL response is much smaller than the Wikipedia user-off percentages. That is expected and should not be treated as a failure:

- the stage table is a scheduled/instantaneous grid-user outage share;
- VJ observes one nighttime overpass window;
- backup power and partial lighting reduce the visible NTL response;
- binary darkness is conservative and misses partial dimming;
- local/distribution outages and municipal scheduling can differ from national stage averages.

The best report use is therefore not one-to-one calibration to the Wikipedia percentages. The best use is a monotonic validation figure: higher implied Eskom stages correspond to higher observed VJ darkness.

## Recommendation

Add a short stage-binned validation section only after the current continuous MLR regression. The continuous MLR regression should remain the statistical headline because it uses measured MW/load-share exposure. The stage-binned analysis should be used for interpretation and presentation.

## Outputs

- Script: `[[validation/eskom_mlr/scripts/vj146a2_stage_binned_mlr_validation.R]]`
- Stage summary: `[[validation/eskom_mlr/data/vj146a2_2023_stage_binned_mlr_stage_summary.csv]]`
- Categorical regression: `[[validation/eskom_mlr/data/vj146a2_2023_stage_binned_mlr_categorical_regression.csv]]`
- Ordinal regression: `[[validation/eskom_mlr/data/vj146a2_2023_stage_binned_mlr_ordinal_regression.csv]]`
- Ordinal FE regression: `[[validation/eskom_mlr/data/vj146a2_2023_stage_binned_mlr_ordinal_fe_regression.csv]]`
- Correlations: `[[validation/eskom_mlr/data/vj146a2_2023_stage_binned_mlr_correlations.csv]]`
- Figure PNG: `[[validation/eskom_mlr/figures/vj146a2-stage-binned-validation/vj146a2_stage_binned_mlr_darkness_vs_stage.png]]`
- Figure PDF: `[[validation/eskom_mlr/figures/vj146a2-stage-binned-validation/vj146a2_stage_binned_mlr_darkness_vs_stage.pdf]]`
