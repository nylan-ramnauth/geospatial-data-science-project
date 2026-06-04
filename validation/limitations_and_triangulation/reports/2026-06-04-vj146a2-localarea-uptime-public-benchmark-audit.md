# VJ146A2 LocalArea Uptime: Public Benchmark Audit

Date: 2026-06-04
Actor: Codex, with delegated web audit by Kepler sub-agent
Workstream: reliability-assessment / PyPSA integration
Related reports: [[validation/eskom_mlr/reports/2026-06-03-recommended-vj-eskom-validation-specification.Rmd]], [[validation/pypsa_uptime/reports/2026-06-04-vj146a2-pypsa-demand-weighted-uptime]]

## Question

If we use the VJ146A2 LocalArea annual availability / not-up layer as the PyPSA-facing reliability input, can those LocalArea results be aligned with any available public data?

## Short Answer

There does not appear to be a public, authoritative, metered South African dataset that reports 2023 annual uptime or energy-not-served at the Eskom LocalArea scale. The LocalArea values therefore cannot be directly validated one-to-one against public ground truth.

The public evidence can still support three useful checks:

- national temporal validation against Eskom MLR and RSA Contracted Demand, which is already the strongest validation channel;
- schedule and survey triangulation, especially for metros and municipalities where public load-shedding schedules or household outage/exposure indicators exist;
- plausibility benchmarking against Eskom/NERSA reliability indicators and peer-reviewed VIIRS nighttime-light reliability studies.

The correct claim is therefore:

```text
The VJ146A2 LocalArea availability layer is externally benchmarked, not directly validated, against public South African reliability evidence. The strongest validation is national/daily: the same demand-weighted VJ not-up object moves strongly with Eskom MLR divided by RSA Contracted Demand. Public schedule, survey, SAIDI/SAIFI, and VIIRS-literature sources support plausibility and triangulation, but no public source provides metered LocalArea annual uptime or ENS suitable for direct calibration.
```

## Current Validated Object

The recommended validation report supports a daily national demand-weighted VJ target:

```text
demandw_not_up_040_t =
  weighted_mean_i(1[p_lit_i,t < 0.40], settlement_demand_i)
```

The PyPSA-facing LocalArea annual construction now localizes that same daily-first object:

```text
localarea_not_up_040_a,t =
  weighted_mean_i(1[p_lit_i,t < 0.40], settlement_demand_i)

localarea_not_up_040_a =
  mean_t(localarea_not_up_040_a,t)

localarea_availability_040_a =
  1 - localarea_not_up_040_a
```

This makes the LocalArea uptime construction aligned with the validated target mechanically. What remains missing is a public LocalArea-level outcome dataset for external one-to-one validation.

## Public Evidence Classes

