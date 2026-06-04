# VJ146A2 Public Triangulation Implementation Plan

Date: 2026-06-04
Actor: Codex
Workstream: reliability-assessment / PyPSA integration
Purpose: standalone plan for implementing public-data triangulation of the VJ146A2 LocalArea uptime layer
Related reports: [[validation/limitations_and_triangulation/reports/2026-06-04-vj146a2-localarea-uptime-public-benchmark-audit]], [[validation/pypsa_uptime/reports/2026-06-04-vj146a2-pypsa-demand-weighted-uptime]], [[validation/eskom_mlr/reports/2026-06-03-recommended-vj-eskom-validation-specification.Rmd]]

## Objective

Implement public-data triangulation checks for the VJ146A2 PyPSA-facing LocalArea not-up / availability layer.

The checks should answer:

```text
Do public schedule and survey data produce spatial or temporal patterns that are directionally consistent with the VJ146A2 LocalArea not-up proxy?
```

They should not claim:

```text
The public data directly validates LocalArea ENS or metered uptime.
```

No public source identified so far provides 2023 metered Eskom LocalArea annual uptime or ENS. The correct framing is triangulation / benchmarking.

## Validated VJ Metric To Use

Use the daily-first, demand-weighted `p_lit < 0.40` metric:

```text
settlement_not_up_040_i,t = 1[p_lit_i,t < 0.40]

localarea_not_up_040_a,t =
  weighted_mean_i(settlement_not_up_040_i,t, settlement_demand_i)

localarea_not_up_040_a =
  mean_t(localarea_not_up_040_a,t)

localarea_availability_040_a =
  1 - localarea_not_up_040_a
```

Main annual output:

- [[validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_demand_weighted_uptime.csv]]

Useful daily audit output:

- [[validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_daily_demand_weighted_uptime_audit.csv]]

The implementation may need settlement-day and settlement geometry inputs from the reliability-assessment pipeline, not only LocalArea annual outputs.

## Implementation Modules

Implement three modules:

1. Cape Town public schedule pilot.
2. Weak-area schedule pilot, with uMhlathuze/Empangeni first and Steve Tshwete/Middelburg as fallback.
3. Stats SA GHS 2023 and GCRO QoL7 plausibility rankings.

Each module should emit:

- a machine-readable intermediate CSV;
- a short diagnostic report section or standalone markdown;
- a summary table that clearly labels the evidence as triangulation.

## Core Files To Read First

Read these local files before implementation:

- [[validation/limitations_and_triangulation/reports/2026-06-04-vj146a2-localarea-uptime-public-benchmark-audit]]
- [[validation/pypsa_uptime/reports/2026-06-04-vj146a2-pypsa-demand-weighted-uptime]]
- [[validation/pypsa_uptime/reports/2026-06-04-vj146a2-pypsa-uptime-target-alignment-note]]
- [[validation/pypsa_uptime/scripts/build_vj146a2_pypsa_localarea_demand_weighted_uptime.R]]
- [[validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_demand_weighted_uptime.csv]]
- [[validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_daily_demand_weighted_uptime_audit.csv]]

Likely upstream data needed for settlement-level joins:

- [[6-codebases/repos/Reliability-Assessment/Map Data/reliability_outputs_vj146a2/settlement_day_states_strict_yearlykeep_annual_excess_lit_iqr.parquet]]
- [[6-codebases/repos/Reliability-Assessment/Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_simplified_full_col.gpkg]]
- [[6-codebases/repos/Reliability-Assessment/Map Data/Local Area/LOCAL_AREA_GCCA2025.shp]]

## Module 1: Cape Town Schedule Pilot

### Purpose

Test whether settlements in City of Cape Town load-shedding areas scheduled off during the VIIRS overpass window are more likely to appear `not_up_040` in VJ146A2.

This is the cleanest quantitative schedule triangulation pilot because Cape Town has an official schedule-history dataset and a public GIS layer for load-shedding blocks.

### Public Sources

Use these sources:

