# Cape Town Schedule Validation

This module is a focused workspace for Cape Town public schedule triangulation and bright-city threshold sensitivity. It is intentionally separate from the production VJ146A2 reliability pipeline and does not replace the current PyPSA-facing `not_up_040_share_demandw` bridge.

## Current Scope

Only the first two pipeline-parity steps are implemented:

1. `scripts/01_settlement_day_panel_build_threshold_sweep_vj146a2.R`
   - Mirrors the relevant structure of `Builder/settlement_day_panel_build_vj146a2.R`.
   - Builds a lean VJ146A2 settlement-day measurement panel for several pixel radiance thresholds.
   - Does not apply the daily coverage filter.
   - Does not define not-up targets or join Cape Town/Eskom exposure data.

2. `scripts/02_settlement_day_coverage_filter_threshold_sweep_vj146a2.R`
   - Mirrors `Builder/settlement_day_coverage_filter_vj146a2.R`.
   - Applies the daily coverage filter to the threshold-sweep measurement panel.

The public Cape Town schedule and load-shedding block inputs are included in `data/inputs/` for later spatial/schedule exposure steps, but the first two scripts do not use them.

## Pixel-IQR Pipeline

`pixel_iqr_pipeline/` is a separate Cape Town-only branch for pixel-relative darkness. It restricts processing to VJ pixels touching selected Cape Town load-shedding blocks, builds configurable per-pixel lower/upper radiance thresholds, creates daily observed/dark state rasters, and exact-extracts a settlement-day `p_dark_iqr_sett` measurement panel.

This branch is not mixed with the threshold-sweep scripts above. See `pixel_iqr_pipeline/README.md`.

## Measurement Schema

The Stage 2T and Stage 3T Parquets use a lean long-format schema:

```text
settlement_id
date
n_valid
n_lit
n_total_overlap
coverage
coverage_count
p_lit_sett
mean_rad_sett
population
pixel_lit_threshold
source_product
```

`date` keeps the same meaning as the existing VJ pipeline: the VJ product/acquisition date. Local overpass date alignment belongs in later validation scripts.

## Default Thresholds

The default pixel-lit thresholds are:

```text
1, 3, 5, 10
```

Override with:

```sh
VJ146A2_PIXEL_LIT_THRESHOLDS=1,5 Rscript cape_town_schedule_validation/scripts/01_settlement_day_panel_build_threshold_sweep_vj146a2.R
```

## Run Order

Run from the `Reliability-Assessment` repository root:

```sh
Rscript cape_town_schedule_validation/scripts/01_settlement_day_panel_build_threshold_sweep_vj146a2.R
Rscript cape_town_schedule_validation/scripts/02_settlement_day_coverage_filter_threshold_sweep_vj146a2.R
```

No scripts have been run as part of module creation.
