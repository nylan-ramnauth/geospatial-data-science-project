# ============================================================
# Build Reliability States and Aggregate Metrics
# Stage 3 — Reliability Panel
# ============================================================
#
# Purpose:  Reads coverage-filtered settlement-day Parquets; builds daily
#           lit/dark states using rolling-window logic; computes Date of
#           Electrification (DOE) and aggregates to settlement, local-area,
#           and supply-area level at monthly, quarterly, and yearly granularity.
# Inputs:   - Map Data/settlement_day_outputs_rasters_blackmarbler/settlement_day_blackmarbler_cov_YYYY-MM.parquet
#           - Map Data/Local Area/LOCAL_AREA_GCCA2025.shp
#           - Map Data/Supply Area/SUPPLY_AREA_GCCA2025.shp
# Outputs:  - Map Data/reliability_outputs_blackmarbler/settlement_reliability_*.parquet
#           - Map Data/reliability_outputs_blackmarbler/localarea_reliability_*.parquet
#           - Map Data/reliability_outputs_blackmarbler/supplyarea_reliability_*.parquet
# Run:      Rscript Visualizer/reliability_panel_build.R
# ============================================================

# Housekeeping
rm(list = ls())

suppressPackageStartupMessages({
  library(here)
  library(sf)
  library(dplyr)
  library(arrow)
  library(stringr)
  library(lubridate)
  library(tidyr)
  library(slider)
  library(purrr)
})

sf::sf_use_s2(FALSE)
if (requireNamespace("data.table", quietly = TRUE)) {
  data.table::setDTthreads(0L)
}

# -----------------------------
# CONFIG
# -----------------------------
BASE_PATH <- here::here()

IN_DIR <- file.path(BASE_PATH, "Map Data", "settlement_day_outputs_rasters_blackmarbler")
OUT_DIR <- file.path(BASE_PATH, "Map Data", "reliability_outputs_blackmarbler")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

LOCAL_AREAS_SHP <- file.path(BASE_PATH, "Map Data", "Local Area","LOCAL_AREA_GCCA2025.shp")
SUPPLY_AREAS_SHP <- file.path(BASE_PATH, "Map Data", "Supply Area","SUPPLY_AREA_GCCA2025.shp")
SETT_FULL_GPKG <- file.path(
  BASE_PATH,
  "Map Data",
  "Settlements",
  "GPKG",
  "south_africa_dre_atlas_settlements_simplified_full_col.gpkg"
)
SETT_FULL_LAYER <- "settlements_simplified"

START_MONTH <- "2023-01"
END_MONTH <- "2023-12"

# Thresholds chosen by user
LIT_THRESHOLD <- 0.4
DARK_THRESHOLD <- 0.05
ROLLING_DAYS <- 30L
ROLLING_LIT_MIN <- 17L
ROLLING_OBS_MIN <- 20L

N_DAYS_MIN_MONTH <- 10L
N_DAYS_MIN_QUARTER <- 40L
N_DAYS_MIN_YEAR <- 85L
AREA_COVERAGE_MIN <- 0.25
NEAR_SUPPORT_DAYS_BUFFER <- 10L
NEAR_AREA_COVERAGE_BUFFER <- 0.05
NEAR_DOE_MARGIN_BUFFER <- 2L

# Moonlight / stray-light mitigation (date exclusion)
# - Excludes whole days from the panel before building lit_day/rolling windows.
# - Recommended: "obvious" (19 days). "maybe" is aggressive (~91 days in your 2023 screen).
MOONLIGHT_FILTER_MODE <- "none" # none | obvious | maybe
MOONLIGHT_DAYS_OBVIOUS <- file.path(
  BASE_PATH,
  "blackmarbler",
  "out_vnp46a2_sa_daily",
  "animations",
  "sa_blackmarble_2023_visually_obvious_contamination_days.txt"
)
MOONLIGHT_DAYS_MAYBE <- file.path(
  BASE_PATH,
  "blackmarbler",
  "out_vnp46a2_sa_daily",
  "animations",
  "sa_blackmarble_2023_maybe_contaminated_days.txt"
)

# Output/caches suffix (prevents overwriting unfiltered outputs).
OUTPUT_SUFFIX <- if (MOONLIGHT_FILTER_MODE == "none") "" else paste0("_moonfilter_", MOONLIGHT_FILTER_MODE)

# Execution mode and cache behavior:
# - "auto": reuse caches when available, otherwise rebuild
# - "full": force rebuild of enrichment + states
# - "metrics_only": require cached states (fastest)
RUN_MODE <- "full"
REUSE_EXISTING_ENRICHED <- TRUE
REUSE_EXISTING_STATES <- TRUE
PREFER_SINGLE_YEARLY_ENRICHED <- TRUE
USE_CACHED_STATES_IN_AUTO <- TRUE
WRITE_DIAGNOSTICS <- TRUE
DIAG_DIR <- file.path(OUT_DIR, "diagnostics")
if (WRITE_DIAGNOSTICS) dir.create(DIAG_DIR, recursive = TRUE, showWarnings = FALSE)

# -----------------------------
# HELPERS
# -----------------------------
first_non_na <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA)
  x[[1]]
}

weighted_mean_na <- function(x, w) {
  idx <- !is.na(x) & !is.na(w)
  if (!any(idx)) return(NA_real_)
  sum(x[idx] * w[idx]) / sum(w[idx])
}

log_step <- function(...) {
  cat(format(Sys.time(), "%H:%M:%S"), "-", ..., "\n")
  flush.console()
}

quantile_safe <- function(x, p) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA_real_)
  as.numeric(stats::quantile(x, probs = p, na.rm = TRUE))
}

period_from_date <- function(date, period_name) {
  switch(
    period_name,
    monthly = lubridate::floor_date(date, "month"),
    quarterly = lubridate::floor_date(date, "quarter"),
    yearly = lubridate::floor_date(date, "year"),
    stop("Invalid period_name: ", period_name)
  )
}

read_exclude_dates <- function(mode) {
  mode <- tolower(mode)
  if (mode == "none") return(as.Date(character(0)))
  if (!mode %in% c("obvious", "maybe")) stop("MOONLIGHT_FILTER_MODE must be one of: none, obvious, maybe")

  path <- if (mode == "obvious") MOONLIGHT_DAYS_OBVIOUS else MOONLIGHT_DAYS_MAYBE
  if (!file.exists(path)) {
    stop(
      "Moonlight filter enabled but list file is missing: ", path, "\n",
      "Generate it from the GIF screening step, or set MOONLIGHT_FILTER_MODE <- 'none'."
    )
  }

  lines <- trimws(readLines(path, warn = FALSE))
  lines <- lines[nzchar(lines)]
  d <- as.Date(lines)
  d <- d[!is.na(d)]
  sort(unique(d))
}

