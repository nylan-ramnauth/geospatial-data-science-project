# VJ146A2 PyPSA-Facing Demand-Weighted Uptime

Date: 2026-06-04
Actor: Codex
Workstream: reliability-assessment / PyPSA integration
Related note: [[validation/pypsa_uptime/reports/2026-06-04-vj146a2-pypsa-uptime-target-alignment-note]]

## Specification

This is the updated PyPSA-facing NTL reliability metric aligned to the recommended VJ/Eskom validation target:

- Source panel: VJ146A2 strict yearly-keep post-DOE daily states after annual-IQR excess-lit date removal.
- Date screen: keep observed VJ product dates after removing `annual_q3_plus_1p5_iqr` excess-lit dates from [[validation/eskom_mlr/data/vj146a2_2023_annual_iqr_excess_lit_day_flags.csv]].
- Settlement-day validity: keep non-missing `p_lit_sett` rows from the upstream `coverage >= 0.50` panel.
- LocalArea-day validity: keep annual aggregation days where observed post-DOE settlement demand is at least 40% of total positive settlement demand assigned to that LocalArea.
- Main aggregation: compute LocalArea daily demand-weighted `1[p_lit_sett < threshold]` first, then average those daily not-up shares over the year.
- LocalArea observed-demand support-gate sensitivity: the builder also emits the same daily-first annual metrics under observed-demand support gates `0.10`, `0.30`, `0.40`, `0.50`, and `0.60`.
- `p_lit` outage-threshold sensitivity: the builder emits a separate long-form sensitivity for `p_lit_sett < q`, with `q` in `0.05`, `0.10`, `0.20`, `0.30`, `0.40`, `0.50`, and `0.60`, while keeping the LocalArea observed-demand support gate fixed at `0.40`.

The preferred PyPSA ENS-proxy column is `not_up_040_share_demandw`. Its availability complement is `availability_040_demandw`.

The previous settlement-first construction is retained for comparison as `uptime_demandw_settlement_first`; `uptime_demandw` remains as a compatibility alias for that legacy value, not the preferred validated proxy.

## Headline Results

- LocalAreas with annual metrics: `33`
- LocalAreas passing `share_demand_kept >= 50%`: `33`
- Minimum `share_demand_kept`: `91.61%`
- Observed, non-excess-lit VJ product dates: `345`
- LocalArea-day audit rows: `11,385`
- LocalArea-days passing the 40% demand gate: `7,603`
- National demand-weighted daily-first availability at `p_lit >= 0.40`: `94.77%`
- National demand-weighted daily-first not-up share at `p_lit < 0.40`: `5.23%`
- National demand-weighted settlement-first legacy uptime: `94.87%`
- Median LocalArea daily-first availability: `93.82%`
- Demand-weighted mean settlement observation days: `192.9`
- Weakest mean settlement observation days: `101.5`
- Area-level daily-first minus settlement-first availability range: `-0.75` to `+1.16` percentage points

The construction change is therefore modest nationally but important conceptually: the PyPSA-facing annual input is now the annual mean of the same daily demand-weighted not-up object validated against Eskom MLR.

## Support-Gate Sensitivity

The 40% LocalArea observed-demand support gate remains the preferred validation-aligned support threshold, but the same annual daily-first construction is now available for stricter and looser LocalArea-day support gates. This sensitivity changes the minimum observed settlement-demand share required for a LocalArea-day to enter the annual mean; it does not change the `p_lit_sett < 0.40` outage definition.

| LocalArea demand gate | LocalArea-days retained | National availability 0.40 | National not-up 0.40 | Median LocalArea availability 0.40 |
|---:|---:|---:|---:|---:|
| 0.10 | 9,072 | 94.36% | 5.64% | 92.93% |
| 0.30 | 8,038 | 94.72% | 5.28% | 93.75% |
| 0.40 | 7,603 | 94.77% | 5.23% | 93.82% |
| 0.50 | 7,126 | 94.88% | 5.12% | 93.58% |
| 0.60 | 6,594 | 95.01% | 4.99% | 93.46% |

