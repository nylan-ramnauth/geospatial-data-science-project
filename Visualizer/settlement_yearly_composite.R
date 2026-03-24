# ============================================================
# Settlement Yearly Composite Calibration
# Stage 2c — Annual Cross-Check / Calibration
# ============================================================
#
# Purpose:  Downloads the VNP46A4 annual composite from blackmarbler,
#           extracts settlement-level stats, and sweeps over lit thresholds
#           to find the value that best matches the official SA electrification
#           target population share.
# Inputs:   - Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_full_col.gpkg
#           - blackmarbler annual VNP46A4 tile (downloaded at runtime)
# Outputs:  - Map Data/reliability_outputs_blackmarbler/yearly_composite_calibration_YYYY.csv
#           - Map Data/reliability_outputs_blackmarbler/yearly_settlement_stats_YYYY.parquet
#           - Map Data/reliability_outputs_blackmarbler/yearly_settlement_classification_best_YYYY.gpkg
# Run:      Rscript Visualizer/settlement_yearly_composite.R
# ============================================================

rm(list = ls())

suppressPackageStartupMessages({
  library(here)
  library(sf)
  library(terra)
  library(blackmarbler)
  library(exactextractr)
  library(data.table)
})

sf::sf_use_s2(FALSE)

# ------------------------------------------------------------
# CONFIG
# ------------------------------------------------------------
BASE_PATH <- here::here()

SETT_GPKG <- file.path(
  BASE_PATH, "Map Data", "Settlements", "GPKG", "south_africa_dre_atlas_settlements_full_col.gpkg"
)

OUT_DIR <- file.path(BASE_PATH, "Map Data", "reliability_outputs_blackmarbler")
YEAR_LABEL <- "2023"

TARGET_POP_SHARE <- 0.877
PIXEL_LIT_THRESHOLD <- 2
SETTLEMENT_LIT_THRESHOLDS <- seq(0.05, 0.95, by = 0.01)
MIN_COVERAGE_SHARE <- 0.50
POP_FIELD <- "population"

# BlackMarbler yearly composite config (QF==0)
BM_PRODUCT_ID <- "VNP46A4"
BM_DATE <- YEAR_LABEL
BM_VARIABLE <- "NearNadir_Composite_Snow_Free"
BM_QUALITY_FLAG_RM <- c(1L, 2L) # keep only quality flag 0
BM_H5_CACHE <- file.path(BASE_PATH, "blackmarbler", "out_vnp46a2_sa_daily", "h5_cache_annual")

TILES_URL <- "https://raw.githubusercontent.com/worldbank/blackmarbler/main/data/blackmarbletiles.geojson"
TILES_PATH <- file.path(BASE_PATH, "blackmarbler", "blackmarbletiles.geojson")

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(BM_H5_CACHE, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(SETT_GPKG)) stop("Settlements file not found: ", SETT_GPKG)

patch_blackmarbler_tiles <- function(tiles_url, tiles_path) {
  if (!file.exists(tiles_path)) return(invisible(FALSE))
  ns <- asNamespace("blackmarbler")
  objs <- ls(envir = ns, all.names = TRUE)
  hit_fns <- Filter(function(nm) {
    obj <- tryCatch(get(nm, envir = ns), error = function(e) NULL)
    if (!is.function(obj)) return(FALSE)
    txt <- paste(deparse(body(obj)), collapse = "\n")
    grepl(tiles_url, txt, fixed = TRUE)
  }, objs)
  if (length(hit_fns) == 0) return(invisible(FALSE))
  for (nm in hit_fns) {
    f <- get(nm, envir = ns)
    f_txt <- paste(deparse(body(f)), collapse = "\n")
    f_txt2 <- gsub(tiles_url, tiles_path, f_txt, fixed = TRUE)
    f2 <- f
    body(f2) <- parse(text = f_txt2)
    unlockBinding(nm, ns)
    assign(nm, f2, envir = ns)
    lockBinding(nm, ns)
  }
  invisible(TRUE)
}

# ------------------------------------------------------------
# LOAD
# ------------------------------------------------------------
cat("Reading settlements...\n")
sett <- sf::st_read(SETT_GPKG, quiet = TRUE)
if (!("settlement_id" %in% names(sett))) stop("settlement_id missing in settlements.")
if (!(POP_FIELD %in% names(sett))) stop("Population field missing in settlements: ", POP_FIELD)

sett$settlement_id <- as.character(sett$settlement_id)
sett[[POP_FIELD]] <- as.numeric(sett[[POP_FIELD]])
sett[[POP_FIELD]][is.na(sett[[POP_FIELD]])] <- 0
sett <- sf::st_make_valid(sett)

patch_blackmarbler_tiles(TILES_URL, TILES_PATH)

bearer <- blackmarbler::get_nasa_token(
  username = Sys.getenv("EARTHDATA_USER"),
  password = Sys.getenv("EARTHDATA_PASS")
)
if (!nzchar(bearer)) stop("Could not retrieve NASA bearer token.")

cat("Downloading yearly composite from blackmarbler...\n")
roi_sf <- sf::st_sf(id = 1L, geometry = sf::st_as_sfc(sf::st_bbox(sett)))

rad <- blackmarbler::bm_raster(
  roi_sf = roi_sf,
  product_id = BM_PRODUCT_ID,
  date = BM_DATE,
  bearer = bearer,
  variable = BM_VARIABLE,
  quality_flag_rm = BM_QUALITY_FLAG_RM,
  output_location_type = "memory",
  h5_dir = BM_H5_CACHE,
  quiet = TRUE
)

