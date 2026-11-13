rm(list = ls())

# ============================================================
# Build Cape Town Settlement-Day Panel from Pixel-IQR State Rasters
# Pixel-IQR Stage 4 - Settlement-day measurement panel
# ============================================================
#
# Purpose:  Exact-extracts daily Cape Town pixel-IQR state rasters onto
#           yearly-keep settlement geometries clipped to the Cape Town AOI.
#           Writes measurement-only settlement-day panels without defining
#           not-up or schedule-exposure targets.
# Inputs:   - pixel_iqr_pipeline/data/daily_states/cape_town_pixel_iqr_state_YYYY-MM-DD.tif
#           - pixel_iqr_pipeline/data/aoi/cape_town_city_schedule_blocks.geojson
#           - Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_full_col.gpkg
#           - Map Data/reliability_outputs_vj146a2/vj146a2_yearly_keep_YYYY.parquet
# Outputs:  - pixel_iqr_pipeline/data/stage2_pixel_iqr_nocov/
#             settlement_day_vj146a2_pixel_iqr_nocov_YYYY-MM.parquet
#           - matching monthly daily-summary CSVs
# Run:      Rscript cape_town_schedule_validation/pixel_iqr_pipeline/scripts/04_settlement_day_panel_build_pixel_iqr_dark_vj146a2.R
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

SETT_GPKG <- Sys.getenv(
  "VJ146A2_SETT_GPKG",
  file.path(
    BASE_PATH,
    "Map Data",
    "Settlements",
    "GPKG",
    "south_africa_dre_atlas_settlements_full_col.gpkg"
  )
)
AOI_GEOJSON <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_AOI_GEOJSON",
  file.path(MODULE_DIR, "data", "aoi", "cape_town_city_schedule_blocks.geojson")
)
STATE_DIR <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_DAILY_STATE_DIR",
  file.path(MODULE_DIR, "data", "daily_states")
)
OUT_DIR <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_NOCOV_DIR",
  file.path(MODULE_DIR, "data", "stage2_pixel_iqr_nocov")
)
YEARLY_DIR <- Sys.getenv(
  "VJ146A2_YEARLY_DIR",
  file.path(BASE_PATH, "Map Data", "reliability_outputs_vj146a2")
)
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

START_MONTH <- Sys.getenv("VJ146A2_START_MONTH", "2023-01")
END_MONTH <- Sys.getenv("VJ146A2_END_MONTH", "2023-12")
YEAR_LABEL <- Sys.getenv("VJ146A2_YEAR", substr(START_MONTH, 1, 4))
AREA_CRS <- "+proj=aea +lat_1=-18 +lat_2=-32 +lat_0=0 +lon_0=24 +datum=WGS84 +units=m +no_defs"
USE_YEARLY_KEEP <- Sys.getenv("VJ146A2_USE_YEARLY_KEEP", "1") != "0"
YEARLY_KEEP_FILE <- Sys.getenv(
  "VJ146A2_YEARLY_KEEP_FILE",
  file.path(YEARLY_DIR, paste0("vj146a2_yearly_keep_", YEAR_LABEL, ".parquet"))
)
YEARLY_STATS_FILE <- Sys.getenv(
  "VJ146A2_YEARLY_STATS_FILE",
  file.path(YEARLY_DIR, paste0("yearly_settlement_stats_", YEAR_LABEL, ".parquet"))
)

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

safe_weighted_mean <- function(x, w) {
  ok <- is.finite(x) & is.finite(w) & w > 0
  if (!any(ok)) return(NA_real_)
  weighted.mean(x[ok], w[ok])
}

read_yearly_keep_ids <- function(keep_file, stats_file) {
  if (file.exists(keep_file)) {
    yearly <- arrow::read_parquet(keep_file)
    source_file <- keep_file
  } else if (file.exists(stats_file)) {
    yearly <- arrow::read_parquet(stats_file)
    source_file <- stats_file
  } else {
    stop(
      "VJ yearly keep/stats file not found.\n",
      "Expected one of:\n  - ", keep_file, "\n  - ", stats_file, "\n",
      "Run VJ pre-Stage 2 first: Rscript Builder/vj146a2_yearly_keep_build.R\n",
      "For full-universe diagnostics only, set VJ146A2_USE_YEARLY_KEEP=0."
    )
  }

  if (!"settlement_id" %in% names(yearly)) {
    stop("VJ yearly keep/stats file is missing settlement_id: ", source_file)
  }
  if ("electrified_best" %in% names(yearly)) {
    electrified_best <- suppressWarnings(as.integer(yearly$electrified_best))
    yearly <- yearly[!is.na(electrified_best) & electrified_best == 1L, , drop = FALSE]
  }

  settlement_ids <- unique(as.character(yearly$settlement_id))
  settlement_ids <- settlement_ids[!is.na(settlement_ids) & nzchar(settlement_ids)]
  if (length(settlement_ids) == 0) {
    stop("VJ yearly keep/stats file has no electrified settlement IDs: ", source_file)
  }

  list(
    settlement_ids = settlement_ids,
    source_file = source_file
  )
}

