# VIIRS Daily Download - Stray Light / Residual Artifact Fix Plan

**Date:** 2026-06-02  
**Author:** nylan-ramnauth + Codex plan review  
**Status:** Diagnostic-only plan; do not modify the full NTL pipeline yet  
**Scope:** First create a standalone blackmarbler redownload diagnostic for a few contaminated/control days. Production changes to `nightlight_downloader/viirs_daily_download.R`, `Builder/settlement_day_panel_build.R`, and downstream outputs are explicitly deferred until the diagnostic proves the masking approach works.

---

## Problem Statement

Some 2023 VNP46A2 daily rasters contain broad diagonal bands of spuriously high radiance over South Africa. These bands do not follow settlements, inflate `p_lit`, and can bias rolling-window reliability estimates. The confirmed visual set is 19 days; the automated/GIF screening set is 91 candidate days.

The original draft assumed this was solved by masking `QF_Cloud_Mask` bit 13 as stray light. That is incorrect for the Collection 2 VNP46A2 data downloaded by this pipeline. In Collection 2, `QF_Cloud_Mask` bit 13 is **lunar eclipse**, not stray light. Before changing the full pipeline, the next task is to redownload a small diagnostic set through `blackmarbler::bm_raster()` and test whether a corrected Collection 2 QA mask removes the visual artifacts.

The full-pipeline fix should be designed only after the diagnostic answers whether per-pixel QA is sufficient or whether date-level exclusion is still needed.

---

## Resolved Questions

1. **Is bit 13 of `QF_Cloud_Mask` confirmed as stray light?**

   No. For Collection 2 VNP46A2, `QF_Cloud_Mask` bit 13 is **Lunar Eclipse Detected**. The relevant bit layout is:

   | Bits | Meaning | Keep criterion |
   |---|---|---|
   | 0 | Day/Night | `0` night |
   | 1-3 | Land/Water background | use for diagnostics; do not use as primary SA mask unless water should be removed |
   | 4-5 | Cloud mask quality | diagnostic only unless a stricter cloud-mask-quality threshold is added |
   | 6-7 | Cloud detection/confidence | `0` confident clear, optionally `1` probably clear |
   | 8 | Shadow detected | `0` no shadow |
   | 9 | Cirrus detected | `0` no cloud |
   | 10 | Snow/Ice | `0` no snow/ice |
   | 11 | VI used | diagnostic only |
   | 12 | Aurora detected | `0` no aurora |
   | 13 | Lunar eclipse detected | `0` no lunar eclipse |

   Source: NASA Black Marble User Guide Collection 2.0, Table 6, and LAADS VNP46A2 Collection 2 filespec. The stray-light flag appears in the **VNP46A1 `QF_DNB`** mask as value `16` (`2^4`), not in VNP46A2 `QF_Cloud_Mask`.

2. **Can stray-light-contaminated pixels have `Mandatory_Quality_Flag = 0`?**

   Yes, residual visually obvious artifacts can pass as `Mandatory_Quality_Flag = 0` because Collection 2 VNP46A2 does not expose a separate mandatory-quality "stray light" class. Its `Mandatory_Quality_Flag` values are:

   | Value | Meaning |
   |---|---|
   | 0 | High-quality, main algorithm |
   | 1 | Poor-quality: outlier, potential cloud contamination, or other issues |
   | 2 | Poor-quality: high solar zenith angle 102-108 degrees |
   | 3 | Poor-quality: lunar eclipse |
   | 4 | Poor-quality: aurora |
   | 5 | Poor-quality: glint |
   | 255 | No retrieval / fill |

   Source: NASA Black Marble User Guide Collection 2.0, Table 9; LAADS VNP46A2 Collection 2 filespec. Therefore, if contaminated days pass the current `MANDATORY_QF_MAX <- 0L` filter, the artifact is either unflagged residual contamination or is encoded only in `QF_Cloud_Mask` bits that the main downloader currently ignores.

