# VJ146A2 Full Year 2023 Parquet Reproduction Checklist

**Date:** 2026-06-03  
**Status:** Ready to launch for full-year VJ Parquet production, subject to data and NASA credential prerequisites

---

## Scope

This checklist covers the VJ146A2 path needed to regenerate the 2023 settlement-day, yearly-keep, regional reliability, and Eskom MLR validation Parquet/CSV outputs.

It intentionally excludes static map, population coverage map, Leaflet, and optional audit artifacts from the VNP full reproduction checklist.

---

## Required Inputs

| Component | Expected location | Notes |
|---|---|---|
| VJ146A2 daily GeoTIFFs | `blackmarbler/out_vj146a2_sa_daily/vj146a2_sa_500m_daily_YYYY-MM-DD.tif` | Full 2023 daily acquisition path. Known absent raster dates are handled as missing observations. |
| Settlement full GPKG | `Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_full_col.gpkg` | Used for pixel extraction and annual-composite extraction. |
| Settlement simplified GPKG | `Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_simplified_full_col.gpkg` | Used for area joins in reliability outputs. |
| Local Area shapefile | `Map Data/Local Area/LOCAL_AREA_GCCA2025.shp` | Used for regional reliability Parquets. |
| Supply Area shapefile | `Map Data/Supply Area/SUPPLY_AREA_GCCA2025.shp` | Used for regional reliability Parquets. |
| Eskom hourly validation CSV | `../pypsa-earth/data/za_validation/eskom_2023_hourly_clean.csv` | Used by full-year MLR validation. |
| NASA Earthdata credentials | `EARTHDATA_USER`, `EARTHDATA_PASS` | Required for VJ pre-Stage 2 annual composite download. |

---

## Pipeline Stages

### Pre-Stage 2: VJ Annual-Composite Yearly Keep

- **File:** `Builder/vj146a2_yearly_keep_build.R`
- **Preferred annual source:** `VJ146A4`
- **Fallback annual source:** `VNP46A4`, only if `VJ146A4` cannot be downloaded/read
- **Annual variable:** `NearNadir_Composite_Snow_Free`
- **Output directory:** `Map Data/reliability_outputs_vj146a2/`
- **Purpose:** creates the annual `electrified_best == 1` settlement keep list before daily extraction, so Stage 2 only runs expensive exact extraction on the kept settlement universe.
- **Outputs:**
  - `yearly_settlement_stats_2023.parquet`
  - `yearly_settlement_stats_2023.csv`
  - `vj146a2_yearly_keep_2023.parquet`
  - `vj146a2_yearly_keep_calibration_2023.csv`
- **Required provenance columns:**
  - `annual_source_product`
  - `annual_source_variable`
  - `annual_fallback_used`
  - `annual_fallback_reason`
  - `yearly_method`

### Stage 2: VJ Settlement-Day Panel

- **File:** `Builder/settlement_day_panel_build_vj146a2.R`
- **Input:** VJ146A2 daily GeoTIFFs and the pre-Stage-2 yearly keep list
- **Output:** `Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_nocov_YYYY-MM.parquet`
- **Summary output:** `settlement_day_vj146a2_nocov_YYYY-MM_daily_summary.csv`
- **Full-year behavior:** runs `2023-01` through `2023-12` by default.
- **Settlement-universe behavior:** production default is `VJ146A2_USE_YEARLY_KEEP=1`, which requires `vj146a2_yearly_keep_2023.parquet` and prefilters settlements before `exactextractr`.
- **Full-universe diagnostic override:** set `VJ146A2_USE_YEARLY_KEEP=0` only when deliberately rebuilding the old full-settlement Stage 2 diagnostic panel.
- **Missing raster behavior:** absent dates are skipped and recorded in monthly summaries.
- **Smoke behavior:** `VJ146A2_MAX_DATES_PER_MONTH` writes only under `Map Data/settlement_day_outputs_vj146a2/smoke/` with `_smoke` filenames.

### Stage 3: VJ Coverage Filter

- **File:** `Builder/settlement_day_coverage_filter_vj146a2.R`
- **Input:** 12 monthly `settlement_day_vj146a2_nocov_YYYY-MM.parquet` files
- **Output:** `Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_cov_YYYY-MM.parquet`
- **Coverage rule:** `coverage >= 0.50`

### Stage 3b: VJ Yearly-Keep Monthly Materialization

- **File:** `Builder/settlement_day_yearlykeep_filter_vj146a2.R`
- **Input:** monthly coverage Parquets from Stage 3 and yearly stats from pre-Stage 2
- **Output:** `Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_cov_yearlykeep_YYYY-MM.parquet`
- **Summary output:** `settlement_day_vj146a2_cov_yearlykeep_YYYY-MM_daily_summary.csv`
- **Purpose:** preserves the existing `cov_yearlykeep` monthly output contract and verifies the same annual keep restriction, even though production Stage 2 has already prefiltered the extraction universe.
- **Full-year behavior:** stops if any configured month is missing unless `VJ146A2_ALLOW_PARTIAL=1`.

### Stage 5: VJ Regional Reliability Parquets

