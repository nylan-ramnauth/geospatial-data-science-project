rm(list = ls())

# ============================================================
# Build Cape Town Daily Pixel State Rasters from VJ146A2
# Pixel-IQR Stage 3 - Daily observed/dark/excluded states
# ============================================================
#
# Purpose:  Applies the Cape Town pixel threshold baseline to each daily
#           VJ146A2 raster and writes compact daily state rasters.
# Inputs:   - pixel_iqr_pipeline/data/aoi/cape_town_vj146a2_processing_mask.tif
#           - pixel_iqr_pipeline/data/baseline/cape_town_vj146a2_YYYY_pixel_threshold_baseline.tif
#           - blackmarbler/out_vj146a2_sa_daily/vj146a2_sa_500m_daily_YYYY-MM-DD.tif
# Outputs:  - pixel_iqr_pipeline/data/daily_states/cape_town_pixel_iqr_state_YYYY-MM-DD.tif
# Run:      Rscript cape_town_schedule_validation/pixel_iqr_pipeline/scripts/03_build_cape_town_daily_pixel_state_rasters_vj146a2.R
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(terra)
})

# -----------------------------
# CONFIG
# -----------------------------
BASE_PATH <- here::here()
MODULE_DIR <- file.path(BASE_PATH, "cape_town_schedule_validation", "pixel_iqr_pipeline")

RAST_DIR <- Sys.getenv(
  "VJ146A2_RAST_DIR",
  file.path(BASE_PATH, "blackmarbler", "out_vj146a2_sa_daily")
)
START_MONTH <- Sys.getenv("VJ146A2_START_MONTH", "2023-01")
END_MONTH <- Sys.getenv("VJ146A2_END_MONTH", "2023-12")
YEAR_LABEL <- Sys.getenv("VJ146A2_YEAR", substr(START_MONTH, 1, 4))
MASK_TIF <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_MASK_TIF",
  file.path(MODULE_DIR, "data", "aoi", "cape_town_vj146a2_processing_mask.tif")
)
BASELINE_TIF <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_BASELINE_TIF",
  file.path(MODULE_DIR, "data", "baseline", paste0("cape_town_vj146a2_", YEAR_LABEL, "_pixel_threshold_baseline.tif"))
)
OUT_DIR <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_DAILY_STATE_DIR",
  file.path(MODULE_DIR, "data", "daily_states")
)
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

MAX_DATES_PER_MONTH <- suppressWarnings(as.integer(Sys.getenv("VJ146A2_MAX_DATES_PER_MONTH", "")))
if (!is.finite(MAX_DATES_PER_MONTH)) MAX_DATES_PER_MONTH <- NA_integer_
OVERWRITE <- Sys.getenv("VJ146A2_OVERWRITE", "1") != "0"

# -----------------------------
# HELPERS
# -----------------------------
get_date <- function(path) {
  m <- regexpr("[0-9]{4}-[0-9]{2}-[0-9]{2}", basename(path))
  if (m < 0) stop("Could not parse date from filename: ", basename(path))
  as.Date(regmatches(basename(path), m))
}

# -----------------------------
# RUN
# -----------------------------
if (!dir.exists(RAST_DIR)) stop("VJ146A2 raster directory not found: ", RAST_DIR)
if (!file.exists(MASK_TIF)) stop("Cape Town processing mask not found: ", MASK_TIF)
if (!file.exists(BASELINE_TIF)) stop("Pixel threshold baseline not found: ", BASELINE_TIF)

month_start <- as.Date(paste0(START_MONTH, "-01"))
month_end <- as.Date(paste0(END_MONTH, "-01"))
if (is.na(month_start) || is.na(month_end)) stop("Invalid START_MONTH/END_MONTH (use 'YYYY-MM').")
if (month_start > month_end) stop("START_MONTH must be <= END_MONTH.")
months_seq <- seq.Date(from = month_start, to = month_end, by = "month")
analysis_end <- seq.Date(from = month_end, by = "month", length.out = 2)[2] - 1

