rm(list = ls())

# ============================================================
# Build October 2023 Settlement-Day Panel from VJ146A2 Rasters
# Diagnostic/trial path only. Does not touch production VNP files.
# ============================================================
#
# Purpose:  Reads existing October 2023 VJ146A2 daily rasters and
#           builds a settlement-day parquet for Ravi's Eskom comparison.
# Inputs:   - Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_full_col.gpkg
#           - Map Data/reliability_outputs_blackmarbler/yearly_settlement_stats_2023.parquet
#           - blackmarbler/out_vnp46a2_sa_daily/qa_straylight_validation/vj146a2_month_2023-10/rasters/*.tif
# Outputs:  - Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_cov_yearlykeep_2023-10.parquet
#           - Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_cov_yearlykeep_2023-10_daily_summary.csv
# Run:      Rscript Builder/Others/settlement_day_panel_build_vj146a2_oct2023.R
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

SETT_GPKG <- file.path(
  BASE_PATH,
  "Map Data",
  "Settlements",
  "GPKG",
  "south_africa_dre_atlas_settlements_full_col.gpkg"
)

ANNUAL_PARQUET <- file.path(
  BASE_PATH,
  "Map Data",
  "reliability_outputs_blackmarbler",
  "yearly_settlement_stats_2023.parquet"
)

RAST_DIR <- file.path(
  BASE_PATH,
  "blackmarbler",
  "out_vnp46a2_sa_daily",
  "qa_straylight_validation",
  "vj146a2_month_2023-10",
  "rasters"
)

DIAG_SUMMARY_CSV <- file.path(
  BASE_PATH,
  "blackmarbler",
  "out_vnp46a2_sa_daily",
  "qa_straylight_validation",
  "vj146a2_month_2023-10",
  "vj146a2_month_2023-10_summary.csv"
)

OUT_DIR <- file.path(BASE_PATH, "Map Data", "settlement_day_outputs_vj146a2")
OUT_PARQUET <- file.path(
  OUT_DIR,
  "settlement_day_vj146a2_cov_yearlykeep_2023-10.parquet"
)
OUT_DAILY_SUMMARY <- file.path(
  OUT_DIR,
  "settlement_day_vj146a2_cov_yearlykeep_2023-10_daily_summary.csv"
)

START_DATE <- as.Date("2023-10-02")
END_DATE <- as.Date("2023-10-31")
SKIP_DATE <- as.Date("2023-10-01")

PIXEL_LIT_THRESHOLD <- 1.0
MIN_COVERAGE <- 0.50
SETTLEMENT_LIT_THRESHOLD <- 0.40
SETTLEMENT_DARK_THRESHOLD <- 0.05
AREA_CRS <- "+proj=aea +lat_1=-18 +lat_2=-32 +lat_0=0 +lon_0=24 +datum=WGS84 +units=m +no_defs"

# -----------------------------
# HELPERS
# -----------------------------
get_date <- function(path) {
  m <- regexpr("[0-9]{4}-[0-9]{2}-[0-9]{2}", basename(path))
  if (m < 0) stop("Could not parse date from filename: ", basename(path))
  as.Date(regmatches(basename(path), m))
}

weighted_median <- function(x, w) {
  ok <- is.finite(x) & is.finite(w) & w > 0
  if (!any(ok)) return(NA_real_)

  x <- x[ok]
  w <- w[ok]
  ord <- order(x)
  x <- x[ord]
  w <- w[ord]

  cutoff <- 0.5 * sum(w)
  x[which(cumsum(w) >= cutoff)[1]]
}

safe_weighted_mean <- function(x, w) {
  ok <- is.finite(x) & is.finite(w) & w > 0
  if (!any(ok)) return(NA_real_)
  weighted.mean(x[ok], w[ok])
}

extract_one_settlement <- function(values, coverage_fraction) {
  valid <- as.numeric(values$valid)
  lit <- as.numeric(values$lit)
  rad <- as.numeric(values$rad)
  cell_area_m2 <- as.numeric(values$cell_area_m2)
  cf <- as.numeric(coverage_fraction)

  valid_w <- ifelse(is.na(valid), 0, valid) * cf
  lit_w <- ifelse(is.na(lit), 0, lit) * cf
  rad_ok <- is.finite(rad) & is.finite(cf) & cf > 0

  data.frame(
    n_valid = sum(valid_w, na.rm = TRUE),
    n_lit = sum(lit_w, na.rm = TRUE),
    rad_sum = ifelse(any(rad_ok), sum(rad[rad_ok] * cf[rad_ok], na.rm = TRUE), 0),
    median_rad_sett = weighted_median(rad, cf),
    valid_area_m2 = sum(cell_area_m2 * valid_w, na.rm = TRUE)
  )
}

