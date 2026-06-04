---
type: work-report
date: '2026-06-03'
workstream: reliability-assessment
status: non-canonical
---

# Ba-Phalaborwa Pixel Accounting for Slide Methodology

Settlement: Ba-Phalaborwa Local Municipality, `settlement_id = 76690`, population `89,045`.

Source graphic/event: `2023-10-05` strict dark event in [[6-codebases/repos/Reliability-Assessment/Map Data/settlement_day_outputs_vj146a2/pixel_closeups/vj146a2_pixel_closeup_76690_2023-10-05.png]].

Exact extracted CSV: [[validation/closeups/data/ba_phalaborwa_76690_pixel_accounting_2023-10-04_to_06.csv]].

## Method

The settlement-day panel is built by [[6-codebases/repos/Reliability-Assessment/Builder/Others/settlement_day_panel_build_vj146a2_oct2023.R]].

Definitions:

- Pixel lit threshold: `rad > 1`.
- Valid pixel: `valid == 1`.
- Dark valid pixel: `valid == 1` and `rad <= 1`.
- NA / missing pixel: not valid, or no valid radiance.
- Pixel weights are fractional boundary weights from `exactextractr`; boundary pixels can contribute less than one full pixel.
- `coverage = valid_area_m2 / settlement_area_m2`.
- `p_lit_sett = n_lit / n_valid`; invalid pixels lower coverage but do not enter the `p_lit_sett` denominator once the day passes the coverage filter.
- Daily uptime flag: `p_lit_sett >= 0.40`.
- Mostly dark flag: `p_lit_sett < 0.20`.
- Strictly dark flag: `p_lit_sett < 0.05`.

## Slide-Ready Numbers

Settlement polygon area is `49.560 km2`. The raster overlap contains `326` intersecting raster cells, equivalent to `253.186` fully weighted 500 m pixels inside the polygon.

| VJ date | Interpretation | Coverage | p_lit | Weighted lit pixels | Weighted dark pixels | Weighted NA pixels | Lit area km2 | Dark area km2 | NA area km2 | Uptime | Mostly dark | Strictly dark |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2023-10-04 | before, mostly lit but many invalid observations | 0.532 | 0.991 | 133.608 | 1.155 | 118.424 | 26.154 | 0.226 | 23.181 | yes | no | no |
| 2023-10-05 | event, valid observations mostly dark | 0.662 | 0.042 | 7.000 | 160.664 | 85.522 | 1.370 | 31.449 | 16.741 | no | yes | yes |
| 2023-10-06 | after, almost fully observed and mostly lit | 1.000 | 0.998 | 252.671 | 0.516 | 0.000 | 49.459 | 0.101 | 0.000 | yes | no | no |

## Main Slide Message

Day 1 is not counted as dark despite many grey pixels because coverage is still above the `0.50` minimum and almost all valid pixels are lit. Its `p_lit` is `0.991`, not exactly `1.000`.

Day 2 is a strict dark event: coverage is acceptable at `0.662`, but only `7.000` weighted valid pixels are lit while `160.664` weighted valid pixels are dark. This gives `p_lit = 0.0418`, so it passes both mostly-dark and strictly-dark definitions.

Day 3 shows the clean recovery case: full coverage and `p_lit = 0.998`.

## Additional Context

For this settlement in the October filtered panel, there are `16` observed days from `2023-10-04` through `2023-10-27`. Summary over those observed days:

- Mean `p_lit`: `0.934`.
- Median `p_lit`: `0.998`.
- Mean coverage: `0.893`.
- Lit days: `15`.
- Strict dark days: `1`.
- Mostly dark days: `1`.

The visual should describe the method as conservative on observation quality: missing pixels do not create artificial darkness, but they can drop a day if coverage falls below the threshold. For retained days, the status is determined from the valid pixels only.