- City load-shedding page: https://www.capetown.gov.za/loadshedding/Pages/default.aspx
- Official ArcGIS schedule-history item: https://www.arcgis.com/home/item.html?id=ea0d0e97d123475abf34073bc719a988
- Backup ArcGIS schedule-history item: https://www.arcgis.com/home/item.html?id=b8889768c4454b899cf9db3fa03ee165
- City load-shedding block GIS layer: https://citymaps.capetown.gov.za/agsext/rest/services/Theme_Based/ODP_SPLIT_7/FeatureServer/13
- All-areas schedule/map PDF: https://www.capetown.gov.za/Loadshedding1/loadshedding/Load_Shedding_All_Areas_Schedule_and_Map.pdf

The primary schedule-history item is reported to contain:

```text
Load_shedding_data_per_area_CCT_January__2020_to__April_2025.csv
fields: Date, Time, Stage, Circuit, Minutes
2023 rows found in exploratory audit: 10,024
2023 date range found: 2023-01-01 to 2023-12-14
spatial unit: Circuit / Area 1-16
```

### Required Local Inputs

Use settlement-level VJ daily states, not only annual LocalArea outputs:

```text
settlement_id
product_date
p_lit_sett
not_up_040 = 1[p_lit_sett < 0.40]
demand weight
settlement centroid geometry
LocalArea assignment
```

Use the same cleaned daily universe as the uptime construction:

- post-DOE eligible settlements;
- non-missing `p_lit_sett`;
- annual-IQR excess-lit dates removed;
- coverage already enforced upstream;
- LocalArea/day demand support gate where applicable.

### Method

1. Download or read the City ArcGIS schedule CSV.
2. Filter to 2023 rows.
3. Parse `Date`, `Time`, `Minutes`, `Stage`, and `Circuit`.
4. Convert each row into an interval in SAST:

```text
scheduled_start_sast
scheduled_end_sast = scheduled_start_sast + Minutes
```

5. Create a schedule-overpass flag for the VJ window:

```text
scheduled_off_1_2am = 1[scheduled interval overlaps 01:00-02:00 SAST]
```

6. Confirm date alignment. The VJ validation uses product dates tied to the VIIRS observation night. Use the same convention as the main validation report. If the codebase uses `product_date + 1` for local overpass calendar date, implement that explicitly and document it.
7. Download/query the City load-shedding block GIS layer.
8. Spatial-join settlement centroids to Cape Town `BlockID` / area polygons.
9. Join settlements to scheduled exposure by:

```text
settlement_id -> BlockID/Circuit
date -> scheduled date
```

10. Compare:

```text
Pr(not_up_040 = 1 | scheduled_off_1_2am = 1)
Pr(not_up_040 = 1 | scheduled_off_1_2am = 0)
```

11. Estimate simple triangulation models:

```text
not_up_040_i,t ~ scheduled_off_1_2am_i,t
```

and a demand-weighted daily version:

```text
daily_vj_not_up_040_t =
  weighted_mean_i(not_up_040_i,t, demand_i)

daily_scheduled_exposure_t =
  weighted_mean_i(scheduled_off_1_2am_i,t, demand_i)

daily_vj_not_up_040_t ~ daily_scheduled_exposure_t
```

12. Report correlations and rank checks, not calibrated outage levels.

### Expected Outputs

Create outputs such as:

```text
validation/data_manifest.md#external-public-benchmark-inputs (vj146a2_2023_cape_town_schedule_overpass_exposure.csv)
validation/data_manifest.md#external-public-benchmark-inputs (vj146a2_2023_cape_town_settlement_schedule_vj_join.csv)
validation/data_manifest.md#external-public-benchmark-inputs
```

Suggested columns for settlement schedule/VJ join:

```text
settlement_id
settlement_name
product_date
overpass_date_sast
p_lit_sett
not_up_040
demand_weight
localarea_name
city_loadshedding_block
scheduled_off_1_2am
scheduled_stage
scheduled_minutes_overlap_1_2am
```

### Caveats

- This checks scheduled exposure, not realized outage.
- The City can shield customers by one or more stages relative to Eskom.
- Area boundaries can change; the GIS layer is current/live and may not exactly match 2023.
- Cape Town Area 17-23 / Eskom-supplied zones should be treated separately or excluded in the first pass.
- Backup generation and bright urban lighting can suppress observed VJ darkness even when scheduled off.