make_daily_summary <- function(sett_day) {
  sett_day %>%
    group_by(date) %>%
    summarise(
      n_settlements = n(),
      population_sum = sum(population, na.rm = TRUE),
      mean_coverage = mean(coverage, na.rm = TRUE),
      mean_p_lit_sett = mean(p_lit_sett, na.rm = TRUE),
      median_p_lit_sett = median(p_lit_sett, na.rm = TRUE),
      popw_mean_p_lit_sett = safe_weighted_mean(p_lit_sett, population),
      popw_share_dark = safe_weighted_mean(as.numeric(dark), population),
      mean_mean_lit_sett = mean(mean_lit_sett, na.rm = TRUE),
      median_median_lit_sett = median(median_lit_sett, na.rm = TRUE),
      mean_mean_rad_sett = mean(mean_rad_sett, na.rm = TRUE),
      median_mean_rad_sett = median(mean_rad_sett, na.rm = TRUE),
      popw_mean_rad_sett = safe_weighted_mean(mean_rad_sett, population),
      median_median_rad_sett = median(median_rad_sett, na.rm = TRUE),
      .groups = "drop"
    )
}

validate_outputs <- function(sett_day, daily_summary) {
  required_cols <- c(
    "settlement_id",
    "date",
    "n_valid",
    "n_lit",
    "rad_sum",
    "mean_lit_sett",
    "median_lit_sett",
    "mean_rad_sett",
    "median_rad_sett",
    "valid_area_m2",
    "area_m2",
    "coverage",
    "p_lit_sett",
    "lit_day",
    "dark_day",
    "dark",
    "settlement_state",
    "population",
    "electrified_best"
  )
  missing_cols <- setdiff(required_cols, names(sett_day))
  if (length(missing_cols) > 0) {
    stop("Required columns missing: ", paste(missing_cols, collapse = ", "))
  }

  expected_dates <- seq.Date(START_DATE, END_DATE, by = "day")
  actual_dates <- sort(unique(as.Date(sett_day$date)))
  if (!setequal(actual_dates, expected_dates)) {
    stop(
      "Unexpected dates in output. Expected ",
      paste(expected_dates, collapse = ", "),
      "; got ",
      paste(actual_dates, collapse = ", ")
    )
  }
  if (SKIP_DATE %in% actual_dates) stop("Skipped date is present in output: ", SKIP_DATE)

  if (any(sett_day$electrified_best != 1, na.rm = FALSE)) {
    stop("Found rows with electrified_best != 1.")
  }
  if (any(sett_day$coverage < MIN_COVERAGE, na.rm = TRUE)) {
    stop("Found rows below minimum coverage.")
  }
  if (any(sett_day$p_lit_sett < -1e-9 | sett_day$p_lit_sett > 1 + 1e-9, na.rm = TRUE)) {
    stop("Found p_lit_sett outside [0, 1].")
  }
  if (any(abs(sett_day$p_lit_sett - sett_day$mean_lit_sett) > 1e-12, na.rm = TRUE)) {
    stop("p_lit_sett and mean_lit_sett differ.")
  }
  if (any(!is.na(sett_day$median_lit_sett) & !(sett_day$median_lit_sett %in% c(0, 1)))) {
    stop("median_lit_sett has values outside {0, 1, NA}.")
  }
  if (any(sett_day$mean_rad_sett < -1e-9, na.rm = TRUE)) {
    stop("Found negative mean_rad_sett.")
  }
  if (any(sett_day$median_rad_sett < -1e-9, na.rm = TRUE)) {
    stop("Found negative median_rad_sett.")
  }
  if (any(sett_day$dark != (sett_day$p_lit_sett < SETTLEMENT_DARK_THRESHOLD), na.rm = TRUE)) {
    stop("dark does not equal p_lit_sett < threshold.")
  }
  valid_states <- c("lit", "dark", "ambiguous")
  if (any(!is.na(sett_day$settlement_state) & !(sett_day$settlement_state %in% valid_states))) {
    stop("Unexpected settlement_state value.")
  }
  if (n_distinct(as.Date(daily_summary$date)) != length(expected_dates)) {
    stop("Daily summary does not contain 30 dates.")
  }

  invisible(TRUE)
}

