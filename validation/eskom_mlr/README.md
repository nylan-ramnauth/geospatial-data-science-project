# Eskom MLR Validation

This section holds the current full-year VJ146A2 validation against Eskom MLR, including the recommended demand-gated report, robustness notes, lightweight result tables, and headline figures.

## Current Specification

- Primary denominator: `MLR / RSA Contracted Demand`.
- Headline gate: demand-weighted observation support, with national nights passing at observed demand share `>= 0.40`.
- Settlement observation support: coverage `>= 0.50` for the selected demand-gate extract.
- Excess-lit handling: exclude annual IQR excess-lit dates.

## Main Report

From the repository root:

```sh
Rscript -e 'rmarkdown::render("validation/eskom_mlr/reports/2026-06-03-recommended-vj-eskom-validation-specification.Rmd")'
```

The committed PDF is `reports/2026-06-03-recommended-vj-eskom-validation-specification.pdf`.

## Production Sources

Do not copy these production scripts into validation. Rerun or inspect them in place:

- `Builder/vj146a2_2023_mlr_validation.R`
- `Builder/vj146a2_2023_demand_weighted_gate_mlr_validation.R`
- `Builder/vj146a2_2023_autocorr_robustness_mlr_validation.R`
- `Builder/vj146a2_2023_per_settlement_slope_mlr_validation.R`
- `Builder/vj146a2_2023_settlement_threshold_ladder_mlr_validation.R`
- `Builder/vj146a2_2023_national_continuous_dimming_mlr_validation.R`
- `Builder/vnp46a2_2023_mlr_validation.R`

Validation-local scripts in `scripts/` are companion analyses that read committed lightweight tables or external production outputs.