## Module 2: Weak-Area Schedule Pilot

### Purpose

Test whether a weak VJ LocalArea can be benchmarked against local public schedule data.

Start with uMhlathuze/Empangeni because Empangeni is one of the weakest VJ146A2 LocalAreas:

```text
availability_040_demandw = 86.27%
not_up_040_share_demandw = 13.73%
demand kept = 99.32%
gated dates = 172
```

If uMhlathuze cannot support a defensible join, switch to Steve Tshwete/Middelburg as the cleaner fallback.

### Public Sources

uMhlathuze / Empangeni:

- uMhlathuze load-shedding page: https://www.umhlathuze.gov.za/index.php/load-shedding
- uMhlathuze schedule PDF identified in audit: https://www.umhlathuze.gov.za/images/Load_shedding_schedule_May_2024.pdf
- Eskom municipal schedule page: https://loadshedding.eskom.co.za/LoadShedding/loadsheddingmunic

Steve Tshwete / Middelburg fallback:

- Steve Tshwete load-shedding page: https://stlm.gov.za/load-shedding/
- Steve Tshwete schedule PDF identified in audit: https://stlm.gov.za/loadshedding/Load%20shedding%20schedule%202019.pdf

Optional fallback / marked non-official:

- ESP / EskomSePush: https://sepush.co.za/loadshedding

### Empangeni Findings To Verify

The exploratory audit found:

- uMhlathuze schedule PDF has last revision date `07 December 2022`;
- public/local evidence suggests it was active into 2023 until further notice;
- Empangeni appears in schedule blocks:
  - `Emp CBD` and `Sanlam Centre` under Block 13;
  - `Empangeni`, `Braeburn`, `Kuleka`, rail/SAR areas under Block 14;
  - other Empangeni-adjacent areas in Blocks 5-7;
- no official GIS block polygons were found;
- the LocalArea likely mixes municipal-fed and Eskom-direct areas;
- standard municipal slots visible in the audited PDF may not cleanly cover `01:00-02:00` SAST.

### Method

1. Download official uMhlathuze PDF and extract block/suburb table.
2. Verify whether the Dec. 2022 revision was active during 2023 using official page metadata, archived official pages, or clearly marked local press.
3. Build a manual settlement-to-block crosswalk:

```text
settlement_id
settlement_name
localarea_name
municipality
suburb_or_place_name
candidate_schedule_block
crosswalk_confidence
source_note
```

4. Separate municipal-fed and Eskom-direct areas when possible.
5. If no robust crosswalk can be built, stop Empangeni at qualitative triangulation.
6. For any mapped blocks, combine schedule table with 2023 declared stage history.
7. Create daily scheduled exposure:

```text
scheduled_off_1_2am_i,t
scheduled_off_any_night_i,t
scheduled_off_any_day_i,t
```

8. Compare against settlement-day `not_up_040`.
9. If Empangeni is too weak, repeat the same procedure for Steve Tshwete/Middelburg, where the audit found clearer block-area mapping.

### Expected Outputs

Create outputs such as:

```text
validation/data_manifest.md#external-public-benchmark-inputs (vj146a2_2023_empangeni_schedule_crosswalk_audit.csv)
validation/data_manifest.md#external-public-benchmark-inputs (vj146a2_2023_empangeni_schedule_vj_triangulation.csv)
validation/data_manifest.md#external-public-benchmark-inputs (vj146a2_2023_middelburg_schedule_crosswalk_audit.csv)
validation/data_manifest.md#external-public-benchmark-inputs (vj146a2_2023_middelburg_schedule_vj_triangulation.csv)
validation/data_manifest.md#external-public-benchmark-inputs
```

### Decision Rule

Use Empangeni if:

- at least a meaningful demand share of Empangeni LocalArea settlements can be assigned to official blocks;
- the schedule was plausibly active in 2023;
- Eskom-direct areas can be flagged or excluded.

Use Middelburg fallback if:

- Empangeni crosswalk confidence is low;
- overpass schedule exposure cannot be reconstructed;
- Eskom-direct mixing dominates the mapped settlements.

### Caveats

