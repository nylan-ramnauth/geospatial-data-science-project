# VJ146A2 Full-Year 2023 Large-Settlement Dark Events Brief

**Date:** 2026-06-03
**Status:** Working full-year event brief; filename retained from the Jan-June draft
**Input event table:** `6-codebases/repos/Reliability-Assessment/Map Data/settlement_day_outputs_vj146a2/mlr_validation_2023/vj146a2_2023_mlr_validation_large_events.csv`
**Work copy:** `validation/closeups/data/vj146a2_full_year_large_dark_events.csv`
**Priority candidate table:** `validation/closeups/data/vj146a2_full_year_diverse_pixel_closeup_candidates.csv`
**Additional vetted plot/GIF candidates:** `validation/closeups/data/vj146a2_full_year_additional_plot_gif_candidates.csv`
**Table builder:** `validation/closeups/scripts/vj146a2_full_year_large_dark_events_brief_tables.R`
**Related reports:** [[validation/eskom_mlr/reports/2026-06-03-vj-full-year-mlr-validation-calibration]], [[validation/closeups/reports/2026-06-03-vj-full-year-additional-plot-gif-candidates]], [[validation/eskom_mlr/reports/2026-06-03-vj-jan-jun-mlr-validation-comparison]]

## Purpose

This brief updates the earlier Jan-June scan to the full available 2023 VJ146A2 yearlykeep daily panel. It identifies settlement-day candidates where a blackout or large darkness event could have happened, grouped by settlement size and by clustered event dates. These are candidates for pixel-level inspection, not confirmed outages.

The full event table has `8,065` mostly-dark settlement-day rows, including `5,146` strict-dark rows, across `572` settlements. Because the full table is too large for a report, the complete working copy is stored at `validation/closeups/data/vj146a2_full_year_large_dark_events.csv`.

## Definitions

These are **settlement-day** events from the VJ146A2 coverage-filtered yearlykeep daily panel joined to Eskom MLR exposure.

- `strict dark`: `p_lit_sett < 0.05`, matching the stricter darkness proxy used in the October validation.
- `mostly dark`: `p_lit_sett < 0.20`, a looser diagnostic threshold for sharp partial drops. Mostly-dark counts are inclusive of strict-dark days.
- `large settlement`: grouped by DRE settlement population thresholds.
- `analysis_median_p_lit`: the median settlement lit share over the full 2023 analysis window, not a monthly median.
- `drop_from_analysis_median`: `analysis_median_p_lit - p_lit_sett`.
- Eskom exposure uses the established alignment `local_overpass_date = vj_product_date + 1` and the `01:00-02:00 SAST` window.

## Coverage Context

The full-year MLR daily panel has `362` VJ product-date rows from `2023-01-01` to `2023-12-31`. Three calendar dates are absent from the validation panel:

- `2023-09-29`: present in Stage 2, but no rows survive `coverage >= 0.50`;
- `2023-09-30`: absent from Stage 2;
- `2023-10-01`: absent from Stage 2.

Daily quality-settlement support varies materially across the year:

| Daily panel days | Min date | Max date | Min daily quality settlements | Median daily quality settlements | Max daily quality settlements |
|:--|:--|:--|:--|:--|:--|
| 362 | 2023-01-01 | 2023-12-31 | 802 | 6,836 | 11,641 |

The event scan should therefore be interpreted as a candidate generator. Pixel-level inspection remains necessary for any settlement-day that will be used as evidence of a specific blackout.

## Event Counts

| Population threshold | Strict-dark events | Strict-dark settlements | Mostly-dark events, inclusive | Mostly-dark settlements | Jul-Dec strict | Jul-Dec mostly |
|:--|--:|--:|--:|--:|--:|--:|
| >= 5,000 | 5,146 | 468 | 8,065 | 572 | 1,958 | 3,128 |
| >= 10,000 | 2,528 | 265 | 4,452 | 348 | 966 | 1,758 |
| >= 50,000 | 99 | 24 | 437 | 47 | 36 | 170 |
| >= 100,000 | 3 | 3 | 75 | 9 | 0 | 27 |

The second half of the year adds many candidate events, including `170` mostly-dark events above 50,000 population. However, all three strict-dark events above 100,000 population remain in the January-June window. For very large settlements, the second-half update mostly adds mostly-dark rather than strict-dark candidates.

## Monthly Event Counts