build_daily_states_dt <- function(df) {
  if (!requireNamespace("data.table", quietly = TRUE)) {
    stop("Package 'data.table' is required for state construction. Install it with install.packages('data.table').")
  }

  dt <- data.table::as.data.table(df)
  dt[, settlement_id := as.character(settlement_id)]
  dt[, date := as.Date(date)]
  data.table::setorder(dt, settlement_id, date)

  date_min <- min(dt$date, na.rm = TRUE)
  date_max <- max(dt$date, na.rm = TRUE)
  if (!is.finite(date_min) || !is.finite(date_max)) {
    stop("Invalid date range in input panel.")
  }
  calendar <- data.table::CJ(
    settlement_id = unique(dt$settlement_id),
    date = seq.Date(date_min, date_max, by = "day"),
    unique = TRUE
  )
  dt <- dt[calendar, on = .(settlement_id, date)]
  data.table::setorder(dt, settlement_id, date)

  for (name in c("population", "lon", "lat")) {
    if (name %in% names(dt)) {
      dt[, (name) := data.table::nafill(get(name), type = "locf"), by = settlement_id]
      dt[, (name) := data.table::nafill(get(name), type = "nocb"), by = settlement_id]
    }
  }

  dt[, lit_day := data.table::fifelse(
    is.na(p_lit_sett),
    NA_integer_,
    data.table::fifelse(p_lit_sett >= LIT_THRESHOLD, 1L, 0L)
  )]
  dt[, dark_day := data.table::fifelse(
    is.na(p_lit_sett),
    NA_integer_,
    data.table::fifelse(p_lit_sett < DARK_THRESHOLD, 1L, 0L)
  )]

  dt[, n_lit30 := {
    lit_one <- as.integer(lit_day == 1L)
    lit_one[is.na(lit_one)] <- 0L
    rev(data.table::frollsum(rev(lit_one), n = ROLLING_DAYS, align = "right"))
  }, by = settlement_id]
  dt[, n_obs30 := {
    obs_one <- as.integer(!is.na(lit_day))
    rev(data.table::frollsum(rev(obs_one), n = ROLLING_DAYS, align = "right"))
  }, by = settlement_id]

  dt[, window_mode_30d := "forward"]
  dt[, electrified_30d_strict := data.table::fifelse(
    !is.na(n_obs30) & n_obs30 >= ROLLING_OBS_MIN,
    data.table::fifelse(n_lit30 >= ROLLING_LIT_MIN, 1L, 0L),
    NA_integer_
  )]

  dt[, doe_strict := {
    idx <- which(electrified_30d_strict == 1L)
    if (length(idx) > 0) date[idx[1L]] else as.Date(NA)
  }, by = settlement_id]
  dt[, electrified_after_doe_strict := data.table::fifelse(
    !is.na(doe_strict) & date >= doe_strict,
    1L,
    0L
  )]

  data.table::setDF(dt)
  dt
}

compute_settlement_base_metrics <- function(df_obs, period_col, n_days_min, keep_all = FALSE) {
  if (!requireNamespace("data.table", quietly = TRUE)) {
    stop("Package 'data.table' is required for settlement metrics.")
  }

  period_nm <- period_col
  by_cols <- c("settlement_id", period_nm)

  dt <- data.table::as.data.table(df_obs)
  data.table::setorderv(dt, c("settlement_id", period_nm, "date"))

  dt[, lit_lag := data.table::shift(lit_day), by = by_cols]
  dt[, switch := data.table::fifelse(
    !is.na(lit_day) & !is.na(lit_lag),
    data.table::fifelse(lit_day != lit_lag, 1L, 0L),
    NA_integer_
  )]

  out <- dt[, .(
    n_days_obs = sum(!is.na(p_lit_sett)),
    n_lit_days = sum(lit_day == 1L, na.rm = TRUE),
    n_dark_days = sum(dark_day == 1L, na.rm = TRUE),
    uptime = mean(lit_day, na.rm = TRUE),
    dark_share = mean(dark_day, na.rm = TRUE),
    mean_p_lit = mean(p_lit_sett, na.rm = TRUE),
    sd_p_lit = if (sum(!is.na(p_lit_sett)) >= 2) sd(p_lit_sett, na.rm = TRUE) else NA_real_,
    switch_rate = if (sum(!is.na(switch)) > 0) mean(switch, na.rm = TRUE) else NA_real_,
    mean_coverage = mean(coverage, na.rm = TRUE)
  ), by = by_cols]

  out[, cv_p_lit := data.table::fifelse(
    !is.na(mean_p_lit) & mean_p_lit > 0,
    sd_p_lit / mean_p_lit,
    NA_real_
  )]
  out[, support_ok := n_days_obs >= n_days_min]
  if (!keep_all) out <- out[support_ok == TRUE]
  data.table::setDF(out)
  out
}

compute_state_shares <- function(df_obs, period_col, state_col) {
  if (!requireNamespace("data.table", quietly = TRUE)) {
    stop("Package 'data.table' is required for state share metrics.")
  }

  period_nm <- period_col
  state_nm <- state_col
  by_cols <- c("settlement_id", period_nm)

  dt <- data.table::as.data.table(df_obs)
  out <- dt[, .(state_days_obs = sum(!is.na(get(state_nm)))), by = by_cols]

  data.table::setDF(out)
  out
}

compute_settlement_metrics <- function(base_metrics, state_shares, period_col) {
  if (!requireNamespace("data.table", quietly = TRUE)) {
    stop("Package 'data.table' is required for settlement metrics join.")
  }

  join_keys <- c("settlement_id", period_col)
  dt_base <- data.table::as.data.table(base_metrics)
  dt_state <- data.table::as.data.table(state_shares)

  data.table::setkeyv(dt_base, join_keys)
  data.table::setkeyv(dt_state, join_keys)

  out <- dt_state[dt_base]
  out[is.na(state_days_obs), state_days_obs := 0L]

  data.table::setDF(out)
  out
}

compute_area_metrics <- function(sett_metrics, settlement_static, lookup, area_col, period_col, return_diag = FALSE) {
  if (!requireNamespace("data.table", quietly = TRUE)) {
    stop("Package 'data.table' is required for area metrics.")
  }

  sett_pop <- settlement_static %>%
    select(settlement_id, population) %>%
    distinct(settlement_id, .keep_all = TRUE)

  lookup_std <- lookup %>%
    rename(area_name = all_of(area_col))

  dt_sett_pop <- data.table::as.data.table(sett_pop)
  dt_lookup <- data.table::as.data.table(lookup_std)
  dt_sett <- data.table::as.data.table(sett_metrics)

  dt_sett_pop[, settlement_id := as.character(settlement_id)]
  dt_lookup[, settlement_id := as.character(settlement_id)]
  dt_sett[, settlement_id := as.character(settlement_id)]

  dt_sett_pop <- unique(dt_sett_pop, by = "settlement_id")
  dt_lookup <- unique(dt_lookup, by = c("settlement_id", "area_name"))

  dt_area_pop <- merge(dt_lookup, dt_sett_pop, by = "settlement_id", all.x = TRUE)
  dt_area_pop <- dt_area_pop[!is.na(area_name) & !is.na(population),
    .(area_population = sum(population)),
    by = .(area_name)
  ]

  if (!("population" %in% names(dt_sett))) dt_sett[, population := NA_real_]
  dt_sett <- merge(dt_sett, dt_sett_pop, by = "settlement_id", all.x = TRUE, suffixes = c("", ".static"))
  dt_sett[, population := data.table::fcoalesce(population, population.static)]
  dt_sett[, population.static := NULL]

  dt_sett <- merge(dt_sett, dt_lookup, by = "settlement_id", all.x = TRUE, allow.cartesian = TRUE)
  dt_sett <- dt_sett[!is.na(area_name) & !is.na(population)]

  by_cols <- c("area_name", period_col)
  out <- dt_sett[, .(
    n_settlements = data.table::uniqueN(settlement_id),
    kept_population = sum(population, na.rm = TRUE),
    uptime_popw = weighted_mean_na(uptime, population),
    dark_share_popw = weighted_mean_na(dark_share, population),
    mean_p_lit_popw = weighted_mean_na(mean_p_lit, population),
    switch_rate_popw = weighted_mean_na(switch_rate, population),
    mean_coverage_popw = weighted_mean_na(mean_coverage, population)
  ), by = by_cols]

  out <- out[dt_area_pop, on = .(area_name)]
  out[, share_population_kept := data.table::fifelse(
    area_population > 0,
    kept_population / area_population,
    NA_real_
  )]
  out_all <- data.table::copy(out)
  out <- out_all[!is.na(share_population_kept) & share_population_kept >= AREA_COVERAGE_MIN]

  if (!return_diag) {
    data.table::setDF(out)
    return(out)
  }

  period_vals <- sort(unique(dt_sett[[period_col]]))
  area_vals <- sort(unique(dt_area_pop$area_name))

  if (length(period_vals) == 0 || length(area_vals) == 0) {
    diag <- data.table::data.table()
  } else {
    diag_grid <- data.table::CJ(
      area_name = area_vals,
      period_value = period_vals,
      unique = TRUE
    )
    data.table::setnames(diag_grid, "period_value", period_col)
    diag <- merge(diag_grid, out_all, by = c("area_name", period_col), all.x = TRUE)
    diag[, drop_reason := data.table::fifelse(
      is.na(n_settlements),
      "no_settlement_rows",
      data.table::fifelse(
        is.na(share_population_kept),
        "missing_coverage",
        data.table::fifelse(
          share_population_kept < AREA_COVERAGE_MIN,
          "below_area_coverage_min",
          "kept"
        )
      )
    )]
    diag[, kept := drop_reason == "kept"]
  }

  data.table::setDF(out)
  data.table::setDF(diag)
  list(metrics = out, diagnostics = diag)
}

