# Project Overview
- Builds daily VIIRS night-light settlement panels for South Africa from NASA LAADS (via `blackmarbler`), computes reliability states and electrification dates per settlement, and renders maps.
- Scripts auto-detect the project root via the `here` package — no path edits needed after cloning (see Quickstart).

# Pipeline Workflow

## Visual Pipeline Flow

```
Stage 0: Spatial layer prep (settlements, boundaries, generators, grid)
    ↓
Stage 1: Download VIIRS TIFs (from Google Drive — full year 2023 available)
    ↓
Stage 2: Settlement-Day Panel (no coverage filter)
    Inputs: 365 VIIRS daily TIFFs + settlement polygons
    Outputs: 12 monthly Parquets (nocov variant)
    ↓
Stage 3: Coverage Filter (≥0.5 pixel-coverage threshold)
    Outputs: 12 monthly Parquets (cov variant)
    ↓
Stage 4: Yearly Composite Calibration ⭐ REQUIRED
    Uses VNP46A4 annual composite (higher quality, full-year integrated)
    Classifies settlements as electrified (electrified_best flag)
    Output: yearly_settlement_stats_2023.parquet
    ↓
Stage 5: Reliability Panel — Yearlykeep ⭐ USE THIS
    Pre-filters to electrified settlements from Stage 4
    Runs rolling-window DOE detection on daily values
    Outputs: settlement/localarea/supplyarea reliability Parquets
    ↓
Stage 6: Choropleth Maps ⭐ YOUR REPORT MAPS
    Outputs: uptime + SD uptime + CV radiance × local/supply area (6 maps)
    ↓
Stage 7: Population Coverage Maps  [optional]
    Maps share of total settled population covered by the analysis
    Flags areas where < 50% of total settled population is included
    ↓
Stage 8: Interactive Leaflet Map ✅ SUPPLEMENTARY
    Output: leaflet_reliability_yearly.html
```

**Why Stage 4 (annual composite) instead of a rolling-window sweep?**
A rolling-window sweep forces daily parameters to match the ~87.7% national electrification statistic. Stage 4 uses the VNP46A4 annual composite (full year integrated, higher signal quality) as direct ground truth — more accurate and methodologically cleaner.

---

## Population Filtering — Two-Stage Logic

The analysis discards part of the settled population in two distinct stages:

**Filter 1 — Yearly composite (Stage 4)**
The VNP46A4 annual composite classifies each settlement as electrified or dark. Only electrified settlements (`electrified_best == 1`) enter the reliability pipeline. In areas with large rural or informal populations this can be the dominant cut: nationally 87.7% of VIIRS-observed settled population is electrified; in Mthatha only 32%, in Empangeni only 47%.

**Filter 2 — DOE confirmation in the daily panel (Stage 5)**
Within electrified settlements, some lack sufficient daily clear-sky observations to make a reliable call. The `share_population_kept` metric in the reliability Parquets captures this second filter:

```
share_population_kept = kept_population / area_population

  area_population  — population of yearly-composite-electrified settlements
                     in the area (denominator is electrified, not total)
  kept_population  — population of the subset that additionally have
                     sufficient daily observations and DOE-confirmed
                     electrification (electrified_after_doe_strict == 1)
```

Nationally, `share_population_kept ≈ 1.0`: once a settlement is classified as electrified by the yearly composite, the daily panel almost always confirms it.

A full breakdown of both stages (total VIIRS-observed pop → electrified pop → yearly-keep pop) for every local area, supply area, and nationally is in:
`Map Data/reliability_outputs_blackmarbler/figures/yearlykeep_population_coverage.csv`

---

## Step-by-Step Execution Guide

1. **Stage 0 (Spatial prep)**
   ```bash
   Rscript "Map Data/Boundaries/SA_boundaries.r"
   Rscript "Map Data/Generators Data/gen_clean.r"
   Rscript "Map Data/Grid Data/grid_clean.r"
   Rscript settlements_cleaning/settlements_csv_to_gpkg.R
   ```

2. **Stage 1 (Download VIIRS TIFs)**
   ```bash
   Rscript "nightlight_downloader/viirs_daily_download.R"
   ```

3. **Stage 2 (Settlement-day panel)**
   ```bash
   Rscript "Builder/settlement_day_panel_build.R"
   ```

