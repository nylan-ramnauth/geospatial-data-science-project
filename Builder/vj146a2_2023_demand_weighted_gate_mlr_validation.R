rm(list = ls())

# ============================================================
# 2023 VJ146A2 demand-weighted coverage gate validation
# ============================================================
#
# Concept companion to Builder/vj146a2_2023_mlr_validation.R.
# This script does not modify the existing validation outputs.
#
# Goal:
#   Build a demand-weighted confidence gate for national NTL-vs-Eskom
#   validation. The gate asks how much fixed settlement demand was actually
#   seen by the satellite on each night, not how many settlement rows were
#   present.
#
# Run:
#   Rscript Builder/vj146a2_2023_demand_weighted_gate_mlr_validation.R
#
# Main configurable parameters:
#   VJ146A2_DEMAND_GATE_T=0.40
#   VJ146A2_DEMAND_GATE_HARD_FLOOR=0.20
#   VJ146A2_DEMAND_GATE_COVERAGE_MIN=0.80
#   VJ146A2_DEMAND_GATE_POP_MIN=100
#   VJ146A2_DEMAND_GATE_SHARE_COL=observed_demand_share
#   ESKOM_HOURLY_CSV=/abs/path/to/eskom_2023_hourly_clean.csv
#   PYPSA_EARTH_DIR=/abs/path/to/pypsa-earth
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(arrow)
  library(dplyr)
  library(tidyr)
  library(sf)
  library(ggplot2)
  library(broom)
})

BASE_PATH <- here::here()
PYPSA_EARTH_DIR <- normalizePath(
  Sys.getenv("PYPSA_EARTH_DIR", file.path(dirname(BASE_PATH), "pypsa-earth")),
  mustWork = FALSE
)

START_MONTH <- Sys.getenv("VJ146A2_START_MONTH", "2023-01")
END_MONTH <- Sys.getenv("VJ146A2_END_MONTH", "2023-12")
month_start <- as.Date(paste0(START_MONTH, "-01"))
month_end <- as.Date(paste0(END_MONTH, "-01"))
if (is.na(month_start) || is.na(month_end)) stop("Invalid START_MONTH/END_MONTH (use YYYY-MM).")
if (month_start > month_end) stop("START_MONTH must be <= END_MONTH.")

months_seq <- seq.Date(from = month_start, to = month_end, by = "month")
analysis_end <- seq.Date(from = month_end, by = "month", length.out = 2)[2] - 1
analysis_label <- paste0(START_MONTH, "_to_", END_MONTH)
analysis_window_text <- paste0(format(month_start, "%Y-%m-%d"), " to ", format(analysis_end, "%Y-%m-%d"))
default_out_subdir <- if (START_MONTH == "2023-01" && END_MONTH == "2023-12") {
  "mlr_validation_demand_gate_2023"
} else {
  paste0("mlr_validation_demand_gate_", analysis_label)
}

ESKOM_START_DATE <- month_start
ESKOM_END_DATE <- analysis_end + 1L

VJ_PANEL_DIR <- file.path(BASE_PATH, "Map Data", "settlement_day_outputs_vj146a2")
VJ_PANEL_FILES <- file.path(
  VJ_PANEL_DIR,
  paste0("settlement_day_vj146a2_cov_yearlykeep_", format(months_seq, "%Y-%m"), ".parquet")
)

VJ_YEARLY_STATS_FILE <- Sys.getenv(
  "VJ146A2_YEARLY_STATS_FILE",
  file.path(
    BASE_PATH,
    "Map Data",
    "reliability_outputs_vj146a2",
    paste0("yearly_settlement_stats_", substr(START_MONTH, 1, 4), ".parquet")
  )
)

SETT_GPKG <- file.path(
  BASE_PATH,
  "Map Data",
  "Settlements",
  "GPKG",
  "south_africa_dre_atlas_settlements_full_col.gpkg"
)

ESKOM_HOURLY <- normalizePath(
  Sys.getenv(
    "ESKOM_HOURLY_CSV",
    file.path(PYPSA_EARTH_DIR, "data", "za_validation", "eskom_2023_hourly_clean.csv")
  ),
  mustWork = FALSE
)

OUT_DIR <- file.path(
  BASE_PATH,
  "Map Data",
  "settlement_day_outputs_vj146a2",
  Sys.getenv("VJ146A2_DEMAND_GATE_OUT_SUBDIR", default_out_subdir)
)