3. **Does `qa_quality_flag_comparison.R`'s `qf0_only` scenario produce a clean output on contaminated days?**

   Based on code logic, it should **not** be expected to clean residual artifacts that already pass `Mandatory_Quality_Flag = 0`. The diagnostic calls:

   ```r
   blackmarbler::bm_raster(..., quality_flag_rm = c(1L, 2L, 3L, 4L, 5L))
   ```

   The installed `blackmarbler` source maps `quality_flag_rm` to `h5_data$Mandatory_Quality_Flag` for VNP46A2, not to `QF_Cloud_Mask` bits. That makes `qf0_only` equivalent to retaining only Mandatory QF 0 on the radiance layer. The main downloader already applies `qf <= 0`, plus cloud-confidence and snow filters, so it is at least as strict on those dimensions. If `qf0_only` appears clean, investigate a mismatch in ROI, variable, tile cache, or template alignment; do not infer that `quality_flag_rm` is applying the cloud-mask bits.

4. **How many days are affected, and what is the worst month?**

   From `sa_blackmarble_2023_straylight_candidates.csv`:

   - Rows available: 362 daily scenes.
   - `flag_any == True`: 91 days (25.1% of available scenes).
   - Strong flags: 26 days.
   - Moderate flags: 65 days.
   - Visually obvious: 19 days (5.2% of available scenes).
   - Worst month by flagged-day share: November 2023, 10 of 29 available scenes (34.5%).
   - Worst months by raw flagged count: April, October, and November, each with 10 flagged scenes.
   - Worst month by visual severity: October 2023, with 5 visually obvious scenes and the worst single day.
   - Worst single day: 2023-10-20 (`p_lit = 0.3821`, `lit_share_all = 0.2680`).

   The current "maybe" file has 91 dates and matches the `flag_any` count.

5. **Is re-filtering from H5 cache feasible?**

   Yes, if the cache files remain readable and contain the needed SDS layers: `DNB_BRDF-Corrected_NTL`, `Mandatory_Quality_Flag`, `QF_Cloud_Mask`, and `Snow_Flag`. A read-only cache check found all 91 `flag_any` dates have 6 cached Collection 2 H5 tiles each. The H5 filenames use `.002`, and `blackmarbler` downloads from `allData/5200`, so this pipeline is using Collection 2.

   However, the **first diagnostic should not re-filter from the production H5 cache**. It should redownload the selected dates through `blackmarbler::bm_raster()` into an isolated diagnostic cache/output directory. This avoids confusing "the cache can be reprocessed" with "a fresh blackmarbler download plus corrected QA removes the artifact."

   Later fallback if production regeneration is needed and any target date/tile is missing or unreadable:

   - re-download only the affected target dates from NASA LAADS, not the full year;
   - if NASA access is unavailable, use a Stage 2 date-exclusion path in the active settlement-day builder (`Builder/settlement_day_panel_build.R`) or regenerate target daily GeoTIFFs as fully invalid. Do not rely on the legacy `Visualizer/Others/reliability_panel_build.R` date-exclusion hook for final outputs.

6. **After re-filtering, which downstream stages need to be re-run?**

   None during the first diagnostic. The diagnostic must write to a separate folder and must not overwrite production daily GeoTIFFs or parquet outputs.

   Only after the diagnostic proves the chosen mask works should production regeneration be planned. If the eventual production target is all 91 `flag_any` days, those dates span every month, so the active final settlement-day panel builder would need to be rerun for all 2023 months:

   - `Map Data/settlement_day_outputs_rasters_blackmarbler/settlement_day_blackmarbler_nocov_2023-01.parquet` through `..._2023-12.parquet`
   - `Map Data/settlement_day_outputs_rasters_blackmarbler/settlement_month_blackmarbler_nocov_2023-01.gpkg` through `..._2023-12.gpkg`
   - `Map Data/settlement_day_outputs_rasters_blackmarbler/settlement_day_blackmarbler_cov_2023-01.parquet` through `..._2023-12.parquet`
   - any final reliability/electrification outputs that consume the rebuilt `settlement_day_blackmarbler_cov_2023-*.parquet` files.

   Do **not** rerun `Visualizer/settlement_yearly_composite.R` unless the implementation intentionally changes the VNP46A4 yearly electrification calibration; that stage is based on annual composite data, not the daily VNP46A2 GeoTIFFs.

---

## Architecture Context

