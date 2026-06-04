rm(list = ls())

# ============================================================
# Build Settlement-Day Panel from Daily VJ146A2 GeoTIFFs
# VJ Stage 2 — Panel Construction
# ============================================================
#
# Purpose:  Reads the pre-Stage-2 annual yearly-keep list, settlement
#           polygons, and already-downloaded daily VJ146A2 GeoTIFFs;
#           loops month-by-month and computes exact-overlap
#           settlement-day metrics without applying the daily coverage
#           filter. Production runs prefilter settlements to
#           electrified_best == 1 before exact extraction.
# Inputs:   - Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_full_col.gpkg
#           - Map Data/reliability_outputs_vj146a2/vj146a2_yearly_keep_YYYY.parquet
#           - blackmarbler/out_vj146a2_sa_daily/vj146a2_sa_500m_daily_YYYY-MM-DD.tif
# Outputs:  - Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_nocov_YYYY-MM.parquet
#           - Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_nocov_YYYY-MM_daily_summary.csv
# Smoke:   If VJ146A2_MAX_DATES_PER_MONTH is set, writes only under
#          Map Data/settlement_day_outputs_vj146a2/smoke/ with `_smoke`
#          filenames. Smoke runs never write production monthly names.
# Run:      Rscript Builder/settlement_day_panel_build_vj146a2.R
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

RAST_DIR <- file.path(BASE_PATH, "blackmarbler", "out_vj146a2_sa_daily")
OUT_DIR <- file.path(BASE_PATH, "Map Data", "settlement_day_outputs_vj146a2")
YEARLY_DIR <- file.path(BASE_PATH, "Map Data", "reliability_outputs_vj146a2")

START_MONTH <- Sys.getenv("VJ146A2_START_MONTH", "2023-01")
END_MONTH <- Sys.getenv("VJ146A2_END_MONTH", "2023-12")
YEAR_LABEL <- Sys.getenv("VJ146A2_YEAR", substr(START_MONTH, 1, 4))

PIXEL_LIT_THRESHOLD <- as.numeric(Sys.getenv("VJ146A2_PIXEL_LIT_THRESHOLD", "1.0"))
SETTLEMENT_LIT_THRESHOLD <- 0.40
SETTLEMENT_DARK_THRESHOLD <- 0.05
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

# Optional smoke-test cap. Example:
# VJ146A2_MAX_DATES_PER_MONTH=1 Rscript Builder/settlement_day_panel_build_vj146a2.R
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

safe_mean <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) == 0) return(NA_real_)
  mean(x)
}

safe_median <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) == 0) return(NA_real_)
  median(x)
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

extract_one_settlement <- function(values, coverage_fraction) {
  valid <- as.numeric(values$valid)
  lit <- as.numeric(values$lit)
  rad <- as.numeric(values$rad)
  cell_area_m2 <- as.numeric(values$cell_area_m2)
  cf <- as.numeric(coverage_fraction)

  valid_w <- ifelse(is.na(valid), 0, valid) * cf
  lit_w <- ifelse(is.na(lit), 0, lit) * cf
  rad_ok <- is.finite(rad) & is.finite(cf) & cf > 0
  cf_ok <- is.finite(cf) & cf > 0

  data.frame(
    n_valid = sum(valid_w, na.rm = TRUE),
    n_lit = sum(lit_w, na.rm = TRUE),
    n_total_overlap = sum(cf[cf_ok], na.rm = TRUE),
    rad_sum = ifelse(any(rad_ok), sum(rad[rad_ok] * cf[rad_ok], na.rm = TRUE), 0),
    median_rad_sett = weighted_median(rad, cf),
    valid_area_m2 = sum(cell_area_m2 * valid_w, na.rm = TRUE)
  )
}

make_daily_summary <- function(sett_day, days_in_month, missing_dates) {
  observed <- sett_day %>%
    group_by(date) %>%
    summarise(
      status = "observed",
      n_settlements = n(),
      population_sum = sum(population, na.rm = TRUE),
      mean_coverage = safe_mean(coverage),
      median_coverage = safe_median(coverage),
      mean_p_lit_sett = safe_mean(p_lit_sett),
      median_p_lit_sett = safe_median(p_lit_sett),
      popw_mean_p_lit_sett = safe_weighted_mean(p_lit_sett, population),
      popw_share_dark = safe_weighted_mean(as.numeric(dark), population),
      mean_mean_rad_sett = safe_mean(mean_rad_sett),
      median_mean_rad_sett = safe_median(mean_rad_sett),
      popw_mean_rad_sett = safe_weighted_mean(mean_rad_sett, population),
      median_median_rad_sett = safe_median(median_rad_sett),
      .groups = "drop"
    )

  calendar <- tibble(date = days_in_month) %>%
    mutate(status = ifelse(date %in% missing_dates, "missing_raster", "not_processed"))

  calendar %>%
    select(date, status) %>%
    left_join(observed %>% select(-status), by = "date") %>%
    mutate(status = ifelse(date %in% observed$date, "observed", status))
}

