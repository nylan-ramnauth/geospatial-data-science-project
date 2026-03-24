rm(list = ls())

suppressPackageStartupMessages({
  library(here)     # portable paths
  library(geodata)  # downloads GADM
  library(terra)    # geodata returns SpatVector
  library(sf)       # write to gpkg/shp
})

sf::sf_use_s2(FALSE)

# -----------------------------
# PATHS (EDIT)
# -----------------------------
BASE_PATH <- here::here()

OUT_DIR <- file.path(BASE_PATH, "Map Data", "Boundaries", "boundaries_outputs")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

OUT_GPKG <- file.path(OUT_DIR, "south_africa_admin_boundaries_GADM.gpkg")

# Optional Shapefile outputs (creates multiple files)
OUT_SHP0 <- file.path(OUT_DIR, "south_africa_admin0.shp")
OUT_SHP1 <- file.path(OUT_DIR, "south_africa_admin1.shp")
OUT_SHP2 <- file.path(OUT_DIR, "south_africa_admin2.shp")

# -----------------------------
# 1) DOWNLOAD GADM BOUNDARIES
# -----------------------------
# level = 0: country
# level = 1: provinces
# level = 2: districts (or comparable)
sa0 <- geodata::gadm(country = "ZAF", level = 0, path = OUT_DIR)
sa1 <- geodata::gadm(country = "ZAF", level = 1, path = OUT_DIR)
sa2 <- geodata::gadm(country = "ZAF", level = 2, path = OUT_DIR)

# -----------------------------
# 2) CONVERT TO sf
# -----------------------------
sa0_sf <- st_as_sf(sa0)
sa1_sf <- st_as_sf(sa1)
sa2_sf <- st_as_sf(sa2)

# -----------------------------
# 3) WRITE GEOPACKAGE (QGIS-FRIENDLY)
# -----------------------------
# One GeoPackage with multiple layers
st_write(sa0_sf, OUT_GPKG, layer = "admin0_country", delete_layer = TRUE, quiet = TRUE)
st_write(sa1_sf, OUT_GPKG, layer = "admin1_provinces", delete_layer = TRUE, quiet = TRUE)
st_write(sa2_sf, OUT_GPKG, layer = "admin2_districts", delete_layer = TRUE, quiet = TRUE)

# -----------------------------
# 4) OPTIONAL: ALSO WRITE SHAPEFILES
# -----------------------------
st_write(sa0_sf, OUT_SHP0, delete_dsn = TRUE, quiet = TRUE)
st_write(sa1_sf, OUT_SHP1, delete_dsn = TRUE, quiet = TRUE)
st_write(sa2_sf, OUT_SHP2, delete_dsn = TRUE, quiet = TRUE)

cat("Done.\n")
cat("Wrote GeoPackage:\n - ", OUT_GPKG, "\n", sep = "")
cat("Optional Shapefiles:\n - ", OUT_SHP0, "\n - ", OUT_SHP1, "\n - ", OUT_SHP2, "\n", sep = "")
