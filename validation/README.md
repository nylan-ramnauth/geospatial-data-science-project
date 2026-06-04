# Reliability Validation Package

This directory is the portable VJ146A2 validation handoff package for Ravi. It is organized as a validation layer on top of the existing `Reliability-Assessment` repository; it does not duplicate the production pipeline.

## Layout

- `eskom_mlr/`: Eskom MLR validation reports, lightweight result tables, headline figures, and companion validation scripts.
- `pypsa_uptime/`: PyPSA/LocalArea uptime bridge outputs and scripts. The preferred PyPSA metric is `not_up_040_share_demandw`; availability is `availability_040_demandw`.
- `limitations_and_triangulation/`: limitation notes and public-benchmarking triangulation plan. Public benchmarks are for triangulation only, not as a replacement denominator or validation truth set.
- `closeups/`: selected pixel closeup scripts, stripped notebooks, candidate tables, and small QA extracts.
- `legacy_october_diagnostics/`: October-only diagnostics retained for provenance. The current full-year headline is under `eskom_mlr/`.
- `scripts/validation_paths.R`: shared path helper for validation scripts and R Markdown reports.

## Technical Defaults

- Eskom MLR denominator: `MLR / RSA Contracted Demand`.
- Lit threshold for uptime/down classification: `p_lit_sett < 0.40`.
- Construction order: daily first, then demand-weighted LocalArea aggregation.
- Main PyPSA proxy: `not_up_040_share_demandw`; companion availability field: `availability_040_demandw`.
- Excess-lit dates: exclude the annual IQR excess-lit dates from `eskom_mlr/data/vj146a2_2023_annual_iqr_excess_lit_day_flags.csv`.

## Running

From the repository root:

```sh
Rscript -e 'rmarkdown::render("validation/eskom_mlr/reports/2026-06-03-recommended-vj-eskom-validation-specification.Rmd")'
Rscript validation/pypsa_uptime/scripts/build_vj146a2_pypsa_localarea_demand_weighted_uptime.R
Rscript validation/pypsa_uptime/scripts/map_vj146a2_pypsa_localarea_demand_weighted_uptime.R
```

Set `PYPSA_EARTH_DIR` or `ESKOM_HOURLY_CSV` if `../pypsa-earth/data/za_validation/eskom_2023_hourly_clean.csv` is not available beside this repository.

## Production Boundary

Production pipeline scripts remain in `Builder/` and `Visualizer/`. Validation scripts in this directory consume their outputs and produce handoff reports, sensitivity tables, and PyPSA-facing bridge files. Do not move production builders into `validation/`; reference or rerun them from their existing locations.

See `validation/data_manifest.md` for committed and external-only artifacts.