| Script | Role | Current QA behavior |
|---|---|---|
| `nightlight_downloader/viirs_daily_download.R` | Main downloader; writes daily `rad`, `lit`, `valid` GeoTIFFs | Manual `Mandatory_Quality_Flag <= 0`, `Snow_Flag == 0`, and cloud confidence bits 6-7 <= 1 |
| `nightlight_downloader/Others/qa_quality_flag_comparison.R` | Diagnostic for one test date | Uses `blackmarbler::bm_raster(quality_flag_rm = c(1,2,3,4,5))`; this filters `Mandatory_Quality_Flag`, not cloud-mask bits |
| Future standalone diagnostic script | First implementation target | Must redownload a few selected dates through `blackmarbler::bm_raster()` into isolated diagnostic output; must not edit or call the full-year downloader |
| `Builder/settlement_day_panel_build.R` | Active final settlement-day panel builder; reads daily GeoTIFFs and writes no-coverage monthly settlement-day parquet + monthly GPKG | No built-in contamination-date exclusion; it consumes whatever daily GeoTIFFs Stage 1 leaves in `blackmarbler/out_vnp46a2_sa_daily/` |
| `Builder/settlement_day_coverage_filter.R` | Applies coverage threshold after active panel build | Reads `settlement_day_blackmarbler_nocov_YYYY-MM.parquet` and writes `settlement_day_blackmarbler_cov_YYYY-MM.parquet` |

---

## Root Cause

The current downloader assumes that `Mandatory_Quality_Flag == 0`, cloud confidence <= probably-clear, and `Snow_Flag == 0` are sufficient to remove all non-anthropogenic artifacts. That assumption is not defensible for the observed 2023 diagonal-band contamination.

The old root-cause hypothesis, "missing bit 13 stray-light filter," is false for this Collection 2 VNP46A2 workflow. Bit 13 is lunar eclipse. There is no VNP46A2 `QF_Cloud_Mask` stray-light bit to extract. NASA's product documentation says VNP46A2 is produced from radiances corrected for terrain, snow, atmospheric variation, moonlight, and stray light, but the residual artifacts observed here are not guaranteed to be exposed as a user-maskable stray-light bit.

The likely root cause is therefore one of:

1. residual artifact contamination not represented by VNP46A2 mandatory QA;
2. contamination represented by unfiltered `QF_Cloud_Mask` bits such as shadow, cirrus, aurora, or lunar eclipse;
3. a downstream screening issue where date-level artifacts must be excluded before or inside `Builder/settlement_day_panel_build.R` because per-pixel QA cannot recover trustworthy observations.

Implementation must test the bit distributions on the 19 visually obvious days before assuming that per-pixel QA alone is enough.

---

## Contamination Scale

| Metric | Value |
|---|---:|
| Available 2023 daily scenes in stats CSV | 362 |
| `flag_any == True` candidate days | 91 |
| Strong candidate days | 26 |
| Moderate candidate days | 65 |
| Visually obvious contaminated days | 19 |
| Candidate-day share of available scenes | 25.1% |
| Visually obvious share of available scenes | 5.2% |
| Mean `p_lit` on flagged days | 0.178 |
| Mean `p_lit` on unflagged days | 0.0378 |
| Worst day | 2023-10-20 (`p_lit = 0.3821`) |
| Worst month by flagged-day share | 2023-11 (10/29 = 34.5%) |
| Worst month by obvious-day count | 2023-10 (5 obvious days) |

Estimated loss after fix:

- Exact per-pixel loss cannot be known until the corrected QA mask is applied, because there is no verified VNP46A2 stray-light bit.
- Lower-bound high-confidence exclusion: 19/362 days = 5.2%.
- Conservative full candidate exclusion: 91/362 days = 25.1%.
- Use "mostly NA" as `valid_share_after < 0.20` in validation. Before the fix, 8 scenes already have `valid_share_of_all_pixels < 0.20` and 16 have `< 0.30`; the fix must report any additional scenes crossing those thresholds.

Months already thin by mean valid coverage are February (0.514), December (0.539), January (0.542), November (0.572), and May (0.596). Be especially careful that full-day exclusion does not push these months below reliability-panel support thresholds.

---

## Diagnostic-First Implementation Plan

### Step 1 - Create a standalone blackmarbler redownload diagnostic

Do not edit `nightlight_downloader/viirs_daily_download.R`. Do not edit `Builder/settlement_day_panel_build.R`. Do not overwrite any files in `blackmarbler/out_vnp46a2_sa_daily/` except inside a new diagnostic subdirectory.

Create a new script later, for example:

```text
nightlight_downloader/Others/stray_light_blackmarbler_redownload_diagnostic.R
```

The script should:

1. build the same South Africa-minus-Lesotho ROI used by the full downloader;
2. call `blackmarbler::bm_raster()` for a small date set and for these variables:
   - `DNB_BRDF-Corrected_NTL`
   - `Mandatory_Quality_Flag`
   - `QF_Cloud_Mask`
   - `Snow_Flag`