- **File:** `Visualizer/reliability_panel_build_yearlykeep_vj146a2.R`
- **Input:** 12 monthly `settlement_day_vj146a2_cov_yearlykeep_YYYY-MM.parquet` files and pre-Stage-2 yearly stats/keep
- **Output directory:** `Map Data/reliability_outputs_vj146a2/`
- **Settlement outputs:**
  - `settlement_reliability_monthly_strict_yearlykeep_postdoe.parquet`
  - `settlement_reliability_quarterly_strict_yearlykeep_postdoe.parquet`
  - `settlement_reliability_yearly_strict_yearlykeep_postdoe.parquet`
- **Regional outputs:**
  - `localarea_reliability_monthly_strict_yearlykeep_postdoe.parquet`
  - `localarea_reliability_quarterly_strict_yearlykeep_postdoe.parquet`
  - `localarea_reliability_yearly_strict_yearlykeep_postdoe.parquet`
  - `supplyarea_reliability_monthly_strict_yearlykeep_postdoe.parquet`
  - `supplyarea_reliability_quarterly_strict_yearlykeep_postdoe.parquet`
  - `supplyarea_reliability_yearly_strict_yearlykeep_postdoe.parquet`
- **Additional outputs:**
  - `settlement_day_states_strict_yearlykeep.parquet`
  - `localarea_yearly_electrification_share_2023.parquet`
  - `supplyarea_yearly_electrification_share_2023.parquet`
  - `end_of_year_electrification_2023_*`
  - diagnostics under `Map Data/reliability_outputs_vj146a2/diagnostics/`
- **Full-year behavior:** stops if any configured yearlykeep month is missing unless `VJ146A2_ALLOW_PARTIAL=1`.

### Full-Year Eskom MLR Validation

- **File:** `Builder/vj146a2_2023_mlr_validation.R`
- **Input:** 12 monthly yearlykeep VJ panels, pre-Stage-2 yearly stats, and Eskom hourly validation CSV
- **Output directory:** `Map Data/settlement_day_outputs_vj146a2/mlr_validation_2023/`
- **Outputs:**
  - `vj146a2_2023_mlr_validation_daily_panel.csv`
  - `vj146a2_2023_mlr_validation_event_counts_by_threshold.csv`
  - `vj146a2_2023_mlr_validation_models.csv`
  - `vj146a2_2023_mlr_validation_robustness_windows.csv`
  - `vj146a2_2023_mlr_validation_large_events.csv`
  - `vj146a2_2023_mlr_validation_ravi_style_table.csv`
  - report figures as PNG
  - `vj146a2_2023_mlr_validation_report.Rmd`
  - `vj146a2_2023_mlr_validation_report.pdf` when local PDF rendering succeeds
- **Date convention:** `local_overpass_date = VJ product date + 1`
- **Primary Eskom exposure:** 01:00-02:00 SAST
- **Settlement universe:** VJ pre-Stage-2 `electrified_best == 1` yearlykeep settlements

---

## Launch Commands

Run from the repository root:

```bash
cd 6-codebases/repos/Reliability-Assessment

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
```

Pre-Stage 2 also requires:

```bash
export EARTHDATA_USER=<your-earthdata-username>
export EARTHDATA_PASS=<your-earthdata-password>
```

---

## Output Checks

```bash
ls "Map Data/settlement_day_outputs_vj146a2"/settlement_day_vj146a2_nocov_2023-*.parquet | wc -l
ls "Map Data/settlement_day_outputs_vj146a2"/settlement_day_vj146a2_cov_2023-*.parquet | wc -l
ls "Map Data/settlement_day_outputs_vj146a2"/settlement_day_vj146a2_cov_yearlykeep_2023-*.parquet | wc -l

ls "Map Data/reliability_outputs_vj146a2"/yearly_settlement_stats_2023.parquet
ls "Map Data/reliability_outputs_vj146a2"/settlement_reliability_*_strict_yearlykeep_postdoe.parquet
ls "Map Data/reliability_outputs_vj146a2"/localarea_reliability_*_strict_yearlykeep_postdoe.parquet
ls "Map Data/reliability_outputs_vj146a2"/supplyarea_reliability_*_strict_yearlykeep_postdoe.parquet

ls "Map Data/settlement_day_outputs_vj146a2/mlr_validation_2023"/vj146a2_2023_mlr_validation_*.csv
```

Expected monthly counts:

- 12 `nocov` monthly Parquets
- 12 `cov` monthly Parquets
- 12 `cov_yearlykeep` monthly Parquets

Known absent daily rasters inside those months are treated as missing observations, not as missing monthly outputs.

---

## Readiness Summary

The VJ Parquet pipeline is ready to launch for full-year 2023 production if:

- VJ146A2 daily GeoTIFFs are present under `blackmarbler/out_vj146a2_sa_daily/`.
- Settlement, local-area, supply-area, and Eskom validation inputs exist at the expected paths.
- `EARTHDATA_USER` and `EARTHDATA_PASS` are available for pre-Stage-2 annual-composite download.
- The run is launched with `VJ146A2_ALLOW_PARTIAL=0` for production.
- The run is launched with `VJ146A2_USE_YEARLY_KEEP=1` for the faster production path.

This run will produce the full-year VJ settlement-day, yearlykeep, regional reliability, and Eskom MLR validation outputs needed for the Eskom calibration workflow.