| Month | Strict-dark events | Mostly-dark events, inclusive | Settlements with any event |
|:--|--:|--:|--:|
| 2023-01 | 576 | 876 | 400 |
| 2023-02 | 546 | 843 | 375 |
| 2023-03 | 428 | 654 | 323 |
| 2023-04 | 903 | 1,456 | 455 |
| 2023-05 | 687 | 1,041 | 428 |
| 2023-06 | 48 | 67 | 55 |
| 2023-07 | 509 | 801 | 390 |
| 2023-08 | 391 | 627 | 346 |
| 2023-09 | 574 | 914 | 394 |
| 2023-10 | 100 | 166 | 149 |
| 2023-11 | 237 | 385 | 256 |
| 2023-12 | 147 | 235 | 166 |

April, May, July, and September are the densest event months in the full-year scan. June, October, November, and December have fewer candidates; this could reflect true lower event incidence, seasonal/nightlight behavior, quality-filter retention, or the interaction between coverage and the yearlykeep settlement universe.

## Strict-Dark Events Above 100,000 Population

Only three settlement-days above 100,000 population cross the strict `p_lit_sett < 0.05` threshold in the full year.

| Date | Local overpass | Settlement ID | Settlement | Province | District | Population | p_lit_sett | Analysis median | Drop | Coverage | Obs days | MLR 01-02 MW | Shed share |
|:--|:--|--:|:--|:--|:--|--:|--:|--:|--:|--:|--:|--:|--:|
| 2023-03-10 | 2023-03-11 | 30250 | Maluti-a-Phofung Local Municipality | Free State | Thabo Mofutsanyane | 387,711 | 0.0483 | 0.8774 | 0.8291 | 0.9032 | 197 | 2,378.5 | 0.0935 |
| 2023-05-19 | 2023-05-20 | 73644 | Polokwane Local Municipality | Limpopo | Capricorn | 106,744 | 0.0493 | 0.9629 | 0.9136 | 1.0000 | 225 | 1,779.6 | 0.0752 |
| 2023-05-25 | 2023-05-26 | 76354 | Bushbuckridge | Mpumalanga | Ehlanzeni | 152,551 | 0.0255 | 0.9141 | 0.8886 | 1.0000 | 159 | 954.1 | 0.0410 |

These remain the highest-priority strict-dark candidates. Bushbuckridge and Polokwane have full valid coverage on the event day, so they are especially useful for distinguishing real pixel darkening from missing-observation artifacts. Bushbuckridge has a lower national shed share than the other two, so it remains useful for separating national Eskom MLR signal from local outage, artifact, or unrelated darkness.

## Mostly-Dark Episodes Above 100,000 Population

Nine settlements above 100,000 population have at least one mostly-dark day in the full-year panel.

| Settlement ID | Settlement | Province | District | Population | Events | Strict | First date | Last date | Min p_lit | Median p_lit on event days | Median coverage | Max shed share |
|--:|:--|:--|:--|--:|--:|--:|:--|:--|--:|--:|--:|--:|
| 30250 | Maluti-a-Phofung Local Municipality | Free State | Thabo Mofutsanyane | 387,711 | 22 | 1 | 2023-01-24 | 2023-11-10 | 0.0483 | 0.0999 | 0.9947 | 0.1496 |
| 73644 | Polokwane Local Municipality | Limpopo | Capricorn | 106,744 | 10 | 1 | 2023-01-23 | 2023-09-07 | 0.0493 | 0.1248 | 1.0000 | 0.1275 |
| 61860 | Thembisile Hani Local Municipality | Mpumalanga | Nkangala | 323,779 | 9 | 0 | 2023-01-23 | 2023-09-17 | 0.0770 | 0.1226 | 1.0000 | 0.1142 |
| 74474 | Polokwane Local Municipality | Limpopo | Capricorn | 198,577 | 8 | 0 | 2023-02-23 | 2023-08-23 | 0.0978 | 0.1500 | 1.0000 | 0.1275 |
| 76219 | Mbombela | Mpumalanga | Ehlanzeni | 187,925 | 8 | 0 | 2023-01-24 | 2023-11-17 | 0.0963 | 0.1356 | 1.0000 | 0.1279 |
| 69888 | Nkomazi | Mpumalanga | Ehlanzeni | 173,115 | 8 | 0 | 2023-01-23 | 2023-10-06 | 0.0845 | 0.1302 | 1.0000 | 0.1279 |
| 71202 | Mogalakwena Local Municipality | Limpopo | Waterberg | 165,309 | 8 | 0 | 2023-01-17 | 2023-07-13 | 0.1208 | 0.1474 | 1.0000 | 0.1133 |
| 76354 | Bushbuckridge | Mpumalanga | Ehlanzeni | 152,551 | 1 | 1 | 2023-05-25 | 2023-05-25 | 0.0255 | 0.0255 | 1.0000 | 0.0410 |
| 76553 | Acornhoek | Mpumalanga | Ehlanzeni | 124,432 | 1 | 0 | 2023-05-16 | 2023-05-16 | 0.0971 | 0.0971 | 1.0000 | 0.0877 |