3. use a separate diagnostic H5 directory, such as:
   - `blackmarbler/out_vnp46a2_sa_daily/qa_straylight_validation/h5_cache_redownload/`
4. force a genuine redownload for the selected dates by starting with an empty diagnostic H5 cache or by deleting only diagnostic-cache files for those dates;
5. write all outputs under:
   - `blackmarbler/out_vnp46a2_sa_daily/qa_straylight_validation/`
6. produce side-by-side rasters/statistics for:
   - current production TIFF
   - fresh blackmarbler mandatory-QF-only output
   - fresh blackmarbler variables with the candidate Collection 2 QA bit mask applied
7. create machine-readable summaries that a notebook can load directly:
   - `qa_straylight_validation/diagnostic_summary.csv`
   - `qa_straylight_validation/diagnostic_bit_shares.csv`
   - per-date comparison rasters or PNG panels for the selected scenarios

Also create a companion notebook later, for example:

```text
nightlight_downloader/Others/stray_light_blackmarbler_redownload_comparison.ipynb
```

The notebook is for human review only. It should not implement production logic. It should load the diagnostic outputs and show side-by-side maps for exactly three review dates:

| Date | Role in notebook | Required side-by-side panels |
|---|---|---|
| 2023-10-20 | Worst single contaminated day by `p_lit` and `lit_share_all` | current production TIFF; blackmarbler redownload QF0-only; blackmarbler redownload candidate C2 mask; difference/current-vs-candidate |
| 2023-02-28 | Visually obvious contaminated day from the primary 19-day set | same four panels |
| 2023-01-29 | Nearby clean control | same four panels |

Each notebook row should use the same color scale across the three radiance panels for that date, and a separate diverging scale for the difference panel. Add a small table under each date with `valid_share`, `p_lit`, `lit_share_all`, and the applied QA-bit shares.

Run on this first-pass date set:

- 2023-10-20: worst single day by `p_lit` and `lit_share_all`
- 2023-02-28: visually obvious, high `p_lit`
- 2023-04-28: visually obvious, high `p_lit`
- 2023-11-06: visually obvious, later-season artifact
- 2023-01-27: maybe-contaminated, included in the user's example and broader candidate set
- 2023-01-29: nearby non-flagged control
- 2023-10-22: nearby control after the 2023-10-20/21 contamination cluster

For each date, compute:

- `Mandatory_Quality_Flag` distribution;
- `QF_Cloud_Mask` bit shares for bits 0, 6-7, 8, 9, 10, 12, and 13;
- production-current valid share and `p_lit` from the existing TIFF;
- blackmarbler-redownload mandatory-QF-only valid share and `p_lit`;
- blackmarbler-redownload candidate Collection 2 mask valid share and `p_lit`;
- before/after rural Northern Cape sentinel-cell `p_lit` and whole-scene `p_lit`;
- visual PNGs or small GeoTIFFs that make the diagonal band easy to inspect.

Do not rely on the current diagnostic's `qf0_only` result as proof of a final fix. It tests only Mandatory QF filtering. Add a production-equivalent diagnostic scenario if needed.

### Step 2 - Verify main downloader and diagnostic equivalence for Mandatory QF only

Confirm these facts in the implementation notes:

- `blackmarbler::bm_raster(quality_flag_rm = c(1,2,3,4,5))` removes `Mandatory_Quality_Flag` values 1-5 for VNP46A2.
- The main downloader's `qf <= MANDATORY_QF_MAX` with `MANDATORY_QF_MAX <- 0L` is equivalent for the mandatory flag.
- The main downloader also applies `cloud_conf <= ALLOW_CLOUD_CONF_MAX` and `snow == 0`; the diagnostic does not.
- All QA rasters are aligned with `method = "near"`; do not use bilinear interpolation on QA layers.

If these checks fail, revise only the standalone diagnostic plan/script first. Do not fix the production downloader until the blackmarbler redownload diagnostic has a passing result.

### Step 3 - Candidate mask to test in the standalone diagnostic

Do **not** implement this old helper:

```r
stray_light_fun <- function(x) {
  bitwAnd(bitwShiftR(as.integer(round(x)), 13L), 1L)
}
```

That would mask lunar-eclipse pixels while falsely labeling them as stray light.