validate_month_output <- function(sett_day, month_summary) {
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
    "coverage_count",
    "p_lit_sett",
    "lit_day",
    "dark_day",
    "dark",
    "settlement_state",
    "population"
  )
  missing_cols <- setdiff(required_cols, names(sett_day))
  if (length(missing_cols) > 0) {
    stop("Required columns missing: ", paste(missing_cols, collapse = ", "))
  }
  if (any(sett_day$p_lit_sett < -1e-9 | sett_day$p_lit_sett > 1 + 1e-9, na.rm = TRUE)) {
    stop("Found p_lit_sett outside [0, 1].")
  }
  if (any(sett_day$coverage < -1e-9 | sett_day$coverage > 1 + 1e-9, na.rm = TRUE)) {
    stop("Found coverage outside [0, 1].")
  }
  if (any(abs(sett_day$p_lit_sett - sett_day$mean_lit_sett) > 1e-12, na.rm = TRUE)) {
    stop("p_lit_sett and mean_lit_sett differ.")
  }
  valid_states <- c("lit", "dark", "ambiguous")
  if (any(!is.na(sett_day$settlement_state) & !(sett_day$settlement_state %in% valid_states))) {
    stop("Unexpected settlement_state value.")
  }
  if (!("status" %in% names(month_summary))) stop("Daily summary missing status column.")
  invisible(TRUE)
}

# -----------------------------
# 1) READ INPUTS
# -----------------------------
if (!file.exists(SETT_GPKG)) stop("Settlement GPKG not found: ", SETT_GPKG)
if (!dir.exists(RAST_DIR)) stop("VJ146A2 raster directory not found: ", RAST_DIR)
if (!is.finite(PIXEL_LIT_THRESHOLD)) stop("Invalid VJ146A2_PIXEL_LIT_THRESHOLD.")
if (!grepl("^\\d{4}$", YEAR_LABEL)) stop("Invalid VJ146A2_YEAR; expected YYYY.")

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

in_range <- tif_dates >= month_start & tif_dates <= analysis_end
if (!any(in_range)) {
  stop("No VJ146A2 rasters found in date range ", START_MONTH, " to ", END_MONTH, ".")
}

r0 <- terra::rast(tifs[which(in_range)[1]])
if (is.na(terra::crs(r0))) stop("Raster CRS is missing.")
if (!all(c("rad", "valid") %in% names(r0))) {
  stop("VJ146A2 rasters must include bands named 'rad' and 'valid'.")
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
  pop_full <- sum(sett$population, na.rm = TRUE)
  keep_tbl <- tibble(settlement_id = yearly_keep$settlement_ids)

  sett <- sett %>%
    semi_join(keep_tbl, by = "settlement_id")

  if (nrow(sett) == 0) {
    stop("No settlement geometries remain after applying VJ yearly keep list: ", yearly_keep$source_file)
  }

  message(
    "VJ yearly keep prefilter active: retained ",
    nrow(sett), " / ", n_sett_full, " settlements (",
    round(100 * nrow(sett) / n_sett_full, 2), "%) before exact extraction."
  )
  pop_retained <- sum(sett$population, na.rm = TRUE)
  pop_pct <- if (is.finite(pop_full) && pop_full > 0) round(100 * pop_retained / pop_full, 2) else NA_real_
  message(
    "Population retained before exact extraction: ",
    round(pop_retained), " / ", round(pop_full),
    " (", pop_pct, "%)."
  )
  message("Yearly keep source: ", yearly_keep$source_file)
} else {
  message("VJ146A2_USE_YEARLY_KEEP=0; processing the full settlement universe.")
}

sett <- sf::st_make_valid(sett)
area_m2 <- as.numeric(sf::st_area(sf::st_transform(sett, AREA_CRS)))
if (any(!is.finite(area_m2)) || any(area_m2 <= 0)) {
  stop("Invalid settlement areas after transform to AREA_CRS.")
}
sett <- sett %>% mutate(area_m2 = area_m2)

sett_extract <- sf::st_transform(sett, terra::crs(r0))
sett_meta <- sett %>%
  sf::st_drop_geometry() %>%
  dplyr::select(settlement_id, population, area_m2, any_of(c("lon", "lat")))