The expected support-quality tradeoff appears: stricter gates retain fewer LocalArea-days and slightly increase measured availability because low-observation days tend to be noisier and darker in this panel.

## `p_lit` Outage-Threshold Sensitivity

The separate `p_lit` outage-threshold sensitivity asks how the annual daily-first not-up metric changes when the outage definition varies from severe darkness to partial-light conditions. The LocalArea observed-demand support gate is held fixed at `0.40`, matching the main PyPSA bridge.

For each LocalArea, date, and threshold `q`:

```text
daily_not_up_share_a,t,q =
  weighted_mean_i(1[p_lit_sett_i,t < q], demand_i)
```

Annual metrics are then computed only over LocalArea-days passing the fixed 40% observed-demand support gate:

```text
annual_not_up_share_a,q =
  mean_t(daily_not_up_share_a,t,q)

annual_availability_a,q =
  1 - annual_not_up_share_a,q
```

National demand-weighted summary:

| `p_lit` outage threshold | Gated LocalArea-days | National not-up share | National availability | Median LocalArea not-up | Median LocalArea availability |
|---:|---:|---:|---:|---:|---:|
| 0.05 | 7,603 | 2.38% | 97.62% | 2.59% | 97.41% |
| 0.10 | 7,603 | 2.90% | 97.10% | 3.27% | 96.73% |
| 0.20 | 7,603 | 3.67% | 96.33% | 4.09% | 95.91% |
| 0.30 | 7,603 | 4.37% | 95.63% | 4.87% | 95.13% |
| 0.40 | 7,603 | 5.23% | 94.77% | 6.18% | 93.82% |
| 0.50 | 7,603 | 6.26% | 93.74% | 7.84% | 92.16% |
| 0.60 | 7,603 | 7.74% | 92.26% | 10.76% | 89.24% |

LocalArea availability by `p_lit` outage threshold:

| LocalArea | p_lit < 0.05 | p_lit < 0.10 | p_lit < 0.20 | p_lit < 0.30 | p_lit < 0.40 | p_lit < 0.50 | p_lit < 0.60 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Middelburg | 93.03% | 91.41% | 89.00% | 87.76% | 86.26% | 84.33% | 81.97% |
| Empangeni | 94.48% | 93.20% | 91.26% | 88.61% | 86.27% | 83.54% | 79.90% |
| Polokwane | 92.70% | 91.39% | 89.50% | 88.11% | 86.36% | 84.22% | 81.36% |
| Ladysmith | 96.28% | 94.10% | 90.60% | 88.33% | 86.69% | 84.80% | 80.85% |
| Phalaborwa | 94.48% | 92.93% | 91.14% | 89.62% | 87.38% | 85.11% | 82.25% |
| Kalahari | 96.38% | 94.81% | 91.16% | 89.51% | 87.58% | 83.71% | 77.93% |
| Mthatha | 96.34% | 95.24% | 93.35% | 90.95% | 88.35% | 84.57% | 79.59% |
| Lephalale | 93.58% | 92.98% | 92.14% | 90.83% | 88.87% | 86.42% | 83.55% |
| Hydra Central | 94.39% | 93.83% | 92.57% | 90.93% | 89.12% | 86.97% | 84.57% |
| Namaqualand | 94.99% | 94.37% | 93.19% | 92.33% | 90.83% | 88.70% | 85.67% |
| Warmbad | 95.72% | 94.57% | 93.55% | 92.80% | 91.48% | 89.67% | 87.15% |
| Kimberley | 96.48% | 96.12% | 95.25% | 94.01% | 92.17% | 89.85% | 86.89% |
| Carletonville | 96.46% | 96.08% | 95.38% | 94.34% | 92.57% | 90.44% | 87.34% |
| Highveld South | 96.64% | 96.09% | 95.31% | 94.16% | 92.71% | 91.29% | 88.95% |
| Vredendal | 95.94% | 95.44% | 94.78% | 93.99% | 92.80% | 90.97% | 89.24% |
| Newcastle | 97.41% | 96.73% | 95.91% | 94.94% | 93.70% | 92.16% | 89.07% |
| Johannesburg | 96.77% | 96.44% | 95.86% | 95.13% | 93.82% | 92.64% | 91.24% |
| East London | 97.97% | 97.59% | 96.84% | 95.56% | 94.02% | 91.62% | 88.66% |
| Witbank | 98.06% | 97.28% | 96.16% | 95.18% | 94.66% | 94.05% | 93.17% |
| Lowveld | 98.11% | 97.35% | 96.16% | 95.58% | 94.81% | 94.36% | 92.48% |
| Welkom | 98.04% | 97.42% | 96.52% | 95.70% | 95.03% | 94.25% | 93.35% |
| Outeniqua | 97.86% | 97.66% | 97.24% | 96.66% | 95.85% | 94.74% | 93.48% |
| Rustenburg | 98.22% | 97.87% | 97.46% | 97.02% | 96.36% | 95.57% | 94.79% |
| Bloemfontein | 98.53% | 98.42% | 98.16% | 97.77% | 97.29% | 96.98% | 96.49% |
| Pinetown | 98.81% | 98.55% | 98.20% | 97.82% | 97.32% | 96.79% | 95.87% |
| West Coast | 98.58% | 98.51% | 98.19% | 97.89% | 97.35% | 96.25% | 95.19% |
| Vaal | 99.16% | 98.96% | 98.64% | 98.15% | 97.46% | 96.46% | 95.76% |
| Gqeberha | 98.93% | 98.80% | 98.48% | 98.12% | 97.76% | 97.25% | 96.60% |
| Pretoria | 99.14% | 99.02% | 98.80% | 98.65% | 98.49% | 98.26% | 97.83% |
| Nigel | 99.38% | 99.27% | 99.15% | 98.98% | 98.80% | 98.61% | 98.40% |
| West Rand | 99.56% | 99.53% | 99.38% | 99.25% | 99.00% | 98.75% | 97.95% |
| Peninsula | 99.83% | 99.82% | 99.79% | 99.75% | 99.71% | 99.62% | 99.49% |
| Midrand | 99.99% | 99.99% | 99.99% | 99.99% | 99.99% | 99.98% | 99.98% |