| Source class                               | Public source                                                                        | Scale / variable                                                                              | What it can validate                                                                                  | What it cannot validate                                                  |
| ------------------------------------------ | ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Eskom Data Portal MLR and demand           | Eskom Data Portal glossary and data request form [1], [2]                            | Hourly national MLR, RSA Contracted Demand, residual demand                                   | Strong national temporal validation of the VJ daily target against system scarcity / manual reduction | LocalArea annual uptime or LocalArea ENS                                 |
| Eskom system status and integrated reports | Eskom system status reports and integrated results [3], [4], [5]                     | Weekly / annual system adequacy, load-shedding days, EAF, SAIDI/SAIFI                         | National benchmark for direction and magnitude of 2023 crisis                                         | Local nighttime outage realization; LocalArea-level delivery             |
| Eskom direct load-shedding schedules       | Eskom load-shedding website [6], [7]                                                 | Direct Eskom-customer area schedules                                                          | Schedule-based checks for directly supplied areas                                                     | Actual outage realization, restoration timing, exemptions, faults        |
| Municipal schedules                        | Eskom municipal schedule page and municipal pages such as City of Cape Town [8], [9] | Municipal blocks / areas                                                                      | Schedule triangulation for selected metros and municipalities                                         | Clean mapping to Eskom LocalAreas; actual delivered outage duration      |
| EskomSePush / ESP                          | ESP area/schedule infrastructure and API references [10], [11]                       | App/API area status, events, schedule, area search                                            | Best operational public/proprietary proxy for area-level schedule history if archived and licensed    | Official metered ENS; public authoritative LocalArea dataset             |
| Stats SA GHS                               | Stats SA GHS 2023 publication and microdata pages [12], [13], [14]                   | Household access, energy sources, alternative energy use, province/household survey variables | Social exposure and robustness checks; context for backup-energy adoption                             | Hourly outage duration or LocalArea annual uptime                        |
| GCRO Quality of Life survey                | GCRO electricity interruption and QoL data pages [15], [16]                          | Gauteng household-reported electricity interruptions, municipality/mesozone                   | Spatial plausibility within Gauteng; distribution versus generation caveats                           | National LocalArea ENS; direct 2023 Eskom LocalArea comparison           |
| Eskom / NERSA distribution reliability     | Eskom integrated report SAIDI/SAIFI [5]                                              | Eskom distribution SAIDI/SAIFI and restoration indicators                                     | Reliability context and a warning about conflating distribution interruptions with load shedding      | Generation-adequacy load shedding ENS; LocalArea not-up rates            |
| Peer-reviewed VIIRS reliability studies    | Li and Wang 2026, plus broader VIIRS reliability literature [17], [18], [19]         | NTL reliability proxies, pixel/admin units, mostly monthly or lower-frequency                 | Methodological support for VIIRS as an electricity-reliability signal                                 | Direct validation of this daily binary, demand-weighted LocalArea metric |

## Main Findings

### 1. The national validation is the strongest available external anchor

Eskom defines MLR as an estimate of demand reduced due to load shedding and/or curtailment, and defines RSA Contracted Demand as the hourly average demand that needs to be supplied by contracted resources [1]. The data request form exposes both RSA Contracted Demand and Manual Load Reduction as downloadable/requestable fields [2].

This is exactly the right type of public data for validating the daily national VJ target, because it measures national system-side scarcity at the same daily time scale as the satellite overpass. It does not validate the LocalArea annual surface directly, but it validates the target construction that the LocalArea metric now localizes.

### 2. Public schedules are useful, but they are not realized uptime

Eskom describes load shedding as a controlled process to protect the electricity system from a total blackout, and the public Eskom site provides direct-customer schedules by province/area [6], [7]. Eskom also provides a municipal schedule page, but explicitly states that municipal schedules are maintained by the relevant metro or municipality, not by Eskom [8].

City of Cape Town publishes area schedules and notes that City areas 1-16 follow the City schedule while some areas use Eskom schedules [9]. This could be used for case-study checks in Cape Town, Johannesburg/City Power, Ekurhuleni, Tshwane, eThekwini, and selected municipalities.

The limitation is important: schedules are planned load-shedding exposure, not actual nighttime power state. They do not capture late restoration, skipped slots, local faults, street-light switching, backup generation, partial dimming, or the difference between a municipal block and an Eskom LocalArea.

### 3. ESP is the most practical operational comparator, but not an official ground truth

ESP/EskomSePush now organizes load-shedding information around real areas, suburbs, and neighbourhoods rather than only blocks [10]. API ecosystem documentation indicates that area search, area schedule, current status, and upcoming event information can be retrieved with a license key [11].

This makes ESP the most practical source for a future operational benchmark: map LocalArea settlements to ESP areas, reconstruct scheduled outage exposure, and compare scheduled exposure to VJ not-up. But it remains a schedule/event product, not an official metered outage or ENS dataset, and API terms/history availability need to be checked before treating it as reproducible public evidence.

### 4. SAIDI/SAIFI are not the right numeric target