OUT_COVERAGE <- file.path(OUT_DIR, "vj146a2_2023_demand_gate_coverage.csv")
OUT_VALIDATION <- file.path(OUT_DIR, "vj146a2_2023_demand_gate_validation_metrics.csv")
OUT_SWEEP <- file.path(OUT_DIR, "vj146a2_2023_demand_gate_threshold_sweep.csv")
OUT_MONTHLY <- file.path(OUT_DIR, "vj146a2_2023_demand_gate_monthly_bias.csv")
OUT_SUMMARY_TABLE <- file.path(OUT_DIR, "vj146a2_2023_demand_gate_summary_table.csv")
OUT_UNIVERSE <- file.path(OUT_DIR, "vj146a2_2023_demand_gate_universe.csv")
OUT_VARIANTS <- file.path(OUT_DIR, "vj146a2_2023_demand_gate_metric_variant_comparison.csv")
OUT_SUMMARY_MD <- file.path(OUT_DIR, "vj146a2_2023_demand_gate_summary.md")
OUT_SWEEP_PNG <- file.path(OUT_DIR, "vj146a2_demand_gate_threshold_sweep.png")
OUT_MONTHLY_PNG <- file.path(OUT_DIR, "vj146a2_demand_gate_monthly_bias.png")

missing_vj_panels <- VJ_PANEL_FILES[!file.exists(VJ_PANEL_FILES)]
if (length(missing_vj_panels) > 0) {
  stop(
    "Missing VJ yearly-keep monthly panel(s):\n  - ",
    paste(missing_vj_panels, collapse = "\n  - ")
  )
}
for (p in c(VJ_YEARLY_STATS_FILE, SETT_GPKG, ESKOM_HOURLY)) {
  if (!file.exists(p)) stop("Input not found: ", p)
}
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

GATE_T <- as.numeric(Sys.getenv("VJ146A2_DEMAND_GATE_T", "0.40"))
HARD_FLOOR <- as.numeric(Sys.getenv("VJ146A2_DEMAND_GATE_HARD_FLOOR", "0.20"))
COVERAGE_MIN <- as.numeric(Sys.getenv("VJ146A2_DEMAND_GATE_COVERAGE_MIN", "0.80"))
POP_MIN <- as.numeric(Sys.getenv("VJ146A2_DEMAND_GATE_POP_MIN", "100"))
MIN_RAD_BASELINE_DAYS <- as.integer(Sys.getenv("VJ146A2_DEMAND_GATE_MIN_RAD_BASELINE_DAYS", "5"))
RAD_SIGMA_MIN <- as.numeric(Sys.getenv("VJ146A2_DEMAND_GATE_RAD_SIGMA_MIN", "0.05"))
GATE_SHARE_COL <- Sys.getenv("VJ146A2_DEMAND_GATE_SHARE_COL", "observed_demand_share")
STRICT_DARK_MAX <- 0.05
MOSTLY_DARK_MAX <- 0.20
RELAXED_DARK_MAX <- 0.40

if (!is.finite(GATE_T) || GATE_T < 0 || GATE_T > 1) stop("Invalid GATE_T.")
if (!is.finite(HARD_FLOOR) || HARD_FLOOR < 0 || HARD_FLOOR > 1) stop("Invalid HARD_FLOOR.")
if (HARD_FLOOR > GATE_T) stop("HARD_FLOOR must be <= GATE_T.")

safe_sum <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) == 0) return(0)
  sum(x)
}

safe_mean <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) == 0) return(NA_real_)
  mean(x)
}

safe_weighted_mean <- function(x, w) {
  ok <- is.finite(x) & is.finite(w) & w > 0
  if (!any(ok)) return(NA_real_)
  stats::weighted.mean(x[ok], w[ok])
}

safe_cor <- function(x, y, method = "pearson") {
  ok <- is.finite(x) & is.finite(y)
  if (sum(ok) < 3 || length(unique(x[ok])) < 2 || length(unique(y[ok])) < 2) return(NA_real_)
  suppressWarnings(stats::cor(x[ok], y[ok], method = method))
}

auc_rank <- function(label, score) {
  ok <- !is.na(label) & is.finite(score)
  label <- as.integer(label[ok])
  score <- score[ok]
  n_pos <- sum(label == 1L)
  n_neg <- sum(label == 0L)
  if (n_pos == 0 || n_neg == 0) return(NA_real_)
  ranks <- rank(score, ties.method = "average")
  (sum(ranks[label == 1L]) - n_pos * (n_pos + 1) / 2) / (n_pos * n_neg)
}