The long-form annual threshold output has `231` rows (`33` LocalAreas x `7` thresholds). The daily audit writes all LocalArea-days before support gating, so it has `79,695` rows (`7` thresholds x `11,385` LocalArea-days); the `localarea_demand_gate` column identifies the `7,603` LocalArea-days per threshold that enter the annual means.

The `0.05`, `0.20`, and `0.40` threshold rows exactly match the corresponding columns in the main annual file under the fixed 0.40 observed-demand support gate. By LocalArea, `not_up_share_demandw` weakly increases and `availability_demandw` weakly decreases as the `p_lit` outage threshold rises.

## Lowest-Availability LocalAreas

| LocalArea | Availability 0.40 daily-first | Not-up 0.40 daily-first | Legacy settlement-first uptime | Delta daily minus legacy | Demand kept | Gated dates |
|---|---:|---:|---:|---:|---:|---:|
| Middelburg | 86.26% | 13.74% | 86.98% | -0.72 pp | 99.02% | 259 |
| Empangeni | 86.27% | 13.73% | 85.98% | +0.29 pp | 99.32% | 172 |
| Polokwane | 86.36% | 13.64% | 87.05% | -0.68 pp | 100.00% | 230 |
| Ladysmith | 86.69% | 13.31% | 86.91% | -0.23 pp | 99.42% | 201 |
| Phalaborwa | 87.38% | 12.62% | 88.01% | -0.63 pp | 99.85% | 202 |
| Kalahari | 87.58% | 12.42% | 87.95% | -0.37 pp | 99.89% | 275 |
| Mthatha | 88.35% | 11.65% | 88.61% | -0.26 pp | 97.76% | 125 |
| Lephalale | 88.87% | 11.13% | 89.39% | -0.52 pp | 99.93% | 265 |

## Weakest Support Areas

