rm(list = ls())

# ============================================================
# Build Cape Town Block-Day Panel from Pixel-IQR State Rasters
# Pixel-IQR Stage 4B - Schedule-block measurement panel
# ============================================================
#
# Purpose:  Exact-extracts daily Cape Town pixel-IQR state rasters onto
#           the Cape Town load-shedding schedule-block polygons. This is
#           the block-level builder for schedule validation; the schedule
#           block GeoJSON replaces the settlement geometry.
# Inputs:   - pixel_iqr_pipeline/data/daily_states/cape_town_pixel_iqr_state_YYYY-MM-DD.tif
#           - pixel_iqr_pipeline/data/aoi/cape_town_city_schedule_blocks.geojson
# Outputs:  - pixel_iqr_pipeline/data/stage2_block_iqr_nocov/
#             block_day_vj146a2_pixel_iqr_nocov_YYYY-MM.parquet
#           - matching monthly daily-summary CSVs
# Run:      Rscript cape_town_schedule_validation/pixel_iqr_pipeline/scripts/04_block_day_panel_build_pixel_iqr_dark_vj146a2.R
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(sf)
  library(dplyr)
  library(arrow)
  library(terra)
  library(exactextractr)
})

sf::sf_use_s2(FALSE)

# -----------------------------
# CONFIG
# -----------------------------
BASE_PATH <- here::here()
MODULE_DIR <- file.path(BASE_PATH, "cape_town_schedule_validation", "pixel_iqr_pipeline")

AOI_GEOJSON <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_AOI_GEOJSON",
  file.path(MODULE_DIR, "data", "aoi", "cape_town_city_schedule_blocks.geojson")
)
STATE_DIR <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_DAILY_STATE_DIR",
  file.path(MODULE_DIR, "data", "daily_states")
)
OUT_DIR <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_BLOCK_NOCOV_DIR",
  file.path(MODULE_DIR, "data", "stage2_block_iqr_nocov")
)
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

START_MONTH <- Sys.getenv("VJ146A2_START_MONTH", "2023-01")
END_MONTH <- Sys.getenv("VJ146A2_END_MONTH", "2023-12")
AREA_CRS <- "+proj=aea +lat_1=-18 +lat_2=-32 +lat_0=0 +lon_0=24 +datum=WGS84 +units=m +no_defs"

MAX_DATES_PER_MONTH <- suppressWarnings(as.integer(Sys.getenv("VJ146A2_MAX_DATES_PER_MONTH", "")))
if (!is.finite(MAX_DATES_PER_MONTH)) MAX_DATES_PER_MONTH <- NA_integer_
SMOKE_MODE <- !is.na(MAX_DATES_PER_MONTH)
OUTPUT_SUFFIX <- if (SMOKE_MODE) "_smoke" else ""
if (SMOKE_MODE) OUT_DIR <- file.path(OUT_DIR, "smoke")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

# -----------------------------
# HELPERS
# -----------------------------
get_date <- function(path) {
  m <- regexpr("[0-9]{4}-[0-9]{2}-[0-9]{2}", basename(path))
  if (m < 0) stop("Could not parse date from filename: ", basename(path))
  as.Date(regmatches(basename(path), m))
}

safe_mean <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) == 0) return(NA_real_)
  mean(x)
}

