rm(list = ls())

# ============================================================
# Prepare Cape Town Pixel AOI for VJ146A2 Pixel-IQR Pipeline
# Pixel-IQR Stage 1 - AOI and raster mask
# ============================================================
#
# Purpose:  Selects Cape Town load-shedding blocks and builds a raster mask
#           on the VJ146A2 grid. The mask keeps pixels touching the selected
#           polygons, so later pixel-threshold work is Cape Town-only.
# Inputs:   - cape_town_schedule_validation/data/inputs/load_shedding_area.geojson
#           - blackmarbler/out_vj146a2_sa_daily/vj146a2_sa_500m_daily_YYYY-MM-DD.tif
# Outputs:  - pixel_iqr_pipeline/data/aoi/cape_town_city_schedule_blocks.geojson
#           - pixel_iqr_pipeline/data/aoi/cape_town_vj146a2_processing_mask.tif
# Run:      Rscript cape_town_schedule_validation/pixel_iqr_pipeline/scripts/01_prepare_cape_town_pixel_aoi_vj146a2.R
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(sf)
  library(dplyr)
  library(terra)
})

sf::sf_use_s2(FALSE)

# -----------------------------
# CONFIG
# -----------------------------
BASE_PATH <- here::here()
PARENT_MODULE_DIR <- file.path(BASE_PATH, "cape_town_schedule_validation")
MODULE_DIR <- file.path(PARENT_MODULE_DIR, "pixel_iqr_pipeline")

LOAD_SHEDDING_AREA_GEOJSON <- Sys.getenv(
  "CAPE_TOWN_LOAD_SHEDDING_AREA_GEOJSON",
  file.path(PARENT_MODULE_DIR, "data", "inputs", "load_shedding_area.geojson")
)
RAST_DIR <- Sys.getenv(
  "VJ146A2_RAST_DIR",
  file.path(BASE_PATH, "blackmarbler", "out_vj146a2_sa_daily")
)
OUT_DIR <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_AOI_DIR",
  file.path(MODULE_DIR, "data", "aoi")
)
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

START_MONTH <- Sys.getenv("VJ146A2_START_MONTH", "2023-01")
END_MONTH <- Sys.getenv("VJ146A2_END_MONTH", "2023-12")
CAPE_TOWN_BLOCK_IDS_SPEC <- Sys.getenv("CAPE_TOWN_BLOCK_IDS", "1:16")
OVERWRITE <- Sys.getenv("VJ146A2_OVERWRITE", "1") != "0"

# -----------------------------
# HELPERS
# -----------------------------
get_date <- function(path) {
  m <- regexpr("[0-9]{4}-[0-9]{2}-[0-9]{2}", basename(path))
  if (m < 0) stop("Could not parse date from filename: ", basename(path))
  as.Date(regmatches(basename(path), m))
}

parse_id_spec <- function(spec) {
  pieces <- unlist(strsplit(spec, ",", fixed = TRUE))
  ids <- integer()
  for (piece in pieces) {
    piece <- trimws(piece)
    if (!nzchar(piece)) next
    if (grepl("^-?[0-9]+:-?[0-9]+$", piece)) {
      bounds <- as.integer(strsplit(piece, ":", fixed = TRUE)[[1]])
      ids <- c(ids, seq.int(bounds[1], bounds[2]))
    } else {
      ids <- c(ids, as.integer(piece))
    }
  }
  ids <- sort(unique(ids[is.finite(ids)]))
  if (length(ids) == 0) stop("No valid block IDs parsed from CAPE_TOWN_BLOCK_IDS=", spec)
  ids
}

normalize_block_id <- function(x) {
  if (is.numeric(x) || is.integer(x)) return(as.integer(x))
  suppressWarnings(as.integer(gsub("[^0-9-]", "", as.character(x))))
}

# -----------------------------
# RUN
# -----------------------------
if (!file.exists(LOAD_SHEDDING_AREA_GEOJSON)) {
  stop("Cape Town load-shedding GeoJSON not found: ", LOAD_SHEDDING_AREA_GEOJSON)
}
if (!dir.exists(RAST_DIR)) stop("VJ146A2 raster directory not found: ", RAST_DIR)

month_start <- as.Date(paste0(START_MONTH, "-01"))
month_end <- as.Date(paste0(END_MONTH, "-01"))
if (is.na(month_start) || is.na(month_end)) stop("Invalid START_MONTH/END_MONTH (use 'YYYY-MM').")
if (month_start > month_end) stop("START_MONTH must be <= END_MONTH.")
analysis_end <- seq.Date(from = month_end, by = "month", length.out = 2)[2] - 1

tifs <- list.files(RAST_DIR, pattern = "\\.tif$", full.names = TRUE, ignore.case = TRUE)
if (length(tifs) == 0) stop("No VJ146A2 GeoTIFFs found in: ", RAST_DIR)
tifs <- tifs[order(tifs)]
tif_dates <- as.Date(vapply(tifs, function(path) format(get_date(path), "%Y-%m-%d"), character(1)))
in_range <- tif_dates >= month_start & tif_dates <= analysis_end
if (!any(in_range)) {
  stop("No VJ146A2 rasters found in date range ", START_MONTH, " to ", END_MONTH, ".")
}

block_ids <- parse_id_spec(CAPE_TOWN_BLOCK_IDS_SPEC)
blocks <- sf::st_read(LOAD_SHEDDING_AREA_GEOJSON, quiet = TRUE)
if (!"BlockID" %in% names(blocks)) stop("GeoJSON is missing BlockID.")
blocks <- blocks %>%
  mutate(BlockID_int = normalize_block_id(BlockID)) %>%
  filter(BlockID_int %in% block_ids)
if (nrow(blocks) == 0) {
  stop("No load-shedding polygons matched CAPE_TOWN_BLOCK_IDS=", CAPE_TOWN_BLOCK_IDS_SPEC)
}

blocks <- sf::st_make_valid(blocks)
blocks_out <- blocks %>%
  select(any_of(c("BlockID", "BlockID_int")), geometry)

r0 <- terra::rast(tifs[which(in_range)[1]])
if (is.na(terra::crs(r0))) stop("Raster CRS is missing.")

blocks_raster_crs <- sf::st_transform(blocks_out, terra::crs(r0))
blocks_vect <- terra::vect(blocks_raster_crs)
template <- terra::crop(r0[[1]], blocks_vect, snap = "out")
mask <- terra::rasterize(
  blocks_vect,
  template,
  field = 1,
  touches = TRUE,
  background = NA
)
names(mask) <- "cape_town_processing_mask"

out_blocks <- file.path(OUT_DIR, "cape_town_city_schedule_blocks.geojson")
out_mask <- file.path(OUT_DIR, "cape_town_vj146a2_processing_mask.tif")

sf::st_write(
  sf::st_transform(blocks_out, 4326),
  out_blocks,
  delete_dsn = OVERWRITE,
  quiet = TRUE
)
terra::writeRaster(mask, out_mask, overwrite = OVERWRITE, datatype = "INT1U")

message("Selected BlockID values: ", paste(block_ids, collapse = ", "))
message("AOI polygons retained: ", nrow(blocks_out))
message("Mask cells retained: ", terra::global(!is.na(mask), "sum", na.rm = TRUE)[1, 1])
message("Wrote AOI GeoJSON: ", out_blocks)
message("Wrote processing mask: ", out_mask)