4. **Stage 3 (Coverage filter)**
   ```bash
   Rscript "Builder/settlement_day_coverage_filter.R"
   ```

5. **Stage 4 (Annual composite)** ⭐ identifies electrified settlements
   ```bash
   Rscript "Visualizer/settlement_yearly_composite.R"
   ```

6. **Stage 5 (Reliability panel)** ⭐ core analysis
   ```bash
   Rscript "Visualizer/reliability_panel_build_yearlykeep.R"
   ```

7. **Stage 6 (Choropleth maps)** ⭐ report maps
   ```bash
   Rscript "Visualizer/reliability_choropleth_maps.R"
   ```

8. **Stage 7 (Population coverage maps)** *(optional)*
   Produces two choropleth maps showing the share of total settled population covered, with areas below 50% flagged with `*`.
   ```bash
   Rscript "Visualizer/population_coverage_map.R"
   ```

9. **Stage 8 (Leaflet map)** ✅ supplementary
   ```bash
   Rscript "Visualizer/reliability_leaflet_map.R"
   ```

> Superseded scripts in `Visualizer/Others/` are archived and not part of the active pipeline.

---

# Pipeline (run in order)

## Step 0 — Prepare spatial layers (one-time prep, can run in parallel)

### Generated by scripts (run once)
- **Settlements:** `settlements_cleaning/settlements_csv_to_gpkg.R` — converts `south_africa_dre_atlas_settlements.csv` (WKT) to `south_africa_dre_atlas_settlements_full_col.gpkg` (full geometry, for zonal stats) and `south_africa_dre_atlas_settlements_simplified_full_col.gpkg` (simplified, for rendering) in `Map Data/Settlements/GPKG/`.
- **Boundaries:** `Map Data/Boundaries/SA_boundaries.r` — downloads GADM admin0–2 for South Africa to `Map Data/Boundaries/boundaries_outputs/south_africa_admin_boundaries_GADM.gpkg`.
- **Generators:** `Map Data/Generators Data/gen_clean.r` — cleans Africa Energy Tracker Excel (`Africa-Energy-Tracker-2025-10-21.xlsx`) and writes GeoPackage/Parquet/GeoJSON to `Map Data/Generators Data/generators_outputs/`.
- **Grid:** `Map Data/Grid Data/grid_clean.r` — clips continental JRC grid shapefile (`elect_grid_africa_epsg3426_withgau_JRC.shp`) to South Africa and writes to `Map Data/Grid Data/electricitygrid_Africa_JRC/output_folder/electricity_grid_south_africa.gpkg`.

### Pre-existing static data (no script needed — must be present)
- **Local Areas:** `Map Data/Local Area/LOCAL_AREA_GCCA2025.shp` — Eskom local area boundaries (GCCA 2025).
- **Supply Areas:** `Map Data/Supply Area/SUPPLY_AREA_GCCA2025.shp` — Eskom supply area boundaries (GCCA 2025).

## Step 1 — Download daily VIIRS rasters (NASA LAADS)
- **Script:** `nightlight_downloader/viirs_daily_download.R`
- Downloads VNP46A2 BRDF-corrected, no-gap-fill daily radiance for South Africa via the `blackmarbler` R package.
- Applies quality filters (cloud mask bits 6–7, Mandatory QF, snow flag) and writes 3-band GeoTIFFs (`rad`, `lit`, `valid`) to `blackmarbler/out_vnp46a2_sa_daily/`.
- Output filename pattern: `sa_viirs_500m_daily_YYYY-MM-DD.tif`
- Requires NASA Earthdata credentials set in `~/.Renviron` as `EARTHDATA_USER` / `EARTHDATA_PASS`.

## Step 2 — Build settlement-day panel (no coverage filter)
- **Script:** `Builder/settlement_day_panel_build.R`
- Reads settlement polygons and daily GeoTIFFs from `blackmarbler/out_vnp46a2_sa_daily/`.
- Loops month-by-month over `START_MONTH`–`END_MONTH`; coverage filter is **not** applied here (done in Step 3).
- **Note on settlement GPKG:** the script's default `SETT_GPKG` points to `south_africa_dre_atlas_settlements_full_col.gpkg` (the current output of `settlements_csv_to_gpkg.R`).
- Outputs per-month Parquet panels + monthly-mean GeoPackages to `Map Data/settlement_day_outputs_rasters_blackmarbler/`.