- This remains schedule triangulation, not metered outage validation.
- Manual suburb crosswalks are prone to false matches.
- Eskom-direct and municipal-fed areas must not be mixed silently.
- Public schedules may omit actual local switching failures, restoration delays, and over-shedding.

## Module 3: Stats SA GHS 2023 And GCRO QoL7 Plausibility Rankings

### Purpose

Compare VJ146A2 spatial not-up rankings with public survey indicators of outage exposure, grid dependence, and adaptation.

This checks plausibility:

```text
Do provinces / Gauteng municipalities or wards with higher VJ not-up also show higher reported interruption burden or alternative-energy adaptation?
```

It does not calibrate annual uptime levels.

### Public Sources

Stats SA GHS 2023:

- Stats SA GHS 2023 publication: https://www.statssa.gov.za/?PPN=P0318&SCH=73897&page_id=1854
- Isibalo GHS 2023 data page: https://isibaloweb.statssa.gov.za/pages/surveys/pss/ghs/2023/ghs2023.php

GCRO QoL7:

- GCRO QoL7 basic services brief: https://www.gcro.ac.za/outputs/data-briefs/detail/basic-services-qol7/
- GCRO QoL survey viewer / datasets: https://www.gcro.ac.za/data-gallery/quality-of-life/detail/quality-life-v-201718-survey-viewer/

### Recommended Variables

Stats SA GHS 2023 primary:

```text
eng_loadshed_freq
```

Interpretation: previous-week scheduled load shedding and/or unscheduled outages. Recode so higher values mean worse exposure.

Stats SA GHS 2023 secondary:

```text
eng_light_alt
eng_cook_alt
```

Interpretation: alternative lighting/cooking during electrical interruptions or load shedding.

Stats SA GHS 2023 controls/context:

```text
eng_access
eng_mains
eng_supply
eng_cook
eng_light
eng_mainelect
solar panels / generator / gas stove asset variables where available
```

GCRO QoL7 primary:

```text
q1_14_elec_interruptions
```

Interpretation: electricity interruptions in the past 12 months. Recode so weekly/monthly interruption shares are worse.

GCRO QoL7 secondary/adaptation:

```text
Generating_electricity
q1_12_10_pv_panels
q1_12_11_inverter
q1_12_4_generator
plan_to_invest_alt_energy
q1_12a_alt_energy
```

GCRO QoL7 controls/confounds:

```text
q1_15_cooking
q1_16_lighting
q2_5_energy
q2_9_street_lights
income / urban / dwelling indicators where available
```

### Method: Stats SA Province Ranking

1. Download GHS 2023 data and metadata.
2. Confirm variable labels and coding.
3. Create province-level survey indicators using survey weights:

```text
share_daily_or_frequent_loadshed
share_any_previous_week_loadshed
share_using_alternative_lighting
share_using_alternative_cooking
share_with_grid_access
share_with_solar_or_generator
```

4. Aggregate VJ not-up to province.

Preferred aggregation:

```text
province_not_up_040 =
  demand-weighted mean of settlement/localarea not_up_040
```

Use settlement-level demand and province assignment if possible. If only LocalArea annual data is available, document that province aggregation is approximate.

5. Compare rankings:

```text
Spearman(province_vj_not_up_040, province_survey_disruption)
Kendall(province_vj_not_up_040, province_survey_disruption)
top/bottom province overlap
```

6. Report direction and caveats, not level fit.

### Method: GCRO Gauteng Ranking

1. Download QoL7 data / metadata or use public viewer exports where possible.
2. Confirm geography fields:

```text
ward
municipality
planning region
survey weights
```

3. Build Gauteng survey indicators:

```text
share_weekly_or_monthly_interruptions
share_any_interruptions
share_generating_electricity
share_pv_panels
share_inverter
share_generator
share_planning_alt_energy
share_using_grid_for_lighting
share_using_candles_or_other_alt_lighting
```

4. Build VJ Gauteng comparator:

Option A, preferred:

```text
settlement centroid -> ward / municipality
demand-weighted VJ not_up_040 by ward / municipality
```

Option B:

```text
GCRO ward / municipality -> overlapping VJ LocalArea
population-weighted or demand-weighted aggregation
```