In the standalone diagnostic, test a generic cloud-mask bit helper and explicitly named derived rasters:

```r
qf_bits_fun <- function(x, shift, mask) {
  x <- as.integer(round(x))
  bitwAnd(bitwShiftR(x, shift), mask)
}

cloud_conf_fun <- function(x) qf_bits_fun(x, 6L, 3L)
day_night_fun <- function(x) qf_bits_fun(x, 0L, 1L)
shadow_fun <- function(x) qf_bits_fun(x, 8L, 1L)
cirrus_fun <- function(x) qf_bits_fun(x, 9L, 1L)
snow_ice_cloud_fun <- function(x) qf_bits_fun(x, 10L, 1L)
aurora_fun <- function(x) qf_bits_fun(x, 12L, 1L)
lunar_eclipse_fun <- function(x) qf_bits_fun(x, 13L, 1L)
```

Then compute these after aligning `cloud` to the template:

```r
cloud_conf <- terra::app(cloud, cloud_conf_fun)
day_night <- terra::app(cloud, day_night_fun)
shadow <- terra::app(cloud, shadow_fun)
cirrus <- terra::app(cloud, cirrus_fun)
snow_ice_cloud <- terra::app(cloud, snow_ice_cloud_fun)
aurora <- terra::app(cloud, aurora_fun)
lunar_eclipse <- terra::app(cloud, lunar_eclipse_fun)
```

Test this candidate `valid_logical`:

```r
valid_logical <- (day_night == 0) &
  (cloud_conf <= ALLOW_CLOUD_CONF_MAX) &
  (qf <= MANDATORY_QF_MAX) &
  (snow == 0) &
  (snow_ice_cloud == 0) &
  (shadow == 0) &
  (cirrus == 0) &
  (aurora == 0) &
  (lunar_eclipse == 0)
```

Logging must include daily rates for each newly applied bit:

```r
cat("Shadow share:", round(100 * terra::global(shadow, "mean", na.rm = TRUE)[1, 1], 3), "%\n")
cat("Cirrus share:", round(100 * terra::global(cirrus, "mean", na.rm = TRUE)[1, 1], 3), "%\n")
cat("Aurora share:", round(100 * terra::global(aurora, "mean", na.rm = TRUE)[1, 1], 3), "%\n")
cat("Lunar eclipse share:", round(100 * terra::global(lunar_eclipse, "mean", na.rm = TRUE)[1, 1], 3), "%\n")
```

`ALLOW_CLOUD_CONF_MAX` decision:

- Keep `ALLOW_CLOUD_CONF_MAX <- 1L` for the first corrected run. It allows confident-clear and probably-clear pixels and preserves coverage.
- Do not silently tighten to `0L` as part of this fix. Tightening may reduce already thin monthly coverage and is not targeted to the diagonal artifact.
- Run an A/B diagnostic on the 19 obvious dates and the 91 candidate dates. If diagonal artifacts remain after the corrected bit mask, use date-level exclusion at the active Stage 2 input/panel-build point rather than assuming cloud confidence is the cause.

Whether to apply this to `qa_quality_flag_comparison.R`:

- Do not change `qa_quality_flag_comparison.R` for the first pass.
- Create a separate blackmarbler redownload diagnostic instead.
- Keep `qf0_only` labeled as Mandatory-QF-only; do not rename it as if it tests the full candidate mask.

### Step 4 - Diagnostic target set and decision gate

Target only the small first-pass date set in Step 1. Do **not** regenerate all 91 `flag_any` dates yet.

Justification:

- the immediate question is whether a fresh blackmarbler redownload plus candidate QA mask removes known visual interference;
- a small set is enough to validate the mechanism before touching the full pipeline;
- the 91-day set remains the likely production target only if the diagnostic succeeds.

Pass/fail gate:

1. If the candidate mask removes diagonal artifacts on the visually obvious dates while preserving clean controls, then write a second plan section for production integration.
2. If artifacts remain after the candidate mask, do not modify the full downloader; investigate additional QA fields, product choice, or date-level exclusion.
3. If the redownloaded blackmarbler mandatory-QF-only output is already clean, diagnose why the existing production TIFFs differ before proposing any production patch.

Deferred production paths after the diagnostic passes:

1. integrate the candidate mask into the full downloader;
2. regenerate the chosen production target set, likely all 91 `flag_any` days if the candidate mask works;
3. only then rebuild `Builder/settlement_day_panel_build.R`, `Builder/settlement_day_coverage_filter.R`, and final consumers.