The full-year recurrent large-settlement candidates remain concentrated in Maluti-a-Phofung, Polokwane, Thembisile Hani, Mbombela, Nkomazi, and Mogalakwena. The new July-December months extend the date range for several of these settlements but do not introduce new strict-dark events above 100,000 population.

## Recurring Strict-Dark Settlements Above 50,000 Population

This table highlights the top recurring strict-dark candidates above 50,000 population.

| Settlement ID | Settlement | Province | District | Population | Strict events | First date | Last date | Min p_lit | Median coverage |
|--:|:--|:--|:--|--:|--:|:--|:--|--:|--:|
| 70733 | Elias Motsoaledi Local Municipality | Limpopo | Sekhukhune | 52,367 | 18 | 2023-01-20 | 2023-08-23 | 0.0143 | 1.0000 |
| 61851 | Thembisile Hani Local Municipality | Mpumalanga | Nkangala | 56,096 | 13 | 2023-01-18 | 2023-11-17 | 0.0000 | 1.0000 |
| 75003 | Greater Letaba Local Municipality | Limpopo | Mopani | 89,817 | 10 | 2023-03-17 | 2023-12-13 | 0.0225 | 1.0000 |
| 58972 | Mkhondo | Mpumalanga | Gert Sibande | 70,521 | 9 | 2023-01-18 | 2023-09-14 | 0.0000 | 1.0000 |
| 51558 | Merafong City Local Municipality | Gauteng | West Rand | 54,228 | 8 | 2023-01-22 | 2023-12-07 | 0.0000 | 1.0000 |
| 27703 | Msunduzi Local Municipality | KwaZulu-Natal | Umgungundlovu | 54,048 | 8 | 2023-04-18 | 2023-12-11 | 0.0000 | 0.9909 |
| 57346 | Abaqulusi Local Municipality | KwaZulu-Natal | Zululand | 66,588 | 6 | 2023-02-23 | 2023-09-10 | 0.0000 | 1.0000 |
| 74732 | Molemole Local Municipality | Limpopo | Capricorn | 51,249 | 5 | 2023-04-28 | 2023-09-14 | 0.0132 | 1.0000 |
| 49044 | Moqhaka Local Municipality | Free State | Fezile Dabi | 80,800 | 3 | 2023-04-27 | 2023-08-08 | 0.0290 | 1.0000 |
| 75613 | Makhado Local Municipality | Limpopo | Vhembe | 77,720 | 3 | 2023-05-25 | 2023-08-13 | 0.0001 | 0.9973 |
| 55160 | Moses Kotane Local Municipality | North West | Bojanala | 56,179 | 2 | 2023-01-17 | 2023-04-17 | 0.0249 | 0.9890 |
| 33852 | Emnambithi/Ladysmith Local Municipality | KwaZulu-Natal | Uthukela | 53,793 | 2 | 2023-04-17 | 2023-05-19 | 0.0031 | 1.0000 |
| 30250 | Maluti-a-Phofung Local Municipality | Free State | Thabo Mofutsanyane | 387,711 | 1 | 2023-03-10 | 2023-03-10 | 0.0483 | 0.9032 |
| 76354 | Bushbuckridge | Mpumalanga | Ehlanzeni | 152,551 | 1 | 2023-05-25 | 2023-05-25 | 0.0255 | 1.0000 |
| 73644 | Polokwane Local Municipality | Limpopo | Capricorn | 106,744 | 1 | 2023-05-19 | 2023-05-19 | 0.0493 | 1.0000 |
| 62231 | Steve Tshwete | Mpumalanga | Nkangala | 96,376 | 1 | 2023-07-12 | 2023-07-12 | 0.0339 | 1.0000 |
| 48709 | Klerksdorp | North West | Dr Kenneth Kaunda | 92,082 | 1 | 2023-02-18 | 2023-02-18 | 0.0299 | 0.9019 |
| 76690 | Ba-Phalaborwa Local Municipality | Limpopo | Mopani | 89,045 | 1 | 2023-02-23 | 2023-02-23 | 0.0455 | 1.0000 |
| 53921 | Madibeng Local Municipality | North West | Bojanala | 80,350 | 1 | 2023-07-11 | 2023-07-11 | 0.0281 | 1.0000 |
| 70382 | Thembisile Hani Local Municipality | Mpumalanga | Nkangala | 73,668 | 1 | 2023-02-22 | 2023-02-22 | 0.0471 | 1.0000 |