### Configuration parameters
| Parameter | Default | Description |
|---|---|---|
| `MIN_COVERAGE` | `0.50` | Coverage threshold used in Step 3 (defined here for reference) |
| `START_MONTH` | `"2023-09"` | First month to process (`YYYY-MM`) |
| `END_MONTH` | `"2023-12"` | Last month to process (`YYYY-MM`) |
| `AREA_CRS` | Albers Equal-Area (SA) | CRS used to compute settlement areas in m² |
| `APPLY_COVERAGE_FILTER` | `FALSE` | Set `TRUE` to apply coverage filter inside this script; normally leave `FALSE` and use Step 3 |

### Computed columns (per settlement-day row)
| Column            | Computation                                       | Description                                                                                         |
| ----------------- | ------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `n_valid`         | `exact=TRUE` area-weighted sum of `valid` pixels  | Fractional count of valid (cloud-free) pixels intersecting the settlement, weighted by overlap area |
| `n_lit`           | `exact=TRUE` area-weighted sum of `lit` pixels    | Fractional count of lit pixels intersecting the settlement, weighted by overlap area                |
| `n_valid_count`   | `exact=FALSE` pixel-centre sum of `valid`         | Count of valid pixels whose centres fall inside the settlement                                      |
| `n_lit_count`     | `exact=FALSE` pixel-centre sum of `lit`           | Count of lit pixels whose centres fall inside the settlement                                        |
| `n_valid_overlap` | `touches=TRUE` sum of `valid > 0`                 | Count of valid pixels that touch (not necessarily centre-inside) the settlement polygon             |
| `n_total_overlap` | `touches=TRUE` total pixel count                  | Total pixel count touching the settlement (denominator for `coverage_count`)                        |
| `valid_area_m2`   | `exact=TRUE` sum of `cell_area_m2 × valid`        | Area (m²) of valid pixels overlapping the settlement; used as numerator for `coverage`              |
| `p_lit_sett`      | `n_lit / n_valid`                                 | Area-weighted share of valid pixels that are lit; primary lighting measure                          |
| `p_lit_count`     | `n_lit_count / n_valid_count`                     | Pixel-centre lighting share; alternative to `p_lit_sett` for comparison                             |
| `coverage`        | `valid_area_m2 / settlement_area_m2`, capped at 1 | Fraction of the settlement's area covered by valid (cloud-free) pixels                              |
| `coverage_count`  | `n_valid_overlap / n_total_overlap`               | Alternative coverage metric using any-touch pixel counts                                            |

### Monthly aggregation columns (in the `.gpkg` output)
| Column | Description |
|---|---|
| `mean_p_lit` | Mean of `p_lit_sett` across observed days |
| `mean_p_lit_count` | Mean of `p_lit_count` across observed days |
| `sd_p_lit` | Standard deviation of `p_lit_sett` (NA if fewer than 2 observations) |
| `drop_frac` | Fraction of days where `p_lit_sett < 0.2` |
| `n_days_obs` | Number of days with a non-NA `p_lit_sett` |
| `mean_cov` | Mean `coverage` across observed days |
| `mean_cov_count` | Mean `coverage_count` across observed days |
| `mean_n_valid` | Mean `n_valid` (area-weighted valid pixels) across observed days |
| `mean_n_valid_count` | Mean `n_valid_count` across observed days |

### Outputs
- `Map Data/settlement_day_outputs_rasters_blackmarbler/settlement_day_blackmarbler_nocov_YYYY-MM.parquet`
- `Map Data/settlement_day_outputs_rasters_blackmarbler/settlement_month_blackmarbler_nocov_YYYY-MM.gpkg`

## Step 3 — Apply coverage filter
- **Script:** `Builder/settlement_day_coverage_filter.R`
- Reads the `nocov` Parquet files from Step 2 and filters to `coverage >= MIN_COVERAGE` (default `0.5`).
- Writes filtered panels to `Map Data/settlement_day_outputs_rasters_blackmarbler/settlement_day_blackmarbler_cov_YYYY-MM.parquet`.

