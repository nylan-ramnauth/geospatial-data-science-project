# ============================================================
# Build Reliability Panel (Yearly-Keep Variant)
# Stage 3b — Reliability Panel with Annual Pre-filter
# ============================================================
#
# Purpose:  Variant of Stage 3 that pre-filters settlements to those
#           flagged as electrified in the yearly composite calibration
#           (Stage 2c) before running the rolling-window reliability logic.
# Inputs:   - Map Data/settlement_day_outputs_rasters_blackmarbler/settlement_day_blackmarbler_cov_YYYY-MM.parquet
#           - Map Data/reliability_outputs_blackmarbler/yearly_settlement_stats_2023.parquet  (from Stage 2c / settlement_yearly_composite.R)
# Outputs:  - Map Data/reliability_outputs_blackmarbler/settlement_reliability_*.parquet  (yearlykeep variant)
# Run:      Rscript Visualizer/reliability_panel_build_yearlykeep.R
# ============================================================

# Housekeeping
rm(list = ls())

suppressPackageStartupMessages({
  library(here)
  library(sf)
  library(dplyr)
  library(arrow)
  library(lubridate)
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

LOCAL_AREAS_SHP <- file.path(BASE_PATH, "Map Data", "Local Area", "LOCAL_AREA_GCCA2025.shp")
SUPPLY_AREAS_SHP <- file.path(BASE_PATH, "Map Data", "Supply Area", "SUPPLY_AREA_GCCA2025.shp")
# Use simplified geometry for spatial joins (local/supply area assignment):
# exact pixel extraction is not needed here; simplified polygons are faster
# and sufficient for point-in-polygon / area overlay operations.
# (Stages 2 and 2c use the full geometry for pixel-level extraction.)
# _simplified_ geometry; _full_col_ means full attribute columns (not simplified attributes).
SETT_SIMPL_GPKG <- file.path(
  BASE_PATH,
  "Map Data",
  "Settlements",
  "GPKG",
  "south_africa_dre_atlas_settlements_simplified_full_col.gpkg"
)
SETT_SIMPL_LAYER <- "settlements_simplified"

START_MONTH <- "2023-01"
END_MONTH <- "2023-12"

# Yearly composite settlement keep-list (from settlement_yearly_composite.R)
YEAR_LABEL <- substr(START_MONTH, 1, 4)   # derives "2023" from "2023-01"
YEARLY_KEEP_FILE <- file.path(OUT_DIR, paste0("yearly_settlement_stats_", YEAR_LABEL, ".parquet"))
YEARLY_KEEP_ID_COL <- "settlement_id"
YEARLY_KEEP_FLAG_COL <- "electrified_best"

LIT_THRESHOLD <- 0.40   # unchanged (sweep confirmed 0.4 optimal)
DARK_THRESHOLD <- 0.05
ROLLING_DAYS <- 30L
ROLLING_LIT_MIN <- 8L    # was 17L; sweep: 99.90% vs 94.22% confirmation
ROLLING_OBS_MIN <- 15L   # was 20L; 15/30 clear-sky days (50%)

N_DAYS_MIN_MONTH <- 10L
N_DAYS_MIN_QUARTER <- 40L
N_DAYS_MIN_YEAR <- 85L
AREA_COVERAGE_MIN <- 0.5
if (nzchar(Sys.getenv("RUN_AREA_COV_MIN"))) AREA_COVERAGE_MIN <- as.numeric(Sys.getenv("RUN_AREA_COV_MIN"))
NEAR_SUPPORT_DAYS_BUFFER <- 10L
NEAR_AREA_COVERAGE_BUFFER <- 0.05

# Moonlight / stray-light mitigation (date exclusion)
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

# state_name already contains "_yearlykeep"; no suffix needed for the default run.
OUTPUT_SUFFIX <- if (MOONLIGHT_FILTER_MODE == "none") "" else
  paste0("_moonfilter_", MOONLIGHT_FILTER_MODE)
if (nzchar(Sys.getenv("RUN_OUTPUT_SUFFIX"))) OUTPUT_SUFFIX <- Sys.getenv("RUN_OUTPUT_SUFFIX")

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

# Population-weighted standard deviation across settlements within an area.
# Captures cross-sectional inequality in uptime: how much does reliability
# vary between settlements, not just the area average.
weighted_sd_na <- function(x, w) {
  idx <- !is.na(x) & !is.na(w)
  if (sum(idx) < 2) return(NA_real_)
  xw <- weighted_mean_na(x[idx], w[idx])
  sqrt(sum(w[idx] * (x[idx] - xw)^2) / sum(w[idx]))
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

ensure_static_cols <- function(df, gpkg_path, gpkg_layer) {
  static_cols <- c("population", "lon", "lat")
  missing_static <- setdiff(static_cols, names(df))
  if (length(missing_static) == 0) return(df)
  if (!file.exists(gpkg_path)) {
    stop("Settlement GPKG not found for static column enrichment: ", gpkg_path)
  }

  gpkg_all <- st_read(gpkg_path, layer = gpkg_layer, quiet = TRUE) %>%
    st_drop_geometry() %>%
    distinct(settlement_id, .keep_all = TRUE) %>%
    mutate(settlement_id = as.character(settlement_id)) %>%
    dplyr::select(settlement_id, any_of(static_cols))

  out <- df %>%
    mutate(settlement_id = as.character(settlement_id)) %>%
    left_join(gpkg_all, by = "settlement_id", suffix = c("", ".gpkg"))

  for (nm in static_cols) {
    gp <- paste0(nm, ".gpkg")
    if (!(nm %in% names(out))) out[[nm]] <- NA_real_
    if (gp %in% names(out)) {
      out[[nm]] <- dplyr::coalesce(out[[nm]], out[[gp]])
      out[[gp]] <- NULL
    }
  }
  out
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

  # Forward-looking rolling sum: n_lit30[i] = lit days in the window *starting*
  # at day i (days i to i+29), not the past 30 days. This gives an ex-post DOE:
  # the first day from which the NEXT 30 days are consistently lit.
  # Unobserved days (NA p_lit_sett) are treated as dark (conservative: lit_one[NA] <- 0),
  # so the 17/30 threshold is relative to all calendar days, not just observed days.
  dt[, n_lit30 := {
    lit_one <- as.integer(lit_day == 1L)
    lit_one[is.na(lit_one)] <- 0L
    rev(data.table::frollsum(rev(lit_one), n = ROLLING_DAYS, align = "right"))
  }, by = settlement_id]
  dt[, n_obs30 := {
    obs_one <- as.integer(!is.na(lit_day))
    rev(data.table::frollsum(rev(obs_one), n = ROLLING_DAYS, align = "right"))
  }, by = settlement_id]

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

  by_cols <- c("settlement_id", period_col)
  dt <- data.table::as.data.table(df_obs)
  out <- dt[, .(state_days_obs = sum(!is.na(get(state_col)))), by = by_cols]
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
    dplyr::select(settlement_id, population) %>%
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
    n_settlements     = data.table::uniqueN(settlement_id),
    kept_population   = sum(population, na.rm = TRUE),
    uptime_popw       = weighted_mean_na(uptime,        population),
    sd_uptime_popw    = weighted_sd_na(uptime,          population),
    dark_share_popw   = weighted_mean_na(dark_share,    population),
    mean_p_lit_popw   = weighted_mean_na(mean_p_lit,    population),
    cv_p_lit_popw     = weighted_mean_na(cv_p_lit,      population),
    switch_rate_popw  = weighted_mean_na(switch_rate,   population),
    mean_coverage_popw = weighted_mean_na(mean_coverage, population)
  ), by = by_cols]

  out <- out[dt_area_pop, on = .(area_name)]
  # share_population_kept = kept_population / area_population, where:
  #   - area_population  : total population of settlements electrified in the
  #                        yearly composite (electrified_best == 1); derived
  #                        from settlement_static which is post-yearly-keep.
  #   - kept_population  : population of the subset that additionally have
  #                        sufficient daily observations and are confirmed
  #                        electrified via DOE (electrified_after_doe_strict).
  # Interpretation: share of yearly-composite-electrified people whose
  # settlements have DOE-confirmed reliability estimates in the daily panel.
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
# 1) READ INPUT PANEL + APPLY YEARLY KEEP LIST
# -----------------------------
month_start <- as.Date(paste0(START_MONTH, "-01"))
month_end <- as.Date(paste0(END_MONTH, "-01"))
stopifnot(!is.na(month_start), !is.na(month_end), month_start <= month_end)
months_seq <- seq.Date(from = month_start, to = month_end, by = "month")
analysis_end <- seq.Date(from = month_end, by = "month", length.out = 2)[2] - 1
run_tag <- paste0(format(month_start, "%Y-%m"), "_to_", format(month_end, "%Y-%m"), OUTPUT_SUFFIX)

input_files <- file.path(
  IN_DIR,
  paste0("settlement_day_blackmarbler_cov_", format(months_seq, "%Y-%m"), ".parquet")
)
existing_files <- input_files[file.exists(input_files)]
if (length(existing_files) == 0) stop("No monthly coverage-qualified parquet files found in range.")

log_step("Reading monthly panel files:", length(existing_files))
sett_day <- map_dfr(existing_files, read_parquet) %>%
  mutate(
    settlement_id = as.character(settlement_id),
    date = as.Date(date)
  ) %>%
  filter(date >= month_start, date <= analysis_end)

required_cols <- c("settlement_id", "date", "p_lit_sett", "coverage")
missing_cols <- setdiff(required_cols, names(sett_day))
if (length(missing_cols) > 0) {
  stop("Missing required columns in input panel: ", paste(missing_cols, collapse = ", "))
}

sett_day <- ensure_static_cols(sett_day, SETT_SIMPL_GPKG, SETT_SIMPL_LAYER)

exclude_dates <- read_exclude_dates(MOONLIGHT_FILTER_MODE)
if (length(exclude_dates) > 0) {
  n_before <- nrow(sett_day)
  sett_day <- sett_day %>% filter(!(date %in% exclude_dates))
  log_step("Excluded dates:", length(exclude_dates), "| rows:", n_before, "->", nrow(sett_day))
}

if (!file.exists(YEARLY_KEEP_FILE)) {
  stop("Yearly keep file not found: ", YEARLY_KEEP_FILE, "\nRun settlement_yearly_composite.R first.")
}

yearly_stats <- read_parquet(YEARLY_KEEP_FILE) %>%
  mutate(
    settlement_id = as.character(.data[[YEARLY_KEEP_ID_COL]]),
    electrified_best = as.integer(.data[[YEARLY_KEEP_FLAG_COL]])
  )

if (!("population" %in% names(yearly_stats))) {
  yearly_stats$population <- NA_real_
}

yearly_keep <- yearly_stats %>%
  filter(electrified_best == 1L) %>%
  distinct(settlement_id)

if (nrow(yearly_keep) == 0) {
  stop("No kept settlements found in yearly keep file (", YEARLY_KEEP_FILE, ").")
}

# Yearly-composite electrification share by Local Area (population-weighted)
year_label <- YEAR_LABEL   # already derived from START_MONTH in CONFIG

sett_full_sf <- st_read(SETT_SIMPL_GPKG, layer = SETT_SIMPL_LAYER, quiet = TRUE) %>%
  mutate(settlement_id = as.character(settlement_id)) %>%
  dplyr::select(settlement_id, any_of("population")) %>%
  { if (!("population" %in% names(.))) dplyr::mutate(., population = NA_real_) else . } %>%
  left_join(
    yearly_stats %>% dplyr::select(settlement_id, electrified_best, population_yearly = population),
    by = "settlement_id"
  ) %>%
  mutate(
    population = coalesce(population, population_yearly),
    electrified_best = coalesce(electrified_best, 0L)
  )

sett_full_tbl <- st_drop_geometry(sett_full_sf) %>%
  dplyr::select(settlement_id, population, electrified_best) %>%
  distinct(settlement_id, .keep_all = TRUE) %>%
  filter(!is.na(population))

if (!("population" %in% names(st_drop_geometry(sett_full_sf)))) {
  stop("Population field is missing; cannot compute LocalArea electrification shares.")
}

local_areas_yearly <- st_read(LOCAL_AREAS_SHP, quiet = TRUE)
sett_local_yearly <- st_join(
  st_transform(st_point_on_surface(sett_full_sf), st_crs(local_areas_yearly)),
  local_areas_yearly["LocalArea"],
  left = TRUE
) %>%
  st_drop_geometry() %>%
  dplyr::select(settlement_id, LocalArea) %>%
  distinct(settlement_id, .keep_all = TRUE) %>%
  left_join(sett_full_tbl, by = "settlement_id") %>%
  filter(!is.na(LocalArea), !is.na(population))

localarea_yearly_elect <- sett_local_yearly %>%
  group_by(LocalArea) %>%
  summarise(
    n_settlements_total = n(),
    n_settlements_electrified = sum(electrified_best == 1L, na.rm = TRUE),
    population_total = sum(population, na.rm = TRUE),
    population_electrified = sum(ifelse(electrified_best == 1L, population, 0), na.rm = TRUE),
    share_population_electrified = ifelse(population_total > 0, population_electrified / population_total, NA_real_),
    .groups = "drop"
  ) %>%
  arrange(desc(share_population_electrified))

localarea_yearly_csv <- file.path(OUT_DIR, paste0("localarea_yearly_electrification_share_", year_label, ".csv"))
localarea_yearly_parquet <- file.path(OUT_DIR, paste0("localarea_yearly_electrification_share_", year_label, ".parquet"))
write.csv(localarea_yearly_elect, localarea_yearly_csv, row.names = FALSE)
write_parquet(localarea_yearly_elect, localarea_yearly_parquet)

national_share <- with(
  sett_full_tbl,
  sum(ifelse(electrified_best == 1L, population, 0), na.rm = TRUE) / sum(population, na.rm = TRUE)
)
log_step("Yearly composite electrified population share (national):", paste0(round(100 * national_share, 2), "%"))
log_step("Wrote LocalArea yearly electrification shares:", localarea_yearly_csv)
print(localarea_yearly_elect)

# SupplyArea yearly-composite electrification shares (population-weighted)
supply_areas_yearly <- st_read(SUPPLY_AREAS_SHP, quiet = TRUE)
sett_supply_yearly <- st_join(
  st_transform(st_point_on_surface(sett_full_sf), st_crs(supply_areas_yearly)),
  supply_areas_yearly["SupplyArea"],
  left = TRUE
) %>%
  st_drop_geometry() %>%
  dplyr::select(settlement_id, SupplyArea) %>%
  distinct(settlement_id, .keep_all = TRUE) %>%
  left_join(sett_full_tbl, by = "settlement_id") %>%
  filter(!is.na(SupplyArea), !is.na(population))

supplyarea_yearly_elect <- sett_supply_yearly %>%
  group_by(SupplyArea) %>%
  summarise(
    n_settlements_total = n(),
    n_settlements_electrified = sum(electrified_best == 1L, na.rm = TRUE),
    population_total = sum(population, na.rm = TRUE),
    population_electrified = sum(ifelse(electrified_best == 1L, population, 0), na.rm = TRUE),
    share_population_electrified = ifelse(population_total > 0, population_electrified / population_total, NA_real_),
    .groups = "drop"
  ) %>%
  arrange(desc(share_population_electrified))

supplyarea_yearly_csv <- file.path(OUT_DIR, paste0("supplyarea_yearly_electrification_share_", year_label, ".csv"))
supplyarea_yearly_parquet <- file.path(OUT_DIR, paste0("supplyarea_yearly_electrification_share_", year_label, ".parquet"))
write.csv(supplyarea_yearly_elect, supplyarea_yearly_csv, row.names = FALSE)
write_parquet(supplyarea_yearly_elect, supplyarea_yearly_parquet)
log_step("Wrote SupplyArea yearly electrification shares:", supplyarea_yearly_csv)
print(supplyarea_yearly_elect)

n_sett_before <- dplyr::n_distinct(sett_day$settlement_id)
sett_day <- sett_day %>% semi_join(yearly_keep, by = "settlement_id")
n_sett_after <- dplyr::n_distinct(sett_day$settlement_id)

log_step("Yearly keep filter applied | settlements:", n_sett_before, "->", n_sett_after)

if (nrow(sett_day) == 0) {
  stop("Panel is empty after yearly keep filtering.")
}

if (anyDuplicated(sett_day %>% dplyr::select(settlement_id, date)) > 0) {
  stop("Input panel has duplicate settlement_id-date rows.")
}

# settlement_static is derived from sett_day AFTER the yearly-keep semi_join
# (line above). It therefore contains only settlements classified as electrified
# by settlement_yearly_composite.R (electrified_best == 1). The area_population
# column computed from this in compute_area_metrics() is consequently the
# population of yearly-composite-electrified settlements per area — the
# denominator of share_population_kept.
settlement_static <- sett_day %>%
  group_by(settlement_id) %>%
  summarise(
    population = first_non_na(population),
    lon = first_non_na(lon),
    lat = first_non_na(lat),
    .groups = "drop"
  )

# -----------------------------
# 2) BUILD DAILY STATES (WITH DOE ON YEARLY-KEPT SETTLEMENTS)
# -----------------------------
sett_day_states <- build_daily_states_dt(sett_day)

state_file <- file.path(OUT_DIR, paste0("settlement_day_states_strict_yearlykeep", OUTPUT_SUFFIX, ".parquet"))
write_parquet(sett_day_states, state_file)
log_step("Wrote yearly-keep states cache:", state_file)

# Reliability pool: observed post-DOE days only, in yearly-kept settlements
sett_obs <- sett_day_states %>%
  filter(!is.na(p_lit_sett), electrified_after_doe_strict == 1L) %>%
  mutate(
    month = floor_date(date, "month"),
    quarter = floor_date(date, "quarter"),
    year = floor_date(date, "year"),
    electrified_after_yearly_keep = 1L
  )

if (WRITE_DIAGNOSTICS) {
  keep_diag <- data.frame(
    run_tag = run_tag,
    section = "yearly_keep_filter",
    metric = c("n_settlements_before", "n_settlements_after", "n_rows_after", "n_excluded_days"),
    value = c(n_sett_before, n_sett_after, nrow(sett_day), length(exclude_dates))
  )
  write_parquet(keep_diag, file.path(DIAG_DIR, paste0("diagnostic_yearly_keep_filter_", run_tag, ".parquet")))
  utils::write.csv(keep_diag, file.path(DIAG_DIR, paste0("diagnostic_yearly_keep_filter_", run_tag, ".csv")), row.names = FALSE)
}

# -----------------------------
# 3) LOOKUPS
# -----------------------------
local_areas  <- local_areas_yearly   # reuse already-loaded geometry
supply_areas <- supply_areas_yearly  # reuse already-loaded geometry

# Use st_point_on_surface for consistent area assignment — guaranteed to fall
# inside the polygon, unlike raw centroids (lon/lat) which can land outside
# concave or irregular settlement boundaries.
sett_points <- sett_full_sf %>%
  filter(settlement_id %in% settlement_static$settlement_id) %>%
  st_transform(4326) %>%
  st_point_on_surface() %>%
  dplyr::select(settlement_id)

local_lookup <- st_join(
  st_transform(sett_points, st_crs(local_areas)),
  local_areas["LocalArea"],
  left = TRUE
) %>%
  st_drop_geometry() %>%
  distinct(settlement_id, .keep_all = TRUE) %>%
  dplyr::select(settlement_id, LocalArea)

supply_lookup <- st_join(
  st_transform(sett_points, st_crs(supply_areas)),
  supply_areas["SupplyArea"],
  left = TRUE
) %>%
  st_drop_geometry() %>%
  distinct(settlement_id, .keep_all = TRUE) %>%
  dplyr::select(settlement_id, SupplyArea)

# -----------------------------
# 4) RELIABILITY OUTPUTS
# -----------------------------
period_specs <- list(
  list(name = "monthly", period_col = "month", min_days = N_DAYS_MIN_MONTH),
  list(name = "quarterly", period_col = "quarter", min_days = N_DAYS_MIN_QUARTER),
  list(name = "yearly", period_col = "year", min_days = N_DAYS_MIN_YEAR)
)

state_name <- "strict_yearlykeep_postdoe"
state_col <- "electrified_after_doe_strict"
dashboard_parts <- list()

for (period_cfg in period_specs) {
  log_step("Start period:", period_cfg$name)
  t_period <- Sys.time()

  base_metrics_all <- compute_settlement_base_metrics(
    sett_obs,
    period_col = period_cfg$period_col,
    n_days_min = period_cfg$min_days,
    keep_all = TRUE
  )
  base_metrics <- base_metrics_all %>% filter(support_ok)

  # NOTE: sett_obs contains only rows with electrified_after_doe_strict == 1,
  # so state_days_obs will always equal n_days_obs in this variant. Kept for
  # structural parity with the standard (non-yearlykeep) variant.
  state_shares <- compute_state_shares(
    sett_obs,
    period_col = period_cfg$period_col,
    state_col = state_col
  )
  sett_metrics <- compute_settlement_metrics(
    base_metrics = base_metrics,
    state_shares = state_shares,
    period_col = period_cfg$period_col
  ) %>%
    left_join(settlement_static %>% dplyr::select(settlement_id, population, lon, lat), by = "settlement_id")

  out_sett <- file.path(
    OUT_DIR,
    paste0("settlement_reliability_", period_cfg$name, "_", state_name, OUTPUT_SUFFIX, ".parquet")
  )
  write_parquet(sett_metrics, out_sett)

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
  write_parquet(local_metrics, out_local)
  write_parquet(supply_metrics, out_supply)

  if (WRITE_DIAGNOSTICS) {
    write_parquet(
      local_result$diagnostics,
      file.path(
        DIAG_DIR,
        paste0("diagnostic_localarea_drop_", period_cfg$name, "_", state_name, "_", run_tag, ".parquet")
      )
    )
    write_parquet(
      supply_result$diagnostics,
      file.path(
        DIAG_DIR,
        paste0("diagnostic_supplyarea_drop_", period_cfg$name, "_", state_name, "_", run_tag, ".parquet")
      )
    )

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
  }

  log_step(
    "Wrote:", period_cfg$name, state_name,
    "| settlements:", nrow(sett_metrics),
    "| local areas:", nrow(local_metrics),
    "| supply areas:", nrow(supply_metrics),
    "| sec:", round(as.numeric(difftime(Sys.time(), t_period, units = "secs")), 2)
  )
}

if (WRITE_DIAGNOSTICS && length(dashboard_parts) > 0) {
  diagnostic_dashboard <- bind_rows(dashboard_parts)
  dashboard_parquet <- file.path(DIAG_DIR, paste0("diagnostic_dashboard_", run_tag, "_", state_name, ".parquet"))
  dashboard_csv <- file.path(DIAG_DIR, paste0("diagnostic_dashboard_", run_tag, "_", state_name, ".csv"))
  write_parquet(diagnostic_dashboard, dashboard_parquet)
  utils::write.csv(diagnostic_dashboard, dashboard_csv, row.names = FALSE)
  log_step("Wrote compact dashboard:", basename(dashboard_parquet), "and", basename(dashboard_csv))
}

# -----------------------------
# 5) END-OF-YEAR ELECTRIFICATION STATUS SUMMARY
# -----------------------------
# Classify each yearly-keep settlement by DOE confirmation status:
#   confirmed_doe      — met rolling-window criterion within the analysis period
#   yearly_keep_no_doe — yearly composite flagged electrified but no qualifying
#                        30-day window found (data-sparse or below threshold)
#
# doe_strict is constant per settlement in sett_day_states (set by data.table by-group).
doe_summary <- sett_day_states %>%
  distinct(settlement_id, doe_strict) %>%
  mutate(
    doe_confirmed = !is.na(doe_strict) & as.Date(doe_strict) <= analysis_end,
    doe_status = ifelse(doe_confirmed, "confirmed_doe", "yearly_keep_no_doe")
  ) %>%
  left_join(
    settlement_static %>% dplyr::select(settlement_id, population),
    by = "settlement_id"
  )

log_step(
  "DOE confirmation:",
  sum(doe_summary$doe_confirmed, na.rm = TRUE), "confirmed /",
  nrow(doe_summary), "yearly-keep settlements"
)

# National summary
eoy_national <- doe_summary %>%
  summarise(
    n_settlements_yearly_keep = n(),
    n_settlements_confirmed_doe = sum(doe_confirmed, na.rm = TRUE),
    pop_yearly_keep = sum(population, na.rm = TRUE),
    pop_confirmed_doe = sum(ifelse(doe_confirmed, population, 0L), na.rm = TRUE),
    share_pop_confirmed_doe = ifelse(
      pop_yearly_keep > 0, pop_confirmed_doe / pop_yearly_keep, NA_real_
    )
  )
log_step(
  "National DOE-confirmed population share:",
  paste0(round(100 * eoy_national$share_pop_confirmed_doe, 2), "%")
)

# LocalArea breakdown
eoy_localarea <- doe_summary %>%
  left_join(local_lookup, by = "settlement_id") %>%
  filter(!is.na(LocalArea), !is.na(population)) %>%
  group_by(LocalArea) %>%
  summarise(
    n_settlements_yearly_keep = n(),
    n_confirmed_doe = sum(doe_confirmed, na.rm = TRUE),
    pop_total = sum(population, na.rm = TRUE),
    pop_confirmed_doe = sum(ifelse(doe_confirmed, population, 0L), na.rm = TRUE),
    share_pop_confirmed_doe = ifelse(
      pop_total > 0, pop_confirmed_doe / pop_total, NA_real_
    ),
    .groups = "drop"
  )

# SupplyArea breakdown
eoy_supplyarea <- doe_summary %>%
  left_join(supply_lookup, by = "settlement_id") %>%
  filter(!is.na(SupplyArea), !is.na(population)) %>%
  group_by(SupplyArea) %>%
  summarise(
    n_settlements_yearly_keep = n(),
    n_confirmed_doe = sum(doe_confirmed, na.rm = TRUE),
    pop_total = sum(population, na.rm = TRUE),
    pop_confirmed_doe = sum(ifelse(doe_confirmed, population, 0L), na.rm = TRUE),
    share_pop_confirmed_doe = ifelse(
      pop_total > 0, pop_confirmed_doe / pop_total, NA_real_
    ),
    .groups = "drop"
  )

# Write outputs
eoy_base <- file.path(
  OUT_DIR, paste0("end_of_year_electrification_", YEAR_LABEL)
)
write_parquet(
  doe_summary, paste0(eoy_base, "_settlement_doe_status.parquet")
)
utils::write.csv(
  eoy_national, paste0(eoy_base, "_national_summary.csv"), row.names = FALSE
)
write_parquet(eoy_localarea,  paste0(eoy_base, "_localarea.parquet"))
utils::write.csv(
  eoy_localarea, paste0(eoy_base, "_localarea.csv"), row.names = FALSE
)
write_parquet(eoy_supplyarea, paste0(eoy_base, "_supplyarea.parquet"))
utils::write.csv(
  eoy_supplyarea, paste0(eoy_base, "_supplyarea.csv"), row.names = FALSE
)
log_step("Wrote end-of-year electrification summary:", eoy_base)

message("Reliability pipeline complete (yearly keep-set mode).")