# -----------------------------
# 1) READ INPUTS
# -----------------------------
for (p in c(SETT_GPKG, ANNUAL_PARQUET, RAST_DIR)) {
  if (!file.exists(p)) stop("Input not found: ", p)
}

tifs <- list.files(RAST_DIR, pattern = "\\.tif$", full.names = TRUE, ignore.case = TRUE)
if (length(tifs) == 0) stop("No VJ146A2 rasters found in: ", RAST_DIR)
tif_dates <- as.Date(vapply(tifs, get_date, as.Date("1970-01-01")))
tif_map <- setNames(tifs, format(tif_dates, "%Y-%m-%d"))

target_dates <- seq.Date(START_DATE, END_DATE, by = "day")
missing_dates <- setdiff(format(target_dates, "%Y-%m-%d"), names(tif_map))
if (length(missing_dates) > 0) {
  stop("Missing required VJ146A2 raster dates: ", paste(missing_dates, collapse = ", "))
}

if (format(SKIP_DATE, "%Y-%m-%d") %in% names(tif_map)) {
  message("Found ", SKIP_DATE, " raster but will skip it by plan.")
}

r0 <- terra::rast(tif_map[format(START_DATE, "%Y-%m-%d")])
if (is.na(terra::crs(r0))) stop("Raster CRS is missing.")
if (!all(c("rad", "valid") %in% names(r0))) {
  stop("VJ rasters must include bands named 'rad' and 'valid'.")
}

annual <- arrow::read_parquet(ANNUAL_PARQUET) %>%
  mutate(settlement_id = as.character(settlement_id)) %>%
  select(settlement_id, population_annual = population, electrified_best)

if (!all(c("settlement_id", "population_annual", "electrified_best") %in% names(annual))) {
  stop("Annual parquet is missing required fields.")
}

sett <- sf::st_read(SETT_GPKG, quiet = TRUE) %>%
  sf::st_make_valid() %>%
  mutate(settlement_id = as.character(settlement_id))

if (!all(c("settlement_id", "population") %in% names(sett))) {
  stop("Settlement GPKG must include settlement_id and population.")
}

sett_keep <- sett %>%
  left_join(annual, by = "settlement_id") %>%
  mutate(
    population = coalesce(population_annual, population)
  ) %>%
  filter(electrified_best == 1)

if (nrow(sett_keep) == 0) stop("No settlements remain after electrified_best == 1 filter.")

area_m2 <- as.numeric(sf::st_area(sf::st_transform(sett_keep, AREA_CRS)))
if (any(!is.finite(area_m2)) || any(area_m2 <= 0)) {
  stop("Invalid settlement areas after transform to AREA_CRS.")
}

sett_keep <- sett_keep %>%
  mutate(area_m2 = area_m2)

sett_extract <- sf::st_transform(sett_keep, terra::crs(r0))
sett_meta <- sett_keep %>%
  sf::st_drop_geometry() %>%
  select(settlement_id, population, electrified_best, area_m2)

message("Electrified settlements for extraction: ", nrow(sett_extract))
message("Target dates: ", START_DATE, " through ", END_DATE)

# -----------------------------
# 2) DAILY EXTRACTION
# -----------------------------
results <- vector("list", length(target_dates))
cell_area_r0 <- terra::cellSize(r0[[1]], unit = "m")
names(cell_area_r0) <- "cell_area_m2"