message("Settlements for extraction: ", nrow(sett_extract))
message("Target months: ", START_MONTH, " through ", END_MONTH)
message("Pixel lit threshold: rad > ", PIXEL_LIT_THRESHOLD)
if (SMOKE_MODE) {
  message("Smoke mode: processing at most ", MAX_DATES_PER_MONTH, " available date(s) per month.")
  message("Smoke outputs are isolated under: ", OUT_DIR)
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
  available_dates <- days_in_month[format(days_in_month, "%Y-%m-%d") %in% names(tif_map)]
  missing_dates <- setdiff(days_in_month, available_dates)

  if (SMOKE_MODE) {
    available_dates <- head(available_dates, MAX_DATES_PER_MONTH)
  }

  if (length(available_dates) == 0) {
    message("No available VJ146A2 rasters for ", m_str, "; writing missing-date summary only.")
    month_summary <- make_daily_summary(
      tibble(
        date = as.Date(character()),
        population = numeric(),
        coverage = numeric(),
        p_lit_sett = numeric(),
        dark = logical(),
        mean_rad_sett = numeric(),
        median_rad_sett = numeric()
      ),
      days_in_month,
      missing_dates
    )
    out_summary <- file.path(OUT_DIR, paste0("settlement_day_vj146a2_nocov", OUTPUT_SUFFIX, "_", m_str, "_daily_summary.csv"))
    utils::write.csv(month_summary, out_summary, row.names = FALSE)
    next
  }

  results <- vector("list", length(available_dates))

  for (i in seq_along(available_dates)) {
    d <- available_dates[i]
    d_str <- format(d, "%Y-%m-%d")
    f <- unname(tif_map[d_str])

    if (!file.exists(f) || file.info(f)$size == 0) {
      message("Bad or missing file for ", d_str, " - skipping")
      next
    }

    message("[", i, "/", length(available_dates), "] Processing ", d_str, ": ", basename(f))
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
        coverage_count = ifelse(n_total_overlap > 0, n_valid / n_total_overlap, NA_real_),
        lit_day = ifelse(!is.na(p_lit_sett), as.integer(p_lit_sett >= SETTLEMENT_LIT_THRESHOLD), NA_integer_),
        dark_day = ifelse(!is.na(p_lit_sett), as.integer(p_lit_sett < SETTLEMENT_DARK_THRESHOLD), NA_integer_),
        dark = p_lit_sett < SETTLEMENT_DARK_THRESHOLD,
        settlement_state = case_when(
          is.na(p_lit_sett) ~ NA_character_,
          p_lit_sett >= SETTLEMENT_LIT_THRESHOLD ~ "lit",
          p_lit_sett < SETTLEMENT_DARK_THRESHOLD ~ "dark",
          TRUE ~ "ambiguous"
        ),
        source_product = "VJ146A2",
        pixel_lit_threshold = PIXEL_LIT_THRESHOLD
      ) %>%
      select(
        settlement_id,
        date,
        n_valid,
        n_lit,
        n_total_overlap,
        rad_sum,
        mean_lit_sett,
        median_lit_sett,
        mean_rad_sett,
        median_rad_sett,
        valid_area_m2,
        area_m2,
        coverage,
        coverage_count,
        p_lit_sett,
        lit_day,
        dark_day,
        dark,
        settlement_state,
        population,
        any_of(c("lon", "lat")),
        source_product,
        pixel_lit_threshold
      )

    results[[i]] <- df_day
    message("  Rows: ", nrow(df_day), " | mean coverage: ", round(mean(df_day$coverage, na.rm = TRUE), 3))
  }

  sett_day <- bind_rows(results)
  if (nrow(sett_day) == 0) {
    message("No extractable rasters for ", m_str, "; skipping monthly parquet.")
    next
  }

  month_summary <- make_daily_summary(sett_day, days_in_month, missing_dates)
  validate_month_output(sett_day, month_summary)

  out_parq <- file.path(OUT_DIR, paste0("settlement_day_vj146a2_nocov", OUTPUT_SUFFIX, "_", m_str, ".parquet"))
  out_summary <- file.path(OUT_DIR, paste0("settlement_day_vj146a2_nocov", OUTPUT_SUFFIX, "_", m_str, "_daily_summary.csv"))

  arrow::write_parquet(sett_day, out_parq)
  utils::write.csv(month_summary, out_summary, row.names = FALSE)

  message("Wrote parquet: ", out_parq, " rows: ", nrow(sett_day))
  message("Wrote daily summary: ", out_summary, " rows: ", nrow(month_summary))
}

message("Done.")
