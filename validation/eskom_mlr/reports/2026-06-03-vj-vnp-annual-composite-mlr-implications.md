# VJ146A4 vs VNP46A4 Annual Composite: Implications for Eskom MLR Validation

**Date:** 2026-06-03
**Status:** Working report
**Workstream:** reliability-assessment
**Related codebase:** `6-codebases/repos/Reliability-Assessment`
**Related logs:** [[5-logs/shared/2026-06-03-1613-vj-prestage2-yearlykeep-prefilter]], [[5-logs/shared/2026-06-03-1632-vj-vnp-annual-composite-comparison]]

## Executive Summary

The 2023 VJ annual composite was successfully built from VJ146A4 directly, with no VNP fallback. It calibrates almost exactly to the 87.7% national electrified-population target, but it retains fewer settlements than the existing VNP46A4 annual composite:

| Metric | VJ146A4 | VNP46A4 | VJ minus VNP |
|---|---:|---:|---:|
| Settlement universe | 76,941 | 76,941 | 0 |
| Support-ok settlements | 76,932 | 76,938 | -6 |
| Calibrated threshold | 0.28 | 0.47 | -0.19 |
| Electrified settlements kept | 13,829 | 15,271 | -1,442 |
| Electrified population | 55,438,995 | 55,456,802 | -17,807 |
| Electrified population share | 0.876899 | 0.877181 | -0.000282 |

The lower VJ settlement count is real, but it is not a processing failure. Both products were evaluated over the full settlement universe. The difference is concentrated in low-population, marginal settlements. That matters for Eskom MLR validation if the validation depends on settlement event counts, but it is much less concerning for population-weighted or area-level validation.

My current recommendation is: **use VJ as the primary candidate for the Eskom MLR validation run, but keep VNP as a formal sensitivity/baseline until the full-year MLR results are compared.** VJ is not automatically "better" for every reliability output; it is better motivated for the MLR validation because prior diagnostics show cleaner daily imagery and stronger date-aligned October MLR signal, while the annual-composite comparison shows only a very small population loss.

## Evidence Base

The comparison used:

- VJ annual stats: `Map Data/reliability_outputs_vj146a2/yearly_settlement_stats_2023.parquet`
- VNP annual stats: `Map Data/reliability_outputs_blackmarbler/yearly_settlement_stats_2023.parquet`
- VJ/VNP comparison script: `Visualizer/vj_vnp_annual_composite_compare.R`
- Generated annual radiance panel: `Map Data/reliability_outputs_vj146a2/figures/vj_vnp_annual_composite_radiance_panel_2023.png`
- Generated keep-list panel: `Map Data/reliability_outputs_vj146a2/figures/vj_vnp_yearlykeep_settlement_panel_2023.png`
- Generated lit-share scatter: `Map Data/reliability_outputs_vj146a2/figures/vj_vnp_yearly_p_lit_scatter_2023.png`
- Summary diagnostics: `Map Data/reliability_outputs_vj146a2/diagnostics/vj_vnp_annual_keep_summary_2023.csv`
- Disagreement diagnostics: `Map Data/reliability_outputs_vj146a2/diagnostics/vj_vnp_annual_keep_disagreement_summary_2023.csv`
- Province-level disagreement: `Map Data/reliability_outputs_vj146a2/diagnostics/vj_vnp_annual_keep_disagreement_by_province_2023.csv`
- Settlement-level disagreement detail: `Map Data/reliability_outputs_vj146a2/diagnostics/vj_vnp_annual_keep_disagreement_detail_2023.csv`

The annual radiance panel shows broadly similar spatial structure across VJ and VNP. The major urban and peri-urban corridors are visible in both products. VJ looks slightly dimmer and sparser in low-intensity pixels, which matches the settlement-level diagnostics.

## What Changed When Moving to VJ?

The annual keep-list disagreement has four groups:

| Group | Settlements | Population | Median population | Mean VNP p_lit | Mean VJ p_lit |
|---|---:|---:|---:|---:|---:|
| Both kept | 13,345 | 55,174,095 | 66 | 0.956 | 0.911 |
| Neither kept | 61,186 | 7,499,944 | 36 | 0.0065 | 0.0020 |
| VJ only | 484 | 264,900 | 72 | 0.295 | 0.479 |
| VNP only | 1,926 | 282,707 | 35 | 0.869 | 0.043 |

The critical group is `VNP only`: these are settlements VNP treats as annual-electrified but VJ does not. There are 1,926 of them, but their total population is only 282,707, or about 0.45% of the national settlement population. The median population is 35. This is why the VJ population target still calibrates correctly while the settlement count falls.

