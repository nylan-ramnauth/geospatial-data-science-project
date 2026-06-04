rm(list = ls())

# ============================================================
# 2023 VNP46A2/blackmarbler settlement-day MLR validation
# ============================================================
#
# Companion baseline for Builder/vj146a2_2023_mlr_validation.R.
# It uses the original blackmarbler/VNP46A2 settlement-day panels and
# the VNP46A4 annual keep list, while keeping the same Eskom exposure
# definition used in the VJ run:
#   local_overpass_date = product_date + 1
#   primary exposure = 01:00-02:00 SAST, hour beginning 01:00.
#
# Run:
#   Rscript Builder/vnp46a2_2023_mlr_validation.R
#   VNP46A2_START_MONTH=2023-01 VNP46A2_END_MONTH=2023-06 Rscript Builder/vnp46a2_2023_mlr_validation.R
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(arrow)
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(broom)
})

BASE_PATH <- here::here()
VAULT_PATH <- normalizePath(file.path(BASE_PATH, "..", "..", ".."), mustWork = TRUE)

START_MONTH <- Sys.getenv("VNP46A2_START_MONTH", "2023-01")
END_MONTH <- Sys.getenv("VNP46A2_END_MONTH", "2023-12")
month_start <- as.Date(paste0(START_MONTH, "-01"))
month_end <- as.Date(paste0(END_MONTH, "-01"))
if (is.na(month_start) || is.na(month_end)) stop("Invalid START_MONTH/END_MONTH (use 'YYYY-MM').")
if (month_start > month_end) stop("START_MONTH must be <= END_MONTH.")
months_seq <- seq.Date(from = month_start, to = month_end, by = "month")
analysis_end <- seq.Date(from = month_end, by = "month", length.out = 2)[2] - 1
analysis_label <- paste0(START_MONTH, "_to_", END_MONTH)
analysis_window_text <- paste0(format(month_start, "%Y-%m-%d"), " to ", format(analysis_end, "%Y-%m-%d"))
default_out_subdir <- if (START_MONTH == "2023-01" && END_MONTH == "2023-12") {
  "mlr_validation_2023"
} else {
  paste0("mlr_validation_", analysis_label)
}

ESKOM_START_DATE <- month_start
ESKOM_END_DATE <- analysis_end + 1L

VNP_PANEL_DIR <- file.path(BASE_PATH, "Map Data", "settlement_day_outputs_rasters_blackmarbler")
VNP_PANEL_FILES <- file.path(
  VNP_PANEL_DIR,
  paste0("settlement_day_blackmarbler_cov_", format(months_seq, "%Y-%m"), ".parquet")
)

VNP_YEARLY_STATS_FILE <- Sys.getenv(
  "VNP46A2_YEARLY_STATS_FILE",
  file.path(
    BASE_PATH,
    "Map Data",
    "reliability_outputs_blackmarbler",
    paste0("yearly_settlement_stats_", substr(START_MONTH, 1, 4), ".parquet")
  )
)

VJ_YEARLY_STATS_FILE <- file.path(
  BASE_PATH,
  "Map Data",
  "reliability_outputs_vj146a2",
  paste0("yearly_settlement_stats_", substr(START_MONTH, 1, 4), ".parquet")
)

ESKOM_HOURLY <- file.path(
  VAULT_PATH,
  "6-codebases",
  "repos",
  "pypsa-earth",
  "data",
  "za_validation",
  "eskom_2023_hourly_clean.csv"
)

OUT_DIR <- file.path(
  BASE_PATH,
  "Map Data",
  "settlement_day_outputs_rasters_blackmarbler",
  Sys.getenv("VNP46A2_MLR_OUT_SUBDIR", default_out_subdir)
)

OUT_PANEL <- file.path(OUT_DIR, "vnp46a2_2023_mlr_validation_daily_panel.csv")
OUT_COUNTS <- file.path(OUT_DIR, "vnp46a2_2023_mlr_validation_event_counts_by_threshold.csv")
OUT_MODELS <- file.path(OUT_DIR, "vnp46a2_2023_mlr_validation_models.csv")
OUT_ROBUSTNESS <- file.path(OUT_DIR, "vnp46a2_2023_mlr_validation_robustness_windows.csv")
OUT_RAVI_STYLE <- file.path(OUT_DIR, "vnp46a2_2023_mlr_validation_ravi_style_table.csv")
OUT_EXTREME_SENS <- file.path(OUT_DIR, "vnp46a2_fullyear_ravi_extreme_bin_sensitivity.csv")
OUT_VJ_COMPARE <- file.path(OUT_DIR, "vnp46a2_vs_vj146a2_ravi_style_comparison.csv")
OUT_DAILY_COMPARE <- file.path(OUT_DIR, "vnp46a2_vs_vj146a2_daily_correlation_comparison.csv")
OUT_DISAGREE <- file.path(OUT_DIR, "vnp46a2_2023_mlr_validation_disagreement_set_sensitivity.csv")
OUT_SCATTER <- file.path(OUT_DIR, "vnp46a2_ravi_style_popw_darkness_vs_shed_share.png")
OUT_EXTREME <- file.path(OUT_DIR, "vnp46a2_ravi_style_extreme_bin_darkness.png")

VJ_FULL_YEAR_DIR <- file.path(BASE_PATH, "Map Data", "settlement_day_outputs_vj146a2", "mlr_validation_2023")
VJ_RAVI_STYLE <- file.path(VJ_FULL_YEAR_DIR, "vj146a2_2023_mlr_validation_ravi_style_table.csv")
VJ_DAILY_PANEL <- file.path(VJ_FULL_YEAR_DIR, "vj146a2_2023_mlr_validation_daily_panel.csv")