| LocalArea | Availability 0.40 daily-first | Legacy settlement-first uptime | Demand kept | Demand-weighted obs. days | Gated dates |
|---|---:|---:|---:|---:|---:|
| Mthatha | 88.35% | 88.61% | 97.76% | 101.5 | 125 |
| Pinetown | 97.32% | 97.77% | 91.61% | 105.3 | 117 |
| Lowveld | 94.81% | 94.54% | 99.96% | 118.2 | 139 |
| Empangeni | 86.27% | 85.98% | 99.32% | 127.3 | 172 |
| East London | 94.02% | 93.74% | 98.94% | 136.1 | 166 |
| Highveld South | 92.71% | 92.32% | 98.14% | 145.9 | 196 |
| Phalaborwa | 87.38% | 88.01% | 99.85% | 152.5 | 202 |
| Outeniqua | 95.85% | 95.88% | 99.95% | 161.2 | 223 |

## Interpretation

The report note's recommended bridge is now implemented:

```text
LocalArea daily not-up share =
  weighted_mean_i(1[p_lit_i,t < threshold], demand_i)

Annual PyPSA proxy =
  mean_t(LocalArea daily not-up share)
```

Use `not_up_040_share_demandw` as the main annual ENS-proxy input. Use `strict_dark_005_share_demandw` and `mostly_dark_020_share_demandw` as backward-compatible wide-file threshold sensitivity columns, and use the long-form `p_lit` outage-threshold sensitivity file when comparing the full seven-threshold ladder. Use `availability_040_demandw` when the model or map needs an availability complement.

`uptime_demandw_settlement_first` is still useful for continuity checks because it reproduces the old aggregation order:

```text
settlement annual uptime -> LocalArea demand-weighted mean
```

The direct comparison column is `delta_availability_040_daily_minus_settlement_first`.

## Outputs

- Metric builder: [[validation/pypsa_uptime/scripts/build_vj146a2_pypsa_localarea_demand_weighted_uptime.R]]
- Choropleth renderer: [[validation/pypsa_uptime/scripts/map_vj146a2_pypsa_localarea_demand_weighted_uptime.R]]
- Main CSV: [[validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_demand_weighted_uptime.csv]]
- Main Parquet: [[validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_demand_weighted_uptime.parquet]]
- Daily audit CSV: [[validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_daily_demand_weighted_uptime_audit.csv]]
- Daily audit Parquet: [[validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_daily_demand_weighted_uptime_audit.parquet]]
- LocalArea observed-demand support-gate sensitivity CSV: [[validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_demand_weighted_uptime_gate_sensitivity.csv]]
- LocalArea observed-demand support-gate sensitivity Parquet: [[validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_demand_weighted_uptime_gate_sensitivity.parquet]]
- LocalArea observed-demand support-gate sensitivity daily audit CSV: [[validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_daily_demand_weighted_uptime_gate_sensitivity_audit.csv]]
- LocalArea observed-demand support-gate sensitivity daily audit Parquet: [[validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_daily_demand_weighted_uptime_gate_sensitivity_audit.parquet]]
- `p_lit` outage-threshold sensitivity CSV: [[validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_p_lit_threshold_sensitivity.csv]]
- `p_lit` outage-threshold sensitivity Parquet: [[validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_p_lit_threshold_sensitivity.parquet]]
- `p_lit` outage-threshold daily audit CSV: [[validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_daily_p_lit_threshold_sensitivity_audit.csv]]
- `p_lit` outage-threshold daily audit Parquet: [[validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_daily_p_lit_threshold_sensitivity_audit.parquet]]
- Expanded daily support CSV: [[validation/pypsa_uptime/data/vj146a2_2023_pypsa_localarea_daily_demand_support.csv]]
- Choropleth PNG: [[validation/pypsa_uptime/figures/vj146a2-pypsa-demand-weighted-uptime/localarea_demand_weighted_uptime_vj146a2_2023_annual_excess_lit_iqr.png]]
- Choropleth PDF: [[validation/pypsa_uptime/figures/vj146a2-pypsa-demand-weighted-uptime/localarea_demand_weighted_uptime_vj146a2_2023_annual_excess_lit_iqr.pdf]]