if (!inherits(rad, "SpatRaster")) {
  stop("Blackmarbler download failed for ", BM_PRODUCT_ID, " ", BM_DATE)
}
if (terra::nlyr(rad) > 1) {
  cat("Downloaded raster has", terra::nlyr(rad), "bands. Using first band only.\n")
  rad <- rad[[1]]
}
names(rad) <- "rad"

if (is.na(sf::st_crs(sett))) stop("Settlements CRS is missing.")
if (!identical(sf::st_crs(sett)$wkt, sf::st_crs(terra::crs(rad))$wkt)) {
  cat("Reprojecting settlements to raster CRS...\n")
  sett <- sf::st_transform(sett, terra::crs(rad))
}

# ------------------------------------------------------------
# SETTLEMENT-LEVEL STATS FROM YEARLY COMPOSITE
# ------------------------------------------------------------
cat("Extracting settlement-level raster stats...\n")
valid <- terra::ifel(is.na(rad), 0, 1)
lit <- terra::ifel(is.na(rad), 0, terra::ifel(rad >= PIXEL_LIT_THRESHOLD, 1, 0))
allpix <- terra::setValues(terra::rast(rad), 1)

mean_rad <- exactextractr::exact_extract(rad, sett, "mean", progress = TRUE)
lit_weight <- exactextractr::exact_extract(lit, sett, "sum", progress = TRUE)
valid_weight <- exactextractr::exact_extract(valid, sett, "sum", progress = TRUE)
total_weight <- exactextractr::exact_extract(allpix, sett, "sum", progress = TRUE)

sett_stats <- data.table(
  settlement_id = sett$settlement_id,
  population = sett[[POP_FIELD]],
  mean_rad = as.numeric(mean_rad),
  lit_weight = as.numeric(lit_weight),
  valid_weight = as.numeric(valid_weight),
  total_weight = as.numeric(total_weight)
)

sett_stats[, coverage_share := fifelse(total_weight > 0, valid_weight / total_weight, NA_real_)]
sett_stats[, p_lit_sett_year := fifelse(valid_weight > 0, lit_weight / valid_weight, NA_real_)]
sett_stats[, support_ok := !is.na(p_lit_sett_year) & !is.na(coverage_share) & coverage_share >= MIN_COVERAGE_SHARE]

pop_total <- sett_stats[, sum(population, na.rm = TRUE)]
n_total <- nrow(sett_stats)

if (!is.finite(pop_total) || pop_total <= 0) stop("Total population is zero or invalid.")

# ------------------------------------------------------------
# THRESHOLD SWEEP (CALIBRATION)
# ------------------------------------------------------------
cat("Running threshold sweep...\n")
calib <- rbindlist(lapply(SETTLEMENT_LIT_THRESHOLDS, function(th) {
  elect <- sett_stats$support_ok & sett_stats$p_lit_sett_year >= th
  n_elect <- sum(elect, na.rm = TRUE)
  pop_elect <- sum(sett_stats$population[elect], na.rm = TRUE)
  share_pop <- pop_elect / pop_total

  data.table(
    year = YEAR_LABEL,
    yearly_tif = paste(BM_PRODUCT_ID, BM_DATE, BM_VARIABLE, "qf0", sep = "_"),
    pixel_lit_threshold = PIXEL_LIT_THRESHOLD,
    settlement_lit_threshold = th,
    min_coverage_share = MIN_COVERAGE_SHARE,
    n_settlements_total = n_total,
    n_settlements_support_ok = sum(sett_stats$support_ok, na.rm = TRUE),
    n_settlements_electrified = n_elect,
    share_settlements_electrified = n_elect / n_total,
    population_total = pop_total,
    population_electrified = pop_elect,
    share_population_electrified = share_pop,
    target_population_share = TARGET_POP_SHARE,
    abs_error = abs(share_pop - TARGET_POP_SHARE)
  )
}))

setorder(calib, abs_error, -share_population_electrified)
best <- calib[1]

cat("\nBest threshold summary:\n")
print(best)

# ------------------------------------------------------------
# SAVE OUTPUTS
# ------------------------------------------------------------
calib_csv <- file.path(OUT_DIR, paste0("yearly_composite_calibration_", YEAR_LABEL, ".csv"))
fwrite(calib, calib_csv)
cat("Wrote:", calib_csv, "\n")

sett_stats[, electrified_best := as.integer(support_ok & p_lit_sett_year >= best$settlement_lit_threshold)]
sett_stats[, pixel_lit_threshold_best := best$pixel_lit_threshold]
sett_stats[, settlement_lit_threshold_best := best$settlement_lit_threshold]
sett_stats[, target_population_share := TARGET_POP_SHARE]

stats_csv <- file.path(OUT_DIR, paste0("yearly_settlement_stats_", YEAR_LABEL, ".csv"))
fwrite(sett_stats, stats_csv)
cat("Wrote:", stats_csv, "\n")

if (requireNamespace("arrow", quietly = TRUE)) {
  stats_parq <- file.path(OUT_DIR, paste0("yearly_settlement_stats_", YEAR_LABEL, ".parquet"))
  arrow::write_parquet(sett_stats, stats_parq)
  cat("Wrote:", stats_parq, "\n")
}

sett_out <- sett[, c("settlement_id", POP_FIELD, "geom")]
names(sett_out)[names(sett_out) == "geom"] <- attr(sett, "sf_column")
sett_out <- merge(sett_out, sett_stats, by = "settlement_id", all.x = TRUE, sort = FALSE)

gpkg_out <- file.path(OUT_DIR, paste0("yearly_settlement_classification_best_", YEAR_LABEL, ".gpkg"))
sf::st_write(sett_out, gpkg_out, layer = "settlement_yearly_best", delete_layer = TRUE, quiet = TRUE)
cat("Wrote:", gpkg_out, "\n")

cat("\nDone.\n")