The repeated strict-dark records are useful for checking whether some settlements are systematically unstable in VJ, whether there are recurring local outage patterns, or whether the settlement geometry/coverage creates repeated false positives. Elias Motsoaledi, Thembisile Hani, Greater Letaba, Mkhondo, Merafong City, and Msunduzi should be treated as recurring priority cases for pixel-level review.

## Clustered Event Dates Above 50,000 Population

These are the product dates with the most mostly-dark events among settlements above 50,000 population.

| Date | Local overpass | Mostly events >=50k | Strict events >=50k | Affected population sum | Largest settlement pop. | Mean shed share |
|:--|:--|--:|--:|--:|--:|--:|
| 2023-02-23 | 2023-02-24 | 15 | 4 | 1,311,600 | 198,577 | 0.1275 |
| 2023-09-14 | 2023-09-15 | 14 | 3 | 1,358,784 | 387,711 | 0.1102 |
| 2023-07-12 | 2023-07-13 | 13 | 3 | 1,314,728 | 323,779 | 0.1142 |
| 2023-04-17 | 2023-04-18 | 12 | 5 | 1,079,778 | 187,925 | 0.1078 |
| 2023-05-16 | 2023-05-17 | 11 | 3 | 881,987 | 124,432 | 0.0877 |
| 2023-04-19 | 2023-04-20 | 11 | 1 | 802,695 | 92,690 | 0.1085 |
| 2023-07-13 | 2023-07-14 | 10 | 0 | 1,318,324 | 387,711 | 0.0959 |
| 2023-02-24 | 2023-02-25 | 10 | 0 | 1,192,604 | 387,711 | 0.1279 |
| 2023-04-18 | 2023-04-19 | 10 | 4 | 810,888 | 165,309 | 0.1133 |
| 2023-07-11 | 2023-07-12 | 9 | 3 | 1,084,097 | 387,711 | 0.1056 |
| 2023-05-24 | 2023-05-25 | 8 | 0 | 1,030,049 | 387,711 | 0.0611 |
| 2023-05-25 | 2023-05-26 | 8 | 2 | 947,007 | 198,577 | 0.0410 |
| 2023-09-13 | 2023-09-14 | 8 | 3 | 879,031 | 387,711 | 0.1065 |
| 2023-09-08 | 2023-09-09 | 8 | 1 | 848,174 | 323,779 | 0.1019 |
| 2023-04-16 | 2023-04-17 | 8 | 0 | 653,890 | 173,115 | 0.1149 |
| 2023-05-19 | 2023-05-20 | 7 | 2 | 858,505 | 323,779 | 0.0752 |
| 2023-01-23 | 2023-01-24 | 7 | 0 | 843,066 | 323,779 | 0.0831 |
| 2023-07-22 | 2023-07-23 | 7 | 1 | 658,008 | 198,577 | 0.0596 |
| 2023-08-23 | 2023-08-24 | 7 | 2 | 625,334 | 198,577 | 0.0564 |
| 2023-04-23 | 2023-04-24 | 7 | 1 | 506,540 | 106,744 | 0.0702 |

The strongest clusters now include `2023-09-14`, `2023-07-12`, `2023-07-13`, and `2023-07-11`, which were absent from the Jan-June brief. These should be prioritized for multi-settlement pixel panels because several large settlements darken on the same product dates and the Eskom shed share is also high.

## Diversified Priority Events For Pixel-Level Close-Up Notebook

The automated priority score favors high population, large drop from the full-year median, high coverage, strict darkness, and Eskom shed share. The table below keeps only one candidate per settlement and intentionally includes both first-half and second-half events.

