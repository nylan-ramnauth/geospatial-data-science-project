# External Data Files Required for Pipeline

These files are **NOT in the repo** and must be obtained separately before running the pipeline.

## Files to upload/obtain

| File | Size | Source | Repo Location |
|---|---|---|---|
| **DRE Atlas Settlements CSV** | ~292 MB | [DRE Atlas](https://energydata.info/dataset/south-africa-distributed-renewable-energy-dre) | `settlements_cleaning/south_africa_dre_atlas_settlements.csv` |
| **Africa Energy Tracker Excel** | ~5 MB | [Africa Energy Tracker](https://globalenergymonitor.org/projects/africa-energy-tracker/) | `Map Data/Generators Data/Africa-Energy-Tracker-2025-10-21.xlsx` |
| **JRC Continental Grid Shapefile** | ~100 MB | [JRC GLAES Grid Data](https://data.jrc.ec.europa.eu/) or equivalent | `Map Data/Grid Data/electricitygrid_Africa_JRC/elect_grid_africa_epsg3426_withgau_JRC.shp` (+ `.dbf`, `.shx`) |
| **Eskom Local Areas Shapefile** | Unknown | Eskom / GCCA 2025 | (https://www.ntcsa.co.za/gcca/) | `Map Data/Local Area/LOCAL_AREA_GCCA2025.shp` (+ `.dbf`, `.shx`) |
| **Eskom Supply Areas Shapefile** | Unknown | Eskom / GCCA 2025 | (https://www.ntcsa.co.za/gcca/) | `Map Data/Supply Area/SUPPLY_AREA_GCCA2025.shp` (+ `.dbf`, `.shx`) |

### Setup instructions

1. **DRE Atlas Settlements:**
   - Download from [DRE Atlas](https://energydata.info/dataset/south-africa-distributed-renewable-energy-dre)
   - Save as: `settlements_cleaning/south_africa_dre_atlas_settlements.csv`
   - Then run Stage 1a: `Rscript settlements_cleaning/settlements_csv_to_gpkg.R`

2. **Africa Energy Tracker:**
   - Download latest release from [africaenergytracker.org](https://globalenergymonitor.org/projects/africa-energy-tracker/)
   - Save as: `Map Data/Generators Data/Africa-Energy-Tracker-2025-10-21.xlsx` (update year if needed)
   - Then run Stage 1 prep: `Rscript "Map Data/Generators Data/gen_clean.r"`

3. **JRC Grid:**
   - Download from [JRC](https://figshare.com/articles/dataset/Electricity_grid_Africa/14828862?file=28546659) or equivalent Africa continental grid data
   - Extract shapefile to: `Map Data/Grid Data/electricitygrid_Africa_JRC/elect_grid_africa_epsg3426_withgau_JRC.shp`
   - Then run Stage 1 prep: `Rscript "Map Data/Grid Data/grid_clean.r"`

4. **Eskom Boundaries (Local Areas & Supply Areas):**
   - Obtain from Eskom or GCCA 2025 distribution (https://www.ntcsa.co.za/gcca/)
   - Place shapefiles in:
     - `Map Data/Local Area/LOCAL_AREA_GCCA2025.shp` (+ .dbf, .shx, .prj, etc.)
     - `Map Data/Supply Area/SUPPLY_AREA_GCCA2025.shp` (+ .dbf, .shx, .prj, etc.)

---

## Pre-computed data (Google Drive)

All external input files and partial VIIRS outputs are available on Google Drive:
**[BSE 23DM017 Project Data](https://drive.google.com/drive/folders/1G1DHDuFV3fX-k5AMrLhLCXFdKU5pLlUt?usp=sharing)**

| File | Contains | Size |
|---|---|---|
| `out_vnp46a2_sa_daily_2023_full_year.zip` | VIIRS TIFs for **full year 2023 (Jan–Dec)** | ~12 GB |
| `south_africa_dre_atlas_settlements.csv` | DRE Atlas settlements | 306 MB |
| `Africa-Energy-Tracker-2025-10-21.xlsx` | Power plants data | 1.12 MB |
| `electricitygrid_Africa_JRC.zip` | Continental grid shapefile | 29.67 MB |
| `Local_Area.zip` | Eskom local area boundaries | 3.29 MB |
| `Supply_Area.zip` | Eskom supply area boundaries | 3.28 MB |

### Setup

1. Download all files from the [Google Drive folder](https://drive.google.com/drive/folders/1G1DHDuFV3fX-k5AMrLhLCXFdKU5pLlUt?usp=sharing)
2. Extract to your repo:
   ```bash
   unzip south_africa_dre_atlas_settlements.csv -d settlements_cleaning/
   unzip Africa-Energy-Tracker-2025-10-21.xlsx -d "Map Data/Generators Data/"
   unzip electricitygrid_Africa_JRC.zip -d "Map Data/Grid Data/"
   unzip Local_Area.zip -d "Map Data/Local Area/"
   unzip Supply_Area.zip -d "Map Data/Supply Area/"
   unzip out_vnp46a2_sa_daily_2023_full_year.zip -d blackmarbler/
   ```

3. Run Stage 1 prep scripts to generate GeoPackages:
   ```bash
   Rscript "Map Data/Boundaries/SA_boundaries.r"
   Rscript "Map Data/Generators Data/gen_clean.r"
   Rscript "Map Data/Grid Data/grid_clean.r"
   Rscript settlements_cleaning/settlements_csv_to_gpkg.R
   ```

4. Then run the pipeline from Stage 2 onwards:
   ```bash
   Rscript "Builder/settlement_day_panel_build.R"
   # Continue with Stages 2b, 3, 4, 5, 6 as needed
   ```

---

## NASA Earthdata credentials

Stage 0 (`nightlight_downloader/viirs_daily_download.R`) and Stage 2c (`Visualizer/settlement_yearly_composite.R`) require a free NASA Earthdata account. Set credentials in `~/.Renviron`:

```
EARTHDATA_USER=your_username
EARTHDATA_PASS=your_password
```

Register at: https://urs.earthdata.nasa.gov/