## Step 4 — Yearly composite calibration
- **Script:** `Visualizer/settlement_yearly_composite.R`
- Downloads the VNP46A4 annual composite from blackmarbler and sweeps over lit thresholds to find the best match to the official SA electrification target (87.7% population share).
- **Output:** `Map Data/reliability_outputs_blackmarbler/yearly_settlement_stats_2023.parquet` — one row per settlement with `electrified_best` flag (1 = electrified, 0 = dark).
- This file is the direct input to Step 5's yearly-keep filter.

## Step 5 — Reliability panel (yearly-keep variant) ⭐ ACTIVE
- **Script:** `Visualizer/reliability_panel_build_yearlykeep.R`
- Reads `yearly_settlement_stats_2023.parquet` (Stage 4) and filters `sett_day` to `electrified_best == 1` settlements only before building the daily state panel.
- Runs rolling-window DOE detection; the state used is `electrified_after_doe_strict`.
- `share_population_kept` in the output measures DOE-confirmed population as a share of the yearly-composite-electrified population (see Two-Stage Logic section above).

### Key configuration parameters
| Parameter | Default | Description |
|---|---|---|
| `AREA_COVERAGE_MIN` | `0.5` | Min share of yearly-composite-electrified population with DOE-confirmed data for an area-period to be included |
| `ROLLING_OBS_MIN` | `15` | Min observed days in the 30-day rolling window |
| `N_DAYS_MIN_YEAR` | `85` | Min observed days in a year for yearly metric to be valid |

### Outputs (to `Map Data/reliability_outputs_blackmarbler/`)
- `settlement_reliability_{period}_strict_yearlykeep_postdoe.parquet`
- `localarea_reliability_{period}_strict_yearlykeep_postdoe.parquet`
- `supplyarea_reliability_{period}_strict_yearlykeep_postdoe.parquet`
- `settlement_day_states_strict_yearlykeep.parquet` — daily state cache
- `localarea_yearly_electrification_share_2023.csv` — pre-filter electrification by local area
- `supplyarea_yearly_electrification_share_2023.csv` — pre-filter electrification by supply area
- `diagnostics/` — diagnostic Parquets and CSVs

## Step 6 — Choropleth maps ⭐ REPORT MAPS
- **Script:** `Visualizer/reliability_choropleth_maps.R`
- Reads local-area and supply-area reliability Parquets from Stage 5.
- Produces 6 ggplot2 choropleth PDFs/PNGs across 3 metrics × 2 spatial areas:
  - `uptime_popw` (level) × local / supply area
  - `sd_uptime_popw` (inequality) × local / supply area
  - `cv_p_lit_popw` (volatility) × local / supply area
- **Outputs:** `figures/local_main_yearly_*.pdf/png`, `figures/local_sd_yearly_*.pdf/png`, `figures/local_var_yearly_*.pdf/png`, and `supply_main_*`, `supply_sd_*`, `supply_var_*` equivalents (6 map files total).

## Step 7 — Population coverage maps *(optional)*
- **Script:** `Visualizer/population_coverage_map.R`
- Produces two choropleth maps showing `pop_yearlykeep / pop_total_gpkg` per area, where `pop_total_gpkg` is summed directly from the DRE Atlas settlement GPKG (NA population treated as 0).
- Diverging red–cream–blue colour scale centred at 50%.
- Areas with share < 50% receive a dashed polygon border and a bold `*` appended to their label.
- Local areas map: only flagged areas labelled (Mthatha*, Empangeni*, Greater Komsberg*).
- Supply areas map: all 10 areas labelled; none fall below 50%.
- **Outputs:** `figures/coverage_map_local.pdf/png`, `figures/coverage_map_supply.pdf/png`

## Step 8 — Interactive Leaflet map
- **Script:** `Visualizer/reliability_leaflet_map.R`
- Reads yearly settlement reliability data and renders an interactive Leaflet map overlaid with generators, JRC grid, and SA boundary.
- **Output:** `leaflet_reliability_yearly.html`

---

# Supporting / Diagnostic Scripts

> Additional scripts (diagnostics, superseded alternatives) are in `nightlight_downloader/Others/` and `Visualizer/Others/` — they are NOT part of the active pipeline.