Eskom reports SAIDI and SAIFI in its integrated report; for the 2023 financial year the report table gives SAIDI around 35.5 hours and SAIFI around 11.8 events, with SAIDI/SAIFI reported after national-standard exclusions [5].

These indicators are useful context, but they should not be used to calibrate the VJ LocalArea not-up metric. SAIDI/SAIFI measure regulated distribution interruptions after exclusions. Our target is generation-scarcity-related nighttime service deficit observed in VIIRS and validated against Eskom MLR. These are related reliability concepts but not the same quantity.

### 5. Surveys provide social plausibility checks, not hourly validation

Stats SA's GHS 2023 reports very high mains electricity access and substantial alternative-energy adaptation during load shedding, including increased gas use and other lighting/cooking substitutions [12]. The GHS data and metadata are available through Stats SA / DataFirst / Isibalo [13], [14].

GCRO's Gauteng Quality of Life work is more directly about interruptions. Its 2020/21 map reports the share of respondents experiencing electricity interruptions weekly and explicitly warns that interruptions combine generation constraints, transmission, distribution, maintenance, theft, vandalism, illegal connections, and other causes [15]. The QoL datasets are ward/household survey resources, not LocalArea metered uptime [16].

These sources are valuable for triangulating whether high-not-up areas also appear as places with high reported interruption burden, especially in Gauteng. They cannot directly validate annual LocalArea ENS.

### 6. VIIRS literature supports the method, but not the exact metric

Li and Wang's 2026 South Africa VIIRS reliability paper is the closest academic benchmark identified. It uses VIIRS nighttime lights to characterize electricity reliability patterns from pixels to regional aggregates and discusses South Africa explicitly [17]. Broader VIIRS reliability work also supports the idea that nighttime-light instability can reveal electricity reliability, while warning that individual outage detection can be difficult [18], [19].

This supports the method class. It does not prove our exact daily binary `p_lit < 0.40`, demand-weighted, LocalArea annual construction. The literature should be cited as methodological support and as a source of external spatial plausibility comparisons, not as ground truth.

## Contradictions And Caveats

- National load-shedding stage histories and CSIR/Eskom summaries count system-level planned curtailment, while VJ observes nighttime luminosity outcomes.
- Schedule data can predict planned exposure but not whether a settlement was actually dark during the satellite overpass.
- SAIDI/SAIFI are official reliability metrics but are conceptually mismatched to generation-scarcity ENS and to a satellite-observed nighttime not-up proxy.
- Large bright cities can remain above binary `p_lit` thresholds during partial dimming because of backup power, street-lighting, commercial lighting, or residual brightness. This is already documented in [[validation/limitations_and_triangulation/reports/2026-06-04-vj146a2-large-city-binary-gate-limitation]].
- Survey data mixes load shedding with local faults, maintenance, theft, vandalism, affordability, and household backup choices.
- Administrative boundaries do not line up cleanly: Eskom LocalArea, municipality, load-shedding block, ESP area, settlement, ward, and province are different spatial units.

## Recommended Next Audit

The most defensible public benchmarking sequence is:

1. National temporal validation: keep the current Eskom MLR / RSA Contracted Demand validation as the main evidence.
2. Metro schedule case studies: map settlements in Cape Town, Johannesburg, Tshwane, Ekurhuleni, eThekwini, and one or two weaker LocalAreas to public schedules or ESP areas; compare scheduled overpass exposure to VJ not-up.
3. Province / municipality triangulation: aggregate LocalArea not-up to provinces or municipalities where possible and compare rankings to GCRO/Stats SA interruption or alternative-energy indicators.
4. Literature triangulation: compare high/low spatial patterns with Li and Wang-style VIIRS reliability maps where comparable units can be extracted.

The result should be framed as triangulation. It should not be described as direct LocalArea ENS validation unless a metered LocalArea outage/ENS dataset is obtained from Eskom, NERSA, municipalities, or another authority.

## Recommendation For The Thesis / Report

