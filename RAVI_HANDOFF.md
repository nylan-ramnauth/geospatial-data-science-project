# Ravi Handoff: VJ146A2 Reliability Validation

Purpose: audit the VJ146A2 reliability pipeline, especially the Eskom MLR validation, PyPSA-facing uptime construction, threshold choices, and settlement-level diagnostics. Treat this as a code review and reproducibility handoff, not just a report package.

Run commands from the repository root.

## 1. External Data To Place

Raw inputs, not committed:

- `blackmarbler/out_vj146a2_sa_daily/vj146a2_sa_500m_daily_2023-MM-DD.tif`
- `Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_full_col.gpkg`
- `Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_simplified_full_col.gpkg`
- `Map Data/Local Area/LOCAL_AREA_GCCA2025.*`
- `Map Data/Supply Area/SUPPLY_AREA_GCCA2025.*`
- Eskom hourly CSV: default `../pypsa-earth/data/za_validation/eskom_2023_hourly_clean.csv`, or set `ESKOM_HOURLY_CSV=/abs/path/eskom_2023_hourly_clean.csv`
- NASA Earthdata credentials only if rebuilding annual composites or redownloading rasters.

Optional generated bundle, if available, saves most runtime:

- `Map Data/settlement_day_outputs_vj146a2/`
- `Map Data/reliability_outputs_vj146a2/`

These paths are intentionally ignored by git.

## 2. Full Pipeline Run Order

```bash
export VJ146A2_START_MONTH=2023-01
export VJ146A2_END_MONTH=2023-12
export VJ146A2_YEAR=2023
export VJ146A2_ALLOW_PARTIAL=0
export VJ146A2_USE_YEARLY_KEEP=1

Rscript Builder/vj146a2_yearly_keep_build.R
Rscript Builder/settlement_day_panel_build_vj146a2.R
Rscript Builder/settlement_day_coverage_filter_vj146a2.R
Rscript Builder/settlement_day_yearlykeep_filter_vj146a2.R
Rscript Visualizer/reliability_panel_build_yearlykeep_vj146a2.R
Rscript Builder/vj146a2_2023_mlr_validation.R
Rscript Builder/vj146a2_2023_demand_weighted_gate_mlr_validation.R
```

Build the excess-lit-excluded reliability cache used by the uptime bridge:

```bash
VJ146A2_EXCESS_LIT_FLAGS_FILE=validation/eskom_mlr/data/vj146a2_2023_annual_iqr_excess_lit_day_flags.csv \
RUN_OUTPUT_SUFFIX=_annual_excess_lit_iqr \
Rscript Visualizer/reliability_panel_build_yearlykeep_vj146a2.R
```

Main validation and PyPSA-facing outputs:

```bash
Rscript -e 'rmarkdown::render("validation/eskom_mlr/reports/2026-06-03-recommended-vj-eskom-validation-specification.Rmd")'
Rscript validation/pypsa_uptime/scripts/build_vj146a2_pypsa_localarea_demand_weighted_uptime.R
Rscript validation/pypsa_uptime/scripts/map_vj146a2_pypsa_localarea_demand_weighted_uptime.R
```

Smoke test the settlement-day builder without touching production names:

```bash
VJ146A2_START_MONTH=2023-01 VJ146A2_END_MONTH=2023-01 VJ146A2_MAX_DATES_PER_MONTH=1 \
Rscript Builder/settlement_day_panel_build_vj146a2.R
```

## 3. Critical Outputs After Builder Stages

Needed for Eskom MLR validation:

- `Map Data/reliability_outputs_vj146a2/yearly_settlement_stats_2023.parquet`
- `Map Data/reliability_outputs_vj146a2/vj146a2_yearly_keep_2023.parquet`
- `Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_cov_yearlykeep_2023-*.parquet` (expect 12)
- `Map Data/settlement_day_outputs_vj146a2/mlr_validation_2023/`
- `Map Data/settlement_day_outputs_vj146a2/mlr_validation_demand_gate_2023/`

Needed for PyPSA uptime construction:

- `Map Data/reliability_outputs_vj146a2/settlement_day_states_strict_yearlykeep_annual_excess_lit_iqr.parquet`
- `Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_simplified_full_col.gpkg`
- `Map Data/Local Area/LOCAL_AREA_GCCA2025.shp`
- `validation/eskom_mlr/data/vj146a2_2023_annual_iqr_excess_lit_day_flags.csv`

Main committed outputs to inspect:

- `validation/eskom_mlr/reports/2026-06-03-recommended-vj-eskom-validation-specification.Rmd`
- `validation/eskom_mlr/reports/2026-06-03-recommended-vj-eskom-validation-specification.pdf`
- `validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_demand_weighted_uptime.csv`
- `validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_p_lit_threshold_sensitivity.csv`
- `validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_p_lit_threshold_uptime_comparison.xlsx`

## 4. Audit Targets

- Denominator: Eskom validation must use `MLR / RSA Contracted Demand`; do not double-count MLR.
- Date alignment: VJ product date maps to local overpass date as documented in validation reports.
- Gate logic: demand-weighted support gate and settlement coverage thresholds should be consistent across Builder and validation reports.
- Uptime threshold: preferred not-up proxy is `p_lit_sett < 0.40`; output column is `not_up_040_share_demandw`; availability is `availability_040_demandw`.
- Aggregation: uptime should be daily-first, demand-weighted, then annualized by LocalArea.
- Excess-lit handling: compare baseline versus annual IQR excess-lit exclusion.
- Large-city limitation: binary `p_lit` gates can understate partial dimming in large metro areas; inspect continuous radiance checks.
- Public benchmarks: use for triangulation only, not direct LocalArea ENS validation.

## 5. Settlement-Level Notebook Work

Use these as templates:

- `validation/closeups/notebooks/vj146a2_full_year_selected_settlement_pixel_closeups.ipynb`
- `validation/closeups/notebooks/vj146a2_jan_jun_selected_city_pixel_closeups.ipynb`
- `validation/closeups/scripts/vj146a2_full_year_selected_settlement_pixel_closeups.R`
- `validation/closeups/scripts/vj146a2_full_year_plot_gif_candidate_screen.R`

Useful inputs for new per-settlement analysis:

- monthly `settlement_day_vj146a2_cov_yearlykeep_2023-*.parquet`
- `Map Data/settlement_day_outputs_vj146a2/mlr_validation_2023/vj146a2_2023_mlr_validation_large_events.csv`
- VJ daily GeoTIFFs in `blackmarbler/out_vj146a2_sa_daily/`
- settlement GPKGs in `Map Data/Settlements/GPKG/`
- Eskom hourly CSV or derived validation daily panel.

Keep exploratory notebooks under `validation/closeups/notebooks/` or an ignored scratch folder until they are clean enough to commit.

## 6. Where To Read First

- `validation/README.md`
- `validation/data_manifest.md`
- `validation/eskom_mlr/README.md`
- `validation/pypsa_uptime/README.md`
- `VJ146A2_FULL_YEAR_REPRODUCTION_CHECKLIST.md`