| Date | Local overpass | Settlement ID | Settlement | Province | District | Population | Class | p_lit | Median | Drop | Coverage | Obs days | MLR MW | Shed share |
|:--|:--|--:|:--|:--|:--|--:|:--|--:|--:|--:|--:|--:|--:|--:|
| 2023-07-12 | 2023-07-13 | 62231 | Steve Tshwete | Mpumalanga | Nkangala | 96,376 | strict_dark_p_lit_lt_0.05 | 0.0339 | 1.0000 | 0.9661 | 1.0000 | 239 | 2,835.4 | 0.1142 |
| 2023-02-23 | 2023-02-24 | 76690 | Ba-Phalaborwa Local Municipality | Limpopo | Mopani | 89,045 | strict_dark_p_lit_lt_0.05 | 0.0455 | 0.9865 | 0.9410 | 1.0000 | 163 | 3,322.0 | 0.1275 |
| 2023-07-11 | 2023-07-12 | 53921 | Madibeng Local Municipality | North West | Bojanala | 80,350 | strict_dark_p_lit_lt_0.05 | 0.0281 | 0.9985 | 0.9704 | 1.0000 | 222 | 2,641.7 | 0.1056 |
| 2023-09-13 | 2023-09-14 | 5832 | KwaNobuhle | Eastern Cape | Nelson Mandela Bay | 58,291 | strict_dark_p_lit_lt_0.05 | 0.0000 | 0.9918 | 0.9918 | 1.0000 | 203 | 2,628.2 | 0.1065 |
| 2023-02-22 | 2023-02-23 | 70382 | Thembisile Hani Local Municipality | Mpumalanga | Nkangala | 73,668 | strict_dark_p_lit_lt_0.05 | 0.0471 | 0.9831 | 0.9359 | 1.0000 | 244 | 3,379.5 | 0.1301 |
| 2023-09-14 | 2023-09-15 | 74732 | Molemole Local Municipality | Limpopo | Capricorn | 51,249 | strict_dark_p_lit_lt_0.05 | 0.0132 | 0.9615 | 0.9483 | 1.0000 | 216 | 2,774.0 | 0.1102 |
| 2023-05-19 | 2023-05-20 | 73644 | Polokwane Local Municipality | Limpopo | Capricorn | 106,744 | strict_dark_p_lit_lt_0.05 | 0.0493 | 0.9629 | 0.9136 | 1.0000 | 225 | 1,779.6 | 0.0752 |
| 2023-07-11 | 2023-07-12 | 75613 | Makhado Local Municipality | Limpopo | Vhembe | 77,720 | strict_dark_p_lit_lt_0.05 | 0.0001 | 0.9188 | 0.9187 | 0.9888 | 185 | 2,641.7 | 0.1056 |
| 2023-05-25 | 2023-05-26 | 76354 | Bushbuckridge | Mpumalanga | Ehlanzeni | 152,551 | strict_dark_p_lit_lt_0.05 | 0.0255 | 0.9141 | 0.8886 | 1.0000 | 159 | 954.1 | 0.0410 |
| 2023-03-10 | 2023-03-11 | 30250 | Maluti-a-Phofung Local Municipality | Free State | Thabo Mofutsanyane | 387,711 | strict_dark_p_lit_lt_0.05 | 0.0483 | 0.8774 | 0.8291 | 0.9032 | 197 | 2,378.5 | 0.0935 |
| 2023-09-08 | 2023-09-09 | 61860 | Thembisile Hani Local Municipality | Mpumalanga | Nkangala | 323,779 | mostly_dark_p_lit_lt_0.20 | 0.0979 | 0.9706 | 0.8727 | 1.0000 | 239 | 2,442.9 | 0.1019 |
| 2023-04-17 | 2023-04-18 | 69888 | Nkomazi | Mpumalanga | Ehlanzeni | 173,115 | mostly_dark_p_lit_lt_0.20 | 0.0845 | 0.9923 | 0.9078 | 1.0000 | 168 | 2,633.6 | 0.1078 |
| 2023-04-17 | 2023-04-18 | 76219 | Mbombela | Mpumalanga | Ehlanzeni | 187,925 | mostly_dark_p_lit_lt_0.20 | 0.1014 | 0.9868 | 0.8854 | 1.0000 | 148 | 2,633.6 | 0.1078 |
| 2023-02-23 | 2023-02-24 | 74474 | Polokwane Local Municipality | Limpopo | Capricorn | 198,577 | mostly_dark_p_lit_lt_0.20 | 0.0978 | 0.9455 | 0.8477 | 1.0000 | 229 | 3,322.0 | 0.1275 |
| 2023-07-11 | 2023-07-12 | 71202 | Mogalakwena Local Municipality | Limpopo | Waterberg | 165,309 | mostly_dark_p_lit_lt_0.20 | 0.1280 | 0.9530 | 0.8250 | 1.0000 | 243 | 2,641.7 | 0.1056 |

