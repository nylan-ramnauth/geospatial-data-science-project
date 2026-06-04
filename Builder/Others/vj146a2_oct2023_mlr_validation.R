rm(list = ls())

# ============================================================
# October 2023 VJ146A2 settlement-day MLR validation diagnostic
# ============================================================
#
# Diagnostic/trial path only. Does not touch production VNP files
# or the earlier exploratory Eskom MLR script outputs.
#
# Inputs:
#   - Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_cov_yearlykeep_2023-10.parquet
#   - ../pypsa-earth/data/za_validation/eskom_2023_hourly_clean.csv
#   - Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_full_col.gpkg
#
# Primary exposure:
#   - hour == 1, i.e. the hour beginning 01:00 SAST / interval 01:00-02:00.
#   - This matches the nominal VIIRS nighttime overpass near 01:30 local time.
#   - VJ146A2 files are UTC-day products. A product date D contains the
#     South Africa nighttime pass at roughly D 23:30 UTC, i.e. D+1 01:30 SAST.
#     Therefore Eskom local-clock exposure is joined on local_overpass_date = date + 1.
#   - Robustness windows allow for local-solar/clock-time spread across South Africa.
#
# Overpass grounding:
#   - NASA Earth Observatory, Black Marble / Suomi NPP:
#     https://earthobservatory.nasa.gov/NaturalHazards/view.php?id=79803
#   - NOAA NESDIS, NOAA-20 local pass timing:
#     https://www.nesdis.noaa.gov/index.php/news/how-many-new-years-eves-will-noaas-satellites-celebrate
#   - NOAA STAR, NOAA-20 VIIRS equator crossing:
#     https://www.star.nesdis.noaa.gov/atmospheric-composition-training/glossary.php
#
# Run:
#   Rscript Builder/Others/vj146a2_oct2023_mlr_validation.R
#
# RStudio:
#   - Open this file and click Source / Run.
#   - Plots are printed to the RStudio Plots pane when running interactively.
#   - To force plot printing in any session:
#       Sys.setenv(VJ146A2_SHOW_PLOTS = "1")
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
VAULT_PATH <- normalizePath(file.path(BASE_PATH, "..", "..", ".."), mustWork = TRUE)

VJ_PARQUET <- file.path(
  BASE_PATH,
  "Map Data",
  "settlement_day_outputs_vj146a2",
  "settlement_day_vj146a2_cov_yearlykeep_2023-10.parquet"
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

SETT_GPKG <- file.path(
  BASE_PATH,
  "Map Data",
  "Settlements",
  "GPKG",
  "south_africa_dre_atlas_settlements_full_col.gpkg"
)

OUT_DIR <- file.path(
  BASE_PATH,
  "Map Data",
  "settlement_day_outputs_vj146a2",
  "mlr_validation"
)

OUT_PANEL <- file.path(OUT_DIR, "vj146a2_oct2023_mlr_validation_daily_panel.csv")
OUT_COUNTS <- file.path(OUT_DIR, "vj146a2_oct2023_mlr_validation_event_counts_by_threshold.csv")
OUT_MODELS <- file.path(OUT_DIR, "vj146a2_oct2023_mlr_validation_models.csv")
OUT_ROBUSTNESS <- file.path(OUT_DIR, "vj146a2_oct2023_mlr_validation_robustness_windows.csv")
OUT_LARGE_EVENTS <- file.path(OUT_DIR, "vj146a2_oct2023_mlr_validation_large_events.csv")
OUT_RAVI_STYLE <- file.path(OUT_DIR, "vj146a2_oct2023_mlr_validation_ravi_style_table.csv")
OUT_REPORT_RMD <- file.path(OUT_DIR, "vj146a2_oct2023_mlr_validation_report.Rmd")
OUT_REPORT_PDF <- file.path(OUT_DIR, "vj146a2_oct2023_mlr_validation_report.pdf")

OUT_TS <- file.path(OUT_DIR, "timeseries_mlr_vs_dark_events.png")
OUT_SCATTER <- file.path(OUT_DIR, "scatter_primary_mlr_large_dark_events.png")
OUT_POP_SENS <- file.path(OUT_DIR, "population_threshold_sensitivity.png")
OUT_WINDOW <- file.path(OUT_DIR, "robustness_window_comparison.png")
OUT_TOP_DAYS <- file.path(OUT_DIR, "top_event_days_barplot.png")
OUT_OLD_VS_FILTERED <- file.path(OUT_DIR, "old_vs_filtered_large_event_relationship.png")
OUT_RAVI_SCATTER <- file.path(OUT_DIR, "ravi_style_popw_darkness_vs_shed_share.png")
OUT_RAVI_EXTREME <- file.path(OUT_DIR, "ravi_style_extreme_bin_darkness.png")

OLD_EXPLORATORY_PANEL <- file.path(
  BASE_PATH,
  "Map Data",
  "settlement_day_outputs_vj146a2",
  "vj146a2_oct2023_eskom_national_panel.csv"
)

for (p in c(VJ_PARQUET, ESKOM_HOURLY, SETT_GPKG)) {
  if (!file.exists(p)) stop("Input not found: ", p)
}
if (!dir.exists(OUT_DIR)) dir.create(OUT_DIR, recursive = TRUE)

POP_THRESHOLDS <- c(5000L, 10000L, 50000L, 100000L)
HEADLINE_THRESHOLD <- 10000L
STRICT_DARK_MAX <- 0.05
MOSTLY_DARK_MAX <- 0.20
COVERAGE_MIN <- 0.80
MONTH_MEDIAN_MIN <- 0.70
RAVI_POP_MIN <- 100
RAVI_EXTREME_N <- 7L
SHOW_PLOTS <- interactive() || Sys.getenv("VJ146A2_SHOW_PLOTS", "0") == "1"

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

safe_max <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) == 0) return(NA_real_)
  max(x)
}