for (p in c(VNP_YEARLY_STATS_FILE, ESKOM_HOURLY)) {
  if (!file.exists(p)) stop("Input not found: ", p)
}
missing_vnp_panels <- VNP_PANEL_FILES[!file.exists(VNP_PANEL_FILES)]
if (length(missing_vnp_panels) > 0) {
  stop(
    "Missing VNP coverage-filtered monthly panel(s):\n  - ",
    paste(missing_vnp_panels, collapse = "\n  - "),
    "\nRun Builder/settlement_day_coverage_filter.R first."
  )
}
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

POP_THRESHOLDS <- c(5000L, 10000L, 50000L, 100000L)
HEADLINE_THRESHOLD <- 10000L
STRICT_DARK_MAX <- 0.05
MOSTLY_DARK_MAX <- 0.20
COVERAGE_MIN <- 0.80
ANALYSIS_MEDIAN_MIN <- 0.70
RAVI_POP_MIN <- 100
RAVI_EXTREME_N <- 7L

safe_mean <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) == 0) return(NA_real_)
  mean(x)
}

safe_sum <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) == 0) return(0)
  sum(x)
}

safe_weighted_mean <- function(x, w) {
  ok <- is.finite(x) & is.finite(w) & w > 0
  if (!any(ok)) return(NA_real_)
  weighted.mean(x[ok], w[ok])
}