validation_metrics <- function(data, outcome, sample_label, gate_threshold = NA_real_) {
  sub <- data %>%
    filter(
      is.finite(.data[[outcome]]),
      is.finite(shed_share_1_2am_primary),
      !is.na(any_shed_1_2am)
    )

  n <- nrow(sub)
  if (n < 3 || length(unique(sub[[outcome]])) < 2 || length(unique(sub$shed_share_1_2am_primary)) < 2) {
    return(data.frame(
      sample = sample_label,
      gate_threshold = gate_threshold,
      outcome = outcome,
      n = n,
      n_any_shed = sum(sub$any_shed_1_2am == 1L, na.rm = TRUE),
      n_zero_shed = sum(sub$any_shed_1_2am == 0L, na.rm = TRUE),
      pearson_r = NA_real_,
      r_squared = NA_real_,
      spearman_rho = NA_real_,
      auc_any_shed = NA_real_,
      estimate = NA_real_,
      effect_pp_per_10pp_shed = NA_real_,
      p_value = NA_real_,
      stringsAsFactors = FALSE
    ))
  }

  fit <- stats::lm(stats::as.formula(paste(outcome, "~ shed_share_1_2am_primary")), data = sub)
  td <- broom::tidy(fit)
  hit <- td[td$term == "shed_share_1_2am_primary", , drop = FALSE]
  estimate <- hit$estimate[[1]]

  data.frame(
    sample = sample_label,
    gate_threshold = gate_threshold,
    outcome = outcome,
    n = stats::nobs(fit),
    n_any_shed = sum(sub$any_shed_1_2am == 1L, na.rm = TRUE),
    n_zero_shed = sum(sub$any_shed_1_2am == 0L, na.rm = TRUE),
    pearson_r = safe_cor(sub[[outcome]], sub$shed_share_1_2am_primary, "pearson"),
    r_squared = summary(fit)$r.squared,
    spearman_rho = safe_cor(sub[[outcome]], sub$shed_share_1_2am_primary, "spearman"),
    auc_any_shed = auc_rank(sub$any_shed_1_2am, sub[[outcome]]),
    estimate = estimate,
    effect_pp_per_10pp_shed = estimate * 10,
    p_value = hit$p.value[[1]],
    stringsAsFactors = FALSE
  )
}

window_exposure <- function(eskom, hours, suffix) {
  tmp <- eskom %>%
    filter(date >= ESKOM_START_DATE, date <= ESKOM_END_DATE) %>%
    filter(hour %in% hours) %>%
    group_by(date) %>%
    summarise(
      n_hours = n(),
      mlr_mean = safe_mean(`Manual Load_Reduction(MLR)`),
      mlr_sum_mwh = safe_sum(`Manual Load_Reduction(MLR)`),
      contracted_demand_mean = safe_mean(`RSA Contracted Demand`),
      contracted_demand_sum_mwh = safe_sum(`RSA Contracted Demand`),
      shed_share = ifelse(
        contracted_demand_sum_mwh > 0,
        mlr_sum_mwh / contracted_demand_sum_mwh,
        NA_real_
      ),
      .groups = "drop"
    )

  names(tmp) <- c(
    "date",
    paste0("n_eskom_hours_", suffix),
    paste0("mlr_mean_", suffix),
    paste0("mlr_sum_mwh_", suffix),
    paste0("contracted_demand_mean_", suffix),
    paste0("contracted_demand_sum_mwh_", suffix),
    paste0("shed_share_", suffix)
  )
  tmp
}

message("Loading settlement demand weights.")
sett_static <- sf::st_read(SETT_GPKG, quiet = TRUE) %>%
  sf::st_drop_geometry() %>%
  mutate(
    settlement_id = as.character(settlement_id),
    demand_weight = as.numeric(demand),
    population_gpkg = as.numeric(population)
  ) %>%
  select(settlement_id, demand_weight, population_gpkg)

yearly_keep <- arrow::read_parquet(VJ_YEARLY_STATS_FILE) %>%
  mutate(
    settlement_id = as.character(settlement_id),
    population_yearly = as.numeric(population),
    electrified_best_yearly = as.integer(electrified_best)
  ) %>%
  filter(electrified_best_yearly == 1L) %>%
  select(settlement_id, population_yearly, electrified_best_yearly)

universe <- yearly_keep %>%
  left_join(sett_static, by = "settlement_id") %>%
  mutate(
    demand_weight = as.numeric(demand_weight),
    in_all_demand_universe = is.finite(demand_weight) & demand_weight > 0,
    in_validation_universe = in_all_demand_universe &
      is.finite(population_yearly) &
      population_yearly > POP_MIN
  )

if (!any(universe$in_validation_universe)) {
  stop("No settlements remain in demand gate validation universe.")
}

