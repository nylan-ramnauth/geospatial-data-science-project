# VJ146A2 Local-Area Uptime After Annual-IQR Excess-Lit Date Exclusion

Date: 2026-06-04
Actor: Codex
Workstream: reliability-assessment
Related codebase: reliability-assessment
Related report: [[validation/eskom_mlr/reports/2026-06-03-recommended-vj-eskom-validation-specification.Rmd]]

## Question

Nylan asked whether excluding the annual upper-Tukey excess-lit dates changes local-area uptime, whether the retained daily panels still cover enough of each area's population, and whether there are still enough observations through the year to calculate local-area uptime.

## Inputs

- Baseline yearly LocalArea reliability: `6-codebases/repos/Reliability-Assessment/Map Data/reliability_outputs_vj146a2/localarea_reliability_yearly_strict_yearlykeep_postdoe.parquet`
- Excess-lit-excluded yearly LocalArea reliability: `6-codebases/repos/Reliability-Assessment/Map Data/reliability_outputs_vj146a2/localarea_reliability_yearly_strict_yearlykeep_postdoe_annual_excess_lit_iqr.parquet`
- Baseline daily state cache: `6-codebases/repos/Reliability-Assessment/Map Data/reliability_outputs_vj146a2/settlement_day_states_strict_yearlykeep.parquet`
- Excess-lit-excluded daily state cache: `6-codebases/repos/Reliability-Assessment/Map Data/reliability_outputs_vj146a2/settlement_day_states_strict_yearlykeep_annual_excess_lit_iqr.parquet`
- Excess-lit date flags: `[[validation/eskom_mlr/data/vj146a2_2023_annual_iqr_excess_lit_day_flags.csv]]`

## Method

The exclusion uses scenario `annual_q3_plus_1p5_iqr`: remove dates whose whole-country excess-lit share is above `Q3_year + 1.5 * IQR_year`, where excess-lit means daily VJ146A2 is lit and the annual VJ146A4 composite is dark among pixels valid in both.

The excluded product dates are:

`2023-02-15`, `2023-03-14`, `2023-03-19`, `2023-03-30`, `2023-04-14`, `2023-04-30`, `2023-05-12`, `2023-06-12`, `2023-08-25`, `2023-08-26`, `2023-09-16`, `2023-10-07`, `2023-10-08`, `2023-10-18`, `2023-10-19`, `2023-10-23`, `2023-11-20`.

For local-area daily coverage, the denominator is the VJ annual-keep/electrified settlement population assigned to each Eskom LocalArea by the same `st_point_on_surface()` to `LOCAL_AREA_GCCA2025.shp` join used in the Stage 5 builder. This is the correct denominator for the reliability metric. A separate column reports what share this analysis population represents of all settlement-GPKG population in the LocalArea.

Because the daily state cache is built after the Stage 3 `coverage >= 0.50` settlement filter, a settlement-day with non-missing `p_lit_sett` already has at least 50% valid pixel coverage inside that settlement. Therefore, the daily `observed_population_share` and `coverage_ge50_population_share` are identical in these outputs.

## Headline Findings

The annual-IQR date exclusion removes 17 dates from the reliability run. It does not threaten the annual LocalArea reliability support:

- LocalAreas kept before exclusion: `33`
- LocalAreas kept after exclusion: `33`
- Minimum post-exclusion `share_population_kept`: `0.9906`
- LocalAreas above the Stage 5 `AREA_COVERAGE_MIN = 0.50` support gate after exclusion: `33 / 33`

Population-weighted mean LocalArea uptime is nearly unchanged nationally:

- Baseline population-weighted uptime: `0.9613`
- After exclusion: `0.9605`
- Difference: `-0.087` percentage points

The direction is mostly downward because removed excess-lit days were artificially bright; removing them slightly lowers measured uptime in most LocalAreas. The largest change is Ladysmith at `-0.526` percentage points. Three LocalAreas increase slightly after exclusion: Mthatha, Pinetown, and Gqeberha.

The daily support picture is more uneven. Nationally, after exclusion:

- Retained calendar dates in scope: `348`
- Dates with any observed national analysis population: `345`
- Dates with at least 50% national analysis population observed: `243`
- Median daily observed national analysis population share: `0.651`
- Mean daily observed national analysis population share: `0.607`

At the LocalArea-day level, some areas have low daily support on many dates, especially Pinetown, Mthatha, Empangeni, Lowveld, and East London. This does not invalidate the annual uptime calculation because the annual builder requires enough settlement-level observations across the year and then a high population-kept share at the LocalArea level. It does mean the outputs are better interpreted as annual reliability estimates from many observed days, not as fully supported daily LocalArea outage panels.

## LocalArea Uptime

