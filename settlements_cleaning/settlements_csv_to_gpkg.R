rm(list = ls())

# ============================================================
# Convert Settlements CSV (WKT) to GeoPackage
# Stage 1a — Spatial Layer Preparation
# ============================================================
#
# Purpose:  Reads the DRE Atlas settlements CSV (WKT geometry column),
#           adds a stable settlement_id join key, and writes full and
#           simplified GeoPackages for downstream computation and rendering.
# Inputs:   - settlements_cleaning/south_africa_dre_atlas_settlements.csv
# Outputs:  - Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_full_col.gpkg
#           - Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_simplified_full_col.gpkg
# Run:      Rscript settlements_cleaning/settlements_csv_to_gpkg.R
# ============================================================

library(here)
library(sf)
library(readr)
library(dplyr)

sf::sf_use_s2(FALSE)

# -----------------------------
# PATHS (EDIT)
# -----------------------------
BASE_PATH <- here::here()

IN_CSV         <- file.path(BASE_PATH, "settlements_cleaning", "south_africa_dre_atlas_settlements.csv")
OUT_GPKG       <- file.path(BASE_PATH, "Map Data", "Settlements", "GPKG", "south_africa_dre_atlas_settlements_full_col.gpkg")
OUT_SIMPL_GPKG <- file.path(BASE_PATH, "Map Data", "Settlements", "GPKG", "south_africa_dre_atlas_settlements_simplified_full_col.gpkg")

# -----------------------------
# USER: SELECT COLUMNS TO KEEP
# -----------------------------
# KEEP_COLS controls which attributes are preserved in the GeoPackages.
# Always required for this pipeline:
# - "geometry"       (WKT polygon column used to create sf geometry)
# - "settlement_id"  (join key created below)
#
# Alternative: set KEEP_COLS <- NULL to keep ALL columns from the CSV.
KEEP_COLS <- NULL
#KEEP_COLS <- c(
#  "lat",
#  "lon",
#  "village_name",
#  "admin_cgaz_1",
#  "admin_cgaz_2",
#  "main_road_access",
#  "population",
#  "demand",
#  "has_nightlight",
#  "security_risk"
#)

# Optional: rename columns to a canonical schema used everywhere downstream
# Left-hand side: original CSV column
# Right-hand side: new name
#RENAME_COLS <- c(
#  lat              = "lat",
#  village_name     = "name",
#  admin_cgaz_1     = "region",
#  admin_cgaz_2     = "district",
#  hull_area        = "area_m2",
#  main_road_access = "road_access",
#  population       = "population",
#  demand           = "demand_kwh_day",
#  has_nightlight   = "has_nightlight_prior",
#  security_risk    = "security_risk"
#)

# -----------------------------
# USER: SIMPLIFICATION
# -----------------------------
# Simplification tolerance (meters). Larger values reduce file size and speed up rendering,
# but can distort small polygons.
# Alternatives: 25m (more faithful), 100–200m (more aggressive).
SIMPLIFY_TOL_M <- 50

# -----------------------------
# 1) READ CSV
# -----------------------------
sett_raw <- read_csv(IN_CSV, show_col_types = FALSE)

# Create join key based on row order (only stable if the row order never changes)
# Alternative (recommended): use a stable source ID or a hash-based ID.
sett_raw <- sett_raw %>%
  mutate(settlement_id = row_number())

# Sanity checks: join key must exist and be unique
stopifnot(!anyNA(sett_raw$settlement_id))
stopifnot(!anyDuplicated(sett_raw$settlement_id))

# -----------------------------
# 2) SELECT + RENAME ATTRIBUTES
# -----------------------------
if (!is.null(KEEP_COLS)) {
  required <- c("settlement_id", "geometry")  # required for pipeline integrity
  keep <- unique(c(required, KEEP_COLS))
  
  missing <- setdiff(keep, names(sett_raw))
  if (length(missing) > 0) {
    stop("These requested columns are not present in the CSV: ", paste(missing, collapse = ", "))
  }
  
  sett_raw <- sett_raw %>% select(all_of(keep))
}

# Apply renaming (only affects columns that exist)
# Alternative: skip renaming if you want to keep original schema
#sett_raw <- sett_raw %>% rename(any_of(RENAME_COLS))

# -----------------------------
# 3) CSV (WKT) -> sf
# -----------------------------
# Convert WKT column ("geometry") into an sf geometry column.
# CRS is WGS84 lon/lat (EPSG:4326).
sett_sf <- st_as_sf(sett_raw, wkt = "geometry", crs = 4326) %>%
  st_make_valid()

# -----------------------------
# 4) WRITE FULL (CANONICAL) GPKG
# -----------------------------
# Use this file for computation (accurate geometry).
st_write(
  sett_sf,
  OUT_GPKG,
  layer = "settlements",
  delete_layer = TRUE,
  quiet = TRUE
)

# -----------------------------
# 5) WRITE SIMPLIFIED GPKG (RENDERING)
# -----------------------------
# Simplify in a metric CRS so dTolerance is in meters (EPSG:3857).
sett_simp <- sett_sf %>%
  st_transform(3857) %>%
  st_simplify(dTolerance = SIMPLIFY_TOL_M, preserveTopology = TRUE) %>%
  st_make_valid() %>%
  st_transform(4326)

st_write(
  sett_simp,
  OUT_SIMPL_GPKG,
  layer = "settlements_simplified",
  delete_layer = TRUE,
  quiet = TRUE
)

cat("Wrote full settlements:      ", OUT_GPKG, "\n")
cat("Wrote simplified settlements:", OUT_SIMPL_GPKG, "\n")