total_demand_all <- sum(universe$demand_weight[universe$in_all_demand_universe], na.rm = TRUE)
total_demand_validation <- sum(universe$demand_weight[universe$in_validation_universe], na.rm = TRUE)
total_n_all <- sum(universe$in_all_demand_universe, na.rm = TRUE)
total_n_validation <- sum(universe$in_validation_universe, na.rm = TRUE)

message("Loading Eskom hourly exposure.")
eskom <- read.csv(ESKOM_HOURLY, stringsAsFactors = FALSE, check.names = FALSE) %>%
  mutate(
    datetime_text = as.character(`Date Time Hour Beginning`),
    date = as.Date(substr(datetime_text, 1, 10)),
    hour = as.integer(substr(datetime_text, 12, 13))
  )

if (any(is.na(eskom$date)) || any(is.na(eskom$hour))) {
  stop("Failed to parse Eskom local-clock date/hour columns.")
}

eskom_windows <- Reduce(
  function(x, y) left_join(x, y, by = "date"),
  list(
    window_exposure(eskom, 0L, "0_1am"),
    window_exposure(eskom, 1L, "1_2am_primary"),
    window_exposure(eskom, 2L, "2_3am"),
    window_exposure(eskom, c(1L, 2L), "1_3am")
  )
)

message("Loading VJ settlement-day panels.")
sett_day <- dplyr::bind_rows(lapply(VJ_PANEL_FILES, arrow::read_parquet)) %>%
  mutate(
    settlement_id = as.character(settlement_id),
    date = as.Date(date),
    population = as.numeric(population),
    coverage = as.numeric(coverage),
    p_lit_sett = as.numeric(p_lit_sett),
    mean_rad_sett = as.numeric(mean_rad_sett),
    median_rad_sett = as.numeric(median_rad_sett),
    strict_dark = p_lit_sett < STRICT_DARK_MAX,
    mostly_dark = p_lit_sett < MOSTLY_DARK_MAX,
    relaxed_dark = p_lit_sett < RELAXED_DARK_MAX
  ) %>%
  filter(date >= month_start, date <= analysis_end) %>%
  inner_join(
    universe %>%
      select(
        settlement_id,
        population_yearly,
        electrified_best_yearly,
        demand_weight,
        in_all_demand_universe,
        in_validation_universe
      ),
    by = "settlement_id"
  ) %>%
  mutate(
    population = coalesce(population, population_yearly),
    observed_any = in_validation_universe & is.finite(p_lit_sett),
    observed_coverage_ok = observed_any & is.finite(coverage) & coverage >= COVERAGE_MIN,
    coverage_fraction = ifelse(observed_any & is.finite(coverage), pmin(pmax(coverage, 0), 1), 0),
    rad_value = coalesce(median_rad_sett, mean_rad_sett)
  )

if (nrow(sett_day) == 0) stop("No settlement-day rows remain after yearly-keep join.")

