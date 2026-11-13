# Cape Town Pixel-IQR Validation Pipeline

This submodule builds a Cape Town-only pixel-relative nightlight darkness panel for schedule validation. It is separate from the threshold-sweep pipeline in `../scripts/` and does not replace the production VJ146A2 settlement-day builder.

The method estimates pixel-level annual radiance thresholds inside the selected Cape Town load-shedding blocks, then converts each daily raster into measurement rasters:

- `observed_iqr`: valid baseline pixels retained in the denominator
- `dark_iqr`: observed pixels below the configured dark threshold
- `bright_excluded_iqr`: valid baseline pixels excluded for excess brightness

The default threshold method is Tukey:

```text
lower = Q1 - 1.5 * IQR
upper = Q3 + 1.5 * IQR
```

Both lower and upper thresholds are configurable. Downstream scripts should define `not_up` or other binary outage targets later from `p_dark_iqr_block`; this pipeline only writes measurement panels.

## Scripts

```text
scripts/01_prepare_cape_town_pixel_aoi_vj146a2.R
scripts/02_build_cape_town_pixel_threshold_baseline_vj146a2.R
scripts/03_build_cape_town_daily_pixel_state_rasters_vj146a2.R
scripts/04_block_day_panel_build_pixel_iqr_dark_vj146a2.R
scripts/05_block_day_coverage_filter_pixel_iqr_dark_vj146a2.R
scripts/06_block_schedule_validation_specs_pixel_iqr_dark_vj146a2.R
scripts/visualize_block_schedule_validation_pixel_iqr_dark_vj146a2.R
scripts/04_settlement_day_panel_build_pixel_iqr_dark_vj146a2.R
scripts/05_settlement_day_coverage_filter_pixel_iqr_dark_vj146a2.R
```

Run the scripts from the `Reliability-Assessment` repo root.

The block-day scripts are the primary Cape Town schedule-validation path. They aggregate daily pixel states directly onto `data/aoi/cape_town_city_schedule_blocks.geojson`, preserving `block_id` and `circuit` values that can join to `Loadshedding_schedule.csv` via `Circuit` labels such as `Area 1`. The settlement-day scripts are retained only as a side diagnostic path.

Script `06` keeps `date` as the VJ product date and uses `local_overpass_date = date + 1` by default when joining to the Cape Town schedule. This mirrors the main VJ146A2 Eskom validation alignment. Override with:

```bash
CAPE_TOWN_EXPOSURE_DATE_SHIFT_DAYS=0
```

to reproduce same-date placebo diagnostics.

## Default Scope

The default AOI is City-scheduled Cape Town `BlockID` 1:16 from `../data/inputs/load_shedding_area.geojson`. Override with:

```bash
CAPE_TOWN_BLOCK_IDS=1:16
```

The pipeline is Cape Town-only by design. Reusing the method nationally would require rebuilding the AOI and pixel baseline nationally.