tifs <- list.files(RAST_DIR, pattern = "\\.tif$", full.names = TRUE, ignore.case = TRUE)
if (length(tifs) == 0) stop("No VJ146A2 GeoTIFFs found in: ", RAST_DIR)
tifs <- tifs[order(tifs)]
tif_dates <- as.Date(vapply(tifs, function(path) format(get_date(path), "%Y-%m-%d"), character(1)))
tif_map <- setNames(tifs, format(tif_dates, "%Y-%m-%d"))

mask <- terra::rast(MASK_TIF)
baseline <- terra::rast(BASELINE_TIF)
required_bands <- c(
  "lower_threshold_rad",
  "upper_threshold_rad",
  "baseline_ok",
  "upper_exclusion_enabled"
)
missing_bands <- setdiff(required_bands, names(baseline))
if (length(missing_bands) > 0) {
  stop("Baseline is missing bands: ", paste(missing_bands, collapse = ", "))
}
if (!terra::compareGeom(mask, baseline[[1]], stopOnError = FALSE)) {
  stop("Cape Town processing mask and baseline raster are not aligned.")
}

for (mi in seq_along(months_seq)) {
  m <- months_seq[mi]
  next_month <- seq.Date(from = m, by = "month", length.out = 2)[2]
  days_in_month <- seq.Date(from = m, to = next_month - 1, by = "day")
  days_in_month <- days_in_month[days_in_month >= month_start & days_in_month <= analysis_end]
  available_dates <- days_in_month[format(days_in_month, "%Y-%m-%d") %in% names(tif_map)]
  if (!is.na(MAX_DATES_PER_MONTH)) {
    available_dates <- head(available_dates, MAX_DATES_PER_MONTH)
  }

  if (length(available_dates) == 0) next

  for (i in seq_along(available_dates)) {
    d <- available_dates[i]
    d_str <- format(d, "%Y-%m-%d")
    f <- unname(tif_map[d_str])
    out_tif <- file.path(OUT_DIR, paste0("cape_town_pixel_iqr_state_", d_str, ".tif"))
    if (file.exists(out_tif) && !OVERWRITE) {
      message("Output exists and overwrite disabled; skipping ", d_str)
      next
    }

    message("[", d_str, "] Building Cape Town pixel-IQR state raster")
    r <- terra::rast(f)
    if (!all(c("rad", "valid") %in% names(r))) {
      stop("Raster missing rad/valid bands: ", basename(f))
    }
    rad <- terra::crop(r[["rad"]], mask, snap = "near")
    valid <- terra::crop(r[["valid"]], mask, snap = "near")
    if (!terra::compareGeom(rad, mask, stopOnError = FALSE)) {
      stop("Daily raster does not align with Cape Town mask: ", basename(f))
    }

    valid_binary <- terra::ifel(valid == 1 & !is.na(mask), 1, 0)
    baseline_ok <- baseline[["baseline_ok"]]
    lower_threshold_rad <- baseline[["lower_threshold_rad"]]
    upper_threshold_rad <- baseline[["upper_threshold_rad"]]
    upper_enabled <- terra::ifel(is.na(baseline[["upper_exclusion_enabled"]]), 0, baseline[["upper_exclusion_enabled"]])

    upper_ok <- terra::ifel(
      upper_enabled == 1,
      terra::ifel(rad <= upper_threshold_rad, 1, 0),
      1
    )
    observed_iqr <- terra::ifel(valid_binary == 1 & baseline_ok == 1 & upper_ok == 1, 1, 0)
    dark_iqr <- terra::ifel(observed_iqr == 1 & rad < lower_threshold_rad, 1, 0)
    bright_excluded_iqr <- terra::ifel(
      valid_binary == 1 & baseline_ok == 1 & upper_enabled == 1 & rad > upper_threshold_rad,
      1,
      0
    )
    rad_observed <- terra::ifel(observed_iqr == 1, rad, NA)

    state <- c(observed_iqr, dark_iqr, bright_excluded_iqr, rad_observed)
    names(state) <- c("observed_iqr", "dark_iqr", "bright_excluded_iqr", "rad_observed")
    terra::writeRaster(state, out_tif, overwrite = OVERWRITE, datatype = "FLT4S")
    message("Wrote: ", out_tif)
  }
}

message("Done.")