### Step 5 - Validate visually and quantitatively

Visual checks:

- 2023-10-20, 2023-02-28, 2023-04-28, and 2023-11-06 must no longer show broad diagonal bands.
- 2023-01-29 and at least one clean date per thin-coverage month must remain visually unchanged except for newly masked bad-QA pixels.
- The comparison notebook must show side-by-side panels for 2023-10-20, 2023-02-28, and 2023-01-29 before any production code changes are proposed.

Quantitative checks:

| Check | Pass threshold |
|---|---|
| Whole-scene `p_lit` on 2023-10-20 | blackmarbler-redownload candidate mask drops from 0.3821 to `< 0.08` |
| Whole-scene `lit_share_all` on 2023-10-20 | blackmarbler-redownload candidate mask drops from 0.2680 to `< 0.05` |
| 2023-01-27 rural Northern Cape sentinel cells | blackmarbler-redownload candidate mask gives `p_lit < 0.05` |
| First-pass visual obvious dates | 2023-10-20, 2023-02-28, 2023-04-28, and 2023-11-06 have no diagonal band after candidate mask |
| Notebook side-by-side review | Notebook panels for 2023-10-20, 2023-02-28, 2023-01-29 | Candidate-mask panels visibly remove artifacts on contaminated days and preserve the clean control |
| Clean controls | median absolute radiance difference on unflagged controls is 0 except where newly masked QA bits are set |
| Coverage collapse | report all dates with `valid_share_after < 0.20`; no unflagged clean control should newly collapse |
| Monthly support | each month still meets reliability-stage support thresholds, or the affected month is flagged in results |

### Step 6 - Deferred downstream propagation, only after diagnostic acceptance

Do not run these steps during the first diagnostic. After the blackmarbler redownload diagnostic is accepted and the production downloader is patched in a separate task, re-run:

1. `Builder/settlement_day_panel_build.R` for all months 2023-01 through 2023-12.
2. `Builder/settlement_day_coverage_filter.R` for all months 2023-01 through 2023-12.
3. The final reliability/electrification aggregation scripts that currently consume `settlement_day_blackmarbler_cov_2023-*.parquet`.
4. The map/report scripts that consume regenerated final reliability/electrification outputs.

Important: `Builder/settlement_day_panel_build.R` is the final settlement-day panel builder in current use. It writes both:

- `settlement_day_blackmarbler_nocov_YYYY-MM.parquet`
- `settlement_month_blackmarbler_nocov_YYYY-MM.gpkg`

If the final downstream aggregation keeps any cached outputs derived from old `settlement_day_blackmarbler_cov_2023-*.parquet` files, invalidate those caches before comparing metrics. Do not assume the legacy `Visualizer/Others/reliability_panel_build.R` cache controls apply to the final workflow unless that script is explicitly reintroduced.

---

## Risks

| Risk | Mitigation |
|---|---|
| Corrected bit mask does not remove residual diagonal artifacts | Stop before production changes; investigate additional QA/product options or plan date exclusion before/inside `Builder/settlement_day_panel_build.R`. |
| Fix removes too many valid days | Report `valid_share_after` by date and month; track days below 0.20 and 0.30; compare reliability support thresholds before/after. |
| Thin-coverage months lose too much support | February, December, January, November, and May are already thin by mean valid share. Use monthly support diagnostics before accepting final reliability outputs. |
| Diagnostic accidentally reuses production cache | Use a separate diagnostic `h5_cache_redownload/` and start it empty for selected dates. |
| Wrong collection bit layout | Pipeline is Collection 2 (`allData/5200`, H5 `.002`). Do not apply Collection 1 assumptions. In Collection 1 VNP46A2, `Mandatory_Quality_Flag` valid range differs and `QF_Cloud_Mask` does not expose the Collection 2 bit-13 lunar-eclipse field; VNP46A1 `QF_DNB` has stray-light mask value 16. |
| Diagnostic script misleads implementation | Keep `qf0_only` labeled as Mandatory-QF-only; add a separate production-equivalent scenario if needed. |
| Downstream caches hide stale data | Force rebuild or delete stale final outputs derived from `settlement_day_blackmarbler_cov_2023-*.parquet` before comparing metrics. |

---

## Acceptance Criteria

