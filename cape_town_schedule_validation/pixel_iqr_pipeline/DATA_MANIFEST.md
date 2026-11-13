# Pixel-IQR Pipeline Data Manifest

## Parent Module Inputs

- `../data/inputs/load_shedding_area.geojson`

## External Inputs

- `blackmarbler/out_vj146a2_sa_daily/vj146a2_sa_500m_daily_YYYY-MM-DD.tif`
- `Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_full_col.gpkg` only for optional settlement-side diagnostics
- `Map Data/reliability_outputs_vj146a2/vj146a2_yearly_keep_2023.parquet` only for optional settlement-side diagnostics
- `Map Data/reliability_outputs_vj146a2/yearly_settlement_stats_2023.parquet` fallback only for optional settlement-side diagnostics

## Generated Outputs

- `data/aoi/cape_town_city_schedule_blocks.geojson`
- `data/aoi/cape_town_vj146a2_processing_mask.tif`
- `data/baseline/cape_town_vj146a2_2023_pixel_threshold_baseline.tif`
- `data/baseline/cape_town_vj146a2_2023_pixel_threshold_config.csv`
- `data/daily_states/cape_town_pixel_iqr_state_YYYY-MM-DD.tif`
- `data/stage2_block_iqr_nocov/block_day_vj146a2_pixel_iqr_nocov_YYYY-MM.parquet`
- `data/stage2_block_iqr_nocov/block_day_vj146a2_pixel_iqr_nocov_YYYY-MM_daily_summary.csv`
- `data/stage3_block_iqr_cov/block_day_vj146a2_pixel_iqr_cov_YYYY-MM.parquet`
- `data/stage2_pixel_iqr_nocov/settlement_day_vj146a2_pixel_iqr_nocov_YYYY-MM.parquet`
- `data/stage2_pixel_iqr_nocov/settlement_day_vj146a2_pixel_iqr_nocov_YYYY-MM_daily_summary.csv`
- `data/stage3_pixel_iqr_cov/settlement_day_vj146a2_pixel_iqr_cov_YYYY-MM.parquet`