Recommended first full-year notebook targets:

1. **Maluti-a-Phofung, 2023-03-10**: largest strict-dark candidate; high MLR and acceptable coverage.
2. **Polokwane, 2023-05-19**: strict-dark above 100,000 population with full coverage and a large drop from a high median.
3. **Bushbuckridge, 2023-05-25**: strict-dark above 100,000 population with full coverage but relatively low national shed share; useful for artifact/local-outage checking.
4. **Steve Tshwete, 2023-07-12**: second-half strict-dark candidate with full coverage, high baseline, and high Eskom shed share.
5. **Thembisile Hani, 2023-09-08 or 2023-02-22**: combines a very large mostly-dark event and a separate recurring strict-dark settlement record.
6. **KwaNobuhle, 2023-09-13**: Eastern Cape second-half strict-dark event with full coverage and a very large drop from baseline.
7. **Mogalakwena, 2023-07-11**: second-half mostly-dark candidate in a high-event July cluster.

## Additional Vetted Plot/GIF Candidates

A stricter follow-up screen joined every full-year large-event row back to the underlying `cov_yearlykeep` monthly panels and required actual previous-day and next-day settlement rows. The screen is documented in [[validation/closeups/reports/2026-06-03-vj-full-year-additional-plot-gif-candidates]].

The screen uses:

- minimum coverage `>= 0.80` on the previous day, event day, and next day;
- at least `180` retained full-year observations for the settlement;
- a separate classification for sharp before/event/after dips versus sustained dark spells that are better suited to GIFs.

Best additional large-settlement notebook candidates include Ga-Segonyana on `2023-04-24`, Matjhabeng on `2023-09-13`, Moqhaka on `2023-05-22`, Merafong City on `2023-07-12`, Westonaria on `2023-01-22`, Moses Kotane on `2023-04-17`, Thembisile Hani on `2023-04-21`, Emalahleni on `2023-07-12`, Albert Luthuli on `2023-10-06`, Bela Bela on `2023-01-22`, Dr JS Moroka on `2023-01-18`, and Elias Motsoaledi on `2023-07-12`.

Best additional large-settlement GIF candidates include Ga-Segonyana on `2023-03-06`, Klerksdorp on `2023-09-14`, Matjhabeng on `2023-04-26`, Merafong City on `2023-02-22`, Westonaria on `2023-02-22`, Thembisile Hani on `2023-04-18`, Albert Luthuli on `2023-12-02`, Dr JS Moroka on `2023-01-26`, and Elias Motsoaledi on `2023-04-21`.

## Next Notebook Requirements

For each selected event, make a close-up panel around the event date:

1. Day before the event.
2. Event day.
3. Day after the event.

Each panel should:

- show raw VJ146A2 500 m pixels inside and around the settlement, not only settlement aggregates;
- use the `rad` band as the primary image;
- show invalid / missing pixels distinctly;
- use the same radiance color scale across the three days for that settlement;
- overlay the settlement polygon boundary;
- include `p_lit_sett`, `coverage`, `mean_rad_sett`, `median_rad_sett`, `MLR 01:00-02:00`, and `shed_share_1_2am_primary`;
- optionally include a binary `rad > 1.0` panel if the radiance image alone is ambiguous.

## Interpretation Caveat

These events are candidates, not confirmations. A low settlement `p_lit_sett` can come from:

1. most valid pixels actually becoming dark;
2. valid coverage disappearing over the normally illuminated part of the settlement;
3. cloud, stray-light, view-angle, or other QA artifacts;
4. local outages not captured by national Eskom MLR;
5. geometry or settlement-boundary issues.

The strongest full-year use of this brief is to select representative pixel-level inspections, not to count confirmed blackouts. The event-count relationship with Eskom MLR is validated in [[validation/eskom_mlr/reports/2026-06-03-vj-full-year-mlr-validation-calibration]], but individual settlement-day events still need visual and QA checks before being used as case-study evidence.