message("Computing settlement-month down-only radiance anomaly.")
rad_baseline <- sett_day %>%
  filter(in_validation_universe, is.finite(rad_value)) %>%
  mutate(month = format(date, "%Y-%m")) %>%
  group_by(settlement_id, month) %>%
  summarise(
    rad_obs_days = n(),
    rad_month_median = median(rad_value, na.rm = TRUE),
    rad_month_mad = stats::mad(rad_value, constant = 1.4826, na.rm = TRUE),
    rad_month_sd = stats::sd(rad_value, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    rad_sigma = case_when(
      is.finite(rad_month_mad) & rad_month_mad >= RAD_SIGMA_MIN ~ rad_month_mad,
      is.finite(rad_month_sd) & rad_month_sd >= RAD_SIGMA_MIN ~ rad_month_sd,
      TRUE ~ RAD_SIGMA_MIN
    ),
    rad_baseline_ok = rad_obs_days >= MIN_RAD_BASELINE_DAYS & is.finite(rad_month_median)
  )

sett_day <- sett_day %>%
  mutate(month = format(date, "%Y-%m")) %>%
  left_join(
    rad_baseline %>%
      select(settlement_id, month, rad_obs_days, rad_month_median, rad_sigma, rad_baseline_ok),
    by = c("settlement_id", "month")
  ) %>%
  mutate(
    down_only_z = ifelse(
      in_validation_universe & rad_baseline_ok & is.finite(rad_value) & is.finite(rad_sigma),
      pmax(0, (rad_month_median - rad_value) / rad_sigma),
      NA_real_
    )
  )

message("Building daily coverage gate table.")
daily_ntl <- sett_day %>%
  group_by(date) %>%
  summarise(
    observed_settlements_validation = sum(observed_any, na.rm = TRUE),
    observed_settlements_all = sum(in_all_demand_universe & is.finite(p_lit_sett), na.rm = TRUE),
    coverage_ok_settlements_validation = sum(observed_coverage_ok, na.rm = TRUE),
    observed_population_validation = safe_sum(ifelse(observed_any, population, 0)),
    raw_observed_demand_validation = safe_sum(ifelse(observed_any, demand_weight, 0)),
    raw_observed_demand_all = safe_sum(ifelse(in_all_demand_universe & is.finite(p_lit_sett), demand_weight, 0)),
    coverage_ok_demand_validation = safe_sum(ifelse(observed_coverage_ok, demand_weight, 0)),
    coverage_weighted_demand_validation = safe_sum(ifelse(observed_any, demand_weight * coverage_fraction, 0)),
    mean_coverage_validation = safe_weighted_mean(coverage, ifelse(in_validation_universe, demand_weight, NA_real_)),
    population_pop_gt100 = safe_sum(ifelse(observed_any, population, 0)),
    popw_strict_dark_share = safe_weighted_mean(
      as.numeric(strict_dark[observed_any]),
      population[observed_any]
    ),
    popw_mostly_dark_share = safe_weighted_mean(
      as.numeric(mostly_dark[observed_any]),
      population[observed_any]
    ),
    popw_relaxed_dark_share = safe_weighted_mean(
      as.numeric(relaxed_dark[observed_any]),
      population[observed_any]
    ),
    demandw_strict_dark_share = safe_weighted_mean(
      as.numeric(strict_dark[observed_any]),
      demand_weight[observed_any]
    ),
    demandw_mostly_dark_share = safe_weighted_mean(
      as.numeric(mostly_dark[observed_any]),
      demand_weight[observed_any]
    ),
    demandw_relaxed_dark_share = safe_weighted_mean(
      as.numeric(relaxed_dark[observed_any]),
      demand_weight[observed_any]
    ),
    demandw_down_only_z = safe_weighted_mean(
      down_only_z[observed_any],
      demand_weight[observed_any]
    ),
    demandw_down_only_z_coverage_ok = safe_weighted_mean(
      down_only_z[observed_coverage_ok],
      demand_weight[observed_coverage_ok]
    ),
    .groups = "drop"
  ) %>%
  mutate(
    total_settlements_all = total_n_all,
    total_settlements_validation = total_n_validation,
    total_demand_all = total_demand_all,
    total_demand_validation = total_demand_validation,
    observed_settlement_share_validation = observed_settlements_validation / total_settlements_validation,
    observed_settlement_share_all = observed_settlements_all / total_settlements_all,
    raw_observed_demand_share = raw_observed_demand_validation / total_demand_validation,
    raw_observed_demand_share_all_electrified = raw_observed_demand_all / total_demand_all,
    observed_demand_share = coverage_ok_demand_validation / total_demand_validation,
    observed_demand_share_all_electrified = coverage_ok_demand_validation / total_demand_all,
    coverage_ok_demand_share = coverage_ok_demand_validation / total_demand_validation,
    coverage_weighted_demand_share = coverage_weighted_demand_validation / total_demand_validation
  )

if (!(GATE_SHARE_COL %in% names(daily_ntl))) {
  stop("GATE_SHARE_COL not found in daily table: ", GATE_SHARE_COL)
}

daily_panel <- daily_ntl %>%
  mutate(
    vj_product_date = date,
    local_overpass_date = date + 1L
  ) %>%
  left_join(
    eskom_windows %>% rename(local_overpass_date = date),
    by = "local_overpass_date"
  ) %>%
  mutate(
    gate_demand_share = .data[[GATE_SHARE_COL]],
    gate_tier = case_when(
      gate_demand_share >= GATE_T ~ "pass",
      gate_demand_share >= HARD_FLOOR ~ "low_confidence",
      TRUE ~ "fail"
    ),
    any_shed_1_2am = case_when(
      is.finite(shed_share_1_2am_primary) & shed_share_1_2am_primary > 0 ~ 1L,
      is.finite(shed_share_1_2am_primary) ~ 0L,
      TRUE ~ NA_integer_
    ),
    month = format(date, "%Y-%m")
  ) %>%
  arrange(date)

outcomes <- c(
  "popw_strict_dark_share",
  "popw_mostly_dark_share",
  "popw_relaxed_dark_share",
  "demandw_strict_dark_share",
  "demandw_mostly_dark_share",
  "demandw_relaxed_dark_share",
  "demandw_down_only_z",
  "demandw_down_only_z_coverage_ok"
)

message("Computing gated and ungated validation metrics.")
validation_table <- bind_rows(lapply(outcomes, function(outcome) {
  bind_rows(
    validation_metrics(daily_panel, outcome, "ungated_all_complete", NA_real_),
    validation_metrics(daily_panel %>% filter(gate_tier == "pass"), outcome, "gated_pass", GATE_T),
    validation_metrics(daily_panel %>% filter(gate_tier == "low_confidence"), outcome, "low_confidence_only", GATE_T),
    validation_metrics(daily_panel %>% filter(gate_tier == "fail"), outcome, "fail_only", GATE_T)
  )
}))

thresholds <- seq(0, 1, by = 0.05)
threshold_sweep <- bind_rows(lapply(thresholds, function(thr) {
  sub <- daily_panel %>% filter(gate_demand_share >= thr)
  bind_rows(lapply(outcomes, function(outcome) {
    validation_metrics(sub, outcome, paste0("threshold_", sprintf("%02d", round(thr * 100))), thr)
  })) %>%
    mutate(
      threshold = thr,
      n_days_surviving = nrow(sub),
      mean_gate_demand_share = safe_mean(sub$gate_demand_share),
      min_gate_demand_share = ifelse(nrow(sub) > 0, min(sub$gate_demand_share, na.rm = TRUE), NA_real_),
      max_gate_demand_share = ifelse(nrow(sub) > 0, max(sub$gate_demand_share, na.rm = TRUE), NA_real_)
    )
}))

monthly_bias <- daily_panel %>%
  group_by(month) %>%
  summarise(
    total_nights = n(),
    matched_eskom_nights = sum(is.finite(shed_share_1_2am_primary), na.rm = TRUE),
    pass = sum(gate_tier == "pass", na.rm = TRUE),
    low_confidence = sum(gate_tier == "low_confidence", na.rm = TRUE),
    fail = sum(gate_tier == "fail", na.rm = TRUE),
    dropped = low_confidence + fail,
    dropped_share = dropped / total_nights,
    mean_gate_demand_share = safe_mean(gate_demand_share),
    min_gate_demand_share = min(gate_demand_share, na.rm = TRUE),
    max_gate_demand_share = max(gate_demand_share, na.rm = TRUE),
    .groups = "drop"
  )

gate_variant_cols <- c(
  "observed_demand_share",
  "coverage_weighted_demand_share",
  "raw_observed_demand_share",
  "observed_settlement_share_validation"
)

gate_variant_comparison <- bind_rows(lapply(gate_variant_cols, function(gate_col) {
  sub <- daily_panel %>% filter(.data[[gate_col]] >= GATE_T)
  bind_rows(lapply(
    c("popw_strict_dark_share", "popw_mostly_dark_share", "demandw_down_only_z"),
    function(outcome) validation_metrics(sub, outcome, gate_col, GATE_T)
  )) %>%
    mutate(
      gate_metric = gate_col,
      surviving_product_date_nights = nrow(sub),
      mean_gate_metric = safe_mean(sub[[gate_col]]),
      .before = 1
    )
}))

summary_table <- data.frame(
  metric = c(
    "analysis_window",
    "gate_threshold",
    "hard_floor",
    "gate_share_column",
    "coverage_min",
    "validation_population_min",
    "settlements_all_demand_universe",
    "settlements_validation_universe",
    "total_demand_all",
    "total_demand_validation",
    "total_product_date_nights",
    "matched_eskom_nights",
    "pass_nights",
    "low_confidence_nights",
    "fail_nights",
    "pass_share_of_matched_nights",
    "mean_gate_demand_share",
    "median_gate_demand_share",
    "min_gate_demand_share",
    "max_gate_demand_share"
  ),
  value = c(
    analysis_window_text,
    as.character(GATE_T),
    as.character(HARD_FLOOR),
    GATE_SHARE_COL,
    as.character(COVERAGE_MIN),
    as.character(POP_MIN),
    as.character(total_n_all),
    as.character(total_n_validation),
    as.character(total_demand_all),
    as.character(total_demand_validation),
    as.character(nrow(daily_panel)),
    as.character(sum(is.finite(daily_panel$shed_share_1_2am_primary))),
    as.character(sum(daily_panel$gate_tier == "pass" & is.finite(daily_panel$shed_share_1_2am_primary))),
    as.character(sum(daily_panel$gate_tier == "low_confidence" & is.finite(daily_panel$shed_share_1_2am_primary))),
    as.character(sum(daily_panel$gate_tier == "fail" & is.finite(daily_panel$shed_share_1_2am_primary))),
    as.character(mean(daily_panel$gate_tier == "pass", na.rm = TRUE)),
    as.character(mean(daily_panel$gate_demand_share, na.rm = TRUE)),
    as.character(median(daily_panel$gate_demand_share, na.rm = TRUE)),
    as.character(min(daily_panel$gate_demand_share, na.rm = TRUE)),
    as.character(max(daily_panel$gate_demand_share, na.rm = TRUE))
  ),
  stringsAsFactors = FALSE
)

universe_summary <- universe %>%
  summarise(
    yearly_keep_settlements = n(),
    all_demand_universe_settlements = sum(in_all_demand_universe, na.rm = TRUE),
    validation_universe_settlements = sum(in_validation_universe, na.rm = TRUE),
    total_demand_all = sum(demand_weight[in_all_demand_universe], na.rm = TRUE),
    total_demand_validation = sum(demand_weight[in_validation_universe], na.rm = TRUE),
    validation_demand_share_of_all = total_demand_validation / total_demand_all,
    missing_or_nonpositive_demand = sum(!in_all_demand_universe, na.rm = TRUE),
    .groups = "drop"
  )

message("Writing tables.")
write.csv(daily_panel, OUT_COVERAGE, row.names = FALSE)
write.csv(validation_table, OUT_VALIDATION, row.names = FALSE)
write.csv(threshold_sweep, OUT_SWEEP, row.names = FALSE)
write.csv(monthly_bias, OUT_MONTHLY, row.names = FALSE)
write.csv(summary_table, OUT_SUMMARY_TABLE, row.names = FALSE)
write.csv(universe_summary, OUT_UNIVERSE, row.names = FALSE)
write.csv(gate_variant_comparison, OUT_VARIANTS, row.names = FALSE)

message("Writing figures.")
sweep_plot_data <- threshold_sweep %>%
  filter(outcome %in% c("popw_strict_dark_share", "popw_mostly_dark_share", "demandw_down_only_z")) %>%
  mutate(outcome_label = recode(
    outcome,
    popw_strict_dark_share = "Population-weighted strict dark",
    popw_mostly_dark_share = "Population-weighted mostly dark",
    demandw_down_only_z = "Demand-weighted down-only radiance z"
  ))

p_sweep <- ggplot(sweep_plot_data, aes(x = threshold, y = pearson_r, color = outcome_label)) +
  geom_hline(yintercept = 0, color = "#999999", linewidth = 0.3) +
  geom_vline(xintercept = GATE_T, linetype = "dashed", color = "#333333", linewidth = 0.4) +
  geom_line(linewidth = 0.7) +
  geom_point(aes(size = n), alpha = 0.8) +
  scale_x_continuous(labels = scales::percent_format(accuracy = 1)) +
  scale_size_continuous(name = "Regression nights", range = c(1.5, 5)) +
  labs(
    title = "Demand-weighted coverage-gate threshold sweep",
    subtitle = paste0("Gate metric: ", GATE_SHARE_COL, "; vertical line is configured T = ", scales::percent(GATE_T, accuracy = 1)),
    x = "Minimum observed demand share",
    y = "Pearson r against Eskom MLR shed share",
    color = NULL
  ) +
  theme_minimal(base_size = 11) +
  theme(legend.position = "bottom")

ggsave(OUT_SWEEP_PNG, p_sweep, width = 9.5, height = 5.8, dpi = 220)

monthly_plot_data <- monthly_bias %>%
  select(month, pass, low_confidence, fail) %>%
  pivot_longer(c(pass, low_confidence, fail), names_to = "tier", values_to = "nights") %>%
  mutate(tier = factor(tier, levels = c("pass", "low_confidence", "fail")))

p_monthly <- ggplot(monthly_plot_data, aes(x = month, y = nights, fill = tier)) +
  geom_col(width = 0.72) +
  scale_fill_manual(values = c(pass = "#2B8CBE", low_confidence = "#FEC44F", fail = "#D95F0E")) +
  labs(
    title = "Demand-weighted coverage gate by month",
    subtitle = paste0("T = ", scales::percent(GATE_T, accuracy = 1), "; hard floor = ", scales::percent(HARD_FLOOR, accuracy = 1)),
    x = NULL,
    y = "Product-date nights",
    fill = NULL
  ) +
  theme_minimal(base_size = 11) +
  theme(axis.text.x = element_text(angle = 45, hjust = 1), legend.position = "bottom")

ggsave(OUT_MONTHLY_PNG, p_monthly, width = 9.5, height = 5.2, dpi = 220)

fmt_num <- function(x, digits = 3) {
  ifelse(is.na(x), "NA", formatC(as.numeric(x), digits = digits, format = "f"))
}

fmt_p <- function(x) {
  ifelse(is.na(x), "NA", formatC(as.numeric(x), digits = 3, format = "e"))
}

main_rows <- validation_table %>%
  filter(
    sample %in% c("ungated_all_complete", "gated_pass"),
    outcome %in% c("popw_strict_dark_share", "popw_mostly_dark_share", "popw_relaxed_dark_share", "demandw_down_only_z")
  ) %>%
  mutate(
    outcome_label = recode(
      outcome,
      popw_strict_dark_share = "Population-weighted strict dark",
      popw_mostly_dark_share = "Population-weighted mostly dark",
      popw_relaxed_dark_share = "Population-weighted p_lit < 0.40",
      demandw_down_only_z = "Demand-weighted down-only z"
    )
  )

summary_lines <- c(
  "# VJ146A2 Demand-Weighted Coverage Gate Validation",
  "",
  paste0("**Date:** ", Sys.Date()),
  paste0("**Status:** Concept validation, separate from the current Ravi-style script"),
  paste0("**Analysis window:** ", analysis_window_text),
  paste0("**Gate metric:** `", GATE_SHARE_COL, "`"),
  paste0("**Configured threshold T:** ", scales::percent(GATE_T, accuracy = 1)),
  paste0("**Hard floor:** ", scales::percent(HARD_FLOOR, accuracy = 1)),
  "",
  "## Universe",
  "",
  paste0("- Yearly-keep settlements with positive demand: `", total_n_all, "`."),
  paste0("- Validation denominator settlements, population > ", POP_MIN, ": `", total_n_validation, "`."),
  paste0("- Validation denominator demand: `", fmt_num(total_demand_validation, 1), "`."),
  paste0("- Demand source: settlement GPKG field `demand`."),
  "",
  "## Gate Counts",
  "",
  paste0("- Product-date nights: `", nrow(daily_panel), "`."),
  paste0("- Matched Eskom nights: `", sum(is.finite(daily_panel$shed_share_1_2am_primary)), "`."),
  paste0("- Pass nights: `", sum(daily_panel$gate_tier == "pass" & is.finite(daily_panel$shed_share_1_2am_primary)), "`."),
  paste0("- Low-confidence nights: `", sum(daily_panel$gate_tier == "low_confidence" & is.finite(daily_panel$shed_share_1_2am_primary)), "`."),
  paste0("- Fail nights: `", sum(daily_panel$gate_tier == "fail" & is.finite(daily_panel$shed_share_1_2am_primary)), "`."),
  "",
  "## Gated vs Ungated Metrics",
  "",
  "| Outcome | Sample | N | Pearson r | R2 | Spearman rho | AUC any shedding | Effect per 10 pp shed | p |",
  "|---|---|---:|---:|---:|---:|---:|---:|---:|"
)

metric_lines <- apply(main_rows, 1, function(r) {
  paste0(
    "| ", r[["outcome_label"]],
    " | ", r[["sample"]],
    " | ", r[["n"]],
    " | ", fmt_num(r[["pearson_r"]], 3),
    " | ", fmt_num(r[["r_squared"]], 3),
    " | ", fmt_num(r[["spearman_rho"]], 3),
    " | ", fmt_num(r[["auc_any_shed"]], 3),
    " | ", fmt_num(r[["effect_pp_per_10pp_shed"]], 2),
    " | ", fmt_p(r[["p_value"]]),
    " |"
  )
})

worst_month <- monthly_bias %>% arrange(desc(dropped_share)) %>% slice(1)

summary_lines <- c(
  summary_lines,
  metric_lines,
  "",
  "## Seasonal Selection Check",
  "",
  paste0(
    "Worst dropped month: `", worst_month$month,
    "`, dropped share `", scales::percent(worst_month$dropped_share, accuracy = 0.1),
    "`."
  ),
  "",
  "The monthly table and plot are written beside this summary. This gate improves or worsens only the validation headline; it does not convert light loss into physical energy-not-served.",
  "",
  "## Output Files",
  "",
  "- `vj146a2_2023_demand_gate_coverage.csv`",
  "- `vj146a2_2023_demand_gate_validation_metrics.csv`",
  "- `vj146a2_2023_demand_gate_threshold_sweep.csv`",
  "- `vj146a2_2023_demand_gate_monthly_bias.csv`",
  "- `vj146a2_2023_demand_gate_metric_variant_comparison.csv`",
  "- `vj146a2_demand_gate_threshold_sweep.png`",
  "- `vj146a2_demand_gate_monthly_bias.png`"
)

writeLines(summary_lines, OUT_SUMMARY_MD)

message("Done.")
message("Output directory: ", OUT_DIR)
message("Gate metric: ", GATE_SHARE_COL, "; T = ", GATE_T, "; hard floor = ", HARD_FLOOR)
