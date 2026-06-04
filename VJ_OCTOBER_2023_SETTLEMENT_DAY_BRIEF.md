# VJ146A2 October 2023 Settlement-Day Plan For Ravi Review

**Date:** 2026-06-03  
**Repository:** `6-codebases/repos/Reliability-Assessment`  
**Status:** Final review plan before xhigh handoff  
**Purpose:** Produce a separate October 2023 VJ146A2 settlement-day dataset that Ravi can compare against Eskom load-shedding data.  

## Ravi Review Summary

This plan creates a **daily settlement-level** VJ146A2 panel for October 2023. It is designed to be close to the current Reliability-Assessment pipeline, but isolated from the production VNP outputs.

The intended outputs are:

```text
Map Data/settlement_day_outputs_vj146a2/
  settlement_day_vj146a2_cov_yearlykeep_2023-10.parquet
  settlement_day_vj146a2_cov_yearlykeep_2023-10_daily_summary.csv
```

The Parquet should let Ravi adapt `SA_nightlights_panel.R` with minimal changes. It will contain one row per settlement per available VJ day, with:

- `date`, `settlement_id`, `population`
- `p_lit_sett`
- `dark = p_lit_sett < 0.05`
- daily settlement state: `lit`, `dark`, or `ambiguous`
- daily mean and median lit indicators
- daily mean and median radiance

The output is already filtered to settlements classified as electrified by the existing annual composite (`electrified_best == 1`) and to settlement-days with adequate valid-pixel coverage (`coverage >= 0.5`).

## What Ravi Should Double Check

Before handoff to xhigh, Ravi should confirm these are the right analysis inputs: Ravi confirmed all of these points.

1. The daily comparison should use only annual-composite-electrified settlements (`electrified_best == 1`).
2. The pixel lit threshold should remain `rad > 1.0`, matching the production VNP convention.
3. The daily darkness proxy should remain `dark = p_lit_sett < 0.05`, matching `SA_nightlights_panel.R`.
4. The settlement state thresholds should be:
   - `lit` if `p_lit_sett >= 0.40`
   - `dark` if `p_lit_sett < 0.05`
   - `ambiguous` otherwise
5. The output should not apply DOE/post-DOE filtering. It should preserve observed daily states for October so Ravi can compare them to daily load shedding.
6. Ravi will aggregate nationally himself. The CSV is only a quick daily sanity summary.
7. If Ravi still wants a population filter such as `population > 100`, it should be applied in his analysis script, not hardcoded into the xhigh output.

## Full Pipeline Alignment

The active Reliability-Assessment pipeline is:

```text
Stage 0  spatial prep
Stage 1  daily VIIRS raster download
Stage 2  settlement-day panel, no coverage filter
Stage 3  coverage filter, coverage >= 0.5
Stage 4  annual composite electrification classification
Stage 5  reliability panel with yearly-keep and DOE logic
Stage 6+ maps and downstream reporting
```

This VJ trial uses the same conceptual path through Stage 4, but stops before the full Stage 5 reliability outputs:

```text
Existing October VJ146A2 rasters
  -> Stage 2 style exact settlement-day extraction
  -> Stage 3 style coverage filter
  -> Stage 4 annual electrified-settlement keep list
  -> Ravi-ready daily settlement panel
```

It does **not** run:

- VNP daily redownload;
- VJ redownload;
- Stage 4 annual composite regeneration;
- DOE detection;
- monthly/yearly reliability panel aggregation;
- local-area or supply-area reliability aggregation.

## Implementation Boundary

This is a diagnostic/trial VJ path, not a production replacement for VNP.

The xhigh agent should create a VJ-specific script and output folder. Recommended script:

```text
Builder/Others/settlement_day_panel_build_vj146a2_oct2023.R
```

Recommended output folder:

```text
Map Data/settlement_day_outputs_vj146a2/
```

Do not overwrite or edit these production files:

```text
blackmarbler/out_vnp46a2_sa_daily/sa_viirs_500m_daily_*.tif
Map Data/settlement_day_outputs_rasters_blackmarbler/settlement_day_blackmarbler_*.parquet
Map Data/reliability_outputs_blackmarbler/*.parquet
nightlight_downloader/viirs_daily_download.R
```

## Files Xhigh Must Read

```text
project_pipeline_submission.Rmd
README.md
SA_nightlights_panel.R
Builder/settlement_day_panel_build.R
Builder/settlement_day_coverage_filter.R
Visualizer/settlement_yearly_composite.R
Visualizer/reliability_panel_build_yearlykeep.R
nightlight_downloader/Others/vj146a2_month_gif_diagnostic.R
```