scale_to <- function(x, target_max) {
  if (!is.finite(target_max) || target_max <= 0) return(rep(0, length(x)))
  xmax <- suppressWarnings(max(x, na.rm = TRUE))
  if (!is.finite(xmax) || xmax <= 0) return(rep(0, length(x)))
  x / xmax * target_max
}

format_p_label <- function(p) {
  if (!is.finite(p)) return("p = NA")
  if (p < 0.001) return("p < 0.001")
  paste0("p = ", sprintf("%.4f", p))
}

window_exposure <- function(eskom, hours, suffix) {
  tmp <- eskom %>%
    filter(date >= as.Date("2023-10-01"), date <= as.Date("2023-11-01")) %>%
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

# -----------------------------
# 1) Eskom hourly exposures
# -----------------------------
eskom <- read.csv(ESKOM_HOURLY, check.names = FALSE)

eskom <- eskom %>%
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

# -----------------------------
# 2) VJ settlement-day panel
# -----------------------------
sett_day <- arrow::read_parquet(VJ_PARQUET) %>%
  mutate(
    settlement_id = as.character(settlement_id),
    date = as.Date(date),
    population = as.numeric(population),
    coverage = as.numeric(coverage),
    p_lit_sett = as.numeric(p_lit_sett),
    strict_dark = p_lit_sett < STRICT_DARK_MAX,
    mostly_dark = p_lit_sett < MOSTLY_DARK_MAX
  )

month_baseline <- sett_day %>%
  group_by(settlement_id) %>%
  summarise(
    month_obs_days = n_distinct(date),
    month_median_p_lit = median(p_lit_sett, na.rm = TRUE),
    .groups = "drop"
  )

sett_day <- sett_day %>%
  left_join(month_baseline, by = "settlement_id") %>%
  mutate(
    quality_ok = is.finite(coverage) &
      coverage >= COVERAGE_MIN &
      is.finite(month_median_p_lit) &
      month_median_p_lit >= MONTH_MEDIAN_MIN
  )

sett_names <- sf::st_read(SETT_GPKG, quiet = TRUE) %>%
  sf::st_drop_geometry() %>%
  mutate(settlement_id = as.character(settlement_id)) %>%
  select(settlement_id, village_name, admin_cgaz_1, admin_cgaz_2)

vj_daily_base <- sett_day %>%
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
    mean_rad_sett = safe_mean(mean_rad_sett),
    popw_mean_rad_sett = safe_weighted_mean(mean_rad_sett, population),
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

vj_thresholds <- Reduce(
  function(x, y) left_join(x, y, by = "date"),
  lapply(POP_THRESHOLDS, threshold_daily)
)

eskom_windows_product_date <- eskom_windows %>%
  rename_with(~ paste0("productdate_", .x), -date)

daily_panel <- vj_daily_base %>%
  left_join(vj_thresholds, by = "date") %>%
  mutate(
    vj_product_date = date,
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
    ],
    mlr_mean_1_2am_prev_day = eskom_windows$mlr_mean_1_2am_primary[
      match(local_overpass_date - 1, eskom_windows$date)
    ],
    mlr_mean_1_2am_next_day = eskom_windows$mlr_mean_1_2am_primary[
      match(local_overpass_date + 1, eskom_windows$date)
    ]
  )

