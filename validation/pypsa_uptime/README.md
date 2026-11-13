# PyPSA Uptime Bridge

This section contains the PyPSA-facing LocalArea reliability target derived from VJ146A2 settlement-day observations.

## Fields

- Preferred outage proxy: `not_up_040_share_demandw`.
- Companion availability field: `availability_040_demandw`.
- Threshold: `p_lit_sett < 0.40`.
- Aggregation: daily first, then LocalArea demand-weighted annual aggregation.

## Rebuild

From the repository root:

```sh
Rscript validation/pypsa_uptime/scripts/build_vj146a2_pypsa_localarea_demand_weighted_uptime.R
Rscript validation/pypsa_uptime/scripts/map_vj146a2_pypsa_localarea_demand_weighted_uptime.R
```

The builder expects external VJ146A2 Parquet panels, LocalArea boundaries, settlement demand weights, and Eskom excess-lit flags. Lightweight CSV/XLSX outputs are committed in `data/`; large Parquet and daily audit outputs stay external.

## Main Output

- `data/vj146a2_2023_pypsa_localarea_demand_weighted_uptime.csv`
- `data/vj146a2_2023_pypsa_localarea_reliability_regions.gpkg`
- `data/vj146a2_2023_pypsa_localarea_reliability_regions_audit.csv`
- `figures/vj146a2-pypsa-demand-weighted-uptime/localarea_demand_weighted_uptime_vj146a2_2023_annual_excess_lit_iqr.png`

The GeoPackage joins the annual PyPSA-facing LocalArea metrics to the
`LOCAL_AREA_GCCA2025.shp` geometry. The PyPSA-Earth ENS-cap input should use
layer `vj146a2_2023_localarea_reliability`,
`service_deficit_column: not_up_040_share_demandw`, and `value_unit: share`.
Rows with missing or invalid metrics are flagged in the audit CSV and in the
`pypsa_export_status` field.