Use `not_up_040_share_demandw` as the main PyPSA-facing reliability proxy because:

- its construction is aligned with the validated daily demand-weighted VJ/Eskom target;
- the national daily target has a strong relationship with corrected Eskom MLR / RSA Contracted Demand;
- the public data ecosystem supports benchmarking and plausibility checks but does not offer a better LocalArea ground truth.

Suggested wording:

```text
We interpret the LocalArea layer as a validated proxy surface, not as measured ENS. The validation is direct at the national daily level, where the demand-weighted VIIRS not-up share moves strongly with Eskom MLR normalized by RSA Contracted Demand. The LocalArea layer applies the same validated daily construction within each Eskom LocalArea. Because no public metered LocalArea ENS or uptime dataset is available, spatial results are benchmarked against schedules, survey evidence, Eskom/NERSA reliability indicators, and existing VIIRS reliability literature rather than calibrated one-to-one.
```

## References

[1] Eskom Data Portal, "Glossary of terms." https://www.eskom.co.za/dataportal/glossary/
[2] Eskom Data Portal, "Data request form." https://www.eskom.co.za/dataportal/data-request-form/
[3] Eskom Data Portal, "Pumped storage generating hours, gas generation & manual load reduction." https://www.eskom.co.za/dataportal/supply-side/pumped-storage-generating-hours-gas-generation-and-manual-load-reduction/
[4] Eskom, "System status reports." https://www.eskom.co.za/eskom-divisions/tx/system-adequacy-reports/
[5] Eskom Holdings SOC Ltd, "Integrated report 2023." https://www.eskom.co.za/wp-content/uploads/2023/10/Eskom_integrated_report_2023.pdf
[6] Eskom, "What is load shedding." https://loadshedding.eskom.co.za/LoadShedding/Description
[7] Eskom, "Load shedding status and schedules." https://loadshedding.eskom.co.za/LoadShedding/Index
[8] Eskom, "Municipal customer schedules." https://loadshedding.eskom.co.za/LoadShedding/loadsheddingmunic
[9] City of Cape Town, "Load-shedding." https://www.capetown.gov.za/loadshedding/Pages/default.aspx
[10] EskomSePush / ESP, "Real Areas, Not Loadshedding Blocks." https://esp.info/loadshedding
[11] Node-RED, "node-red-contrib-eskomsepush." https://flows.nodered.org/node/node-red-contrib-eskomsepush
[12] Government of South Africa / Statistics South Africa, "StatsSA publishes General Household Survey." https://www.gov.za/news/media-statements/statssa-publishes-general-household-survey-23-may-2024
[13] Statistics South Africa, "P0318 - General Household Survey (GHS), 2023." https://www.statssa.gov.za/?PPN=P0318&SCH=73897&page_id=1854
[14] Statistics South Africa, "General Household Survey 2023 data." https://isibaloweb.statssa.gov.za/pages/surveys/pss/ghs/2023/ghs2023.php
[15] Gauteng City-Region Observatory, "Electricity interruptions in the GCR." https://www.gcro.ac.za/outputs/map-of-the-month/detail/electricity-interruptions/
[16] Gauteng City-Region Observatory, "Quality of Life survey datasets." https://gcro.ac.za/data-gallery/quality-of-life/detail/
[17] S. Li and X. Wang, "Spatiotemporal Analysis of Electricity Reliability Using VIIRS Nighttime Lights: Case Study in South Africa," Journal of Geovisualization and Spatial Analysis, 2026. https://link.springer.com/article/10.1007/s41651-026-00250-x
[18] C. D. Elvidge et al., "Nighttime Lights and Electric Power Consumption in Africa," Remote Sensing, 2020. https://www.mdpi.com/2072-4292/12/19/3194
[19] M. L. Mann et al., "Estimating Electricity Reliability in Kenya Using Nighttime Lights," Remote Sensing, 2016. https://doi.org/10.3390/rs8090711