regression_row <- function(data, formula_text, model_type, outcome, predictor,
                           threshold = NA_integer_, window = NA_character_,
                           term = predictor, family = NULL) {
  f <- as.formula(formula_text)
  vars <- all.vars(f)
  sub <- data[, vars, drop = FALSE]
  keep <- stats::complete.cases(sub)
  for (v in vars) keep <- keep & is.finite(sub[[v]])
  sub <- sub[keep, , drop = FALSE]

  if (nrow(sub) < 6 || length(unique(sub[[outcome]])) < 2 || length(unique(sub[[term]])) < 2) {
    return(data.frame(
      model_type = model_type,
      outcome = outcome,
      predictor = predictor,
      term = term,
      threshold = threshold,
      window = window,
      n = nrow(sub),
      estimate = NA_real_,
      std_error = NA_real_,
      statistic = NA_real_,
      p_value = NA_real_,
      r_squared = NA_real_,
      dispersion = NA_real_,
      stringsAsFactors = FALSE
    ))
  }

  fit <- tryCatch(
    {
      if (is.null(family)) {
        stats::lm(f, data = sub)
      } else {
        stats::glm(f, data = sub, family = family)
      }
    },
    error = function(e) NULL
  )

  if (is.null(fit)) {
    return(data.frame(
      model_type = model_type,
      outcome = outcome,
      predictor = predictor,
      term = term,
      threshold = threshold,
      window = window,
      n = nrow(sub),
      estimate = NA_real_,
      std_error = NA_real_,
      statistic = NA_real_,
      p_value = NA_real_,
      r_squared = NA_real_,
      dispersion = NA_real_,
      stringsAsFactors = FALSE
    ))
  }

  td <- broom::tidy(fit)
  gd <- tryCatch(broom::glance(fit), error = function(e) data.frame())
  hit <- td[td$term == term, , drop = FALSE]
  if (nrow(hit) == 0) hit <- td[td$term != "(Intercept)", , drop = FALSE][1, , drop = FALSE]

  data.frame(
    model_type = model_type,
    outcome = outcome,
    predictor = predictor,
    term = ifelse(nrow(hit) == 0, term, hit$term[[1]]),
    threshold = threshold,
    window = window,
    n = stats::nobs(fit),
    estimate = ifelse(nrow(hit) == 0, NA_real_, hit$estimate[[1]]),
    std_error = ifelse(nrow(hit) == 0, NA_real_, hit$std.error[[1]]),
    statistic = ifelse(nrow(hit) == 0, NA_real_, hit$statistic[[1]]),
    p_value = ifelse(nrow(hit) == 0, NA_real_, hit$p.value[[1]]),
    r_squared = ifelse("r.squared" %in% names(gd), gd$r.squared[[1]], NA_real_),
    dispersion = ifelse(inherits(fit, "glm"), summary(fit)$dispersion, NA_real_),
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
        mlr_sum_mwh + contracted_demand_sum_mwh > 0,
        mlr_sum_mwh / (mlr_sum_mwh + contracted_demand_sum_mwh),
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

message("Loading Eskom hourly exposure.")
eskom <- read.csv(ESKOM_HOURLY, check.names = FALSE) %>%
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

message("Loading VNP annual keep list.")
vnp_yearly <- arrow::read_parquet(VNP_YEARLY_STATS_FILE) %>%
  mutate(
    settlement_id = as.character(settlement_id),
    population_yearly = as.numeric(population),
    electrified_best_vnp = as.integer(electrified_best)
  ) %>%
  select(settlement_id, population_yearly, electrified_best_vnp)

if (file.exists(VJ_YEARLY_STATS_FILE)) {
  vj_yearly <- arrow::read_parquet(VJ_YEARLY_STATS_FILE) %>%
    mutate(
      settlement_id = as.character(settlement_id),
      electrified_best_vj = as.integer(electrified_best)
    ) %>%
    select(settlement_id, electrified_best_vj)
} else {
  warning("VJ yearly stats file not found; disagreement-set sensitivity will be skipped: ", VJ_YEARLY_STATS_FILE)
  vj_yearly <- data.frame(settlement_id = character(), electrified_best_vj = integer())
}

yearly_keep <- vnp_yearly %>%
  filter(electrified_best_vnp == 1L) %>%
  left_join(vj_yearly, by = "settlement_id") %>%
  mutate(
    electrified_best_vj = coalesce(electrified_best_vj, 0L),
    annual_keep_status = case_when(
      electrified_best_vnp == 1L & electrified_best_vj == 1L ~ "both_kept",
      electrified_best_vnp == 1L & electrified_best_vj == 0L ~ "vnp_only",
      TRUE ~ "other"
    )
  )

if (nrow(yearly_keep) == 0) {
  stop("VNP yearly stats file has no electrified_best == 1 settlements: ", VNP_YEARLY_STATS_FILE)
}

message("Loading VNP settlement-day panels.")
sett_day <- dplyr::bind_rows(lapply(VNP_PANEL_FILES, function(path) {
  arrow::read_parquet(path) %>%
    select(any_of(c("settlement_id", "date", "coverage", "p_lit_sett"))) %>%
    mutate(source_file = basename(path))
})) %>%
  mutate(
    settlement_id = as.character(settlement_id),
    date = as.Date(date),
    coverage = as.numeric(coverage),
    p_lit_sett = as.numeric(p_lit_sett),
    strict_dark = p_lit_sett < STRICT_DARK_MAX,
    mostly_dark = p_lit_sett < MOSTLY_DARK_MAX
  ) %>%
  filter(date >= month_start, date <= analysis_end) %>%
  inner_join(yearly_keep, by = "settlement_id") %>%
  mutate(population = population_yearly) %>%
  select(-population_yearly)

if (nrow(sett_day) == 0) {
  stop("No VNP settlement-day rows remain after applying electrified_best == 1 from VNP annual stats.")
}

analysis_baseline <- sett_day %>%
  group_by(settlement_id) %>%
  summarise(
    analysis_obs_days = n_distinct(date),
    analysis_median_p_lit = median(p_lit_sett, na.rm = TRUE),
    .groups = "drop"
  )

sett_day <- sett_day %>%
  left_join(analysis_baseline, by = "settlement_id") %>%
  mutate(
    quality_ok = is.finite(coverage) &
      coverage >= COVERAGE_MIN &
      is.finite(analysis_median_p_lit) &
      analysis_median_p_lit >= ANALYSIS_MEDIAN_MIN
  )

message("Building daily panel.")
vnp_daily_base <- sett_day %>%
  group_by(date) %>%
  summarise(
    n_settlements = n(),
    n_quality_settlements = sum(quality_ok, na.rm = TRUE),
    population_sum = safe_sum(population),
    quality_population_sum = safe_sum(ifelse(quality_ok, population, 0)),
    mean_coverage = safe_mean(coverage),
    mean_p_lit_sett = safe_mean(p_lit_sett),
    median_p_lit_sett = median(p_lit_sett, na.rm = TRUE),
    popw_mean_p_lit_sett = safe_weighted_mean(p_lit_sett, population),
    unfiltered_popw_share_dark = safe_weighted_mean(as.numeric(strict_dark), population),
    unfiltered_popw_share_mostly_dark = safe_weighted_mean(as.numeric(mostly_dark), population),
    .groups = "drop"
  )

threshold_daily <- function(threshold) {
  out <- sett_day %>%
    group_by(date) %>%
    summarise(
      n_quality_pop = sum(quality_ok & population >= threshold, na.rm = TRUE),
      mean_coverage_quality_pop = safe_mean(coverage[quality_ok & population >= threshold]),
      large_dark_events = sum(quality_ok & population >= threshold & strict_dark, na.rm = TRUE),
      large_mostly_dark_events = sum(quality_ok & population >= threshold & mostly_dark, na.rm = TRUE),
      pop_strict_dark = safe_sum(ifelse(quality_ok & population >= threshold & strict_dark, population, 0)),
      pop_mostly_dark = safe_sum(ifelse(quality_ok & population >= threshold & mostly_dark, population, 0)),
      popw_share_dark_thr = safe_weighted_mean(
        as.numeric(strict_dark[quality_ok & population >= threshold]),
        population[quality_ok & population >= threshold]
      ),
      popw_share_mostly_dark_thr = safe_weighted_mean(
        as.numeric(mostly_dark[quality_ok & population >= threshold]),
        population[quality_ok & population >= threshold]
      ),
      unfiltered_large_dark_events = sum(population >= threshold & strict_dark, na.rm = TRUE),
      unfiltered_large_mostly_dark_events = sum(population >= threshold & mostly_dark, na.rm = TRUE),
      unfiltered_pop_strict_dark = safe_sum(ifelse(population >= threshold & strict_dark, population, 0)),
      unfiltered_pop_mostly_dark = safe_sum(ifelse(population >= threshold & mostly_dark, population, 0)),
      .groups = "drop"
    )

  names(out) <- c(
    "date",
    paste0("n_quality_pop_ge", threshold),
    paste0("mean_coverage_quality_pop_ge", threshold),
    paste0("large_dark_events_", threshold),
    paste0("large_mostly_dark_events_", threshold),
    paste0("pop_strict_dark_ge", threshold),
    paste0("pop_mostly_dark_ge", threshold),
    paste0("popw_share_dark_ge", threshold),
    paste0("popw_share_mostly_dark_ge", threshold),
    paste0("unfiltered_large_dark_events_", threshold),
    paste0("unfiltered_large_mostly_dark_events_", threshold),
    paste0("unfiltered_pop_strict_dark_ge", threshold),
    paste0("unfiltered_pop_mostly_dark_ge", threshold)
  )
  out
}

vnp_thresholds <- Reduce(
  function(x, y) left_join(x, y, by = "date"),
  lapply(POP_THRESHOLDS, threshold_daily)
)

eskom_windows_product_date <- eskom_windows %>%
  rename_with(~ paste0("productdate_", .x), -date)

daily_panel <- vnp_daily_base %>%
  left_join(vnp_thresholds, by = "date") %>%
  mutate(
    vnp_product_date = date,
    local_overpass_date = date + 1L
  ) %>%
  left_join(
    eskom_windows %>% rename(local_overpass_date = date),
    by = "local_overpass_date"
  ) %>%
  left_join(eskom_windows_product_date, by = "date") %>%
  arrange(local_overpass_date, date) %>%
  mutate(
    popw_share_dark = .data[[paste0("popw_share_dark_ge", HEADLINE_THRESHOLD)]],
    popw_share_mostly_dark = .data[[paste0("popw_share_mostly_dark_ge", HEADLINE_THRESHOLD)]],
    shed_share_1_2am_prev_day = eskom_windows$shed_share_1_2am_primary[
      match(local_overpass_date - 1, eskom_windows$date)
    ],
    shed_share_1_2am_next_day = eskom_windows$shed_share_1_2am_primary[
      match(local_overpass_date + 1, eskom_windows$date)
    ]
  )

event_counts <- bind_rows(lapply(POP_THRESHOLDS, function(threshold) {
  data.frame(
    threshold = threshold,
    n_vnp_observation_days = nrow(daily_panel),
    total_strict_dark_events_filtered = sum(daily_panel[[paste0("large_dark_events_", threshold)]], na.rm = TRUE),
    total_mostly_dark_events_filtered = sum(daily_panel[[paste0("large_mostly_dark_events_", threshold)]], na.rm = TRUE),
    max_daily_strict_dark_events_filtered = max(daily_panel[[paste0("large_dark_events_", threshold)]], na.rm = TRUE),
    max_daily_mostly_dark_events_filtered = max(daily_panel[[paste0("large_mostly_dark_events_", threshold)]], na.rm = TRUE),
    total_population_strict_dark_filtered = sum(daily_panel[[paste0("pop_strict_dark_ge", threshold)]], na.rm = TRUE),
    total_population_mostly_dark_filtered = sum(daily_panel[[paste0("pop_mostly_dark_ge", threshold)]], na.rm = TRUE),
    total_strict_dark_events_unfiltered = sum(daily_panel[[paste0("unfiltered_large_dark_events_", threshold)]], na.rm = TRUE),
    total_mostly_dark_events_unfiltered = sum(daily_panel[[paste0("unfiltered_large_mostly_dark_events_", threshold)]], na.rm = TRUE)
  )
}))

message("Fitting daily validation models.")
model_rows <- list()
for (threshold in POP_THRESHOLDS) {
  ols_outcomes <- c(
    paste0("large_dark_events_", threshold),
    paste0("large_mostly_dark_events_", threshold),
    paste0("pop_strict_dark_ge", threshold)
  )

  for (outcome in ols_outcomes) {
    model_rows[[length(model_rows) + 1]] <- regression_row(
      daily_panel,
      paste(outcome, "~ shed_share_1_2am_primary"),
      "ols_daily",
      outcome,
      "shed_share_1_2am_primary",
      threshold = threshold
    )
  }

  for (outcome in c(paste0("large_dark_events_", threshold), paste0("large_mostly_dark_events_", threshold))) {
    model_rows[[length(model_rows) + 1]] <- regression_row(
      daily_panel,
      paste(outcome, "~ shed_share_1_2am_primary + mean_coverage"),
      "quasi_poisson_count",
      outcome,
      "shed_share_1_2am_primary",
      threshold = threshold,
      family = quasipoisson()
    )
  }
}

for (outcome in c("popw_share_dark", "popw_share_mostly_dark")) {
  model_rows[[length(model_rows) + 1]] <- regression_row(
    daily_panel,
    paste(outcome, "~ shed_share_1_2am_primary"),
    "ols_daily",
    outcome,
    "shed_share_1_2am_primary",
    threshold = HEADLINE_THRESHOLD
  )
}

placebo_predictors <- data.frame(
  model_type = c("placebo_same_day_primary", "placebo_previous_day", "placebo_next_day"),
  predictor = c(
    "shed_share_1_2am_primary",
    "shed_share_1_2am_prev_day",
    "shed_share_1_2am_next_day"
  ),
  stringsAsFactors = FALSE
)

for (i in seq_len(nrow(placebo_predictors))) {
  for (outcome in c(
    paste0("large_dark_events_", HEADLINE_THRESHOLD),
    paste0("large_mostly_dark_events_", HEADLINE_THRESHOLD),
    paste0("pop_strict_dark_ge", HEADLINE_THRESHOLD),
    "popw_share_dark"
  )) {
    model_rows[[length(model_rows) + 1]] <- regression_row(
      daily_panel,
      paste(outcome, "~", placebo_predictors$predictor[[i]]),
      placebo_predictors$model_type[[i]],
      outcome,
      placebo_predictors$predictor[[i]],
      threshold = HEADLINE_THRESHOLD
    )
  }
}

model_table <- bind_rows(model_rows) %>%
  mutate(
    conf_low = estimate - 1.96 * std_error,
    conf_high = estimate + 1.96 * std_error
  )

window_defs <- data.frame(
  window = c("00-01", "01-02 primary", "02-03", "01-03"),
  predictor = c(
    "shed_share_0_1am",
    "shed_share_1_2am_primary",
    "shed_share_2_3am",
    "shed_share_1_3am"
  ),
  stringsAsFactors = FALSE
)

robustness_rows <- list()
for (i in seq_len(nrow(window_defs))) {
  for (outcome in c(
    paste0("large_dark_events_", HEADLINE_THRESHOLD),
    paste0("large_mostly_dark_events_", HEADLINE_THRESHOLD),
    paste0("pop_strict_dark_ge", HEADLINE_THRESHOLD),
    "popw_share_dark"
  )) {
    robustness_rows[[length(robustness_rows) + 1]] <- regression_row(
      daily_panel,
      paste(outcome, "~", window_defs$predictor[[i]]),
      "robustness_window_ols",
      outcome,
      window_defs$predictor[[i]],
      threshold = HEADLINE_THRESHOLD,
      window = window_defs$window[[i]]
    )
  }
}

robustness_windows <- bind_rows(robustness_rows) %>%
  mutate(
    conf_low = estimate - 1.96 * std_error,
    conf_high = estimate + 1.96 * std_error
  )

message("Fitting Ravi-style population-weighted validation.")
ravi_daily <- sett_day %>%
  filter(
    is.finite(population),
    population > RAVI_POP_MIN,
    is.finite(p_lit_sett)
  ) %>%
  group_by(date) %>%
  summarise(
    n_settlements_pop_gt100 = n(),
    population_pop_gt100 = safe_sum(population),
    popw_strict_dark_share = safe_weighted_mean(as.numeric(strict_dark), population),
    popw_mostly_dark_share = safe_weighted_mean(as.numeric(mostly_dark), population),
    .groups = "drop"
  ) %>%
  left_join(
    daily_panel %>%
      select(
        date,
        vnp_product_date,
        local_overpass_date,
        n_eskom_hours_1_2am_primary,
        mlr_mean_1_2am_primary,
        mlr_sum_mwh_1_2am_primary,
        contracted_demand_mean_1_2am_primary,
        contracted_demand_sum_mwh_1_2am_primary,
        shed_share_1_2am_primary
      ),
    by = "date"
  ) %>%
  arrange(local_overpass_date, vnp_product_date)

ravi_outcomes <- data.frame(
  outcome = c("popw_strict_dark_share", "popw_mostly_dark_share"),
  outcome_label = c(
    "Strict dark: p_lit_sett < 0.05",
    "Mostly dark: p_lit_sett < 0.20"
  ),
  stringsAsFactors = FALSE
)

ravi_continuous_rows <- lapply(seq_len(nrow(ravi_outcomes)), function(i) {
  outcome <- ravi_outcomes$outcome[[i]]
  regression_row(
    ravi_daily,
    paste(outcome, "~ shed_share_1_2am_primary"),
    "ravi_continuous_shed_share",
    outcome,
    "shed_share_1_2am_primary"
  )
})

ravi_rank_panel <- ravi_daily %>%
  arrange(shed_share_1_2am_primary, local_overpass_date) %>%
  mutate(
    shed_share_rank_low = row_number(),
    shed_share_rank_high = row_number(desc(shed_share_1_2am_primary)),
    top7_vs_bottom7_shed_share = case_when(
      shed_share_rank_low <= RAVI_EXTREME_N ~ 0L,
      shed_share_rank_high <= RAVI_EXTREME_N ~ 1L,
      TRUE ~ NA_integer_
    )
  )

ravi_rank_rows <- lapply(seq_len(nrow(ravi_outcomes)), function(i) {
  outcome <- ravi_outcomes$outcome[[i]]
  regression_row(
    ravi_rank_panel %>% filter(!is.na(top7_vs_bottom7_shed_share)),
    paste(outcome, "~ top7_vs_bottom7_shed_share"),
    "ravi_rank_top7_vs_bottom7",
    outcome,
    "top7_vs_bottom7_shed_share",
    term = "top7_vs_bottom7_shed_share"
  )
})

ravi_q25 <- stats::quantile(ravi_daily$shed_share_1_2am_primary, 0.25, na.rm = TRUE)
ravi_q75 <- stats::quantile(ravi_daily$shed_share_1_2am_primary, 0.75, na.rm = TRUE)
ravi_tied_panel <- ravi_daily %>%
  mutate(
    tied_zero_bottom_quartile_shed_share = case_when(
      shed_share_1_2am_primary <= ravi_q25 ~ 0L,
      shed_share_1_2am_primary >= ravi_q75 ~ 1L,
      TRUE ~ NA_integer_
    )
  )

ravi_tied_rows <- lapply(seq_len(nrow(ravi_outcomes)), function(i) {
  outcome <- ravi_outcomes$outcome[[i]]
  regression_row(
    ravi_tied_panel %>% filter(!is.na(tied_zero_bottom_quartile_shed_share)),
    paste(outcome, "~ tied_zero_bottom_quartile_shed_share"),
    "ravi_tied_zero_bottom_quartile_sensitivity",
    outcome,
    "tied_zero_bottom_quartile_shed_share",
    term = "tied_zero_bottom_quartile_shed_share"
  )
})

ravi_bin_counts <- bind_rows(
  ravi_rank_panel %>%
    filter(!is.na(top7_vs_bottom7_shed_share)) %>%
    count(top7_vs_bottom7_shed_share, name = "n_bin_days") %>%
    mutate(
      model_type = "ravi_rank_top7_vs_bottom7",
      bin_value = top7_vs_bottom7_shed_share
    ) %>%
    select(model_type, bin_value, n_bin_days),
  ravi_tied_panel %>%
    filter(!is.na(tied_zero_bottom_quartile_shed_share)) %>%
    count(tied_zero_bottom_quartile_shed_share, name = "n_bin_days") %>%
    mutate(
      model_type = "ravi_tied_zero_bottom_quartile_sensitivity",
      bin_value = tied_zero_bottom_quartile_shed_share
    ) %>%
    select(model_type, bin_value, n_bin_days)
)

ravi_style_table <- bind_rows(
  ravi_continuous_rows,
  ravi_rank_rows,
  ravi_tied_rows
) %>%
  mutate(
    conf_low = estimate - 1.96 * std_error,
    conf_high = estimate + 1.96 * std_error,
    outcome_label = ravi_outcomes$outcome_label[match(outcome, ravi_outcomes$outcome)],
    model_label = case_when(
      model_type == "ravi_continuous_shed_share" ~ "Continuous shed share",
      model_type == "ravi_rank_top7_vs_bottom7" ~ "Rank top 7 vs bottom 7 shed-share days",
      model_type == "ravi_tied_zero_bottom_quartile_sensitivity" ~ "Tied-zero bottom-quartile sensitivity",
      TRUE ~ model_type
    ),
    report_role = case_when(
      model_type == "ravi_continuous_shed_share" ~ "headline_continuous",
      model_type == "ravi_rank_top7_vs_bottom7" ~ "headline_rank_extremes",
      model_type == "ravi_tied_zero_bottom_quartile_sensitivity" ~ "robustness_not_headline",
      TRUE ~ "diagnostic"
    ),
    sample_rule = case_when(
      model_type == "ravi_continuous_shed_share" ~ paste0(analysis_window_text, " VNP product dates with matched Eskom exposure; VNP annual-keep settlements with population > 100"),
      model_type == "ravi_rank_top7_vs_bottom7" ~ "Seven highest vs seven lowest local-overpass shed-share days; VNP annual-keep settlements with population > 100",
      model_type == "ravi_tied_zero_bottom_quartile_sensitivity" ~ "All tied zero-MLR bottom-quartile days vs top-quartile days; VNP annual-keep settlements with population > 100",
      TRUE ~ NA_character_
    ),
    product_date_rule = "vnp_product_date = date; local_overpass_date = date + 1",
    eskom_window = "01:00-02:00 SAST, hour beginning 01:00",
    bottom_bin_n = case_when(
      model_type == "ravi_rank_top7_vs_bottom7" ~ ravi_bin_counts$n_bin_days[
        match("ravi_rank_top7_vs_bottom7:0", paste(ravi_bin_counts$model_type, ravi_bin_counts$bin_value, sep = ":"))
      ],
      model_type == "ravi_tied_zero_bottom_quartile_sensitivity" ~ ravi_bin_counts$n_bin_days[
        match("ravi_tied_zero_bottom_quartile_sensitivity:0", paste(ravi_bin_counts$model_type, ravi_bin_counts$bin_value, sep = ":"))
      ],
      TRUE ~ NA_integer_
    ),
    top_bin_n = case_when(
      model_type == "ravi_rank_top7_vs_bottom7" ~ ravi_bin_counts$n_bin_days[
        match("ravi_rank_top7_vs_bottom7:1", paste(ravi_bin_counts$model_type, ravi_bin_counts$bin_value, sep = ":"))
      ],
      model_type == "ravi_tied_zero_bottom_quartile_sensitivity" ~ ravi_bin_counts$n_bin_days[
        match("ravi_tied_zero_bottom_quartile_sensitivity:1", paste(ravi_bin_counts$model_type, ravi_bin_counts$bin_value, sep = ":"))
      ],
      TRUE ~ NA_integer_
    ),
    effect_pp = case_when(
      model_type == "ravi_continuous_shed_share" ~ estimate * 10,
      TRUE ~ estimate * 100
    ),
    conf_low_pp = case_when(
      model_type == "ravi_continuous_shed_share" ~ conf_low * 10,
      TRUE ~ conf_low * 100
    ),
    conf_high_pp = case_when(
      model_type == "ravi_continuous_shed_share" ~ conf_high * 10,
      TRUE ~ conf_high * 100
    ),
    effect_interpretation = case_when(
      model_type == "ravi_continuous_shed_share" ~ "Percentage-point change in dark population share for a 10 pp increase in shed share",
      TRUE ~ "Top-bin minus bottom-bin difference in dark population share, percentage points"
    )
  ) %>%
  select(
    report_role,
    model_type,
    model_label,
    outcome,
    outcome_label,
    predictor,
    term,
    n,
    bottom_bin_n,
    top_bin_n,
    estimate,
    std_error,
    statistic,
    p_value,
    r_squared,
    conf_low,
    conf_high,
    effect_pp,
    conf_low_pp,
    conf_high_pp,
    effect_interpretation,
    sample_rule,
    product_date_rule,
    eskom_window
  )

message("Building wide-bin sensitivity.")
extreme_bin_sensitivity <- bind_rows(lapply(c(7L, 14L, 20L, 30L, 60L, 90L, 120L), function(n_side) {
  ranked <- ravi_daily %>%
    arrange(shed_share_1_2am_primary, local_overpass_date) %>%
    mutate(
      low_rank = row_number(),
      high_rank = row_number(desc(shed_share_1_2am_primary)),
      bin = case_when(
        low_rank <= n_side ~ 0L,
        high_rank <= n_side ~ 1L,
        TRUE ~ NA_integer_
      )
    ) %>%
    filter(!is.na(bin))

  bind_rows(lapply(seq_len(nrow(ravi_outcomes)), function(i) {
    outcome <- ravi_outcomes$outcome[[i]]
    reg <- regression_row(
      ranked,
      paste(outcome, "~ bin"),
      paste0("ravi_rank_top", n_side, "_vs_bottom", n_side),
      outcome,
      "bin",
      term = "bin"
    )
    means <- ranked %>%
      group_by(bin) %>%
      summarise(mean_value = mean(.data[[outcome]], na.rm = TRUE), .groups = "drop")
    reg %>%
      mutate(
        outcome_label = ravi_outcomes$outcome_label[[i]],
        bin_size_per_side = n_side,
        bottom_mean = means$mean_value[match(0L, means$bin)],
        top_mean = means$mean_value[match(1L, means$bin)],
        difference_pp = estimate * 100,
        bottom_mean_pp = bottom_mean * 100,
        top_mean_pp = top_mean * 100
      )
  }))
}))

message("Building VNP annual disagreement-set sensitivity.")
disagreement_daily <- bind_rows(lapply(c("vnp_all_kept", "both_kept", "vnp_only"), function(group_name) {
  tmp <- sett_day
  if (group_name == "both_kept") tmp <- tmp %>% filter(annual_keep_status == "both_kept")
  if (group_name == "vnp_only") tmp <- tmp %>% filter(annual_keep_status == "vnp_only")

  tmp %>%
    filter(is.finite(population), population > RAVI_POP_MIN, is.finite(p_lit_sett)) %>%
    group_by(date) %>%
    summarise(
      n_settlements_pop_gt100 = n(),
      population_pop_gt100 = safe_sum(population),
      popw_strict_dark_share = safe_weighted_mean(as.numeric(strict_dark), population),
      popw_mostly_dark_share = safe_weighted_mean(as.numeric(mostly_dark), population),
      .groups = "drop"
    ) %>%
    left_join(
      daily_panel %>% select(date, local_overpass_date, shed_share_1_2am_primary),
      by = "date"
    ) %>%
    mutate(sample = group_name)
}))

disagreement_sensitivity <- bind_rows(lapply(unique(disagreement_daily$sample), function(sample_name) {
  sample_daily <- disagreement_daily %>% filter(sample == sample_name)
  bind_rows(lapply(seq_len(nrow(ravi_outcomes)), function(i) {
    outcome <- ravi_outcomes$outcome[[i]]
    regression_row(
      sample_daily,
      paste(outcome, "~ shed_share_1_2am_primary"),
      "annual_keep_disagreement_sensitivity",
      outcome,
      "shed_share_1_2am_primary"
    ) %>%
      mutate(
        sample = sample_name,
        outcome_label = ravi_outcomes$outcome_label[[i]],
        mean_settlements_pop_gt100 = mean(sample_daily$n_settlements_pop_gt100, na.rm = TRUE),
        mean_population_pop_gt100 = mean(sample_daily$population_pop_gt100, na.rm = TRUE),
        effect_pp = estimate * 10
      )
  }))
}))

message("Building VJ/VNP comparison tables.")
if (file.exists(VJ_RAVI_STYLE)) {
  vj_ravi <- read.csv(VJ_RAVI_STYLE, check.names = FALSE) %>%
    mutate(product = "VJ146A2")
  vnp_ravi <- ravi_style_table %>%
    mutate(product = "VNP46A2")
  vj_vnp_ravi_comparison <- bind_rows(vj_ravi, vnp_ravi) %>%
    filter(model_type %in% c("ravi_continuous_shed_share", "ravi_rank_top7_vs_bottom7", "ravi_tied_zero_bottom_quartile_sensitivity")) %>%
    select(product, report_role, model_type, outcome, n, bottom_bin_n, top_bin_n, estimate, p_value, r_squared, effect_pp, conf_low_pp, conf_high_pp)
} else {
  warning("VJ Ravi-style table not found; VJ/VNP Ravi comparison skipped: ", VJ_RAVI_STYLE)
  vj_vnp_ravi_comparison <- data.frame()
}

daily_correlation <- function(panel, product) {
  outcomes <- c(
    paste0("large_dark_events_", HEADLINE_THRESHOLD),
    paste0("large_mostly_dark_events_", HEADLINE_THRESHOLD),
    paste0("pop_strict_dark_ge", HEADLINE_THRESHOLD),
    "popw_share_dark",
    "popw_share_mostly_dark"
  )
  bind_rows(lapply(outcomes, function(outcome) {
    if (!(outcome %in% names(panel))) return(data.frame())
    sub <- panel %>%
      select(outcome_value = all_of(outcome), shed_share_1_2am_primary) %>%
      filter(is.finite(outcome_value), is.finite(shed_share_1_2am_primary))
    r <- if (nrow(sub) >= 2 && length(unique(sub$outcome_value)) > 1) {
      stats::cor(sub$outcome_value, sub$shed_share_1_2am_primary)
    } else {
      NA_real_
    }
    reg <- regression_row(
      panel,
      paste(outcome, "~ shed_share_1_2am_primary"),
      "daily_correlation_comparison",
      outcome,
      "shed_share_1_2am_primary"
    )
    reg %>%
      mutate(product = product, r = r, r_squared_from_r = r^2)
  }))
}

if (file.exists(VJ_DAILY_PANEL)) {
  vj_daily_for_compare <- read.csv(VJ_DAILY_PANEL, check.names = FALSE)
  vj_vnp_daily_comparison <- bind_rows(
    daily_correlation(vj_daily_for_compare, "VJ146A2"),
    daily_correlation(daily_panel, "VNP46A2")
  ) %>%
    select(product, model_type, outcome, predictor, n, estimate, p_value, r_squared, r, r_squared_from_r)
} else {
  warning("VJ daily panel not found; VJ/VNP daily comparison skipped: ", VJ_DAILY_PANEL)
  vj_vnp_daily_comparison <- daily_correlation(daily_panel, "VNP46A2") %>%
    select(product, model_type, outcome, predictor, n, estimate, p_value, r_squared, r, r_squared_from_r)
}

message("Writing outputs.")
write.csv(daily_panel, OUT_PANEL, row.names = FALSE)
write.csv(event_counts, OUT_COUNTS, row.names = FALSE)
write.csv(model_table, OUT_MODELS, row.names = FALSE)
write.csv(robustness_windows, OUT_ROBUSTNESS, row.names = FALSE)
write.csv(ravi_style_table, OUT_RAVI_STYLE, row.names = FALSE)
write.csv(extreme_bin_sensitivity, OUT_EXTREME_SENS, row.names = FALSE)
write.csv(disagreement_sensitivity, OUT_DISAGREE, row.names = FALSE)
if (nrow(vj_vnp_ravi_comparison) > 0) write.csv(vj_vnp_ravi_comparison, OUT_VJ_COMPARE, row.names = FALSE)
if (nrow(vj_vnp_daily_comparison) > 0) write.csv(vj_vnp_daily_comparison, OUT_DAILY_COMPARE, row.names = FALSE)

ravi_scatter_panel <- ravi_daily %>%
  select(local_overpass_date, shed_share_1_2am_primary, popw_strict_dark_share, popw_mostly_dark_share) %>%
  pivot_longer(
    c(popw_strict_dark_share, popw_mostly_dark_share),
    names_to = "outcome",
    values_to = "dark_share"
  ) %>%
  mutate(
    outcome_label = ravi_outcomes$outcome_label[match(outcome, ravi_outcomes$outcome)]
  )

p_scatter <- ggplot(ravi_scatter_panel, aes(x = shed_share_1_2am_primary, y = dark_share)) +
  geom_point(alpha = 0.65, size = 1.7, color = "#2B6CB0") +
  geom_smooth(method = "lm", se = TRUE, color = "#222222", linewidth = 0.6) +
  facet_wrap(~ outcome_label, scales = "free_y") +
  scale_x_continuous(labels = scales::percent_format(accuracy = 1)) +
  scale_y_continuous(labels = scales::percent_format(accuracy = 1)) +
  labs(
    title = "VNP46A2 population-weighted darkness vs Eskom MLR",
    subtitle = "VNP annual-keep settlements with population > 100; local_overpass_date = product date + 1",
    x = "Supply-normalized Eskom MLR, 01:00-02:00 SAST",
    y = "Population-weighted dark share"
  ) +
  theme_minimal(base_size = 11)

ggsave(OUT_SCATTER, p_scatter, width = 9.5, height = 5.8, dpi = 220)

ravi_extreme_plot <- ravi_rank_panel %>%
  filter(!is.na(top7_vs_bottom7_shed_share)) %>%
  select(local_overpass_date, top7_vs_bottom7_shed_share, popw_strict_dark_share, popw_mostly_dark_share) %>%
  pivot_longer(
    c(popw_strict_dark_share, popw_mostly_dark_share),
    names_to = "outcome",
    values_to = "dark_share"
  ) %>%
  mutate(
    outcome_label = ravi_outcomes$outcome_label[match(outcome, ravi_outcomes$outcome)],
    shed_bin = ifelse(top7_vs_bottom7_shed_share == 1L, "Top 7 shed-share days", "Bottom 7 shed-share days")
  ) %>%
  group_by(outcome, outcome_label, shed_bin, top7_vs_bottom7_shed_share) %>%
  summarise(
    mean_dark_share = mean(dark_share, na.rm = TRUE),
    .groups = "drop"
  )

p_extreme <- ggplot(ravi_extreme_plot, aes(x = shed_bin, y = mean_dark_share, fill = shed_bin)) +
  geom_col(width = 0.62) +
  facet_wrap(~ outcome_label, scales = "free_y") +
  scale_y_continuous(labels = scales::percent_format(accuracy = 1)) +
  scale_fill_manual(values = c("Bottom 7 shed-share days" = "#74A9CF", "Top 7 shed-share days" = "#D95F0E")) +
  labs(
    title = "VNP46A2 extreme-day validation contrast",
    subtitle = "Seven highest vs seven lowest Eskom shed-share days",
    x = NULL,
    y = "Mean population-weighted dark share"
  ) +
  theme_minimal(base_size = 11) +
  theme(legend.position = "none")

ggsave(OUT_EXTREME, p_extreme, width = 8.5, height = 5.5, dpi = 220)

message("Done.")
message("VNP output directory: ", OUT_DIR)
message("Primary Eskom exposure uses local_overpass_date = product date + 1, hour beginning 01:00.")
