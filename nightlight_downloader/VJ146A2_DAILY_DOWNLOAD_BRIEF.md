# VJ146A2 Daily Download Brief

**Date:** 2026-06-03  
**Script:** `nightlight_downloader/vj146a2_daily_download.R`  
**Default target:** calendar year 2023  
**Status:** isolated VJ146A2 acquisition path; does not replace production VNP46A2 files  

## Purpose

This downloader retrieves daily VJ146A2 Black Marble nighttime-light rasters for South Africa-minus-Lesotho and writes one 3-band GeoTIFF per available day. It is the VJ/NOAA-20 counterpart to the existing VNP46A2 Stage 1 downloader:

```text
nightlight_downloader/viirs_daily_download.R
```

It is intended for VJ146A2 trial runs and settlement-day comparisons. It does not create GIFs and does not write into the production VNP46A2 folder.

## Retrieval Method

The existing VJ diagnostic script:

```text
nightlight_downloader/Others/vj146a2_month_gif_diagnostic.R
```

showed that VJ146A2 can be retrieved directly from NASA LAADS Collection 2 using authenticated H5 downloads. The new downloader keeps that approach:

1. Build the same South Africa-minus-Lesotho ROI used by the existing VIIRS pipeline.
2. Read the local Black Marble tile grid from:

   ```text
   blackmarbler/blackmarbletiles.geojson
   ```

3. Identify the Black Marble tiles intersecting the ROI.
4. For each target date, request the LAADS manifest:

   ```text
   https://ladsweb.modaps.eosdis.nasa.gov/archive/allData/5200/VJ146A2/YYYY/DDD.csv
   ```

5. Download only the H5 files whose tile IDs intersect South Africa-minus-Lesotho.
6. Read these VJ146A2 subdatasets from each H5 file:

   ```text
   DNB_BRDF-Corrected_NTL
   Mandatory_Quality_Flag
   QF_Cloud_Mask
   Snow_Flag
   ```

7. Apply the same fill-value and scale-factor helpers used internally by `blackmarbler`, then merge, crop, and mask to the ROI.

The script caches raw H5 files under:

```text
blackmarbler/out_vj146a2_sa_daily/h5_cache/
```

This makes the run resumable and avoids re-downloading files already present locally.

## Output Contract

Daily GeoTIFFs are written to:

```text
blackmarbler/out_vj146a2_sa_daily/
```

with filename pattern:

```text
vj146a2_sa_500m_daily_YYYY-MM-DD.tif
```

Each GeoTIFF has three bands:

| Band | Name | Meaning |
|---|---|---|
| 1 | `rad` | BRDF-corrected DNB radiance, masked to valid pixels |
| 2 | `lit` | Binary lit class using `rad > 1.0` by default |
| 3 | `valid` | Valid-pixel mask, `1` valid and `0` invalid |

The script also writes a year/run summary CSV:

```text
blackmarbler/out_vj146a2_sa_daily/vj146a2_daily_download_summary_2023.csv
```

## Quality Filter

The VJ valid-pixel mask is intentionally stricter than the current VNP46A2 production downloader because the VJ diagnostic path reads the full `QF_Cloud_Mask` bit layout directly.

A pixel is valid only if all of the following conditions hold:

| Source | Keep criterion | Interpretation |
|---|---|---|
| `QF_Cloud_Mask` bit 0 | `day_night == 0` | nighttime pixel |
| `QF_Cloud_Mask` bits 6-7 | `cloud_conf <= 1` by default | confident clear or probably clear |
| `Mandatory_Quality_Flag` | `qf <= 0` by default | high-quality main-algorithm retrieval |
| `Snow_Flag` | `snow == 0` | no snow flag |
| `QF_Cloud_Mask` bit 10 | `snow_ice_cloud == 0` | no snow/ice cloud-mask flag |
| `QF_Cloud_Mask` bit 8 | `shadow == 0` | no shadow |
| `QF_Cloud_Mask` bit 9 | `cirrus == 0` | no cirrus |
| `QF_Cloud_Mask` bit 12 | `aurora == 0` | no aurora |
| `QF_Cloud_Mask` bit 13 | `lunar_eclipse == 0` | no lunar eclipse |
| all input layers | non-missing | radiance and QA layers present |

Pixels failing any condition receive `valid = 0`. Their `rad` and `lit` values are written as `NA`.

Within valid pixels, the lit class follows the production VNP convention:

```r
lit = 1 if rad > 1.0
lit = 0 if rad <= 1.0
```

The threshold can be overridden with `BM_VJ_LIT_THRESHOLD`, but the default should remain `1.0` for comparability with the current production pipeline and the Ravi handoff.

## Configuration

Default run:

```bash
Rscript nightlight_downloader/vj146a2_daily_download.R
```

Useful environment variables:

| Variable | Default | Meaning |
|---|---:|---|
| `BM_VJ_YEAR` | `2023` | Calendar year to download |
| `BM_VJ_START_DATE` | `YYYY-01-01` | Optional explicit start date |
| `BM_VJ_END_DATE` | next year `YYYY-01-01` | Optional exclusive end date |
| `BM_VJ_LIT_THRESHOLD` | `1.0` | Radiance threshold for `lit` |
| `BM_VJ_ALLOW_CLOUD_CONF_MAX` | `1` | Maximum allowed cloud-confidence class |
| `BM_VJ_MANDATORY_QF_MAX` | `0` | Maximum allowed mandatory-quality flag |
| `BM_VJ_DOWNLOAD_RETRIES` | `3` | Manifest/file download retry count |
| `BM_VJ_OVERWRITE` | `FALSE` | Recompute existing daily GeoTIFFs |
| `BM_VJ_STOP_ON_ERROR` | `TRUE` | Stop on unexpected daily failures |
| `BM_VJ_DRY_RUN` | `FALSE` | Print configuration and exit before auth/download |
| `BM_VJ_KEEP_H5_CACHE` | `TRUE` | Keep raw H5 files after successful daily GeoTIFF creation; set `FALSE` for low-disk full-year runs |

NASA Earthdata credentials must be available as:

```text
EARTHDATA_USER
EARTHDATA_PASS
```

## Important Boundaries

This script does not:

- create GIFs;
- write to `blackmarbler/out_vnp46a2_sa_daily/`;
- alter `nightlight_downloader/viirs_daily_download.R`;
- build settlement-day Parquets;
- run coverage filtering, annual-composite classification, or DOE/post-DOE reliability logic.

Downstream scripts should opt into this VJ output folder explicitly.
