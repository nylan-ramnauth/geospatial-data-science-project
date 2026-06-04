# Validation Data Manifest

This manifest separates committed handoff artifacts from external/generated data. The validation package commits small CSV/XLSX/R/PDF/PNG/report artifacts needed to inspect the headline validation and PyPSA bridge. It intentionally does not commit raw VIIRS rasters, Parquet panels, H5 networks, caches, or bulk generated closeups.

## External Inputs

Place or regenerate these outside git before rerunning full validation:

- `blackmarbler/out_vj146a2_sa_daily/`: VJ146A2 daily raster/product extraction.
- `Map Data/settlement_day_outputs_vj146a2/`: settlement-day Parquet panels and generated MLR validation directories.
- `Map Data/reliability_outputs_vj146a2/`: yearly settlement stats and reliability outputs.
- `Map Data/Settlements/GPKG/`: settlement geometry and demand weights.
- `Map Data/Local Area/`: LocalArea boundary files.
- `Map Data/Supply Area/`: SupplyArea boundary files.
- Eskom hourly CSV: default `../pypsa-earth/data/za_validation/eskom_2023_hourly_clean.csv`; override with `ESKOM_HOURLY_CSV`.

## Environment Variables

- `PYPSA_EARTH_DIR`: sibling pypsa-earth repository or directory containing `data/za_validation/eskom_2023_hourly_clean.csv`.
- `ESKOM_HOURLY_CSV`: explicit path to the cleaned Eskom hourly validation CSV.

## Committed Lightweight Artifacts

- `validation/eskom_mlr/data/`: summary tables, model results, excess-lit flags, centered-window sensitivity outputs, and stage-binned validation tables.
- `validation/pypsa_uptime/data/`: PyPSA-facing LocalArea CSV/XLSX outputs under 1 MB.
- `validation/closeups/data/`: small candidate tables, KMLs, and pixel-accounting extracts.
- `validation/legacy_october_diagnostics/reports/`: October diagnostic report artifacts retained for provenance.
- `validation/*/reports/`: validation reports and headline PDFs.
- `validation/*/figures/`: report-used figures.

## External Public Benchmark Inputs

The public triangulation plan names several municipality schedule, survey, and plausibility tables. They are not committed in this handoff package because they are implementation-plan inputs or outputs, not the main VJ/Eskom or PyPSA bridge artifacts. Keep them external until a public-benchmarking workstream is promoted.

## Legacy Closeup Artifacts

Older Jan-Jun closeup outputs and large event tables were used for screening and are referenced for provenance. The committed closeup package keeps stripped notebooks, small candidate tables, and helper scripts. Bulk rendered image folders and full event tables remain external.

## Not Committed

- `*.parquet`
- `*.h5` or `*.hdf5`
- raw rasters and VIIRS extraction folders
- `.matplotlib-cache/`
- `nightlights_p_lit_raster_2000m_01_nocloud.gif`
- bulk closeup output folders under `validation/closeups/figures/generated/`
- daily audit CSVs larger than 1 MB