# -----------------------------
# 1) READ MONTHLY COVERAGE-QUALIFIED INPUTS
# -----------------------------
month_start <- as.Date(paste0(START_MONTH, "-01"))
month_end <- as.Date(paste0(END_MONTH, "-01"))
stopifnot(!is.na(month_start), !is.na(month_end), month_start <= month_end)
stopifnot(RUN_MODE %in% c("auto", "full", "metrics_only"))
run_tag <- paste0(format(month_start, "%Y-%m"), "_to_", format(month_end, "%Y-%m"), OUTPUT_SUFFIX)
diag_summary_parts <- list()
dashboard_parts <- list()

months_seq <- seq.Date(from = month_start, to = month_end, by = "month")
analysis_end <- seq.Date(from = month_end, by = "month", length.out = 2)[2] - 1
input_files <- file.path(
  IN_DIR,
  paste0("settlement_day_blackmarbler_cov_", format(months_seq, "%Y-%m"), ".parquet")
)

enriched_dir <- file.path(
  OUT_DIR,
  paste0(
    "settlement_day_combined_cov_enriched_",
    format(month_start, "%Y-%m"),
    "_to_",
    format(month_end, "%Y-%m")
  )
)
dir.create(enriched_dir, recursive = TRUE, showWarnings = FALSE)

yearly_combined_dir <- file.path(
  OUT_DIR,
  paste0(
    "settlement_day_combined_cov_enriched_yearly_dataset_",
    format(month_start, "%Y-%m"),
    "_to_",
    format(month_end, "%Y-%m")
  )
)
dir.create(yearly_combined_dir, recursive = TRUE, showWarnings = FALSE)

# Optional single-file yearly parquet export via DuckDB (streaming, low memory)
single_yearly_file <- file.path(
  OUT_DIR,
  paste0(
    "settlement_day_combined_cov_enriched_",
    format(month_start, "%Y-%m"),
    "_to_",
    format(month_end, "%Y-%m"),
    ".parquet"
  )
)

state_file <- file.path(OUT_DIR, paste0("settlement_day_states_strict", OUTPUT_SUFFIX, ".parquet"))
legacy_state_file <- file.path(OUT_DIR, paste0("settlement_day_states_strict_hysteresis", OUTPUT_SUFFIX, ".parquet"))
state_file_to_read <- if (file.exists(state_file)) state_file else legacy_state_file

expected_enriched_monthly_files <- file.path(
  enriched_dir,
  paste0("settlement_day_combined_cov_enriched_", format(months_seq, "%Y-%m"), ".parquet")
)

has_cached_states <- REUSE_EXISTING_STATES && file.exists(state_file_to_read)
has_single_yearly_enriched <- REUSE_EXISTING_ENRICHED && file.exists(single_yearly_file)
has_enriched_monthlies <- REUSE_EXISTING_ENRICHED && all(file.exists(expected_enriched_monthly_files))

log_step(
  "Cache scan | states:", has_cached_states,
  "| single_yearly:", has_single_yearly_enriched,
  "| enriched_monthlies:", has_enriched_monthlies
)

exclude_dates <- read_exclude_dates(MOONLIGHT_FILTER_MODE)
log_step(
  "Moonlight filter | mode:", MOONLIGHT_FILTER_MODE,
  "| exclude days:", length(exclude_dates),
  "| output suffix:", ifelse(nzchar(OUTPUT_SUFFIX), OUTPUT_SUFFIX, "(none)")
)

if (WRITE_DIAGNOSTICS) {
  dashboard_parts[[length(dashboard_parts) + 1L]] <- data.frame(
    run_tag = run_tag,
    section = "config_thresholds",
    metric = c(
      "lit_threshold", "dark_threshold", "rolling_days", "rolling_lit_min",
      "rolling_obs_min", "n_days_min_month", "n_days_min_quarter",
      "n_days_min_year", "area_coverage_min", "moonlight_filter_mode",
      "excluded_days"
    ),
    value = c(
      LIT_THRESHOLD, DARK_THRESHOLD, ROLLING_DAYS, ROLLING_LIT_MIN,
      ROLLING_OBS_MIN, N_DAYS_MIN_MONTH, N_DAYS_MIN_QUARTER,
      N_DAYS_MIN_YEAR, AREA_COVERAGE_MIN, MOONLIGHT_FILTER_MODE,
      length(exclude_dates)
    ),
    stringsAsFactors = FALSE
  )
}

if (WRITE_DIAGNOSTICS && file.exists(single_yearly_file)) {
  moonlight_prefilter_daily <- arrow::read_parquet(
    single_yearly_file,
    col_select = any_of(c("date", "p_lit_sett"))
  ) %>%
    mutate(date = as.Date(date)) %>%
    filter(date >= month_start, date <= analysis_end) %>%
    group_by(date) %>%
    summarise(
      n_obs = sum(!is.na(p_lit_sett)),
      n_lit = sum(!is.na(p_lit_sett) & p_lit_sett >= LIT_THRESHOLD),
      lit_share = ifelse(n_obs > 0, n_lit / n_obs, NA_real_),
      .groups = "drop"
    ) %>%
    mutate(is_excluded = date %in% exclude_dates)

  lit_share_spike95 <- quantile_safe(moonlight_prefilter_daily$lit_share[!moonlight_prefilter_daily$is_excluded], 0.95)

  moonlight_prefilter_daily <- moonlight_prefilter_daily %>%
    mutate(
      lit_share_spike95 = lit_share_spike95,
      is_spike95 = !is.na(lit_share) & !is.na(lit_share_spike95) & lit_share >= lit_share_spike95
    )

  moonlight_prefilter_summary <- moonlight_prefilter_daily %>%
    summarise(
      run_tag = run_tag,
      section = "moonlight_prefilter_summary",
      n_days = n(),
      n_excluded_days = sum(is_excluded, na.rm = TRUE),
      n_days_with_obs = sum(n_obs > 0, na.rm = TRUE),
      n_spike95_days = sum(is_spike95, na.rm = TRUE),
      n_spike95_on_excluded = sum(is_spike95 & is_excluded, na.rm = TRUE),
      n_spike95_on_nonexcluded = sum(is_spike95 & !is_excluded, na.rm = TRUE),
      mean_lit_share = mean(lit_share, na.rm = TRUE),
      p95_lit_share_nonexcluded = lit_share_spike95,
      .groups = "drop"
    )

  dashboard_parts[[length(dashboard_parts) + 1L]] <- moonlight_prefilter_summary
}