| Criterion | How to check | Pass/fail threshold |
|---|---|---|
| No production files changed | Git/status check and output paths | Only the future standalone diagnostic script and diagnostic outputs are touched during implementation |
| blackmarbler redownload is genuine | Diagnostic H5 cache contents | Selected dates are downloaded into isolated `qa_straylight_validation/h5_cache_redownload/` |
| Notebook created for human review | Open `nightlight_downloader/Others/stray_light_blackmarbler_redownload_comparison.ipynb` | Shows 2023-10-20, 2023-02-28, and 2023-01-29 side by side with current, QF0-only, candidate-mask, and difference panels |
| Bit layout corrected | Inspect diagnostic comments and helper names | No helper or log labels bit 13 as stray light; bit 13 is named `lunar_eclipse` |
| Candidate mask uses relevant C2 bits | Review diagnostic `valid_logical` | Includes Mandatory QF, cloud confidence, Snow_Flag, shadow, cirrus, cloud-mask snow/ice, aurora, lunar eclipse, and night-only |
| Worst day cleaned | Recompute diagnostic stats for 2023-10-20 | `p_lit < 0.08` and `lit_share_all < 0.05` in the candidate-mask output |
| Jan 27 rural sentinel cleaned | Rural Northern Cape sentinel-cell check | `p_lit < 0.05` in the candidate-mask output |
| First-pass obvious dates handled | Plot 2023-10-20, 2023-02-28, 2023-04-28, 2023-11-06 | 4/4 show no diagonal artifact after candidate mask |
| Clean controls preserved | Compare 2023-01-29 and 2023-10-22 | No broad new missing-data collapse; changes occur only where candidate QA bits mask pixels |
| Coverage impact reported | Diagnostic summary CSV | All selected dates report `valid_share_current`, `valid_share_qf0_redownload`, and `valid_share_candidate_mask` |

---

## Files to Touch During First Diagnostic Implementation

| File | Change |
|---|---|
| `nightlight_downloader/Others/stray_light_blackmarbler_redownload_diagnostic.R` | New standalone diagnostic script, created in a later implementation task |
| `nightlight_downloader/Others/stray_light_blackmarbler_redownload_comparison.ipynb` | New side-by-side review notebook for 2023-10-20, 2023-02-28, and 2023-01-29 |
| `blackmarbler/out_vnp46a2_sa_daily/qa_straylight_validation/` | New diagnostic output directory for redownloaded small-date-set outputs |

## Files Not to Touch During First Diagnostic Implementation

| File or path | Reason |
|---|---|
| `nightlight_downloader/viirs_daily_download.R` | Full downloader patch is deferred until the diagnostic proves the mask works |
| `Builder/settlement_day_panel_build.R` | Final panel builder must not change during the diagnostic |
| `Builder/settlement_day_coverage_filter.R` | Downstream rebuild is deferred |
| `blackmarbler/out_vnp46a2_sa_daily/sa_viirs_500m_daily_YYYY-MM-DD.tif` | Production daily GeoTIFFs must not be overwritten |
| `Map Data/settlement_day_outputs_rasters_blackmarbler/*` | Production panels must not be rebuilt during the diagnostic |
| Final reliability/electrification outputs | Rebuild only after a separate production-patch task |

Do not change output band names or parquet schemas unless a separate migration plan is written.

---

## References

- NASA Black Marble User Guide, Collection 2.0: `https://landweb.modaps.eosdis.nasa.gov/data/userguide/BlackMarbleUserGuide_Collection2.0_20241203.pdf`
- LAADS VNP46A2 Collection 2 filespec: `https://ladsweb.modaps.eosdis.nasa.gov/filespec/VIIRS/2/VNP46A2_v2.0.fs`
- NASA Black Marble ATBD v1.0: `https://viirsland.gsfc.nasa.gov/PDF/VIIRS_BlackMarble_ATBD_V1.0.pdf`
- NASA Black Marble product page: `https://viirsland.gsfc.nasa.gov/Products/NASA/BlackMarble.html`
- blackmarbler docs and installed source: `blackmarbler::bm_raster()`, internal `file_to_raster()`
- Chakraborty et al. (2025), "A Global Stocktake on Electricity Access and Gaps From NASA Black Marble Nighttime Lights", Earths Future, DOI `10.1029/2024EF005916`; local web clip: `1-sources/web-clips/2026-06-02 WEB A Global Stocktake on Electricity Access and Gaps From NASA Black Marble Nighttime Lights.md`
