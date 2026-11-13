rm(list = ls())

# ============================================================
# Build Cape Town Pixel Threshold Baseline from Daily VJ146A2 GeoTIFFs
# Pixel-IQR Stage 2 - Pixel baseline thresholds
# ============================================================
#
# Purpose:  Computes per-pixel annual radiance quantiles and configurable
#           lower/upper thresholds inside the Cape Town AOI mask. Defaults
#           are Tukey fences: lower = Q1 - 1.5 IQR and upper = Q3 + 1.5 IQR.
# Inputs:   - pixel_iqr_pipeline/data/aoi/cape_town_vj146a2_processing_mask.tif
#           - blackmarbler/out_vj146a2_sa_daily/vj146a2_sa_500m_daily_YYYY-MM-DD.tif
# Outputs:  - pixel_iqr_pipeline/data/baseline/cape_town_vj146a2_YYYY_pixel_threshold_baseline.tif
#           - matching baseline config CSV
# Run:      Rscript cape_town_schedule_validation/pixel_iqr_pipeline/scripts/02_build_cape_town_pixel_threshold_baseline_vj146a2.R
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(dplyr)
  library(terra)
})

# -----------------------------
# CONFIG HELPERS
# -----------------------------
parse_optional_number <- function(x) {
  if (is.na(x) || !nzchar(trimws(x))) return(NA_real_)
  suppressWarnings(as.numeric(x))
}

# -----------------------------
# CONFIG
# -----------------------------
BASE_PATH <- here::here()
MODULE_DIR <- file.path(BASE_PATH, "cape_town_schedule_validation", "pixel_iqr_pipeline")

RAST_DIR <- Sys.getenv(
  "VJ146A2_RAST_DIR",
  file.path(BASE_PATH, "blackmarbler", "out_vj146a2_sa_daily")
)
MASK_TIF <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_MASK_TIF",
  file.path(MODULE_DIR, "data", "aoi", "cape_town_vj146a2_processing_mask.tif")
)
OUT_DIR <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_BASELINE_DIR",
  file.path(MODULE_DIR, "data", "baseline")
)
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

START_MONTH <- Sys.getenv("VJ146A2_START_MONTH", "2023-01")
END_MONTH <- Sys.getenv("VJ146A2_END_MONTH", "2023-12")
YEAR_LABEL <- Sys.getenv("VJ146A2_YEAR", substr(START_MONTH, 1, 4))

LOWER_THRESHOLD_MODE <- Sys.getenv("VJ146A2_PIXEL_DARK_THRESHOLD_MODE", "tukey_lower")
LOWER_QUANTILE <- as.numeric(Sys.getenv("VJ146A2_PIXEL_DARK_LOWER_QUANTILE", "0.25"))
LOWER_IQR_K <- as.numeric(Sys.getenv("VJ146A2_PIXEL_DARK_IQR_K", "1.5"))
LOWER_ABSOLUTE_OVERRIDE <- parse_optional_number(Sys.getenv("VJ146A2_PIXEL_DARK_ABSOLUTE_THRESHOLD", ""))

UPPER_THRESHOLD_MODE <- Sys.getenv("VJ146A2_PIXEL_BRIGHT_THRESHOLD_MODE", "tukey_upper")
UPPER_QUANTILE <- as.numeric(Sys.getenv("VJ146A2_PIXEL_BRIGHT_UPPER_QUANTILE", "0.75"))
UPPER_IQR_K <- as.numeric(Sys.getenv("VJ146A2_PIXEL_BRIGHT_IQR_K", "1.5"))
UPPER_ABSOLUTE_OVERRIDE <- parse_optional_number(Sys.getenv("VJ146A2_PIXEL_BRIGHT_ABSOLUTE_THRESHOLD", ""))

MIN_PIXEL_VALID_DAYS <- as.integer(Sys.getenv("VJ146A2_PIXEL_IQR_MIN_VALID_DAYS", "60"))
OVERWRITE <- Sys.getenv("VJ146A2_OVERWRITE", "1") != "0"

# -----------------------------
# HELPERS
# -----------------------------
get_date <- function(path) {
  m <- regexpr("[0-9]{4}-[0-9]{2}-[0-9]{2}", basename(path))
  if (m < 0) stop("Could not parse date from filename: ", basename(path))
  as.Date(regmatches(basename(path), m))
}

pixel_quantile_fun <- function(prob, min_valid_days) {
  force(prob)
  force(min_valid_days)
  function(x) {
    x <- x[is.finite(x)]
    if (length(x) < min_valid_days) return(NA_real_)
    as.numeric(stats::quantile(x, probs = prob, type = 7, names = FALSE, na.rm = TRUE))
  }
}

constant_like <- function(template, value, name) {
  out <- template
  terra::values(out) <- value
  names(out) <- name
  out
}

