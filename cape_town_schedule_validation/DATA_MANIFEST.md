# Data Manifest

## Included Inputs

These files are copied into the module for future Cape Town schedule validation steps:

| Artifact | Path | Used by current Step 1/2 scripts |
|---|---|---|
| City of Cape Town load-shedding schedule history | `data/inputs/Loadshedding_schedule.csv` | no |
| City of Cape Town load-shedding area polygons | `data/inputs/load_shedding_area.geojson` | no |

## Stage 2T Outputs

`scripts/01_settlement_day_panel_build_threshold_sweep_vj146a2.R` writes:

```text
data/stage2_threshold_sweep_nocov/settlement_day_vj146a2_threshold_sweep_nocov_YYYY-MM.parquet
data/stage2_threshold_sweep_nocov/settlement_day_vj146a2_threshold_sweep_nocov_YYYY-MM_daily_summary.csv
```

Smoke-mode outputs go under:

```text
data/stage2_threshold_sweep_nocov/smoke/
```

## Stage 3T Outputs

`scripts/02_settlement_day_coverage_filter_threshold_sweep_vj146a2.R` writes:

```text
data/stage3_threshold_sweep_cov/settlement_day_vj146a2_threshold_sweep_cov_YYYY-MM.parquet
```

## Pixel-IQR Pipeline Outputs

The separate `pixel_iqr_pipeline/` subfolder owns Cape Town-only pixel-relative darkness artifacts:

```text
pixel_iqr_pipeline/data/aoi/
pixel_iqr_pipeline/data/baseline/
pixel_iqr_pipeline/data/daily_states/
pixel_iqr_pipeline/data/stage2_pixel_iqr_nocov/
pixel_iqr_pipeline/data/stage3_pixel_iqr_cov/
```

## Required External Pipeline Inputs

The Stage 2T builder still depends on the same external VJ pipeline inputs as the existing Stage 2 builder:

```text
Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_full_col.gpkg
Map Data/reliability_outputs_vj146a2/vj146a2_yearly_keep_YYYY.parquet
Map Data/reliability_outputs_vj146a2/yearly_settlement_stats_YYYY.parquet
blackmarbler/out_vj146a2_sa_daily/vj146a2_sa_500m_daily_YYYY-MM-DD.tif
```

Use environment variables to override paths if needed:

```text
VJ146A2_SETT_GPKG
VJ146A2_RAST_DIR
VJ146A2_YEARLY_DIR
VJ146A2_YEARLY_KEEP_FILE
VJ146A2_YEARLY_STATS_FILE
VJ146A2_THRESHOLD_SWEEP_NOCOV_DIR
VJ146A2_THRESHOLD_SWEEP_COV_DIR
```