The largest province-level VNP-only counts are:

| Province | VNP-only settlements | VNP-only population | Median population |
|---|---:|---:|---:|
| KwaZulu-Natal | 465 | 56,025 | 38 |
| Gauteng | 317 | 16,093 | 31 |
| Limpopo | 281 | 85,422 | 44 |
| North West | 208 | 29,420 | 32 |
| Mpumalanga | 175 | 26,016 | 33 |

The largest VJ-only population is in KwaZulu-Natal, where VJ keeps 110 settlements that VNP does not, totalling 110,838 people. This is a useful caution: VJ is not simply dropping all marginal settlements; it is reclassifying the margin differently.

## Why This Matters for Eskom MLR Validation

The Eskom MLR validation is not just an annual electrification exercise. It asks whether daily satellite-observed darkness lines up with load reduction in the relevant local overpass window. Fewer kept settlements can affect that validation in three ways:

1. **Lower event count:** if the validation counts dark settlements, VJ will have fewer eligible settlements and may detect fewer events.
2. **Different regional weighting:** if some VNP-only settlements are concentrated in local areas with meaningful MLR variation, excluding them could weaken a local-area validation even if national population loss is tiny.
3. **Cleaner but stricter signal:** VJ may reduce false positives from contaminated VNP dates, but it may also miss low-intensity electrified settlements where VJ radiance is systematically weaker.

This risk is manageable because the excluded VNP-only settlements are low population on average. For report-grade validation, the headline metric should therefore be population-weighted or local-area-weighted, not a raw settlement-count metric.

## Is VJ Better Overall?

**For the Eskom MLR validation, VJ is the better primary candidate right now, but it should not replace VNP without a full-year sensitivity comparison.**

The case for VJ:

- VJ146A4 was available and used directly for the annual keep list; no VNP fallback occurred.
- The VJ annual keep list matches the national electrified-population target slightly more closely than VNP in this run.
- Earlier VJ diagnostics showed cleaner imagery on VNP-contaminated dates.
- The October date-alignment note found stronger MLR alignment when using `local_overpass_date = vj_product_date + 1`; for the strict event metric, the correlation rose from `0.350` on same-date matching to `0.458` on product-date + 1 matching, and the mostly-dark metric rose from `0.335` to `0.468`.
- The annual-composite settlement loss is mostly a small-settlement issue, not a population-target issue.

The case against declaring VJ universally better yet:

- VJ keeps 1,442 fewer settlements than VNP, so raw event-count validation could be less sensitive.
- The VNP-only group has high VNP annual lit share but near-zero VJ annual lit share, which is a product-level disagreement large enough to require review.
- The current comparison is annual-composite based. The final decision should be based on full-year daily MLR validation, because the scientific target is daily load-shedding detection.

## Recommended Decision Rule

Use this rule for the next stage:

1. Treat **VJ146A2 daily + VJ146A4 annual keep** as the primary MLR validation pipeline.
2. Treat the existing **VNP46A2 daily + VNP46A4 annual keep** as the baseline comparison.
3. Report both population-weighted and settlement-count validation metrics.
4. Add one sensitivity using the disagreement set:
   - VJ primary keep only
   - VJ plus VNP-only annual settlements, or at least a diagnostic showing whether VNP-only settlements would change MLR fit
5. Prefer VJ only if full-year validation improves or preserves MLR fit while reducing visually/diagnostically contaminated VNP artifacts.

In plain terms: **VJ is promising and probably better for the MLR validation use case, but the full-year validation should prove that the cleaner daily signal offsets the lower settlement count.**

## Immediate Next Checks

- Run the full-year VJ MLR validation with yearly-keep monthly panels.
- Compare VJ and VNP validation metrics on the same Eskom exposure definition, especially `01:00-02:00 SAST`.
- Produce a local-area table showing where VNP-only settlements are excluded and whether those areas carry high MLR variation.
- Review the largest VNP-only settlements in `vj_vnp_annual_keep_disagreement_detail_2023.csv`; the largest examples include Amahlathi, Ramotshere Moiloa, Makhado, Mutale, Dipaleseng, Nkomazi, and Phokwane local-municipality entries.

## Bottom Line

The lower VJ settlement count should be documented as a real methodological difference, not an error. It is unlikely to damage national population-weighted validation by itself, because the excluded settlements are mostly small. It could affect settlement-count and local-area event detection, so the final MLR validation should include a VNP baseline and a disagreement-set sensitivity. Until that is done, VJ should be described as the preferred candidate for MLR validation, not as a fully accepted replacement for VNP.