for (i in seq_along(target_dates)) {
  d <- target_dates[i]
  d_str <- format(d, "%Y-%m-%d")
  f <- unname(tif_map[d_str])
  message("[", i, "/", length(target_dates), "] Processing ", d_str, ": ", basename(f))

  r <- terra::rast(f)
  if (!all(c("rad", "valid") %in% names(r))) {
    stop("Raster missing rad/valid bands: ", basename(f))
  }

  rad <- r[["rad"]]
  valid <- r[["valid"]]
  valid_binary <- terra::ifel(is.na(valid), 0, terra::ifel(valid == 1, 1, 0))
  names(valid_binary) <- "valid"

  lit <- terra::ifel(
    is.na(rad),
    NA,
    terra::ifel(valid_binary == 1 & rad > PIXEL_LIT_THRESHOLD, 1, 0)
  )
  lit <- terra::ifel(valid_binary == 1, lit, NA)
  names(lit) <- "lit"

  rad_valid <- terra::ifel(valid_binary == 1, rad, NA)
  names(rad_valid) <- "rad"

  cell_area_r <- if (terra::compareGeom(rad, cell_area_r0, stopOnError = FALSE)) {
    cell_area_r0
  } else {
    terra::cellSize(rad, unit = "m")
  }
  names(cell_area_r) <- "cell_area_m2"

  metrics_stack <- c(valid_binary, lit, rad_valid, cell_area_r)
  names(metrics_stack) <- c("valid", "lit", "rad", "cell_area_m2")

  ex <- exactextractr::exact_extract(
    metrics_stack,
    sett_extract,
    fun = extract_one_settlement,
    progress = FALSE
  )

  if (nrow(ex) != nrow(sett_meta)) {
    stop("Extraction returned unexpected row count on ", d_str)
  }

  df_day <- bind_cols(sett_meta, ex) %>%
    mutate(
      date = d,
      p_lit_sett = ifelse(n_valid > 0, n_lit / n_valid, NA_real_),
      mean_lit_sett = p_lit_sett,
      median_lit_sett = ifelse(!is.na(p_lit_sett), as.integer(p_lit_sett >= 0.5), NA_integer_),
      mean_rad_sett = ifelse(n_valid > 0, rad_sum / n_valid, NA_real_),
      coverage = ifelse(!is.na(valid_area_m2) & area_m2 > 0, pmin(1, valid_area_m2 / area_m2), NA_real_),
      lit_day = ifelse(!is.na(p_lit_sett), as.integer(p_lit_sett >= SETTLEMENT_LIT_THRESHOLD), NA_integer_),
      dark_day = ifelse(!is.na(p_lit_sett), as.integer(p_lit_sett < SETTLEMENT_DARK_THRESHOLD), NA_integer_),
      dark = p_lit_sett < SETTLEMENT_DARK_THRESHOLD,
      settlement_state = case_when(
        is.na(p_lit_sett) ~ NA_character_,
        p_lit_sett >= SETTLEMENT_LIT_THRESHOLD ~ "lit",
        p_lit_sett < SETTLEMENT_DARK_THRESHOLD ~ "dark",
        TRUE ~ "ambiguous"
      )
    ) %>%
    filter(coverage >= MIN_COVERAGE) %>%
    select(
      settlement_id,
      date,
      n_valid,
      n_lit,
      rad_sum,
      mean_lit_sett,
      median_lit_sett,
      mean_rad_sett,
      median_rad_sett,
      valid_area_m2,
      area_m2,
      coverage,
      p_lit_sett,
      lit_day,
      dark_day,
      dark,
      settlement_state,
      population,
      electrified_best
    )

  results[[i]] <- df_day
  message("  Rows after coverage filter: ", nrow(df_day))
}

sett_day <- bind_rows(results)
daily_summary <- make_daily_summary(sett_day)

# -----------------------------
# 3) VALIDATE AND WRITE
# -----------------------------
validate_outputs(sett_day, daily_summary)

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
arrow::write_parquet(sett_day, OUT_PARQUET)
utils::write.csv(daily_summary, OUT_DAILY_SUMMARY, row.names = FALSE)

message("Wrote parquet: ", OUT_PARQUET, " rows: ", nrow(sett_day))
message("Wrote daily summary: ", OUT_DAILY_SUMMARY, " rows: ", nrow(daily_summary))

if (file.exists(DIAG_SUMMARY_CSV)) {
  diag_summary <- utils::read.csv(DIAG_SUMMARY_CSV)
  compare_summary <- daily_summary %>%
    select(date, mean_p_lit_sett, popw_mean_p_lit_sett, mean_mean_rad_sett) %>%
    left_join(
      diag_summary %>%
        mutate(date = as.Date(date)) %>%
        select(date, p_lit_ge1, mean_rad_valid, status),
      by = "date"
    )
  message("Whole-scene diagnostic comparison head:")
  print(head(compare_summary, 10))
}

message("Done.")