sett_day_states <- NULL
settlement_static <- NULL

if (RUN_MODE == "metrics_only" || (RUN_MODE == "auto" && USE_CACHED_STATES_IN_AUTO && has_cached_states)) {
  if (!has_cached_states) {
    stop("RUN_MODE='metrics_only' requires cached states file: ", state_file)
  }
  state_candidate <- arrow::read_parquet(state_file_to_read) %>%
    mutate(date = as.Date(date))
  required_state_cols <- c(
    "settlement_id", "date", "p_lit_sett", "coverage",
    "lit_day", "dark_day", "electrified_after_doe_strict"
  )
  missing_state_cols <- setdiff(required_state_cols, names(state_candidate))

  if (length(missing_state_cols) > 0) {
    if (RUN_MODE == "metrics_only") {
      stop(
        "Cached states file is incompatible (missing: ",
        paste(missing_state_cols, collapse = ", "),
        "). Rebuild once with RUN_MODE='auto' or RUN_MODE='full'."
      )
    }
    log_step(
      "Cached states incompatible, rebuilding states. Missing:",
      paste(missing_state_cols, collapse = ", ")
    )
  } else {
    sett_day_states <- state_candidate
    log_step("Loaded cached states:", state_file_to_read)
  }
}

if (is.null(sett_day_states)) {
  sett_day <- NULL

  if (RUN_MODE != "full" && PREFER_SINGLE_YEARLY_ENRICHED && has_single_yearly_enriched) {
    sett_day <- arrow::read_parquet(single_yearly_file) %>%
      mutate(date = as.Date(date))
    log_step("Loaded cached single yearly enriched file:", single_yearly_file)
  } else if (RUN_MODE != "full" && has_enriched_monthlies) {
    sett_day <- purrr::map_dfr(expected_enriched_monthly_files, arrow::read_parquet) %>%
      mutate(date = as.Date(date))
    log_step("Loaded cached enriched monthly files from:", enriched_dir)
  } else {
    existing_files <- input_files[file.exists(input_files)]
    if (length(existing_files) == 0) {
      stop("No monthly coverage-qualified parquet files found in range.")
    }

    required_cols <- c("settlement_id", "date", "p_lit_sett", "coverage")
    static_cols <- c("population", "lon", "lat")
    if (!file.exists(SETT_FULL_GPKG)) {
      stop("Settlement GPKG not found: ", SETT_FULL_GPKG)
    }

    gpkg_all <- st_read(SETT_FULL_GPKG, layer = SETT_FULL_LAYER, quiet = TRUE) %>%
      st_drop_geometry() %>%
      select(-any_of("hull_area")) %>%
      distinct(settlement_id, .keep_all = TRUE) %>%
      mutate(settlement_id = as.character(settlement_id))

    gpkg_required <- c("settlement_id", static_cols)
    gpkg_missing <- setdiff(gpkg_required, names(gpkg_all))
    if (length(gpkg_missing) > 0) {
      stop("Settlement GPKG is missing columns: ", paste(gpkg_missing, collapse = ", "))
    }

    use_dt <- requireNamespace("data.table", quietly = TRUE)
    if (!use_dt) {
      message("Package 'data.table' not available; month-level enrichment uses slower dplyr joins.")
    }

    sett_day_parts <- vector("list", length(existing_files))

    if (use_dt) {
      dt_gpkg_all <- data.table::as.data.table(gpkg_all)
      dt_gpkg_all[, settlement_id := as.character(settlement_id)]
      data.table::setkey(dt_gpkg_all, settlement_id)
    }

    for (i in seq_along(existing_files)) {
      in_file <- existing_files[i]
      m_tag <- stringr::str_match(basename(in_file), "(\\d{4}-\\d{2})")[, 2]
      if (is.na(m_tag)) m_tag <- sprintf("part_%02d", i)

      part <- arrow::read_parquet(in_file) %>%
        mutate(date = as.Date(date))

      missing_cols <- setdiff(required_cols, names(part))
      if (length(missing_cols) > 0) {
        stop("Missing required columns in input data (", basename(in_file), "): ", paste(missing_cols, collapse = ", "))
      }

      t_join_start <- Sys.time()
      if (use_dt) {
        dt_part <- data.table::as.data.table(part)
        dt_part[, settlement_id := as.character(settlement_id)]
        data.table::setkey(dt_part, settlement_id)

        cols_new <- setdiff(names(dt_gpkg_all), c("settlement_id", names(dt_part)))
        if (length(cols_new) > 0) {
          dt_part[dt_gpkg_all, (cols_new) := mget(paste0("i.", cols_new))]
        }

        for (nm in static_cols) {
          if (!(nm %in% names(dt_part))) dt_part[, (nm) := NA_real_]
          dt_part[dt_gpkg_all, (nm) := data.table::fcoalesce(get(nm), get(paste0("i.", nm)))]
        }

        data.table::setDF(dt_part)
        part <- dt_part
      } else {
        gpkg_join_cols <- union("settlement_id", c(setdiff(names(gpkg_all), names(part)), static_cols))
        gpkg_join <- gpkg_all %>% select(any_of(gpkg_join_cols))

        part <- part %>%
          mutate(settlement_id = as.character(settlement_id)) %>%
          left_join(gpkg_join, by = "settlement_id", suffix = c("", ".gpkg")) %>%
          mutate(
            population = coalesce(population, population.gpkg),
            lon = coalesce(lon, lon.gpkg),
            lat = coalesce(lat, lat.gpkg)
          ) %>%
          select(-any_of(c("population.gpkg", "lon.gpkg", "lat.gpkg")))
      }
      message("Settlement enrichment join [", m_tag, "] took: ", round(as.numeric(difftime(Sys.time(), t_join_start, units = "secs")), 2), " sec")

      missing_static_after <- setdiff(static_cols, names(part))
      if (length(missing_static_after) > 0) {
        stop("Missing required settlement static columns after GPKG join (", basename(in_file), "): ", paste(missing_static_after, collapse = ", "))
      }

      out_part <- file.path(enriched_dir, paste0("settlement_day_combined_cov_enriched_", m_tag, ".parquet"))
      arrow::write_parquet(part, out_part)

      sett_day_parts[[i]] <- part %>% select(any_of(unique(c(required_cols, static_cols))))
      rm(part)
      gc(FALSE)
    }

    enriched_monthly_files <- list.files(
      enriched_dir,
      pattern = "^settlement_day_combined_cov_enriched_\\d{4}-\\d{2}\\.parquet$",
      full.names = TRUE
    )
    if (length(enriched_monthly_files) == 0) {
      stop("No enriched monthly parquet files were written in: ", enriched_dir)
    }

    ds_enriched <- arrow::open_dataset(enriched_monthly_files, format = "parquet")
    arrow::write_dataset(
      ds_enriched,
      path = yearly_combined_dir,
      format = "parquet",
      existing_data_behavior = "overwrite"
    )
    message("Wrote yearly combined enriched dataset: ", yearly_combined_dir)

    if (requireNamespace("DBI", quietly = TRUE) && requireNamespace("duckdb", quietly = TRUE)) {
      duck_con <- DBI::dbConnect(duckdb::duckdb())
      tryCatch(
        {
          glob_path <- file.path(enriched_dir, "*.parquet")
          glob_sql <- gsub("'", "''", glob_path, fixed = TRUE)
          out_sql <- gsub("'", "''", single_yearly_file, fixed = TRUE)
          DBI::dbExecute(
            duck_con,
            paste0(
              "COPY (SELECT * FROM read_parquet('", glob_sql, "')) ",
              "TO '", out_sql, "' (FORMAT PARQUET, COMPRESSION ZSTD)"
            )
          )
          message("Wrote single yearly enriched parquet: ", single_yearly_file)
        },
        finally = {
          DBI::dbDisconnect(duck_con, shutdown = TRUE)
        }
      )
    } else {
      message(
        "Skipping single-file yearly parquet export because 'DBI' and/or 'duckdb' is not installed. ",
        "Run install.packages(c('DBI','duckdb')) to enable it."
      )
    }

    sett_day <- dplyr::bind_rows(sett_day_parts)
    rm(sett_day_parts)
    gc(FALSE)

    message("Wrote enriched monthly combined panel files to: ", enriched_dir)
    message("Built in-memory slim panel for statistics (rows=", nrow(sett_day), ").")
  }

  sett_day <- sett_day %>%
    mutate(date = as.Date(date)) %>%
    filter(date >= month_start, date <= analysis_end)

  if (length(exclude_dates) > 0) {
    before <- nrow(sett_day)
    sett_day <- sett_day %>% filter(!(date %in% exclude_dates))
    log_step(
      "Excluded dates from panel:",
      length(exclude_dates),
      "| rows:", before, "->", nrow(sett_day)
    )
  }

  if (anyDuplicated(sett_day %>% select(settlement_id, date)) > 0) {
    stop("Input panel has duplicate settlement_id-date rows.")
  }

  settlement_static <- sett_day %>%
    group_by(settlement_id) %>%
    summarise(
      population = first_non_na(population),
      lon = first_non_na(lon),
      lat = first_non_na(lat),
      .groups = "drop"
    )

  # -----------------------------
  # 2) BUILD DAILY STATES (STRICT)
  # -----------------------------
  sett_day_states <- build_daily_states_dt(sett_day)

  arrow::write_parquet(
    sett_day_states,
    state_file
  )
  log_step("Wrote strict states cache:", state_file)
}