| Script | Location | Purpose |
|---|---|---|
| `qa_quality_flag_comparison.R` | `nightlight_downloader/Others/` | Compares quality-flag filter scenarios on radiance output |
| `reliability_panel_build.R` | `Visualizer/Others/` | All-settlements reliability panel — superseded by Stage 5 |
| `doe_threshold_sweep.R` | `Visualizer/Others/` | DOE threshold calibration sweep — superseded by Stage 4 |
| `supply_area_calibration.R` | `Visualizer/Others/` | Province-level grid search vs official electrification targets |
| `doe_population_summary.R` | `Visualizer/Others/` | Population-weighted DOE summary |
| `local_area_observation_audit.R` | `Visualizer/Others/` | Validates temporal data coverage at local-area level |
| `Builder/join_parquet_with_simplified_gpkg.r` | `Builder/` | **Legacy** — old GEE nogap pipeline |
| `Builder/settlement_lit_summary_conditions.r` | `Builder/` | **Legacy** — old HQ_nogap_final pipeline |
| `run_coverage_sweep.R` | `Builder/` | Orchestrates the coverage sensitivity sweep across MIN_COVERAGE thresholds |
| `area_coverage_sensitivity.R` | `Builder/` | Tabulates how area-level population coverage changes across coverage thresholds |
| `doe_parameter_sweep.R` | `Builder/` | Sweeps rolling-window DOE parameters (ROLLING_DAYS × ROLLING_LIT_MIN) to assess sensitivity |

---

# Key Inputs & Outputs (relative to BASE_PATH)

| Direction | File |
|---|---|
| Input | `settlements_cleaning/south_africa_dre_atlas_settlements.csv` *(see Google Drive link in DATA.md)* |
| Input | `blackmarbler/out_vnp46a2_sa_daily/*.tif` (downloaded by Step 1) |
| Input | `Map Data/Generators Data/Africa-Energy-Tracker-2025-10-21.xlsx` |
| Input | `Map Data/Grid Data/electricitygrid_Africa_JRC/elect_grid_africa_epsg3426_withgau_JRC.shp` |
| Input | `Map Data/Local Area/LOCAL_AREA_GCCA2025.shp` (static, pre-existing) |
| Input | `Map Data/Supply Area/SUPPLY_AREA_GCCA2025.shp` (static, pre-existing) |
| Output | `Map Data/settlement_day_outputs_rasters_blackmarbler/settlement_day_blackmarbler_nocov_YYYY-MM.parquet` |
| Output | `Map Data/settlement_day_outputs_rasters_blackmarbler/settlement_day_blackmarbler_cov_YYYY-MM.parquet` |
| Output | `Map Data/settlement_day_outputs_rasters_blackmarbler/settlement_month_blackmarbler_nocov_YYYY-MM.gpkg` |
| Output | `Map Data/reliability_outputs_blackmarbler/yearly_settlement_stats_2023.parquet` |
| Output | `Map Data/reliability_outputs_blackmarbler/settlement_reliability_{period}_strict_yearlykeep_postdoe.parquet` |
| Output | `Map Data/reliability_outputs_blackmarbler/localarea_reliability_{period}_strict_yearlykeep_postdoe.parquet` |
| Output | `Map Data/reliability_outputs_blackmarbler/supplyarea_reliability_{period}_strict_yearlykeep_postdoe.parquet` |
| Output | `Map Data/reliability_outputs_blackmarbler/figures/local_main_yearly_strict_yearlykeep_postdoe_all.pdf/png` |
| Output | `Map Data/reliability_outputs_blackmarbler/figures/local_sd_yearly_strict_yearlykeep_postdoe_all.pdf/png` |
| Output | `Map Data/reliability_outputs_blackmarbler/figures/local_var_yearly_strict_yearlykeep_postdoe_all.pdf/png` |
| Output | `Map Data/reliability_outputs_blackmarbler/figures/supply_main_yearly_strict_yearlykeep_postdoe_all.pdf/png` |
| Output | `Map Data/reliability_outputs_blackmarbler/figures/supply_sd_yearly_strict_yearlykeep_postdoe_all.pdf/png` |
| Output | `Map Data/reliability_outputs_blackmarbler/figures/supply_var_yearly_strict_yearlykeep_postdoe_all.pdf/png` |
| Output | `Map Data/reliability_outputs_blackmarbler/figures/yearlykeep_population_coverage.csv` |
| Output | `Map Data/reliability_outputs_blackmarbler/figures/coverage_map_local.pdf/png` |
| Output | `Map Data/reliability_outputs_blackmarbler/figures/coverage_map_supply.pdf/png` |
| Output | `Map Data/Generators Data/generators_outputs/south_africa_power_plants.*` |
| Output | `Map Data/Grid Data/electricitygrid_Africa_JRC/output_folder/electricity_grid_south_africa.gpkg` |
| Output | `Map Data/Boundaries/boundaries_outputs/south_africa_admin_boundaries_GADM.gpkg` |

