# VJ146A2 vs VNP46A2 Eskom MLR Validation: Full-Year 2023 Comparison

**Date:** 2026-06-03
**Status:** Working validation note
**Workstream:** reliability-assessment
**Related logs:** [[5-logs/shared/2026-06-03-1755-vj-full-year-mlr-validation]], [[5-logs/shared/2026-06-03-1637-vj-vnp-mlr-implications-report]]
**Related script:** [[6-codebases/repos/Reliability-Assessment/Builder/vnp46a2_2023_mlr_validation.R]]

## Purpose

This note closes the matched VNP baseline check requested after the full-year VJ Eskom MLR validation. The validation question is whether VJ's stronger full-year MLR calibration is merely an artifact of dropping settlements, or whether it remains better than the existing VNP/blackmarbler baseline under the same Eskom exposure definition.

## Method

The VNP run uses existing `blackmarbler` outputs only:

- daily panel inputs: `Map Data/settlement_day_outputs_rasters_blackmarbler/settlement_day_blackmarbler_cov_2023-01.parquet` through `2023-12`;
- annual keep list: `Map Data/reliability_outputs_blackmarbler/yearly_settlement_stats_2023.parquet`;
- Eskom exposure: `6-codebases/repos/pypsa-earth/data/za_validation/eskom_2023_hourly_clean.csv`;
- date rule: `local_overpass_date = product_date + 1`;
- primary exposure: Eskom hour beginning `01:00`, interpreted as `01:00-02:00 SAST`;
- report-facing sample: annual-keep settlements with `population > 100`;
- outcomes: population-weighted strict darkness (`p_lit_sett < 0.05`) and mostly-darkness (`p_lit_sett < 0.20`).

VNP outputs were written to:

`6-codebases/repos/Reliability-Assessment/Map Data/settlement_day_outputs_rasters_blackmarbler/mlr_validation_2023/`

## Data Completeness

The VNP validation daily panel has `362` product-date rows from `2023-01-01` to `2023-12-31`. There are `361` regression rows with non-missing primary Eskom exposure. The only missing primary-exposure row is product date `2023-12-31`, because its local-overpass date is `2024-01-01`.

## Headline Comparison

| Product | Outcome | Effect, pp per 10 pp shed | p | R2 | N |
|---|---|---:|---:|---:|---:|
| VJ146A2 | Strict dark | 2.72 | 1.00e-54 | 0.492 | 361 |
| VNP46A2 | Strict dark | 1.88 | 6.44e-38 | 0.370 | 361 |
| VJ146A2 | Mostly dark | 4.38 | 1.06e-54 | 0.492 | 361 |
| VNP46A2 | Mostly dark | 3.12 | 3.89e-36 | 0.356 | 361 |

Grounded finding: both products validate positively and significantly against Eskom MLR, but VJ is stronger on the report-facing population-weighted calibration. The VJ strict-dark effect is `0.84` pp larger per 10 pp shed share, and the VJ mostly-dark effect is `1.26` pp larger.

## Large-Settlement Diagnostics

| Product | Outcome, population >=10k | r | R2 |
|---|---|---:|---:|
| VJ146A2 | Strict-dark events | 0.454 | 0.206 |
| VNP46A2 | Strict-dark events | 0.422 | 0.178 |
| VJ146A2 | Mostly-dark events | 0.454 | 0.207 |
| VNP46A2 | Mostly-dark events | 0.440 | 0.194 |
| VJ146A2 | Population-weighted strict dark | 0.466 | 0.217 |
| VNP46A2 | Population-weighted strict dark | 0.406 | 0.165 |
| VJ146A2 | Population-weighted mostly dark | 0.479 | 0.230 |
| VNP46A2 | Population-weighted mostly dark | 0.410 | 0.168 |

The large-settlement diagnostics tell the same story as the Ravi-style calibration: VNP is valid, but VJ has the stronger daily relationship with the Eskom exposure.

## Event Counts

| Product | Population threshold | Strict-dark events | Mostly-dark events |
|---|---:|---:|---:|
| VJ146A2 | >=5,000 | 5,146 | 8,065 |
| VNP46A2 | >=5,000 | 4,012 | 6,540 |
| VJ146A2 | >=10,000 | 2,528 | 4,452 |
| VNP46A2 | >=10,000 | 1,821 | 3,419 |
| VJ146A2 | >=50,000 | 99 | 437 |
| VNP46A2 | >=50,000 | 40 | 257 |
| VJ146A2 | >=100,000 | 3 | 75 |
| VNP46A2 | >=100,000 | 1 | 41 |

Inference: VNP's lower event counts are not simply because VNP keeps fewer annual-electrified settlements; VNP actually keeps more annual settlements than VJ. The lower full-year event count is therefore more consistent with product-level daily signal differences than with annual-keep sample size.

## Robustness

For VNP population-weighted strict darkness, adjacent Eskom windows are stable:

| Window | Effect | p | R2 |
|---|---:|---:|---:|
| 00-01 | 0.077 | 4.56e-15 | 0.158 |
| 01-02 primary | 0.076 | 8.94e-16 | 0.165 |
| 02-03 | 0.077 | 1.59e-15 | 0.162 |
| 01-03 | 0.077 | 9.75e-16 | 0.165 |

The primary date alignment is also stronger than the adjacent-day placebos for VNP population-weighted strict darkness:

| Alignment | Effect | p | R2 |
|---|---:|---:|---:|
| Product date + 1 primary | 0.076 | 8.94e-16 | 0.165 |
| Previous-day placebo | 0.066 | 4.24e-12 | 0.125 |
| Next-day placebo | 0.059 | 8.70e-10 | 0.100 |

## Disagreement-Set Sensitivity

The VNP-only annual-keep group is small in population but highly MLR-sensitive in VNP daily data:

| Sample | Outcome | Effect, pp per 10 pp shed | R2 | Mean pop >100 settlements/day | Mean pop >100 population/day |
|---|---|---:|---:|---:|---:|
| VNP all kept | Strict dark | 1.88 | 0.370 | 3,397 | 34.09m |
| Both VJ and VNP kept | Strict dark | 1.81 | 0.365 | 3,214 | 33.96m |
| VNP only | Strict dark | 19.77 | 0.343 | 183 | 0.13m |
| VNP all kept | Mostly dark | 3.12 | 0.356 | 3,397 | 34.09m |
| Both VJ and VNP kept | Mostly dark | 3.05 | 0.350 | 3,214 | 33.96m |
| VNP only | Mostly dark | 21.77 | 0.306 | 183 | 0.13m |

Interpretation: the VNP-only fringe does contain a real MLR-responsive signal, but it carries too little population weight to drive the national population-weighted validation. This supports retaining VNP-only settlements as a documented sensitivity rather than letting them overturn the VJ primary-path choice.

## Conclusion

The matched VNP baseline strengthens the validation story rather than weakening it. VNP independently validates against Eskom MLR, which supports the overall satellite-darkness method. VJ still performs better on the full-year, population-weighted calibration and on the large-settlement diagnostics under the same Eskom exposure convention.

Practical conclusion: **use VJ146A2 daily + VJ146A4 annual keep as the primary Eskom MLR calibration and reliability-construction path, while retaining VNP46A2/VNP46A4 as the formal baseline sensitivity.**

This remains association evidence around national Eskom MLR exposure. It does not confirm individual local outages or causal attribution for specific settlement-day dark events.