extract_one_block_iqr <- function(values, coverage_fraction) {
  observed <- as.numeric(values$observed_iqr)
  dark <- as.numeric(values$dark_iqr)
  bright_excluded <- as.numeric(values$bright_excluded_iqr)
  rad <- as.numeric(values$rad_observed)
  cell_area_m2 <- as.numeric(values$cell_area_m2)
  cf <- as.numeric(coverage_fraction)

  observed_w <- ifelse(is.na(observed), 0, observed) * cf
  dark_w <- ifelse(is.na(dark), 0, dark) * cf
  bright_w <- ifelse(is.na(bright_excluded), 0, bright_excluded) * cf
  cf_ok <- is.finite(cf) & cf > 0
  rad_ok <- is.finite(rad) & is.finite(cf) & cf > 0

  data.frame(
    n_observed_iqr = sum(observed_w, na.rm = TRUE),
    n_dark_iqr = sum(dark_w, na.rm = TRUE),
    n_bright_excluded_iqr = sum(bright_w, na.rm = TRUE),
    n_total_overlap = sum(cf[cf_ok], na.rm = TRUE),
    observed_area_m2 = sum(cell_area_m2 * observed_w, na.rm = TRUE),
    rad_sum_observed = ifelse(any(rad_ok), sum(rad[rad_ok] * cf[rad_ok], na.rm = TRUE), 0)
  )
}

make_daily_summary <- function(block_day, days_in_month, missing_dates) {
  observed <- block_day %>%
    group_by(date) %>%
    summarise(
      status = "observed",
      n_blocks = n(),
      mean_coverage_iqr = safe_mean(coverage_iqr),
      mean_p_dark_iqr_block = safe_mean(p_dark_iqr_block),
      mean_rad_block = safe_mean(mean_rad_block),
      .groups = "drop"
    )

  calendar <- tibble(date = days_in_month) %>%
    mutate(status = ifelse(date %in% missing_dates, "missing_state_raster", "not_processed"))

  calendar %>%
    select(date, status) %>%
    left_join(observed %>% select(-status), by = "date") %>%
    mutate(status = ifelse(date %in% observed$date, "observed", status))
}

validate_month_output <- function(block_day, month_summary) {
  required_cols <- c(
    "block_id",
    "circuit",
    "date",
    "n_observed_iqr",
    "n_dark_iqr",
    "n_bright_excluded_iqr",
    "n_total_overlap",
    "coverage_iqr",
    "coverage_count_iqr",
    "p_dark_iqr_block",
    "mean_rad_block",
    "source_product",
    "target_family"
  )
  missing_cols <- setdiff(required_cols, names(block_day))
  if (length(missing_cols) > 0) {
    stop("Required columns missing: ", paste(missing_cols, collapse = ", "))
  }
  if (any(block_day$p_dark_iqr_block < -1e-9 | block_day$p_dark_iqr_block > 1 + 1e-9, na.rm = TRUE)) {
    stop("Found p_dark_iqr_block outside [0, 1].")
  }
  if (any(block_day$coverage_iqr < -1e-9 | block_day$coverage_iqr > 1 + 1e-9, na.rm = TRUE)) {
    stop("Found coverage_iqr outside [0, 1].")
  }
  if (any(block_day$target_family != "pixel_iqr_dark_block", na.rm = TRUE)) {
    stop("Unexpected target_family value.")
  }
  if (!("status" %in% names(month_summary))) stop("Daily summary missing status column.")
  invisible(TRUE)
}

# -----------------------------
# 1) READ INPUTS
# -----------------------------
if (!file.exists(AOI_GEOJSON)) stop("Cape Town AOI GeoJSON not found: ", AOI_GEOJSON)
if (!dir.exists(STATE_DIR)) stop("Daily state raster directory not found: ", STATE_DIR)

month_start <- as.Date(paste0(START_MONTH, "-01"))
month_end <- as.Date(paste0(END_MONTH, "-01"))
if (is.na(month_start) || is.na(month_end)) stop("Invalid START_MONTH/END_MONTH (use 'YYYY-MM').")
if (month_start > month_end) stop("START_MONTH must be <= END_MONTH.")
months_seq <- seq.Date(from = month_start, to = month_end, by = "month")
analysis_end <- seq.Date(from = month_end, by = "month", length.out = 2)[2] - 1