sett_day_states <- sett_day_states %>%
  mutate(date = as.Date(date)) %>%
  filter(date >= month_start, date <= analysis_end)

# Cached states were built after exclusion; no further filtering is needed here.

if (is.null(settlement_static)) {
  settlement_static <- sett_day_states %>%
    group_by(settlement_id) %>%
    summarise(
      population = first_non_na(population),
      lon = first_non_na(lon),
      lat = first_non_na(lat),
      .groups = "drop"
    )
}

# Only observed days are used for reliability metrics
sett_obs <- sett_day_states %>%
  filter(!is.na(p_lit_sett), electrified_after_doe_strict == 1L) %>%
  mutate(
    month = lubridate::floor_date(date, "month"),
    quarter = lubridate::floor_date(date, "quarter"),
    year = lubridate::floor_date(date, "year")
  )

if (WRITE_DIAGNOSTICS) {
  settlement_stage_diag <- sett_day_states %>%
    group_by(settlement_id) %>%
    summarise(
      n_days_total = n(),
      n_days_observed = sum(!is.na(p_lit_sett)),
      n_days_after_doe = sum(!is.na(p_lit_sett) & electrified_after_doe_strict == 1L),
      has_doe = any(!is.na(doe_strict)),
      .groups = "drop"
    ) %>%
    mutate(
      drop_reason_stage = case_when(
        n_days_observed == 0 ~ "no_observed_days",
        !has_doe ~ "no_doe_in_sample",
        n_days_after_doe == 0 ~ "no_post_doe_observed_days",
        TRUE ~ "kept_for_metrics_pool"
      )
    )
  arrow::write_parquet(
    settlement_stage_diag,
    file.path(DIAG_DIR, paste0("diagnostic_settlement_stage_", run_tag, ".parquet"))
  )
  settlement_stage_summary <- settlement_stage_diag %>%
    count(drop_reason_stage, name = "n") %>%
    transmute(
      run_tag = run_tag,
      stage = "settlement_stage",
      period = "all",
      state = "strict",
      subset = "all",
      drop_reason = as.character(drop_reason_stage),
      n = as.integer(n)
    )
  diag_summary_parts[[length(diag_summary_parts) + 1L]] <- settlement_stage_summary

  settlement_stage_dashboard <- settlement_stage_diag %>%
    left_join(settlement_static %>% select(settlement_id, population), by = "settlement_id") %>%
    group_by(drop_reason_stage) %>%
    summarise(
      run_tag = run_tag,
      section = "settlement_stage_summary",
      n_settlements = n(),
      population = sum(population, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(
      share_settlements = ifelse(sum(n_settlements) > 0, n_settlements / sum(n_settlements), NA_real_),
      share_population = ifelse(sum(population) > 0, population / sum(population), NA_real_)
    )

  dashboard_parts[[length(dashboard_parts) + 1L]] <- settlement_stage_dashboard
  log_step("Wrote diagnostics: settlement-stage drops")
}

# -----------------------------
# 3) SETTLEMENT RELIABILITY OUTPUTS
# -----------------------------
period_specs <- list(
  list(name = "monthly", period_col = "month", min_days = N_DAYS_MIN_MONTH),
  list(name = "quarterly", period_col = "quarter", min_days = N_DAYS_MIN_QUARTER),
  list(name = "yearly", period_col = "year", min_days = N_DAYS_MIN_YEAR)
)

state_name <- "strict"
state_col <- "electrified_after_doe_strict"

local_areas <- st_read(LOCAL_AREAS_SHP, quiet = TRUE)
supply_areas <- st_read(SUPPLY_AREAS_SHP, quiet = TRUE)

sett_points <- settlement_static %>%
  filter(!is.na(lon), !is.na(lat)) %>%
  st_as_sf(coords = c("lon", "lat"), crs = 4326, remove = FALSE)

local_lookup <- st_join(
  st_transform(sett_points, st_crs(local_areas)),
  local_areas["LocalArea"],
  left = TRUE
) %>%
  st_drop_geometry() %>%
  select(settlement_id, LocalArea)

supply_lookup <- st_join(
  st_transform(sett_points, st_crs(supply_areas)),
  supply_areas["SupplyArea"],
  left = TRUE
) %>%
  st_drop_geometry() %>%
  select(settlement_id, SupplyArea)

if (WRITE_DIAGNOSTICS) {
  doe_margin_cols <- c("electrified_30d_strict", "n_obs30", "n_lit30")
  if (all(doe_margin_cols %in% names(sett_day_states))) {
    doe_trigger_margin <- sett_day_states %>%
      filter(electrified_30d_strict == 1L) %>%
      group_by(settlement_id) %>%
      slice_min(date, n = 1, with_ties = FALSE) %>%
      ungroup() %>%
      transmute(
        settlement_id,
        doe_date = as.Date(date),
        n_obs30 = as.integer(n_obs30),
        n_lit30 = as.integer(n_lit30),
        margin_obs30 = as.integer(n_obs30 - ROLLING_OBS_MIN),
        margin_lit30 = as.integer(n_lit30 - ROLLING_LIT_MIN),
        near_obs30 = margin_obs30 >= 0L & margin_obs30 <= NEAR_DOE_MARGIN_BUFFER,
        near_lit30 = margin_lit30 >= 0L & margin_lit30 <= NEAR_DOE_MARGIN_BUFFER
      )

    arrow::write_parquet(
      doe_trigger_margin,
      file.path(DIAG_DIR, paste0("diagnostic_doe_trigger_margin_", run_tag, ".parquet"))
    )

    doe_trigger_summary <- doe_trigger_margin %>%
      summarise(
        run_tag = run_tag,
        section = "doe_trigger_margin_summary",
        n_settlements_doe = n(),
        mean_margin_obs30 = mean(margin_obs30, na.rm = TRUE),
        p10_margin_obs30 = quantile_safe(margin_obs30, 0.10),
        p50_margin_obs30 = quantile_safe(margin_obs30, 0.50),
        p90_margin_obs30 = quantile_safe(margin_obs30, 0.90),
        mean_margin_lit30 = mean(margin_lit30, na.rm = TRUE),
        p10_margin_lit30 = quantile_safe(margin_lit30, 0.10),
        p50_margin_lit30 = quantile_safe(margin_lit30, 0.50),
        p90_margin_lit30 = quantile_safe(margin_lit30, 0.90),
        n_near_obs30 = sum(near_obs30, na.rm = TRUE),
        n_near_lit30 = sum(near_lit30, na.rm = TRUE),
        share_near_obs30 = ifelse(n_settlements_doe > 0, n_near_obs30 / n_settlements_doe, NA_real_),
        share_near_lit30 = ifelse(n_settlements_doe > 0, n_near_lit30 / n_settlements_doe, NA_real_),
        .groups = "drop"
      )

    dashboard_parts[[length(dashboard_parts) + 1L]] <- doe_trigger_summary
  } else {
    dashboard_parts[[length(dashboard_parts) + 1L]] <- data.frame(
      run_tag = run_tag,
      section = "doe_trigger_margin_summary",
      note = "Skipped: state cache missing one or more of electrified_30d_strict, n_obs30, n_lit30",
      stringsAsFactors = FALSE
    )
  }

  settlement_local <- local_lookup %>%
    distinct(settlement_id, LocalArea) %>%
    rename(area_name = LocalArea) %>%
    left_join(settlement_static %>% select(settlement_id, population), by = "settlement_id") %>%
    mutate(population = coalesce(population, 0))

  local_area_population <- settlement_local %>%
    group_by(area_name) %>%
    summarise(area_population = sum(population, na.rm = TRUE), .groups = "drop")

  local_dates <- seq.Date(month_start, analysis_end, by = "day")

  local_daily_coverage <- sett_day_states %>%
    select(settlement_id, date, p_lit_sett, electrified_after_doe_strict) %>%
    inner_join(settlement_local %>% select(settlement_id, area_name, population), by = "settlement_id") %>%
    mutate(
      kept_population_day = ifelse(!is.na(p_lit_sett) & electrified_after_doe_strict == 1L, population, 0)
    ) %>%
    group_by(area_name, date) %>%
    summarise(kept_population_day = sum(kept_population_day, na.rm = TRUE), .groups = "drop")

  local_daily_coverage <- tidyr::expand_grid(
    area_name = sort(unique(local_area_population$area_name)),
    date = local_dates
  ) %>%
    left_join(local_daily_coverage, by = c("area_name", "date")) %>%
    left_join(local_area_population, by = "area_name") %>%
    mutate(
      kept_population_day = coalesce(kept_population_day, 0),
      share_population_kept_day = ifelse(area_population > 0, kept_population_day / area_population, NA_real_),
      pass_area_coverage_day = !is.na(share_population_kept_day) & share_population_kept_day >= AREA_COVERAGE_MIN,
      near_area_coverage_day = !is.na(share_population_kept_day) &
        abs(share_population_kept_day - AREA_COVERAGE_MIN) <= NEAR_AREA_COVERAGE_BUFFER,
      is_excluded = date %in% exclude_dates
    )

  arrow::write_parquet(
    local_daily_coverage,
    file.path(DIAG_DIR, paste0("diagnostic_localarea_daily_coverage_", run_tag, ".parquet"))
  )

  local_daily_coverage_summary <- local_daily_coverage %>%
    group_by(area_name) %>%
    summarise(
      run_tag = run_tag,
      section = "localarea_daily_coverage_summary",
      n_days_total = n(),
      n_days_pass_area_coverage = sum(pass_area_coverage_day, na.rm = TRUE),
      share_days_pass_area_coverage = ifelse(n_days_total > 0, n_days_pass_area_coverage / n_days_total, NA_real_),
      n_days_near_area_coverage = sum(near_area_coverage_day, na.rm = TRUE),
      mean_share_population_kept_day = mean(share_population_kept_day, na.rm = TRUE),
      p50_share_population_kept_day = quantile_safe(share_population_kept_day, 0.50),
      p10_share_population_kept_day = quantile_safe(share_population_kept_day, 0.10),
      p90_share_population_kept_day = quantile_safe(share_population_kept_day, 0.90),
      n_excluded_days = sum(is_excluded, na.rm = TRUE),
      .groups = "drop"
    )

  dashboard_parts[[length(dashboard_parts) + 1L]] <- local_daily_coverage_summary
}

for (period_cfg in period_specs) {
  log_step("Start period:", period_cfg$name)
  t_period <- Sys.time()
  t_base <- Sys.time()
  base_metrics_all <- compute_settlement_base_metrics(
    sett_obs,
    period_col = period_cfg$period_col,
    n_days_min = period_cfg$min_days,
    keep_all = TRUE
  )
  base_metrics <- base_metrics_all %>% filter(support_ok)
  log_step(
    "Base metrics ready for", period_cfg$name,
    "| rows:", nrow(base_metrics),
    "| sec:", round(as.numeric(difftime(Sys.time(), t_base, units = "secs")), 2)
  )
  if (WRITE_DIAGNOSTICS) {
    support_summary <- base_metrics_all %>%
      group_by(.data[[period_cfg$period_col]]) %>%
      summarise(
        total_groups = n(),
        kept_groups = sum(support_ok, na.rm = TRUE),
        dropped_groups = sum(!support_ok, na.rm = TRUE),
        .groups = "drop"
      )
    support_detail <- base_metrics_all %>%
      select(settlement_id, all_of(period_cfg$period_col), n_days_obs, support_ok)
    arrow::write_parquet(
      support_summary,
      file.path(
        DIAG_DIR,
        paste0("diagnostic_support_summary_", period_cfg$name, "_", run_tag, ".parquet")
      )
    )
    arrow::write_parquet(
      support_detail,
      file.path(
        DIAG_DIR,
        paste0("diagnostic_support_detail_", period_cfg$name, "_", run_tag, ".parquet")
      )
    )
    log_step(
      "Support filter", period_cfg$name,
      "| kept:", sum(base_metrics_all$support_ok, na.rm = TRUE),
      "| dropped:", sum(!base_metrics_all$support_ok, na.rm = TRUE)
    )
    support_drop_summary <- base_metrics_all %>%
      mutate(drop_reason = ifelse(support_ok, "kept", "below_min_days_obs")) %>%
      count(drop_reason, name = "n") %>%
      transmute(
        run_tag = run_tag,
        stage = "support_filter",
        period = period_cfg$name,
        state = state_name,
        subset = "all",
        drop_reason = as.character(drop_reason),
        n = as.integer(n)
      )
    diag_summary_parts[[length(diag_summary_parts) + 1L]] <- support_drop_summary

    support_margin_summary <- base_metrics_all %>%
      mutate(
        period_value = .data[[period_cfg$period_col]],
        support_margin_days = n_days_obs - period_cfg$min_days,
        near_support_threshold = !is.na(support_margin_days) &
          abs(support_margin_days) <= NEAR_SUPPORT_DAYS_BUFFER
      ) %>%
      group_by(period_value) %>%
      summarise(
        run_tag = run_tag,
        section = "support_margin_summary",
        period = period_cfg$name,
        n_settlement_periods = n(),
        n_support_ok = sum(support_ok, na.rm = TRUE),
        n_near_support_threshold = sum(near_support_threshold, na.rm = TRUE),
        share_near_support_threshold = ifelse(n_settlement_periods > 0, n_near_support_threshold / n_settlement_periods, NA_real_),
        p10_support_margin_days = quantile_safe(support_margin_days, 0.10),
        p50_support_margin_days = quantile_safe(support_margin_days, 0.50),
        p90_support_margin_days = quantile_safe(support_margin_days, 0.90),
        mean_support_margin_days = mean(support_margin_days, na.rm = TRUE),
        .groups = "drop"
      )

    dashboard_parts[[length(dashboard_parts) + 1L]] <- support_margin_summary
  }
  log_step("State:", state_name, "| period:", period_cfg$name)
  t_state <- Sys.time()
  state_shares <- compute_state_shares(
    sett_obs,
    period_col = period_cfg$period_col,
    state_col = state_col
  )
  sett_metrics <- compute_settlement_metrics(
    base_metrics = base_metrics,
    state_shares = state_shares,
    period_col = period_cfg$period_col
  )

  sett_metrics <- sett_metrics %>%
    left_join(settlement_static %>% select(settlement_id, population, lon, lat), by = "settlement_id")

  out_sett <- file.path(
    OUT_DIR,
    paste0("settlement_reliability_", period_cfg$name, "_", state_name, OUTPUT_SUFFIX, ".parquet")
  )
  arrow::write_parquet(sett_metrics, out_sett)

  local_result <- compute_area_metrics(
    sett_metrics,
    settlement_static = settlement_static,
    lookup = local_lookup,
    area_col = "LocalArea",
    period_col = period_cfg$period_col,
    return_diag = WRITE_DIAGNOSTICS
  )
  local_metrics <- if (WRITE_DIAGNOSTICS) local_result$metrics else local_result

  supply_result <- compute_area_metrics(
    sett_metrics,
    settlement_static = settlement_static,
    lookup = supply_lookup,
    area_col = "SupplyArea",
    period_col = period_cfg$period_col,
    return_diag = WRITE_DIAGNOSTICS
  )
  supply_metrics <- if (WRITE_DIAGNOSTICS) supply_result$metrics else supply_result

  out_local <- file.path(
    OUT_DIR,
    paste0("localarea_reliability_", period_cfg$name, "_", state_name, OUTPUT_SUFFIX, ".parquet")
  )
  out_supply <- file.path(
    OUT_DIR,
    paste0("supplyarea_reliability_", period_cfg$name, "_", state_name, OUTPUT_SUFFIX, ".parquet")
  )

  arrow::write_parquet(local_metrics, out_local)
  arrow::write_parquet(supply_metrics, out_supply)

  if (WRITE_DIAGNOSTICS) {
    arrow::write_parquet(
      local_result$diagnostics,
      file.path(
        DIAG_DIR,
        paste0("diagnostic_localarea_drop_", period_cfg$name, "_", state_name, "_", run_tag, ".parquet")
      )
    )
    arrow::write_parquet(
      supply_result$diagnostics,
      file.path(
        DIAG_DIR,
        paste0("diagnostic_supplyarea_drop_", period_cfg$name, "_", state_name, "_", run_tag, ".parquet")
      )
    )

    if (nrow(local_result$diagnostics) > 0 && "drop_reason" %in% names(local_result$diagnostics)) {
      local_drop_summary <- local_result$diagnostics %>%
        count(drop_reason, name = "n") %>%
        transmute(
          run_tag = run_tag,
          stage = "area_filter_local",
          period = period_cfg$name,
          state = state_name,
          subset = "all",
          drop_reason = as.character(drop_reason),
          n = as.integer(n)
        )
      diag_summary_parts[[length(diag_summary_parts) + 1L]] <- local_drop_summary
    }
    if (nrow(supply_result$diagnostics) > 0 && "drop_reason" %in% names(supply_result$diagnostics)) {
      supply_drop_summary <- supply_result$diagnostics %>%
        count(drop_reason, name = "n") %>%
        transmute(
          run_tag = run_tag,
          stage = "area_filter_supply",
          period = period_cfg$name,
          state = state_name,
          subset = "all",
          drop_reason = as.character(drop_reason),
          n = as.integer(n)
      )
      diag_summary_parts[[length(diag_summary_parts) + 1L]] <- supply_drop_summary
    }

    local_margin_summary <- local_result$diagnostics %>%
      mutate(
        period_value = .data[[period_cfg$period_col]],
        area_coverage_margin = share_population_kept - AREA_COVERAGE_MIN,
        near_area_coverage_threshold = !is.na(area_coverage_margin) &
          abs(area_coverage_margin) <= NEAR_AREA_COVERAGE_BUFFER
      ) %>%
      group_by(period_value) %>%
      summarise(
        run_tag = run_tag,
        section = "area_coverage_margin_summary_local",
        period = period_cfg$name,
        n_area_periods = n(),
        n_kept = sum(drop_reason == "kept", na.rm = TRUE),
        n_near_area_coverage_threshold = sum(near_area_coverage_threshold, na.rm = TRUE),
        share_near_area_coverage_threshold = ifelse(n_area_periods > 0, n_near_area_coverage_threshold / n_area_periods, NA_real_),
        p10_area_coverage_margin = quantile_safe(area_coverage_margin, 0.10),
        p50_area_coverage_margin = quantile_safe(area_coverage_margin, 0.50),
        p90_area_coverage_margin = quantile_safe(area_coverage_margin, 0.90),
        mean_area_coverage_margin = mean(area_coverage_margin, na.rm = TRUE),
        .groups = "drop"
      )
    dashboard_parts[[length(dashboard_parts) + 1L]] <- local_margin_summary

    supply_margin_summary <- supply_result$diagnostics %>%
      mutate(
        period_value = .data[[period_cfg$period_col]],
        area_coverage_margin = share_population_kept - AREA_COVERAGE_MIN,
        near_area_coverage_threshold = !is.na(area_coverage_margin) &
          abs(area_coverage_margin) <= NEAR_AREA_COVERAGE_BUFFER
      ) %>%
      group_by(period_value) %>%
      summarise(
        run_tag = run_tag,
        section = "area_coverage_margin_summary_supply",
        period = period_cfg$name,
        n_area_periods = n(),
        n_kept = sum(drop_reason == "kept", na.rm = TRUE),
        n_near_area_coverage_threshold = sum(near_area_coverage_threshold, na.rm = TRUE),
        share_near_area_coverage_threshold = ifelse(n_area_periods > 0, n_near_area_coverage_threshold / n_area_periods, NA_real_),
        p10_area_coverage_margin = quantile_safe(area_coverage_margin, 0.10),
        p50_area_coverage_margin = quantile_safe(area_coverage_margin, 0.50),
        p90_area_coverage_margin = quantile_safe(area_coverage_margin, 0.90),
        mean_area_coverage_margin = mean(area_coverage_margin, na.rm = TRUE),
        .groups = "drop"
      )
    dashboard_parts[[length(dashboard_parts) + 1L]] <- supply_margin_summary

    settlement_period_stage <- sett_day_states %>%
      transmute(
        settlement_id,
        period_value = period_from_date(date, period_cfg$name),
        obs_day = !is.na(p_lit_sett),
        post_doe_obs_day = !is.na(p_lit_sett) & electrified_after_doe_strict == 1L
      ) %>%
      group_by(settlement_id, period_value) %>%
      summarise(
        n_days_observed = sum(obs_day, na.rm = TRUE),
        n_days_post_doe = sum(post_doe_obs_day, na.rm = TRUE),
        .groups = "drop"
      ) %>%
      left_join(settlement_static %>% select(settlement_id, population), by = "settlement_id") %>%
      mutate(population = coalesce(population, 0))

    settlement_waterfall <- settlement_period_stage %>%
      group_by(period_value) %>%
      summarise(
        n_settlements_total = n(),
        population_total = sum(population, na.rm = TRUE),
        n_settlements_observed = sum(n_days_observed > 0, na.rm = TRUE),
        population_observed = sum(ifelse(n_days_observed > 0, population, 0), na.rm = TRUE),
        n_settlements_post_doe = sum(n_days_post_doe > 0, na.rm = TRUE),
        population_post_doe = sum(ifelse(n_days_post_doe > 0, population, 0), na.rm = TRUE),
        n_settlements_support_ok = sum(n_days_post_doe >= period_cfg$min_days, na.rm = TRUE),
        population_support_ok = sum(ifelse(n_days_post_doe >= period_cfg$min_days, population, 0), na.rm = TRUE),
        .groups = "drop"
      )

    local_area_waterfall <- local_result$diagnostics %>%
      mutate(period_value = .data[[period_cfg$period_col]]) %>%
      group_by(period_value) %>%
      summarise(
        n_area_total = n(),
        n_area_kept = sum(drop_reason == "kept", na.rm = TRUE),
        area_population_total = sum(area_population, na.rm = TRUE),
        area_population_kept = sum(ifelse(drop_reason == "kept", kept_population, 0), na.rm = TRUE),
        .groups = "drop"
      )

    supply_area_waterfall <- supply_result$diagnostics %>%
      mutate(period_value = .data[[period_cfg$period_col]]) %>%
      group_by(period_value) %>%
      summarise(
        n_area_total = n(),
        n_area_kept = sum(drop_reason == "kept", na.rm = TRUE),
        area_population_total = sum(area_population, na.rm = TRUE),
        area_population_kept = sum(ifelse(drop_reason == "kept", kept_population, 0), na.rm = TRUE),
        .groups = "drop"
      )

    dashboard_waterfall <- bind_rows(
      settlement_waterfall %>%
        transmute(
          run_tag = run_tag,
          section = "period_filter_waterfall",
          period = period_cfg$name,
          period_value,
          stage = "settlement_observed",
          unit = "settlement",
          n_total = n_settlements_total,
          n_kept = n_settlements_observed,
          share_kept = ifelse(n_total > 0, n_kept / n_total, NA_real_),
          population_total,
          population_kept = population_observed,
          population_share_kept = ifelse(population_total > 0, population_kept / population_total, NA_real_)
        ),
      settlement_waterfall %>%
        transmute(
          run_tag = run_tag,
          section = "period_filter_waterfall",
          period = period_cfg$name,
          period_value,
          stage = "settlement_post_doe",
          unit = "settlement",
          n_total = n_settlements_total,
          n_kept = n_settlements_post_doe,
          share_kept = ifelse(n_total > 0, n_kept / n_total, NA_real_),
          population_total,
          population_kept = population_post_doe,
          population_share_kept = ifelse(population_total > 0, population_kept / population_total, NA_real_)
        ),
      settlement_waterfall %>%
        transmute(
          run_tag = run_tag,
          section = "period_filter_waterfall",
          period = period_cfg$name,
          period_value,
          stage = "settlement_support_ok",
          unit = "settlement",
          n_total = n_settlements_total,
          n_kept = n_settlements_support_ok,
          share_kept = ifelse(n_total > 0, n_kept / n_total, NA_real_),
          population_total,
          population_kept = population_support_ok,
          population_share_kept = ifelse(population_total > 0, population_kept / population_total, NA_real_)
        ),
      local_area_waterfall %>%
        transmute(
          run_tag = run_tag,
          section = "period_filter_waterfall",
          period = period_cfg$name,
          period_value,
          stage = "area_coverage_local",
          unit = "localarea",
          n_total = n_area_total,
          n_kept = n_area_kept,
          share_kept = ifelse(n_total > 0, n_kept / n_total, NA_real_),
          population_total = area_population_total,
          population_kept = area_population_kept,
          population_share_kept = ifelse(population_total > 0, population_kept / population_total, NA_real_)
        ),
      supply_area_waterfall %>%
        transmute(
          run_tag = run_tag,
          section = "period_filter_waterfall",
          period = period_cfg$name,
          period_value,
          stage = "area_coverage_supply",
          unit = "supplyarea",
          n_total = n_area_total,
          n_kept = n_area_kept,
          share_kept = ifelse(n_total > 0, n_kept / n_total, NA_real_),
          population_total = area_population_total,
          population_kept = area_population_kept,
          population_share_kept = ifelse(population_total > 0, population_kept / population_total, NA_real_)
        )
    )
    dashboard_parts[[length(dashboard_parts) + 1L]] <- dashboard_waterfall
    log_step("Wrote diagnostics: area drop reasons for", period_cfg$name)
  }

  log_step(
    "Wrote:", period_cfg$name, state_name,
    "| settlements:", nrow(sett_metrics),
    "| local areas:", nrow(local_metrics),
    "| supply areas:", nrow(supply_metrics),
    "| state sec:", round(as.numeric(difftime(Sys.time(), t_state, units = "secs")), 2)
  )
  log_step(
    "Completed period:", period_cfg$name,
    "| sec:", round(as.numeric(difftime(Sys.time(), t_period, units = "secs")), 2)
  )
}

if (WRITE_DIAGNOSTICS && length(diag_summary_parts) > 0) {
  diagnostic_drop_summary <- bind_rows(diag_summary_parts) %>%
    group_by(run_tag, stage, period, state, subset, drop_reason) %>%
    summarise(n = sum(n, na.rm = TRUE), .groups = "drop")

  diag_summary_parquet <- file.path(DIAG_DIR, paste0("diagnostic_drop_summary_", run_tag, ".parquet"))
  diag_summary_csv <- file.path(DIAG_DIR, paste0("diagnostic_drop_summary_", run_tag, ".csv"))

  arrow::write_parquet(diagnostic_drop_summary, diag_summary_parquet)
  utils::write.csv(diagnostic_drop_summary, diag_summary_csv, row.names = FALSE)
  dashboard_parts[[length(dashboard_parts) + 1L]] <- diagnostic_drop_summary %>%
    mutate(section = "current_drop_summary")
  log_step("Wrote diagnostics summary:", basename(diag_summary_parquet), "and", basename(diag_summary_csv))
}

if (WRITE_DIAGNOSTICS && length(dashboard_parts) > 0) {
  diagnostic_dashboard <- bind_rows(dashboard_parts)
  dashboard_parquet <- file.path(DIAG_DIR, paste0("diagnostic_dashboard_", run_tag, ".parquet"))
  dashboard_csv <- file.path(DIAG_DIR, paste0("diagnostic_dashboard_", run_tag, ".csv"))

  arrow::write_parquet(diagnostic_dashboard, dashboard_parquet)
  utils::write.csv(diagnostic_dashboard, dashboard_csv, row.names = FALSE)
  log_step("Wrote compact dashboard:", basename(dashboard_parquet), "and", basename(dashboard_csv))
}

message("Reliability pipeline complete.")