validate_config <- function() {
  lower_modes <- c("tukey_lower", "quantile", "absolute")
  upper_modes <- c("tukey_upper", "quantile", "absolute", "none")
  if (!(LOWER_THRESHOLD_MODE %in% lower_modes)) {
    stop("Invalid VJ146A2_PIXEL_DARK_THRESHOLD_MODE. Expected one of: ", paste(lower_modes, collapse = ", "))
  }
  if (!(UPPER_THRESHOLD_MODE %in% upper_modes)) {
    stop("Invalid VJ146A2_PIXEL_BRIGHT_THRESHOLD_MODE. Expected one of: ", paste(upper_modes, collapse = ", "))
  }
  if (!is.finite(LOWER_QUANTILE) || LOWER_QUANTILE <= 0 || LOWER_QUANTILE >= 1) {
    stop("Invalid VJ146A2_PIXEL_DARK_LOWER_QUANTILE; expected value in (0, 1).")
  }
  if (!is.finite(UPPER_QUANTILE) || UPPER_QUANTILE <= 0 || UPPER_QUANTILE >= 1) {
    stop("Invalid VJ146A2_PIXEL_BRIGHT_UPPER_QUANTILE; expected value in (0, 1).")
  }
  if (LOWER_QUANTILE >= UPPER_QUANTILE) {
    stop("Lower quantile must be less than upper quantile.")
  }
  if (!is.finite(LOWER_IQR_K) || LOWER_IQR_K < 0) stop("Invalid lower IQR k.")
  if (!is.finite(UPPER_IQR_K) || UPPER_IQR_K < 0) stop("Invalid upper IQR k.")
  if (LOWER_THRESHOLD_MODE == "absolute" && !is.finite(LOWER_ABSOLUTE_OVERRIDE)) {
    stop("Lower absolute mode requires VJ146A2_PIXEL_DARK_ABSOLUTE_THRESHOLD.")
  }
  if (UPPER_THRESHOLD_MODE == "absolute" && !is.finite(UPPER_ABSOLUTE_OVERRIDE)) {
    stop("Upper absolute mode requires VJ146A2_PIXEL_BRIGHT_ABSOLUTE_THRESHOLD.")
  }
  if (!is.finite(MIN_PIXEL_VALID_DAYS) || MIN_PIXEL_VALID_DAYS <= 0) {
    stop("Invalid VJ146A2_PIXEL_IQR_MIN_VALID_DAYS.")
  }
  invisible(TRUE)
}

# -----------------------------
# RUN
# -----------------------------
validate_config()
if (!dir.exists(RAST_DIR)) stop("VJ146A2 raster directory not found: ", RAST_DIR)
if (!file.exists(MASK_TIF)) {
  stop("Cape Town processing mask not found: ", MASK_TIF, "\nRun script 01 first.")
}
if (!grepl("^\\d{4}$", YEAR_LABEL)) stop("Invalid VJ146A2_YEAR; expected YYYY.")

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
tifs <- tifs[in_range]
tif_dates <- tif_dates[in_range]
if (length(tifs) == 0) {
  stop("No VJ146A2 rasters found in date range ", START_MONTH, " to ", END_MONTH, ".")
}

mask <- terra::rast(MASK_TIF)
names(mask) <- "cape_town_processing_mask"
rad_layers <- vector("list", length(tifs))

for (i in seq_along(tifs)) {
  d_str <- format(tif_dates[i], "%Y-%m-%d")
  message("[", i, "/", length(tifs), "] Reading Cape Town radiance for ", d_str)
  r <- terra::rast(tifs[i])
  if (!all(c("rad", "valid") %in% names(r))) {
    stop("Raster missing rad/valid bands: ", basename(tifs[i]))
  }
  rad <- terra::crop(r[["rad"]], mask, snap = "near")
  valid <- terra::crop(r[["valid"]], mask, snap = "near")
  if (!terra::compareGeom(rad, mask, stopOnError = FALSE)) {
    stop("Daily raster does not align with Cape Town mask: ", basename(tifs[i]))
  }
  rad_valid <- terra::ifel(valid == 1 & !is.na(mask), rad, NA)
  names(rad_valid) <- paste0("rad_", d_str)
  rad_layers[[i]] <- rad_valid
}

rad_stack <- do.call(c, rad_layers)
n_valid_days <- terra::app(rad_stack, fun = function(x) sum(is.finite(x)))
names(n_valid_days) <- "n_valid_days"

q_lower <- terra::app(rad_stack, fun = pixel_quantile_fun(LOWER_QUANTILE, MIN_PIXEL_VALID_DAYS))
names(q_lower) <- "q_lower_rad"
q_upper <- terra::app(rad_stack, fun = pixel_quantile_fun(UPPER_QUANTILE, MIN_PIXEL_VALID_DAYS))
names(q_upper) <- "q_upper_rad"
iqr_rad <- q_upper - q_lower
names(iqr_rad) <- "iqr_rad"