state_tifs <- list.files(STATE_DIR, pattern = "^cape_town_pixel_iqr_state_[0-9]{4}-[0-9]{2}-[0-9]{2}\\.tif$", full.names = TRUE)
if (length(state_tifs) == 0) stop("No Cape Town pixel-IQR state rasters found in: ", STATE_DIR)
state_tifs <- state_tifs[order(state_tifs)]
state_dates <- as.Date(vapply(state_tifs, function(path) format(get_date(path), "%Y-%m-%d"), character(1)))
state_map <- setNames(state_tifs, format(state_dates, "%Y-%m-%d"))
in_range <- state_dates >= month_start & state_dates <= analysis_end
if (!any(in_range)) {
  stop("No state rasters found in date range ", START_MONTH, " to ", END_MONTH, ".")
}

r0 <- terra::rast(state_tifs[which(in_range)[1]])
required_state_bands <- c("observed_iqr", "dark_iqr", "bright_excluded_iqr", "rad_observed")
missing_state_bands <- setdiff(required_state_bands, names(r0))
if (length(missing_state_bands) > 0) {
  stop("State raster is missing bands: ", paste(missing_state_bands, collapse = ", "))
}

blocks <- sf::st_read(AOI_GEOJSON, quiet = TRUE)
blocks <- sf::st_make_valid(blocks)
if (!"BlockID" %in% names(blocks)) stop("AOI GeoJSON is missing BlockID.")

blocks <- blocks %>%
  mutate(
    block_id = as.integer(BlockID),
    circuit = paste0("Area ", block_id)
  ) %>%
  filter(!is.na(block_id))
if (nrow(blocks) == 0) stop("No valid Cape Town schedule blocks found.")
if (any(duplicated(blocks$block_id))) stop("Duplicate BlockID values found in AOI GeoJSON.")

blocks_area <- sf::st_transform(blocks, AREA_CRS)
blocks$area_m2 <- as.numeric(sf::st_area(blocks_area))
blocks <- blocks %>%
  filter(is.finite(area_m2), area_m2 > 0)
if (nrow(blocks) == 0) stop("No positive-area schedule blocks remain.")

blocks_extract <- sf::st_transform(blocks, terra::crs(r0))
block_meta <- blocks %>%
  sf::st_drop_geometry() %>%
  select(block_id, circuit, area_m2)

message("Schedule-block geometries for extraction: ", nrow(blocks_extract))
message("Target months: ", START_MONTH, " through ", END_MONTH)
if (SMOKE_MODE) {
  message("Smoke mode: processing at most ", MAX_DATES_PER_MONTH, " available date(s) per month.")
}

cell_area_r0 <- terra::cellSize(r0[[1]], unit = "m")
names(cell_area_r0) <- "cell_area_m2"