extract_one_settlement_iqr <- function(values, coverage_fraction) {
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

make_daily_summary <- function(sett_day, days_in_month, missing_dates) {
  observed <- sett_day %>%
    group_by(date) %>%
    summarise(
      status = "observed",
      n_settlements = n(),
      population_sum = sum(population, na.rm = TRUE),
      mean_coverage_iqr = safe_mean(coverage_iqr),
      mean_p_dark_iqr_sett = safe_mean(p_dark_iqr_sett),
      popw_mean_p_dark_iqr_sett = safe_weighted_mean(p_dark_iqr_sett, population),
      mean_rad_sett = safe_mean(mean_rad_sett),
      popw_mean_rad_sett = safe_weighted_mean(mean_rad_sett, population),
      .groups = "drop"
    )

  calendar <- tibble(date = days_in_month) %>%
    mutate(status = ifelse(date %in% missing_dates, "missing_state_raster", "not_processed"))

  calendar %>%
    select(date, status) %>%
    left_join(observed %>% select(-status), by = "date") %>%
    mutate(status = ifelse(date %in% observed$date, "observed", status))
}

validate_month_output <- function(sett_day, month_summary) {
  required_cols <- c(
    "settlement_id",
    "date",
    "n_observed_iqr",
    "n_dark_iqr",
    "n_bright_excluded_iqr",
    "n_total_overlap",
    "coverage_iqr",
    "coverage_count_iqr",
    "p_dark_iqr_sett",
    "mean_rad_sett",
    "population",
    "source_product",
    "target_family"
  )
  missing_cols <- setdiff(required_cols, names(sett_day))
  if (length(missing_cols) > 0) {
    stop("Required columns missing: ", paste(missing_cols, collapse = ", "))
  }
  if (any(sett_day$p_dark_iqr_sett < -1e-9 | sett_day$p_dark_iqr_sett > 1 + 1e-9, na.rm = TRUE)) {
    stop("Found p_dark_iqr_sett outside [0, 1].")
  }
  if (any(sett_day$coverage_iqr < -1e-9 | sett_day$coverage_iqr > 1 + 1e-9, na.rm = TRUE)) {
    stop("Found coverage_iqr outside [0, 1].")
  }
  if (any(sett_day$target_family != "pixel_iqr_dark", na.rm = TRUE)) {
    stop("Unexpected target_family value.")
  }
  if (!("status" %in% names(month_summary))) stop("Daily summary missing status column.")
  invisible(TRUE)
}

# -----------------------------
# 1) READ INPUTS
# -----------------------------
if (!file.exists(SETT_GPKG)) stop("Settlement GPKG not found: ", SETT_GPKG)
if (!file.exists(AOI_GEOJSON)) stop("Cape Town AOI GeoJSON not found: ", AOI_GEOJSON)
if (!dir.exists(STATE_DIR)) stop("Daily state raster directory not found: ", STATE_DIR)
if (!grepl("^\\d{4}$", YEAR_LABEL)) stop("Invalid VJ146A2_YEAR; expected YYYY.")

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

yearly_keep <- NULL
if (USE_YEARLY_KEEP) {
  yearly_keep <- read_yearly_keep_ids(YEARLY_KEEP_FILE, YEARLY_STATS_FILE)
}

sett <- sf::st_read(SETT_GPKG, quiet = TRUE) %>%
  mutate(settlement_id = as.character(settlement_id))
if (!all(c("settlement_id", "population") %in% names(sett))) {
  stop("Settlement GPKG must include settlement_id and population.")
}

sett$population <- as.numeric(sett$population)
sett$population[is.na(sett$population)] <- 0

if (USE_YEARLY_KEEP) {
  n_sett_full <- nrow(sett)
  keep_tbl <- tibble(settlement_id = yearly_keep$settlement_ids)
  sett <- sett %>%
    semi_join(keep_tbl, by = "settlement_id")
  if (nrow(sett) == 0) {
    stop("No settlement geometries remain after applying VJ yearly keep list: ", yearly_keep$source_file)
  }
  message("VJ yearly keep prefilter active: retained ", nrow(sett), " / ", n_sett_full, " settlements.")
  message("Yearly keep source: ", yearly_keep$source_file)
} else {
  message("VJ146A2_USE_YEARLY_KEEP=0; processing the full settlement universe.")
}

aoi <- sf::st_read(AOI_GEOJSON, quiet = TRUE)
aoi <- sf::st_make_valid(aoi)
sett <- sf::st_make_valid(sett)
aoi_sett_crs <- sf::st_transform(aoi, sf::st_crs(sett))
aoi_union <- sf::st_union(aoi_sett_crs)
intersects_aoi <- lengths(sf::st_intersects(sett, aoi_union)) > 0
sett <- sett[intersects_aoi, ]
if (nrow(sett) == 0) stop("No settlements intersect the Cape Town AOI.")

sett_aoi <- suppressWarnings(sf::st_intersection(sett, sf::st_sf(geometry = aoi_union)))
sett_aoi <- sf::st_make_valid(sett_aoi)
sett_aoi <- sett_aoi[!sf::st_is_empty(sett_aoi), ]
area_m2 <- as.numeric(sf::st_area(sf::st_transform(sett_aoi, AREA_CRS)))
sett_aoi <- sett_aoi %>%
  mutate(area_m2 = area_m2) %>%
  filter(is.finite(area_m2), area_m2 > 0)
if (nrow(sett_aoi) == 0) stop("No positive-area settlement/AOI intersections remain.")

sett_extract <- sf::st_transform(sett_aoi, terra::crs(r0))
sett_meta <- sett_aoi %>%
  sf::st_drop_geometry() %>%
  dplyr::select(settlement_id, population, area_m2)

message("Settlement/AOI geometries for extraction: ", nrow(sett_extract))
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
        population = numeric(),
        coverage_iqr = numeric(),
        p_dark_iqr_sett = numeric(),
        mean_rad_sett = numeric()
      ),
      days_in_month,
      missing_dates
    )
    out_summary <- file.path(
      OUT_DIR,
      paste0("settlement_day_vj146a2_pixel_iqr_nocov", OUTPUT_SUFFIX, "_", m_str, "_daily_summary.csv")
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
      sett_extract,
      fun = extract_one_settlement_iqr,
      progress = FALSE
    )
    if (nrow(ex) != nrow(sett_meta)) {
      stop("Extraction returned unexpected row count on ", d_str)
    }

    df_day <- bind_cols(sett_meta, ex) %>%
      mutate(
        date = d,
        coverage_iqr = ifelse(!is.na(observed_area_m2) & area_m2 > 0, pmin(1, observed_area_m2 / area_m2), NA_real_),
        coverage_count_iqr = ifelse(n_total_overlap > 0, n_observed_iqr / n_total_overlap, NA_real_),
        p_dark_iqr_sett = ifelse(n_observed_iqr > 0, n_dark_iqr / n_observed_iqr, NA_real_),
        mean_rad_sett = ifelse(n_observed_iqr > 0, rad_sum_observed / n_observed_iqr, NA_real_),
        source_product = "VJ146A2",
        target_family = "pixel_iqr_dark"
      ) %>%
      select(
        settlement_id,
        date,
        n_observed_iqr,
        n_dark_iqr,
        n_bright_excluded_iqr,
        n_total_overlap,
        coverage_iqr,
        coverage_count_iqr,
        p_dark_iqr_sett,
        mean_rad_sett,
        population,
        source_product,
        target_family
      )

    results[[i]] <- df_day
    message("  Rows: ", nrow(df_day), " | mean coverage_iqr: ", round(mean(df_day$coverage_iqr, na.rm = TRUE), 3))
  }

  sett_day <- bind_rows(results)
  if (nrow(sett_day) == 0) {
    message("No extractable state rasters for ", m_str, "; skipping monthly parquet.")
    next
  }

  month_summary <- make_daily_summary(sett_day, days_in_month, missing_dates)
  validate_month_output(sett_day, month_summary)

  out_parq <- file.path(
    OUT_DIR,
    paste0("settlement_day_vj146a2_pixel_iqr_nocov", OUTPUT_SUFFIX, "_", m_str, ".parquet")
  )
  out_summary <- file.path(
    OUT_DIR,
    paste0("settlement_day_vj146a2_pixel_iqr_nocov", OUTPUT_SUFFIX, "_", m_str, "_daily_summary.csv")
  )

  arrow::write_parquet(sett_day, out_parq)
  utils::write.csv(month_summary, out_summary, row.names = FALSE)

  message("Wrote parquet: ", out_parq, " rows: ", nrow(sett_day))
  message("Wrote daily summary: ", out_summary, " rows: ", nrow(month_summary))
}

message("Done.")