---

# Quickstart
1. Install required R packages:
   ```r
   install.packages(c(
     "here", "sf", "terra", "blackmarbler", "arrow", "dplyr", "lubridate",
     "tidyr", "slider", "purrr", "data.table", "leaflet", "ggplot2", "ggrepel",
     "geodata", "readxl", "janitor", "stringr", "viridisLite", "scales",
     "htmlwidgets", "htmltools", "exactextractr"
   ))
   ```
2. **Download all data** (external inputs + full-year VIIRS TIFs) from [Google Drive](https://drive.google.com/drive/folders/1G1DHDuFV3fX-k5AMrLhLCXFdKU5pLlUt?usp=sharing) and extract per `DATA.md`.
3. **Set NASA Earthdata credentials** in `~/.Renviron` (required for Stage 4; Stage 1 if re-downloading TIFs):
   ```
   EARTHDATA_USER=your_username
   EARTHDATA_PASS=your_password
   ```
4. Run Stage 0 prep scripts:
   ```bash
   Rscript "Map Data/Boundaries/SA_boundaries.r"
   Rscript "Map Data/Generators Data/gen_clean.r"
   Rscript "Map Data/Grid Data/grid_clean.r"
   Rscript settlements_cleaning/settlements_csv_to_gpkg.R
   ```
5. *(Optional — skip if using Google Drive TIFs)* Re-download VIIRS daily rasters:
   ```bash
   Rscript "nightlight_downloader/viirs_daily_download.R"
   ```
6. Build the daily panel (Stage 2) and apply coverage filter (Stage 3):
   ```bash
   Rscript "Builder/settlement_day_panel_build.R"
   Rscript "Builder/settlement_day_coverage_filter.R"
   ```
7. Run annual composite calibration (Stage 4 — requires NASA credentials):
   ```bash
   Rscript "Visualizer/settlement_yearly_composite.R"
   ```
8. Build reliability states (Stage 5):
   ```bash
   Rscript "Visualizer/reliability_panel_build_yearlykeep.R"
   ```
9. Produce static choropleth maps (Stage 6):
   ```bash
   Rscript "Visualizer/reliability_choropleth_maps.R"
   ```
10. *(Optional)* Produce population coverage maps (Stage 7):
    ```bash
    Rscript "Visualizer/population_coverage_map.R"
    ```
11. Produce interactive Leaflet map (Stage 8):
    ```bash
    Rscript "Visualizer/reliability_leaflet_map.R"
    ```

# .gitignore & Data Sources
Large data files are excluded from version control. See `.gitignore` at repo root and `DATA.md` for external data sources.

**Quick link:** Download all input files + full-year VIIRS TIFs (2023) from [Google Drive](https://drive.google.com/drive/folders/1G1DHDuFV3fX-k5AMrLhLCXFdKU5pLlUt?usp=sharing)

Key excluded paths:
- `blackmarbler/out_vnp46a2_sa_daily/` — VIIRS GeoTIFFs for full year 2023 (available on Google Drive)
- `Map Data/settlement_day_outputs_rasters_blackmarbler/` — pipeline outputs (regenerate by running Steps 2–3)
- `Map Data/reliability_outputs_blackmarbler/` — reliability outputs (regenerate by running Steps 4–6)
- `Map Data/Settlements/GPKG/` — processed GeoPackages (regenerate by running Step 0)
- `*.h5` — NASA HDF5 cache files
- `settlements_cleaning/south_africa_dre_atlas_settlements.csv` — DRE Atlas source data (306 MB; available on Google Drive)