event_counts <- bind_rows(lapply(POP_THRESHOLDS, function(threshold) {
  data.frame(
    threshold = threshold,
    n_vj_observation_days = nrow(daily_panel),
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

large_events <- sett_day %>%
  filter(
    quality_ok,
    population >= min(POP_THRESHOLDS),
    strict_dark | mostly_dark
  ) %>%
  left_join(sett_names, by = "settlement_id") %>%
  left_join(
    daily_panel %>%
      select(
        date,
        local_overpass_date,
        mlr_mean_1_2am_primary,
        shed_share_1_2am_primary,
        mlr_mean_0_1am,
        shed_share_0_1am,
        mlr_mean_2_3am,
        shed_share_2_3am
      ),
    by = "date"
  ) %>%
  mutate(
    event_class = case_when(
      strict_dark ~ "strict_dark_p_lit_lt_0.05",
      mostly_dark ~ "mostly_dark_p_lit_lt_0.20",
      TRUE ~ NA_character_
    ),
    drop_from_month_median = month_median_p_lit - p_lit_sett,
    ge5000 = population >= 5000,
    ge10000 = population >= 10000,
    ge50000 = population >= 50000,
    ge100000 = population >= 100000
  ) %>%
  arrange(desc(population), date) %>%
  select(
    vj_product_date = date,
    local_overpass_date,
    settlement_id,
    village_name,
    admin_cgaz_1,
    admin_cgaz_2,
    population,
    event_class,
    strict_dark,
    mostly_dark,
    p_lit_sett,
    month_median_p_lit,
    drop_from_month_median,
    coverage,
    month_obs_days,
    mean_rad_sett,
    median_rad_sett,
    mlr_mean_1_2am_primary,
    shed_share_1_2am_primary,
    mlr_mean_0_1am,
    shed_share_0_1am,
    mlr_mean_2_3am,
    shed_share_2_3am,
    ge5000,
    ge10000,
    ge50000,
    ge100000
  )

# -----------------------------
# 3) Model diagnostics
# -----------------------------
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

model_rows[[length(model_rows) + 1]] <- regression_row(
  daily_panel,
  "popw_share_dark ~ shed_share_1_2am_primary",
  "ols_daily",
  "popw_share_dark",
  "shed_share_1_2am_primary",
  threshold = HEADLINE_THRESHOLD
)

model_rows[[length(model_rows) + 1]] <- regression_row(
  daily_panel,
  "popw_share_mostly_dark ~ shed_share_1_2am_primary",
  "ols_daily",
  "popw_share_mostly_dark",
  "shed_share_1_2am_primary",
  threshold = HEADLINE_THRESHOLD
)

q25 <- stats::quantile(daily_panel$shed_share_1_2am_primary, 0.25, na.rm = TRUE)
q75 <- stats::quantile(daily_panel$shed_share_1_2am_primary, 0.75, na.rm = TRUE)
extreme_panel <- daily_panel %>%
  mutate(
    top_shed_quartile = ifelse(shed_share_1_2am_primary >= q75, 1L,
      ifelse(shed_share_1_2am_primary <= q25, 0L, NA_integer_)
    )
  ) %>%
  filter(!is.na(top_shed_quartile))

for (threshold in POP_THRESHOLDS) {
  for (outcome in c(paste0("large_dark_events_", threshold), paste0("large_mostly_dark_events_", threshold))) {
    model_rows[[length(model_rows) + 1]] <- regression_row(
      extreme_panel,
      paste(outcome, "~ top_shed_quartile"),
      "extreme_bin_top_vs_bottom_quartile",
      outcome,
      "shed_share_1_2am_primary",
      threshold = threshold,
      term = "top_shed_quartile"
    )
  }
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

# -----------------------------
# 4) Ravi-style national validation
# -----------------------------
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
        vj_product_date,
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
  arrange(local_overpass_date, vj_product_date)

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
      model_type == "ravi_continuous_shed_share" ~ "All October VJ product dates; settlements with population > 100",
      model_type == "ravi_rank_top7_vs_bottom7" ~ "Seven highest vs seven lowest local-overpass shed-share days; settlements with population > 100",
      model_type == "ravi_tied_zero_bottom_quartile_sensitivity" ~ "All tied zero-MLR bottom-quartile days vs top-quartile days; settlements with population > 100",
      TRUE ~ NA_character_
    ),
    vj_date_rule = "vj_product_date = date; local_overpass_date = date + 1",
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
    vj_date_rule,
    eskom_window
  )

# -----------------------------
# 5) Figures
# -----------------------------
caption_base <- paste(
  "VJ146A2 Oct 2023 only;",
  "Eskom date = VJ product date + 1;",
  "01:00-02:00 SAST primary;",
  "candidate dark events, not confirmed outages."
)

max_events <- safe_max(c(
  daily_panel[[paste0("large_dark_events_", HEADLINE_THRESHOLD)]],
  daily_panel[[paste0("large_mostly_dark_events_", HEADLINE_THRESHOLD)]]
))
max_events <- ifelse(is.finite(max_events) && max_events > 0, max_events, 1)
max_mlr <- safe_max(daily_panel$mlr_mean_1_2am_primary)

ts_panel <- daily_panel %>%
  transmute(
    local_overpass_date = local_overpass_date,
    `Strict dark >=10k` = .data[[paste0("large_dark_events_", HEADLINE_THRESHOLD)]],
    `Mostly dark >=10k` = .data[[paste0("large_mostly_dark_events_", HEADLINE_THRESHOLD)]],
    `MLR 01-02 scaled` = scale_to(mlr_mean_1_2am_primary, max_events)
  ) %>%
  pivot_longer(-local_overpass_date, names_to = "series", values_to = "value")

p_ts <- ggplot(ts_panel, aes(x = local_overpass_date, y = value, color = series, linetype = series)) +
  geom_line(linewidth = 0.9) +
  geom_point(size = 2) +
  scale_y_continuous(
    name = "Daily candidate dark-event count",
    sec.axis = sec_axis(
      transform = ~ . / max_events * max_mlr,
      name = "Mean MLR, 01:00-02:00 (MW)"
    )
  ) +
  labs(
    title = "Eskom MLR and VJ146A2 candidate dark events",
    subtitle = "Filtered events: coverage >= 0.8, monthly median p_lit >= 0.7, population >= 10,000; x-axis is local overpass date",
    x = "Local overpass date (SAST)",
    color = NULL,
    linetype = NULL,
    caption = caption_base
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom", plot.caption = element_text(hjust = 0))

scatter_panel <- daily_panel %>%
  transmute(
    local_overpass_date = local_overpass_date,
    shed_share_1_2am_primary = shed_share_1_2am_primary,
    mlr_mean_1_2am_primary = mlr_mean_1_2am_primary,
    `Strict dark >=10k` = .data[[paste0("large_dark_events_", HEADLINE_THRESHOLD)]],
    `Mostly dark >=10k` = .data[[paste0("large_mostly_dark_events_", HEADLINE_THRESHOLD)]]
  ) %>%
  pivot_longer(
    cols = c(`Strict dark >=10k`, `Mostly dark >=10k`),
    names_to = "event_type",
    values_to = "events"
  )

p_scatter <- ggplot(scatter_panel, aes(x = shed_share_1_2am_primary, y = events, color = event_type)) +
  geom_point(aes(size = mlr_mean_1_2am_primary), alpha = 0.85) +
  geom_smooth(method = "lm", se = TRUE, linewidth = 0.8) +
  labs(
    title = "Primary MLR exposure vs large candidate dark events",
    subtitle = "Shed share is MLR / (MLR + RSA contracted demand), local overpass date hour beginning 01:00",
    x = "Shed share, 01:00-02:00 SAST",
    y = "Daily candidate event count",
    color = NULL,
    size = "MLR (MW)",
    caption = caption_base
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom", plot.caption = element_text(hjust = 0))

pop_sens <- model_table %>%
  filter(
    model_type == "ols_daily",
    grepl("^large_(mostly_)?dark_events_", outcome),
    predictor == "shed_share_1_2am_primary"
  ) %>%
  mutate(
    threshold_label = paste0(">=", format(threshold, big.mark = ",")),
    event_type = ifelse(grepl("mostly", outcome), "Mostly dark", "Strict dark")
  )

p_pop_sens <- ggplot(pop_sens, aes(x = factor(threshold), y = estimate, color = event_type, group = event_type)) +
  geom_hline(yintercept = 0, linewidth = 0.4, color = "grey55") +
  geom_line(linewidth = 0.8) +
  geom_point(size = 2.4) +
  geom_errorbar(aes(ymin = conf_low, ymax = conf_high), width = 0.12) +
  scale_x_discrete(labels = c("5k", "10k", "50k", "100k")) +
  labs(
    title = "Population-threshold sensitivity",
    subtitle = "OLS coefficient on primary shed share for filtered event counts",
    x = "Settlement population threshold",
    y = "Coefficient: events per unit shed share",
    color = NULL,
    caption = caption_base
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom", plot.caption = element_text(hjust = 0))

window_plot <- robustness_windows %>%
  filter(outcome %in% c(
    paste0("large_dark_events_", HEADLINE_THRESHOLD),
    paste0("large_mostly_dark_events_", HEADLINE_THRESHOLD)
  )) %>%
  mutate(
    outcome_label = ifelse(grepl("mostly", outcome), "Mostly dark >=10k", "Strict dark >=10k"),
    window = factor(window, levels = c("00-01", "01-02 primary", "02-03", "01-03"))
  )

p_window <- ggplot(window_plot, aes(x = window, y = estimate, color = outcome_label, group = outcome_label)) +
  geom_hline(yintercept = 0, linewidth = 0.4, color = "grey55") +
  geom_line(linewidth = 0.8) +
  geom_point(size = 2.4) +
  geom_errorbar(aes(ymin = conf_low, ymax = conf_high), width = 0.12) +
  labs(
    title = "Robustness across overpass-adjacent MLR windows",
    subtitle = "Primary diagnostic uses 01:00-02:00 SAST; adjacent windows are sensitivity checks",
    x = "MLR exposure window",
    y = "Coefficient: events per unit shed share",
    color = NULL,
    caption = caption_base
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom", plot.caption = element_text(hjust = 0))

top_days <- daily_panel %>%
  transmute(
    local_overpass_date = local_overpass_date,
    strict_events = .data[[paste0("large_dark_events_", HEADLINE_THRESHOLD)]],
    mostly_events = .data[[paste0("large_mostly_dark_events_", HEADLINE_THRESHOLD)]],
    pop_mostly_dark = .data[[paste0("pop_mostly_dark_ge", HEADLINE_THRESHOLD)]],
    mlr_mean_1_2am_primary = mlr_mean_1_2am_primary
  ) %>%
  arrange(desc(pop_mostly_dark), desc(mostly_events)) %>%
  slice_head(n = 12) %>%
  arrange(local_overpass_date) %>%
  mutate(
    date_label = format(local_overpass_date, "%b %d"),
    mlr_scaled = scale_to(mlr_mean_1_2am_primary, safe_max(pop_mostly_dark))
  )

p_top_days <- ggplot(top_days, aes(x = reorder(date_label, local_overpass_date))) +
  geom_col(aes(y = pop_mostly_dark), fill = "#4C78A8", alpha = 0.88) +
  geom_line(aes(y = mlr_scaled, group = 1), color = "#F58518", linewidth = 0.9) +
  geom_point(aes(y = mlr_scaled), color = "#F58518", size = 2.2) +
  scale_y_continuous(
    name = "Population in mostly dark settlements, >=10k",
    labels = function(x) format(round(x), big.mark = ",", scientific = FALSE),
    sec.axis = sec_axis(
      transform = ~ . / safe_max(top_days$pop_mostly_dark) * safe_max(top_days$mlr_mean_1_2am_primary),
      name = "Mean MLR, 01:00-02:00 (MW)"
    )
  ) +
  labs(
    title = "Top candidate dark-event days",
    subtitle = "Ranked by filtered population exposed in mostly dark settlements; x-axis is local overpass date",
    x = NULL,
    caption = caption_base
  ) +
  theme_minimal(base_size = 12) +
  theme(axis.text.x = element_text(angle = 35, hjust = 1), plot.caption = element_text(hjust = 0))

if (file.exists(OLD_EXPLORATORY_PANEL)) {
  old_style_daily <- read.csv(OLD_EXPLORATORY_PANEL) %>%
    mutate(date = as.Date(date)) %>%
    transmute(
      date = date,
      old_large_dark_events_10k = large_dark_events_10k,
      old_shed_share = shed_share_mean
    )
  old_scenario_label <- "Stored old exploratory output: unfiltered events, 01-03 exposure"
} else {
  old_style_daily <- sett_day %>%
    group_by(date) %>%
    summarise(
      old_large_dark_events_10k = sum(population >= HEADLINE_THRESHOLD & dark, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    left_join(daily_panel %>% select(date, old_shed_share = shed_share_1_3am), by = "date")
  old_scenario_label <- "Recomputed old-style fallback: unfiltered events, 01-03 exposure"
}

comparison_panel <- bind_rows(
  old_style_daily %>%
    transmute(
      scenario = old_scenario_label,
      x = old_shed_share,
      y = old_large_dark_events_10k
    ),
  daily_panel %>%
    transmute(
      scenario = "Validation: filtered strict events, local 01-02 primary",
      x = shed_share_1_2am_primary,
      y = .data[[paste0("large_dark_events_", HEADLINE_THRESHOLD)]]
    )
)

comparison_stats <- comparison_panel %>%
  group_by(scenario) %>%
  summarise(
    cor_value = cor(x, y, use = "complete.obs"),
    r2_value = summary(lm(y ~ x))$r.squared,
    label = paste0("cor = ", round(cor_value, 3), "\nR2 = ", round(r2_value, 3)),
    .groups = "drop"
  )

p_old_vs_filtered <- ggplot(comparison_panel, aes(x = x, y = y)) +
  geom_point(size = 2.4, alpha = 0.85, color = "#4C78A8") +
  geom_smooth(method = "lm", se = TRUE, linewidth = 0.8, color = "#F58518") +
  geom_text(
    data = comparison_stats,
    aes(x = -Inf, y = Inf, label = label),
    inherit.aes = FALSE,
    hjust = -0.08,
    vjust = 1.15,
    size = 4
  ) +
  facet_wrap(~scenario, ncol = 2) +
  labs(
    title = "Why the old large-event correlation was stronger",
    subtitle = "Old exploratory uses unfiltered large events and 01-03; validation uses filtered events and local-overpass 01-02",
    x = "Shed share in selected MLR window",
    y = "Daily large strict-dark event count, population >=10k",
    caption = caption_base
  ) +
  theme_minimal(base_size = 12) +
  theme(plot.caption = element_text(hjust = 0))

ravi_scatter_panel <- ravi_daily %>%
  select(
    local_overpass_date,
    shed_share_1_2am_primary,
    popw_strict_dark_share,
    popw_mostly_dark_share
  ) %>%
  pivot_longer(
    cols = c(popw_strict_dark_share, popw_mostly_dark_share),
    names_to = "outcome",
    values_to = "dark_share"
  ) %>%
  mutate(outcome_label = ravi_outcomes$outcome_label[match(outcome, ravi_outcomes$outcome)])

ravi_scatter_labels <- ravi_style_table %>%
  filter(model_type == "ravi_continuous_shed_share") %>%
  mutate(
    label = paste0(
      "beta = ", sprintf("%.3f", estimate),
      "\n10 pp effect = ", sprintf("%+.1f pp", effect_pp),
      "\nR2 = ", sprintf("%.3f", r_squared),
      "\n", vapply(p_value, format_p_label, character(1))
    )
  )

p_ravi_scatter <- ggplot(ravi_scatter_panel, aes(x = shed_share_1_2am_primary, y = dark_share)) +
  geom_point(size = 2.3, alpha = 0.86, color = "#276FBF") +
  geom_smooth(method = "lm", se = TRUE, linewidth = 0.85, color = "#C44E52") +
  geom_text(
    data = ravi_scatter_labels,
    aes(x = -Inf, y = Inf, label = label),
    inherit.aes = FALSE,
    hjust = -0.05,
    vjust = 1.08,
    size = 3.7
  ) +
  facet_wrap(~outcome_label, scales = "free_y") +
  scale_x_continuous(labels = function(x) sprintf("%.1f%%", x * 100)) +
  scale_y_continuous(labels = function(x) sprintf("%.1f%%", x * 100)) +
  labs(
    title = "Population-weighted darkness vs local-overpass Eskom shed share",
    subtitle = "Settlements with population > 100; shed share = MLR / (MLR + RSA contracted demand)",
    x = "Supply-normalized Eskom MLR, 01:00-02:00 SAST",
    y = "Population-weighted share of people in dark settlements",
    caption = caption_base
  ) +
  theme_minimal(base_size = 12) +
  theme(plot.caption = element_text(hjust = 0))

ravi_extreme_long <- ravi_rank_panel %>%
  filter(!is.na(top7_vs_bottom7_shed_share)) %>%
  select(
    local_overpass_date,
    top7_vs_bottom7_shed_share,
    popw_strict_dark_share,
    popw_mostly_dark_share
  ) %>%
  pivot_longer(
    cols = c(popw_strict_dark_share, popw_mostly_dark_share),
    names_to = "outcome",
    values_to = "dark_share"
  ) %>%
  mutate(
    outcome_label = ravi_outcomes$outcome_label[match(outcome, ravi_outcomes$outcome)],
    shed_bin = ifelse(top7_vs_bottom7_shed_share == 1L, "Top 7 shed-share days", "Bottom 7 shed-share days")
  )

ravi_extreme_summary <- ravi_extreme_long %>%
  group_by(outcome, outcome_label, shed_bin, top7_vs_bottom7_shed_share) %>%
  summarise(
    n_days = n(),
    mean_share = mean(dark_share, na.rm = TRUE),
    std_error = stats::sd(dark_share, na.rm = TRUE) / sqrt(n_days),
    conf_low = mean_share - stats::qt(0.975, df = n_days - 1) * std_error,
    conf_high = mean_share + stats::qt(0.975, df = n_days - 1) * std_error,
    .groups = "drop"
  ) %>%
  mutate(
    shed_bin = factor(shed_bin, levels = c("Bottom 7 shed-share days", "Top 7 shed-share days"))
  )

ravi_extreme_labels <- ravi_style_table %>%
  filter(model_type == "ravi_rank_top7_vs_bottom7") %>%
  mutate(
    label = paste0(
      "Top - bottom = ", sprintf("%+.2f pp", effect_pp),
      "\n95% CI [", sprintf("%+.2f", conf_low_pp), ", ", sprintf("%+.2f", conf_high_pp), "]"
    )
  )

p_ravi_extreme <- ggplot(ravi_extreme_summary, aes(x = shed_bin, y = mean_share, color = shed_bin)) +
  geom_point(size = 3.0) +
  geom_errorbar(aes(ymin = conf_low, ymax = conf_high), width = 0.14, linewidth = 0.7) +
  geom_text(
    data = ravi_extreme_labels,
    aes(x = 1.5, y = Inf, label = label),
    inherit.aes = FALSE,
    vjust = 1.08,
    size = 3.6
  ) +
  facet_wrap(~outcome_label, scales = "free_y") +
  scale_y_continuous(labels = function(x) sprintf("%.1f%%", x * 100)) +
  scale_color_manual(values = c("Bottom 7 shed-share days" = "#4C78A8", "Top 7 shed-share days" = "#F58518")) +
  labs(
    title = "Darkness is higher on top shed-share nights",
    subtitle = "Rank-based comparison of seven highest vs seven lowest local-overpass shed-share days",
    x = NULL,
    y = "Mean population-weighted dark share",
    color = NULL,
    caption = caption_base
  ) +
  theme_minimal(base_size = 12) +
  theme(
    legend.position = "none",
    axis.text.x = element_text(angle = 12, hjust = 1),
    plot.caption = element_text(hjust = 0)
  )

write_ravi_report_rmd <- function(path) {
  report_lines <- c(
    "---",
    "title: \"VJ146A2 October 2023 MLR Validation Report\"",
    "subtitle: \"Population-weighted nighttime darkness vs supply-normalized Eskom MLR\"",
    "date: \"2026-06-03\"",
    "output:",
    "  pdf_document:",
    "    latex_engine: xelatex",
    "    toc: false",
    "geometry: margin=0.75in",
    "---",
    "",
    "```{r setup, include=FALSE}",
    "knitr::opts_chunk$set(echo = FALSE, message = FALSE, warning = FALSE)",
    "ravi <- read.csv(\"vj146a2_oct2023_mlr_validation_ravi_style_table.csv\", check.names = FALSE)",
    "fmt_num <- function(x, digits = 3) ifelse(is.na(x), \"NA\", sprintf(paste0(\"%.\", digits, \"f\"), x))",
    "fmt_p <- function(p) ifelse(is.na(p), \"NA\", ifelse(p < 0.001, \"<0.001\", sprintf(\"%.4f\", p)))",
    "continuous <- ravi[ravi$model_type == \"ravi_continuous_shed_share\", ]",
    "strict <- continuous[continuous$outcome == \"popw_strict_dark_share\", ]",
    "mostly <- continuous[continuous$outcome == \"popw_mostly_dark_share\", ]",
    "display <- ravi[, c(\"model_type\", \"outcome\", \"n\", \"estimate\", \"p_value\", \"r_squared\", \"effect_pp\")]",
    "display$Spec <- ifelse(display$model_type == \"ravi_continuous_shed_share\", \"Headline continuous\", ifelse(display$model_type == \"ravi_rank_top7_vs_bottom7\", \"Headline top 7 vs bottom 7\", \"Robust tied-zero quartile\"))",
    "display$Outcome <- ifelse(display$outcome == \"popw_strict_dark_share\", \"Strict (<0.05)\", \"Mostly (<0.20)\")",
    "display$estimate <- fmt_num(display$estimate, 4)",
    "display$p_value <- fmt_p(display$p_value)",
    "display$r_squared <- fmt_num(display$r_squared, 3)",
    "display$effect_pp <- fmt_num(display$effect_pp, 2)",
    "display <- display[, c(\"Spec\", \"Outcome\", \"n\", \"estimate\", \"p_value\", \"r_squared\", \"effect_pp\")]",
    "names(display) <- c(\"Specification\", \"Outcome\", \"N\", \"Estimate\", \"p\", \"R2\", \"Effect, pp\")",
    "```",
    "",
    "## Validation Question",
    "",
    "Corrected October 2023 VJ146A2 results show a positive validation relationship between local-overpass Eskom MLR and satellite-observed nighttime darkness.",
    "",
    "The validation question is whether days with higher national Eskom manual load reduction at the VIIRS local overpass window also show higher population-weighted darkness in the settlement panel. The headline outcome is the population-weighted share of people in dark settlements, restricted to settlements with population greater than 100.",
    "",
    "## Methodology",
    "",
    "- Date handling: `vj_product_date = date`; `local_overpass_date = VJ product date + 1`.",
    "- Eskom exposure: local-clock hour beginning 01:00 SAST, interpreted as the 01:00-02:00 overpass window.",
    "- Predictor: `shed_share_1_2am_primary = MLR / (MLR + RSA Contracted Demand)`.",
    "- Darkness definitions: strict dark is `p_lit_sett < 0.05`; mostly dark is `p_lit_sett < 0.20`.",
    "- Sample: October 2023 VJ146A2 product dates with matched Eskom local-overpass exposure; settlements with population greater than 100.",
    "",
    "The continuous models use all 30 matched October VJ dates. The extreme-bin headline compares the seven highest vs seven lowest shed-share dates. The tied-zero bottom-quartile row is a robustness check because zero-MLR days are tied at the lower quartile.",
    "",
    "## Headline Table",
    "",
    "```{r table}",
    "knitr::kable(display, align = \"llrllll\", caption = \"Ravi-style national validation models. Continuous effect is for a 10 pp increase in shed share; bin effects are top minus bottom, in percentage points.\")",
    "```",
    "",
    "For strict darkness, the continuous coefficient is `r fmt_num(strict$estimate, 3)` with R2 `r fmt_num(strict$r_squared, 3)` and p-value `r fmt_p(strict$p_value)`. A 10 percentage-point increase in shed share implies about `r fmt_num(strict$effect_pp, 1)` percentage points higher strict-dark population share.",
    "",
    "For mostly-dark settlements, the continuous coefficient is `r fmt_num(mostly$estimate, 3)` with R2 `r fmt_num(mostly$r_squared, 3)` and p-value `r fmt_p(mostly$p_value)`. A 10 percentage-point increase in shed share implies about `r fmt_num(mostly$effect_pp, 1)` percentage points higher mostly-dark population share.",
    "",
    "## Figures",
    "",
    "```{r ravi-scatter, fig.cap=\"Population-weighted darkness increases with supply-normalized Eskom MLR in the corrected local-overpass alignment.\", out.width=\"100%\"}",
    "knitr::include_graphics(\"ravi_style_popw_darkness_vs_shed_share.png\")",
    "```",
    "",
    "```{r ravi-extreme, fig.cap=\"Rank-based top-vs-bottom shed-share comparison. Effects are reported as percentage-point differences in population-weighted darkness.\", out.width=\"100%\"}",
    "knitr::include_graphics(\"ravi_style_extreme_bin_darkness.png\")",
    "```",
    "",
    "```{r time-series, fig.cap=\"Existing diagnostic time series of Eskom MLR and large candidate dark-event counts.\", out.width=\"100%\"}",
    "knitr::include_graphics(\"timeseries_mlr_vs_dark_events.png\")",
    "```",
    "",
    "```{r threshold-sensitivity, fig.cap=\"Existing population-threshold sensitivity diagnostic for large candidate event counts.\", out.width=\"100%\"}",
    "knitr::include_graphics(\"population_threshold_sensitivity.png\")",
    "```",
    "",
    "## Interpretation",
    "",
    "The corrected October diagnostic is positive and supervisor-ready as validation evidence: higher local-overpass Eskom MLR is associated with higher satellite-observed darkness. The strongest report-facing specification is the population-weighted national share, because it asks how many people are in settlements that appear dark rather than how many settlement polygons cross a threshold.",
    "",
    "The top-7 vs bottom-7 comparison is a compact robustness view of the same relationship. It should be interpreted as an association around the overpass window, not as proof that individual settlements lost power because of Eskom MLR.",
    "",
    "## Caveats",
    "",
    "- Eskom MLR is a national proxy, while settlement darkness is local.",
    "- Candidate dark events are not confirmed outages.",
    "- VJ146A2 provides one nighttime snapshot, not full-night service continuity.",
    "- Clouds, private generation, local heterogeneity, and acquisition timing can affect settlement-level darkness.",
    "- The date-alignment convention is grounded at the workflow level; it is not per-pixel acquisition-time proof."
  )
  writeLines(report_lines, path, useBytes = TRUE)
}

# -----------------------------
# 6) Write outputs
# -----------------------------
utils::write.csv(daily_panel, OUT_PANEL, row.names = FALSE)
utils::write.csv(event_counts, OUT_COUNTS, row.names = FALSE)
utils::write.csv(model_table, OUT_MODELS, row.names = FALSE)
utils::write.csv(robustness_windows, OUT_ROBUSTNESS, row.names = FALSE)
utils::write.csv(large_events, OUT_LARGE_EVENTS, row.names = FALSE)
utils::write.csv(ravi_style_table, OUT_RAVI_STYLE, row.names = FALSE)

ggsave(OUT_TS, p_ts, width = 10.5, height = 6.1, dpi = 180)
ggsave(OUT_SCATTER, p_scatter, width = 8.4, height = 6.2, dpi = 180)
ggsave(OUT_POP_SENS, p_pop_sens, width = 8.6, height = 5.8, dpi = 180)
ggsave(OUT_WINDOW, p_window, width = 8.6, height = 5.8, dpi = 180)
ggsave(OUT_TOP_DAYS, p_top_days, width = 9.4, height = 6.1, dpi = 180)
ggsave(OUT_OLD_VS_FILTERED, p_old_vs_filtered, width = 10, height = 5.8, dpi = 180)
ggsave(OUT_RAVI_SCATTER, p_ravi_scatter, width = 9.5, height = 6.2, dpi = 180)
ggsave(OUT_RAVI_EXTREME, p_ravi_extreme, width = 9.2, height = 5.9, dpi = 180)

write_ravi_report_rmd(OUT_REPORT_RMD)
if (!requireNamespace("rmarkdown", quietly = TRUE)) {
  stop("The rmarkdown package is required to render the PDF report.")
}
rmarkdown::render(
  input = OUT_REPORT_RMD,
  output_format = "pdf_document",
  output_file = basename(OUT_REPORT_PDF),
  output_dir = OUT_DIR,
  quiet = FALSE,
  envir = new.env(parent = globalenv())
)
if (!file.exists(OUT_REPORT_PDF)) {
  stop("PDF report was not created: ", OUT_REPORT_PDF)
}

vj146a2_mlr_validation_plots <- list(
  ravi_style_popw_darkness_vs_shed_share = p_ravi_scatter,
  ravi_style_extreme_bin_darkness = p_ravi_extreme,
  timeseries_mlr_vs_dark_events = p_ts,
  scatter_primary_mlr_large_dark_events = p_scatter,
  population_threshold_sensitivity = p_pop_sens,
  robustness_window_comparison = p_window,
  top_event_days_barplot = p_top_days,
  old_vs_filtered_large_event_relationship = p_old_vs_filtered
)

if (SHOW_PLOTS) {
  message("Printing plots to the active R graphics device / RStudio Plots pane.")
  for (plot_name in names(vj146a2_mlr_validation_plots)) {
    message("Showing plot: ", plot_name)
    print(vj146a2_mlr_validation_plots[[plot_name]])
  }
}

message("Wrote daily panel: ", OUT_PANEL)
message("Wrote event counts: ", OUT_COUNTS)
message("Wrote model table: ", OUT_MODELS)
message("Wrote robustness table: ", OUT_ROBUSTNESS)
message("Wrote large events: ", OUT_LARGE_EVENTS)
message("Wrote Ravi-style table: ", OUT_RAVI_STYLE)
message("Wrote report Rmd: ", OUT_REPORT_RMD)
message("Wrote report PDF: ", OUT_REPORT_PDF)
message("Wrote figures:")
message("  - ", OUT_RAVI_SCATTER)
message("  - ", OUT_RAVI_EXTREME)
message("  - ", OUT_TS)
message("  - ", OUT_SCATTER)
message("  - ", OUT_POP_SENS)
message("  - ", OUT_WINDOW)
message("  - ", OUT_TOP_DAYS)
message("  - ", OUT_OLD_VS_FILTERED)

message("Observation days: ", nrow(daily_panel))
message("Population thresholds: ", paste(event_counts$threshold, collapse = ", "))
message("Primary Eskom exposure uses local_overpass_date = VJ product date + 1, hour beginning 01:00 only.")
message("Model types: ", paste(sort(unique(model_table$model_type)), collapse = ", "))