| LocalArea      | Uptime baseline | Uptime after exclusion | Delta pp | Kept pop share after |
| -------------- | --------------: | ---------------------: | -------: | -------------------: |
| Bloemfontein   |           0.975 |                  0.974 |   -0.093 |                1.000 |
| Carletonville  |           0.941 |                  0.939 |   -0.211 |                1.000 |
| East London    |           0.951 |                  0.950 |   -0.137 |                0.998 |
| Empangeni      |           0.881 |                  0.879 |   -0.162 |                0.999 |
| Gqeberha       |           0.979 |                  0.979 |   +0.029 |                1.000 |
| Highveld South |           0.931 |                  0.928 |   -0.301 |                0.993 |
| Hydra Central  |           0.896 |                  0.894 |   -0.191 |                1.000 |
| Johannesburg   |           0.946 |                  0.943 |   -0.293 |                1.000 |
| Kalahari       |           0.894 |                  0.892 |   -0.136 |                0.999 |
| Kimberley      |           0.943 |                  0.942 |   -0.082 |                1.000 |
| Ladysmith      |           0.870 |                  0.865 |   -0.526 |                0.999 |
| Lephalale      |           0.906 |                  0.904 |   -0.240 |                1.000 |
| Lowveld        |           0.942 |                  0.940 |   -0.141 |                1.000 |
| Middelburg     |           0.880 |                  0.878 |   -0.234 |                0.991 |
| Midrand        |           1.000 |                  1.000 |   -0.000 |                1.000 |
| Mthatha        |           0.894 |                  0.895 |   +0.135 |                0.997 |
| Namaqualand    |           0.913 |                  0.912 |   -0.098 |                1.000 |
| Newcastle      |           0.940 |                  0.938 |   -0.125 |                0.999 |
| Nigel          |           0.991 |                  0.990 |   -0.047 |                1.000 |
| Outeniqua      |           0.968 |                  0.968 |   -0.049 |                1.000 |
| Peninsula      |           0.998 |                  0.998 |   -0.000 |                1.000 |
| Phalaborwa     |           0.888 |                  0.886 |   -0.196 |                0.999 |
| Pinetown       |           0.979 |                  0.980 |   +0.040 |                0.993 |
| Polokwane      |           0.888 |                  0.885 |   -0.293 |                1.000 |
| Pretoria       |           0.991 |                  0.991 |   -0.038 |                1.000 |
| Rustenburg     |           0.973 |                  0.973 |   -0.097 |                1.000 |
| Vaal           |           0.976 |                  0.975 |   -0.103 |                0.992 |
| Vredendal      |           0.941 |                  0.938 |   -0.237 |                1.000 |
| Warmbad        |           0.939 |                  0.937 |   -0.240 |                1.000 |
| Welkom         |           0.948 |                  0.946 |   -0.213 |                1.000 |
| West Coast     |           0.979 |                  0.979 |   -0.024 |                1.000 |
| West Rand      |           0.994 |                  0.993 |   -0.034 |                1.000 |
| Witbank        |           0.953 |                  0.950 |   -0.255 |                1.000 |

## Lowest Daily Population Support After Exclusion

| LocalArea | Retained dates | Dates any obs | Dates >=50% area pop observed | Mean observed pop share | Median observed pop share | Analysis pop / all settlement pop |
|---|---:|---:|---:|---:|---:|---:|
| Pinetown | 348 | 311 | 146 | 0.406 | 0.127 | 0.863 |
| Mthatha | 348 | 316 | 145 | 0.434 | 0.368 | 0.325 |
| Empangeni | 348 | 318 | 156 | 0.437 | 0.391 | 0.477 |
| Lowveld | 348 | 310 | 153 | 0.438 | 0.317 | 0.964 |
| East London | 348 | 317 | 167 | 0.476 | 0.404 | 0.545 |
| Highveld South | 348 | 332 | 179 | 0.514 | 0.510 | 0.785 |
| Phalaborwa | 348 | 329 | 187 | 0.528 | 0.550 | 0.914 |
| Newcastle | 348 | 297 | 198 | 0.528 | 0.679 | 0.695 |

## Interpretation

For annual LocalArea uptime, the exclusion is safe: all LocalAreas remain above the population-kept support gate, and the minimum post-exclusion kept-population share is roughly 99%.

For daily LocalArea interpretation, support is not uniformly large every day. This is expected from valid-pixel/cloud filtering and missing product dates. The annual uptime metric is therefore defensible as a yearly aggregation, but daily LocalArea panels should keep an observation-support column visible and should not be interpreted as complete daily outage truth when observed population share is low.

The exclusion slightly lowers estimated uptime in most areas, consistent with removing artificially bright days. The magnitude is small relative to the cross-area reliability differences; the lowest-uptime areas remain Ladysmith, Middelburg, Empangeni, Polokwane, Phalaborwa, Kalahari, Hydra Central, Mthatha, and Lephalale.

## Output Artifacts

- `[[validation/pypsa_uptime/scripts/compare_vj146a2_localarea_uptime_excess_lit_exclusion.R]]`
- `[[validation/pypsa_uptime/data/vj146a2_2023_localarea_uptime_excess_lit_exclusion_comparison.csv]]`
- `[[validation/pypsa_uptime/data/vj146a2_2023_localarea_uptime_excess_lit_exclusion_national_summary.csv]]`
- `[[validation/pypsa_uptime/data/vj146a2_2023_localarea_daily_population_coverage_baseline_vs_excluded.csv]]`
- `[[validation/pypsa_uptime/data/vj146a2_2023_localarea_daily_population_coverage_summary_baseline_vs_excluded.csv]]`
- `[[validation/pypsa_uptime/data/vj146a2_2023_localarea_daily_population_coverage_summary_wide_baseline_vs_excluded.csv]]`
- `[[validation/pypsa_uptime/data/vj146a2_2023_national_daily_population_coverage_summary_baseline_vs_excluded.csv]]`
- `[[validation/pypsa_uptime/data/vj146a2_2023_localarea_reliability_support_diagnostics_baseline_vs_excluded.csv]]`