if (is.finite(LOWER_ABSOLUTE_OVERRIDE)) {
  lower_threshold_rad <- constant_like(q_lower, LOWER_ABSOLUTE_OVERRIDE, "lower_threshold_rad")
} else if (LOWER_THRESHOLD_MODE == "tukey_lower") {
  lower_threshold_rad <- q_lower - LOWER_IQR_K * iqr_rad
  names(lower_threshold_rad) <- "lower_threshold_rad"
} else if (LOWER_THRESHOLD_MODE == "quantile") {
  lower_threshold_rad <- q_lower
  names(lower_threshold_rad) <- "lower_threshold_rad"
} else if (LOWER_THRESHOLD_MODE == "absolute") {
  lower_threshold_rad <- constant_like(q_lower, LOWER_ABSOLUTE_OVERRIDE, "lower_threshold_rad")
}

upper_exclusion_enabled <- constant_like(q_upper, ifelse(UPPER_THRESHOLD_MODE == "none" && !is.finite(UPPER_ABSOLUTE_OVERRIDE), 0, 1), "upper_exclusion_enabled")
if (is.finite(UPPER_ABSOLUTE_OVERRIDE)) {
  upper_threshold_rad <- constant_like(q_upper, UPPER_ABSOLUTE_OVERRIDE, "upper_threshold_rad")
  upper_exclusion_enabled <- constant_like(q_upper, 1, "upper_exclusion_enabled")
} else if (UPPER_THRESHOLD_MODE == "tukey_upper") {
  upper_threshold_rad <- q_upper + UPPER_IQR_K * iqr_rad
  names(upper_threshold_rad) <- "upper_threshold_rad"
} else if (UPPER_THRESHOLD_MODE == "quantile") {
  upper_threshold_rad <- q_upper
  names(upper_threshold_rad) <- "upper_threshold_rad"
} else if (UPPER_THRESHOLD_MODE == "absolute") {
  upper_threshold_rad <- constant_like(q_upper, UPPER_ABSOLUTE_OVERRIDE, "upper_threshold_rad")
} else if (UPPER_THRESHOLD_MODE == "none") {
  upper_threshold_rad <- constant_like(q_upper, NA_real_, "upper_threshold_rad")
}

upper_threshold_ok <- terra::ifel(
  upper_exclusion_enabled == 1,
  terra::ifel(!is.na(upper_threshold_rad), 1, 0),
  1
)
names(upper_threshold_ok) <- "upper_threshold_ok"

baseline_ok <- terra::ifel(
  n_valid_days >= MIN_PIXEL_VALID_DAYS &
    !is.na(q_lower) &
    !is.na(q_upper) &
    !is.na(iqr_rad) &
    !is.na(lower_threshold_rad) &
    upper_threshold_ok == 1,
  1,
  0
)
names(baseline_ok) <- "baseline_ok"

baseline <- c(
  q_lower,
  q_upper,
  iqr_rad,
  lower_threshold_rad,
  upper_threshold_rad,
  n_valid_days,
  upper_exclusion_enabled,
  baseline_ok
)

out_tif <- file.path(OUT_DIR, paste0("cape_town_vj146a2_", YEAR_LABEL, "_pixel_threshold_baseline.tif"))
out_config <- file.path(OUT_DIR, paste0("cape_town_vj146a2_", YEAR_LABEL, "_pixel_threshold_config.csv"))
terra::writeRaster(baseline, out_tif, overwrite = OVERWRITE, datatype = "FLT4S")

config <- data.frame(
  year = YEAR_LABEL,
  start_month = START_MONTH,
  end_month = END_MONTH,
  lower_threshold_mode = LOWER_THRESHOLD_MODE,
  lower_quantile = LOWER_QUANTILE,
  lower_iqr_k = LOWER_IQR_K,
  lower_absolute_override = LOWER_ABSOLUTE_OVERRIDE,
  upper_threshold_mode = UPPER_THRESHOLD_MODE,
  upper_quantile = UPPER_QUANTILE,
  upper_iqr_k = UPPER_IQR_K,
  upper_absolute_override = UPPER_ABSOLUTE_OVERRIDE,
  min_pixel_valid_days = MIN_PIXEL_VALID_DAYS,
  n_daily_rasters = length(tifs)
)
utils::write.csv(config, out_config, row.names = FALSE)

message("Baseline pixels ok: ", terra::global(baseline_ok == 1, "sum", na.rm = TRUE)[1, 1])
message("Wrote pixel threshold baseline: ", out_tif)
message("Wrote config: ", out_config)
