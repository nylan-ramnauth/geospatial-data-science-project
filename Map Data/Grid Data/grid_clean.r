rm(list = ls())

suppressPackageStartupMessages({
  library(here)
  library(sf)
  library(dplyr)
  library(geodata)   # downloads GADM
})

sf::sf_use_s2(FALSE)

# -----------------------------
# PATHS (EDIT)
# -----------------------------

BASE_PATH <- here::here()

GRID_SHP <- file.path(BASE_PATH, "Map Data", "Grid Data", "electricitygrid_Africa_JRC", "elect_grid_africa_epsg3426_withgau_JRC.shp")
OUT_DIR  <- file.path(BASE_PATH, "Map Data", "Grid Data", "electricitygrid_Africa_JRC", "output_folder")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

OUT_GPKG <- file.path(OUT_DIR, "electricity_grid_south_africa.gpkg")

# -----------------------------
# 1) READ GRID
# -----------------------------
grid_africa <- st_read(GRID_SHP, quiet = TRUE)

# -----------------------------
# 2) DOWNLOAD SOUTH AFRICA BORDER (ADMIN-0) IN R
# -----------------------------
# level=0 = country border. Path controls where downloads are cached.
sa_spat <- geodata::gadm(country = "ZAF", level = 0, path = OUT_DIR)

# Convert to sf
sa <- st_as_sf(sa_spat)

# -----------------------------
# 3) ALIGN CRS + CLEAN
# -----------------------------
grid_africa <- st_transform(grid_africa, st_crs(sa))
grid_africa <- st_make_valid(grid_africa)
sa          <- st_make_valid(sa)

# -----------------------------
# 4) CLIP
# -----------------------------
grid_africa <- grid_africa[st_intersects(grid_africa, sa, sparse = FALSE), ]
grid_sa <- st_intersection(grid_africa, sa)

# -----------------------------
# 5) WRITE
# -----------------------------
st_write(grid_sa, OUT_GPKG, layer = "grid_sa", delete_layer = TRUE, quiet = TRUE)

cat("Done. Wrote:", OUT_GPKG, "\n")