5. Compare:

```text
Spearman(VJ not_up_040, reported interruption share)
Spearman(VJ not_up_040, adaptation indicators)
top/bottom decile overlap
```

6. Flag disagreement cases where high reported interruptions coexist with low VJ not-up, especially bright/backup-heavy urban areas.

### Expected Outputs

Create outputs such as:

```text
validation/data_manifest.md#external-public-benchmark-inputs (vj146a2_2023_stats_sa_ghs_province_plausibility.csv)
validation/data_manifest.md#external-public-benchmark-inputs (vj146a2_2023_gcro_qol7_gauteng_plausibility.csv)
validation/data_manifest.md#external-public-benchmark-inputs
```

Suggested columns for GHS province output:

```text
province
vj_not_up_040_demandw
vj_availability_040_demandw
ghs_share_any_loadshed_previous_week
ghs_share_daily_or_frequent_loadshed
ghs_share_alt_lighting
ghs_share_alt_cooking
ghs_share_grid_access
rank_vj_not_up
rank_ghs_disruption
rank_difference
```

Suggested columns for GCRO output:

```text
geography_type
geography_name
vj_not_up_040_demandw
gcro_share_weekly_or_monthly_interruptions
gcro_share_generating_electricity
gcro_share_pv_or_inverter
gcro_share_generator
gcro_share_planning_alt_energy
gcro_share_grid_lighting
rank_vj_not_up
rank_gcro_interruptions
rank_difference
```

### Caveats

- GHS is a previous-week measure; VJ is annual nighttime observation.
- GCRO QoL7 spans 2023-09-28 to 2024-04-19, not exactly calendar-year 2023.
- Survey responses mix load shedding, local faults, maintenance, theft/vandalism, illegal connections, affordability, and backup behavior.
- Backup generation and urban lighting can make interrupted areas look bright in VIIRS.
- Use rank and directional comparisons, not numeric calibration.

## Final Report Structure

After implementation, write a report with this structure:

```text
# VJ146A2 Public Triangulation Results

## Summary
State that evidence supports triangulation, not direct validation.

## Cape Town Schedule Pilot
Data sources, coverage, method, results, disagreement cases.

## Weak-Area Schedule Pilot
Empangeni result; if weak, Middelburg fallback; schedule/crosswalk caveats.

## Stats SA / GCRO Plausibility Rankings
Variables, rankings, correlations, maps/tables if useful.

## Synthesis
Whether public data supports the VJ LocalArea layer as a plausible proxy.

## Limits
No metered LocalArea ENS, schedule vs realized outage, survey confounding, bright-city limitations.

## Recommendation
How to describe the evidence in the thesis and PyPSA integration documentation.
```

## Acceptance Criteria

The implementation is complete only if:

- each module has a reproducible script or clearly documented manual step;
- public sources and URLs are recorded;
- all external data are cached or instructions are provided for reproducible download;
- outputs distinguish schedule exposure, survey exposure, and VJ not-up;
- no result is described as direct LocalArea ENS validation;
- every table states the unit of observation and date coverage;
- disagreement cases are reported, not hidden.

## Recommended Claim If Results Are Directionally Consistent

Use wording like:

```text
Public data triangulation supports the spatial plausibility of the VJ146A2 LocalArea not-up layer. In Cape Town, official schedule-history records allow a direct comparison between scheduled overpass exposure and VJ not-up at settlement-day level. Survey evidence from Stats SA GHS 2023 and GCRO QoL7 provides additional province and Gauteng plausibility checks. These comparisons benchmark the proxy against public evidence but do not constitute direct validation of metered LocalArea uptime or ENS.
```

## Recommended Claim If Results Are Mixed

Use wording like:

```text
Public data triangulation provides partial support for the VJ146A2 LocalArea not-up layer but also highlights expected mismatches. Schedule exposure, reported interruptions, and satellite darkness measure different objects. Differences are especially expected in bright or backup-rich urban areas, areas with municipal shielding, and areas where public schedule blocks do not map cleanly to settlements. The national Eskom MLR validation remains the primary validation evidence; local public data are used as benchmark checks only.
```