Key interpretation:

- `project_pipeline_submission.Rmd` defines the methods and thresholds.
- `SA_nightlights_panel.R` shows Ravi's prior January workflow.
- `settlement_day_panel_build.R` defines the current Stage 2 settlement-day extraction.
- `settlement_day_coverage_filter.R` defines the Stage 3 coverage filter.
- `settlement_yearly_composite.R` produces the existing `electrified_best` classification.
- `reliability_panel_build_yearlykeep.R` defines state thresholds, but this handoff should not run the full reliability panel.

## Existing VJ Inputs

The VJ146A2 October 2023 rasters already exist:

```text
blackmarbler/out_vnp46a2_sa_daily/qa_straylight_validation/vj146a2_month_2023-10/rasters/
```

Available dates:

```text
2023-10-02 through 2023-10-31
```

Missing date:

```text
2023-10-01
```

Decision: skip `2023-10-01`. Do not create all-NA settlement rows for that date.

Each raster has:

```text
rad      VJ146A2 DNB_BRDF-Corrected_NTL, masked to valid pixels
lit_ge1  diagnostic lit class from rad >= 1
valid    valid-pixel mask
```

The builder should derive lit from `rad` and `valid` rather than trusting `lit_ge1`, because this makes the threshold convention explicit.

## Fixed Decisions For Xhigh

| Topic | Decision |
|---|---|
| Month | October 2023 only |
| Product | VJ146A2 daily |
| Missing day | Skip `2023-10-01` |
| Pixel lit threshold | `rad > 1.0` |
| Coverage filter | `coverage >= 0.5` |
| Settlement keep list | `electrified_best == 1` from existing annual composite |
| DOE/post-DOE filter | Do not apply |
| Daily state thresholds | `lit >= 0.40`, `dark < 0.05`, otherwise `ambiguous` |
| Output unit | Settlement-day |
| Ravi aggregation | National aggregation done later by Ravi |
| Production VNP files | Do not touch |

Note: earlier VJ GIFs/notebooks used `rad >= 1`. This plan intentionally uses `rad > 1.0` to match the current production VNP pipeline and `project_pipeline_submission.Rmd`. The difference should be small, but the Parquet will not exactly match GIF summaries.

## Required Parquet Schema

Write:

```text
Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_cov_yearlykeep_2023-10.parquet
```

Required columns:

| Column | Type | Meaning |
|---|---|---|
| `settlement_id` | character or integer | Settlement key, consistent with existing files |
| `date` | Date | Observation date |
| `n_valid` | double | Exact-overlap weighted count of valid pixels |
| `n_lit` | double | Exact-overlap weighted count of lit pixels using `rad > 1.0` |
| `rad_sum` | double | Exact-overlap weighted sum of valid radiance |
| `mean_lit_sett` | double | Mean binary lit value over valid pixels; equal to `p_lit_sett` |
| `median_lit_sett` | integer/double | Binary weighted median of lit over valid pixels; use `1` if `p_lit_sett >= 0.5`, else `0`; `NA` if no valid pixels |
| `mean_rad_sett` | double | `rad_sum / n_valid` |
| `median_rad_sett` | double | Coverage-weighted median radiance over valid pixels |
| `valid_area_m2` | double | Exact-overlap valid area inside settlement |
| `area_m2` | double | Settlement area in equal-area CRS |
| `coverage` | double | `min(1, valid_area_m2 / area_m2)` |
| `p_lit_sett` | double | `n_lit / n_valid` |
| `lit_day` | integer | `1` if `p_lit_sett >= 0.40`, else `0`; `NA` if missing |
| `dark_day` | integer | `1` if `p_lit_sett < 0.05`, else `0`; `NA` if missing |
| `dark` | logical | Ravi-compatible flag: `p_lit_sett < 0.05` |
| `settlement_state` | character | `lit`, `dark`, or `ambiguous` |
| `population` | double | Settlement population for national weighting |
| `electrified_best` | integer | Annual-composite flag; all output rows should be `1` |

Do not include these old diagnostic columns unless they are trivial to preserve:

```text
n_valid_count, n_lit_count, n_valid_overlap, n_total_overlap,
p_lit_count, coverage_count, n_max
```

## Extraction Method

Use `exactextractr::exact_extract()`, not repeated `terra::extract(..., exact = TRUE)`.

For each daily VJ raster:

1. Read `rad` and `valid`.
2. Derive lit with the production convention:

```r
lit <- terra::ifel(is.na(rad), NA, terra::ifel(valid == 1 & rad > 1.0, 1, 0))
lit <- terra::ifel(valid == 1, lit, NA)
```

3. Compute exact-overlap settlement quantities:

```text
n_valid       = weighted sum of valid
n_lit         = weighted sum of lit
rad_sum       = weighted sum of rad over valid pixels
median_rad    = coverage-weighted median of rad over valid pixels
valid_area_m2 = weighted sum of cell_area_m2 * valid
```

4. Derive:

```text
p_lit_sett      = n_lit / n_valid
mean_lit_sett   = p_lit_sett
median_lit_sett = as.integer(p_lit_sett >= 0.5)
mean_rad_sett   = rad_sum / n_valid
median_rad_sett = weighted median radiance over valid pixels
coverage        = min(1, valid_area_m2 / area_m2)
dark            = p_lit_sett < 0.05
lit_day         = as.integer(p_lit_sett >= 0.40)
dark_day        = as.integer(p_lit_sett < 0.05)
settlement_state = "lit" if p_lit_sett >= 0.40,
                   "dark" if p_lit_sett < 0.05,
                   "ambiguous" otherwise
```

Use `NA` for derived fields when `n_valid <= 0` or the denominator is missing.

For `median_rad_sett`, implement a small coverage-weighted median helper inside `exactextractr::exact_extract(..., fun = function(values, coverage_fraction) ...)`, dropping `NA` radiance values and using `coverage_fraction` as weights.

## Settlement And Annual-Composite Inputs

Settlement geometry:

```text
Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_full_col.gpkg
```

Existing annual-composite classification:

```text
Map Data/reliability_outputs_blackmarbler/yearly_settlement_stats_2023.parquet
```

Use `yearly_settlement_stats_2023.parquet` to join:

```text
settlement_id
electrified_best
population, if needed
```

If population is missing there, use the `population` field from the settlement GPKG.

## Daily Summary CSV

Also write:

```text
Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_cov_yearlykeep_2023-10_daily_summary.csv
```

Required columns:

```text
date
n_settlements
population_sum
mean_coverage
mean_p_lit_sett
median_p_lit_sett
popw_mean_p_lit_sett
popw_share_dark
mean_mean_lit_sett
median_median_lit_sett
mean_mean_rad_sett
median_mean_rad_sett
popw_mean_rad_sett
median_median_rad_sett
```

This CSV is a sanity/debug aid. Ravi can still do his final aggregation from the Parquet.

## Validation Requirements

After the script runs, xhigh should report:

1. Required Parquet exists.
2. Required daily summary CSV exists.
3. No production VNP raster or Parquet was modified.
4. Dates present are exactly `2023-10-02` through `2023-10-31`.
5. `2023-10-01` is absent.
6. All rows have `electrified_best == 1`.
7. All rows have `coverage >= 0.5`.
8. Required columns are present.
9. `p_lit_sett` and `mean_lit_sett` match up to floating-point tolerance.
10. `0 <= p_lit_sett <= 1` where non-missing.
11. `median_lit_sett` is only `0`, `1`, or `NA`.
12. `mean_rad_sett >= 0` and `median_rad_sett >= 0` where non-missing.
13. `dark` equals `p_lit_sett < 0.05`.
14. `settlement_state` only contains `lit`, `dark`, `ambiguous`, or `NA`.
15. The daily summary contains 30 dates.
16. Broad daily `p_lit` shape is not obviously inconsistent with:

```text
blackmarbler/out_vnp46a2_sa_daily/qa_straylight_validation/vj146a2_month_2023-10/vj146a2_month_2023-10_summary.csv
```

The diagnostic summary is whole-scene, while the new Parquet is settlement-only, coverage-filtered, and yearly-keep-filtered. It should not numerically match. Use it only to detect date/order/scale mistakes.

## Non-Goals

Do not:

- redownload VJ data;
- redownload or reprocess VNP data;
- edit `nightlight_downloader/viirs_daily_download.R`;
- overwrite current VNP settlement-day Parquets;
- run Stage 4 annual composite;
- run DOE detection;
- run the full reliability panel;
- create final national regression/plot outputs for Ravi.

## Final Handoff Result

The xhigh implementation should produce:

```text
Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_cov_yearlykeep_2023-10.parquet
Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_cov_yearlykeep_2023-10_daily_summary.csv
```

and return a short validation summary. After Ravi reviews this plan, xhigh can implement it without modifying the production VNP pipeline.