# -----------------------------
# 2) MONTH LOOP
# -----------------------------
for (mi in seq_along(months_seq)) {
  m <- months_seq[mi]
  m_str <- format(m, "%Y-%m")
  message("=== Month ", m_str, " ===")

  next_month <- seq.Date(from = m, by = "month", length.out = 2)[2]
  m_last <- next_month - 1
  days_in_month <- seq.Date(from = m, to = m_last, by = "day")
  available_dates <- days_in_month[format(days_in_month, "%Y-%m-%d") %in% names(state_map)]
  missing_dates <- setdiff(days_in_month, available_dates)

  if (SMOKE_MODE) {
    available_dates <- head(available_dates, MAX_DATES_PER_MONTH)
  }

  if (length(available_dates) == 0) {
    message("No available pixel-IQR state rasters for ", m_str, "; writing missing-date summary only.")
    month_summary <- make_daily_summary(
      tibble(
        date = as.Date(character()),
        coverage_iqr = numeric(),
        p_dark_iqr_block = numeric(),
        mean_rad_block = numeric()
      ),
      days_in_month,
      missing_dates
    )
    out_summary <- file.path(
      OUT_DIR,
      paste0("block_day_vj146a2_pixel_iqr_nocov", OUTPUT_SUFFIX, "_", m_str, "_daily_summary.csv")
    )
    utils::write.csv(month_summary, out_summary, row.names = FALSE)
    next
  }

  results <- vector("list", length(available_dates))

  for (i in seq_along(available_dates)) {
    d <- available_dates[i]
    d_str <- format(d, "%Y-%m-%d")
    f <- unname(state_map[d_str])
    if (!file.exists(f) || file.info(f)$size == 0) {
      message("Bad or missing file for ", d_str, " - skipping")
      next
    }

    message("[", i, "/", length(available_dates), "] Processing ", d_str, ": ", basename(f))
    state <- terra::rast(f)
    missing_state_bands <- setdiff(required_state_bands, names(state))
    if (length(missing_state_bands) > 0) {
      stop("State raster missing bands on ", d_str, ": ", paste(missing_state_bands, collapse = ", "))
    }

    cell_area_r <- if (terra::compareGeom(state[[1]], cell_area_r0, stopOnError = FALSE)) {
      cell_area_r0
    } else {
      terra::cellSize(state[[1]], unit = "m")
    }
    names(cell_area_r) <- "cell_area_m2"

    metrics_stack <- c(
      state[["observed_iqr"]],
      state[["dark_iqr"]],
      state[["bright_excluded_iqr"]],
      state[["rad_observed"]],
      cell_area_r
    )
    names(metrics_stack) <- c("observed_iqr", "dark_iqr", "bright_excluded_iqr", "rad_observed", "cell_area_m2")

    ex <- exactextractr::exact_extract(
      metrics_stack,
      blocks_extract,
      fun = extract_one_block_iqr,
      progress = FALSE
    )
    if (nrow(ex) != nrow(block_meta)) {
      stop("Extraction returned unexpected row count on ", d_str)
    }

    df_day <- bind_cols(block_meta, ex) %>%
      mutate(
        date = d,
        coverage_iqr = ifelse(!is.na(observed_area_m2) & area_m2 > 0, pmin(1, observed_area_m2 / area_m2), NA_real_),
        coverage_count_iqr = ifelse(n_total_overlap > 0, n_observed_iqr / n_total_overlap, NA_real_),
        p_dark_iqr_block = ifelse(n_observed_iqr > 0, n_dark_iqr / n_observed_iqr, NA_real_),
        mean_rad_block = ifelse(n_observed_iqr > 0, rad_sum_observed / n_observed_iqr, NA_real_),
        source_product = "VJ146A2",
        target_family = "pixel_iqr_dark_block"
      ) %>%
      select(
        block_id,
        circuit,
        date,
        n_observed_iqr,
        n_dark_iqr,
        n_bright_excluded_iqr,
        n_total_overlap,
        coverage_iqr,
        coverage_count_iqr,
        p_dark_iqr_block,
        mean_rad_block,
        area_m2,
        source_product,
        target_family
      )

    results[[i]] <- df_day
    message("  Rows: ", nrow(df_day), " | mean coverage_iqr: ", round(mean(df_day$coverage_iqr, na.rm = TRUE), 3))
  }

  block_day <- bind_rows(results)
  if (nrow(block_day) == 0) {
    message("No extractable state rasters for ", m_str, "; skipping monthly parquet.")
    next
  }

  month_summary <- make_daily_summary(block_day, days_in_month, missing_dates)
  validate_month_output(block_day, month_summary)

  out_parq <- file.path(
    OUT_DIR,
    paste0("block_day_vj146a2_pixel_iqr_nocov", OUTPUT_SUFFIX, "_", m_str, ".parquet")
  )
  out_summary <- file.path(
    OUT_DIR,
    paste0("block_day_vj146a2_pixel_iqr_nocov", OUTPUT_SUFFIX, "_", m_str, "_daily_summary.csv")
  )

  arrow::write_parquet(block_day, out_parq)
  utils::write.csv(month_summary, out_summary, row.names = FALSE)

  message("Wrote parquet: ", out_parq, " rows: ", nrow(block_day))
  message("Wrote daily summary: ", out_summary, " rows: ", nrow(month_summary))
}

message("Done.")

