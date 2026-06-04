rm(list = ls())

# ============================================================
# 2023 VJ146A2 excess-darkness validation against Eskom MLR
# ============================================================
#
# Exploratory companion to Builder/vj146a2_2023_mlr_validation.R.
# This script tests a different metric:
#   population-weighted excess darkness relative to each settlement's
#   no-MLR baseline lit share.
#
# No controls are used in the validation models. Every model is:
#   outcome ~ Eskom shed share
#
# Inputs:
#   - Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_cov_yearlykeep_YYYY-MM.parquet
#   - Map Data/reliability_outputs_vj146a2/yearly_settlement_stats_2023.parquet
#   - ../pypsa-earth/data/za_validation/eskom_2023_hourly_clean.csv
#
# Run:
#   Rscript Builder/vj146a2_2023_excess_dark_mlr_validation.R
#   VJ146A2_START_MONTH=2023-01 VJ146A2_END_MONTH=2023-06 Rscript Builder/vj146a2_2023_excess_dark_mlr_validation.R
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

START_MONTH <- Sys.getenv("VJ146A2_START_MONTH", "2023-01")
END_MONTH <- Sys.getenv("VJ146A2_END_MONTH", "2023-12")
month_start <- as.Date(paste0(START_MONTH, "-01"))
month_end <- as.Date(paste0(END_MONTH, "-01"))
if (is.na(month_start) || is.na(month_end)) stop("Invalid START_MONTH/END_MONTH (use 'YYYY-MM').")
if (month_start > month_end) stop("START_MONTH must be <= END_MONTH.")

months_seq <- seq.Date(from = month_start, to = month_end, by = "month")
analysis_end <- seq.Date(from = month_end, by = "month", length.out = 2)[2] - 1
analysis_label <- paste0(START_MONTH, "_to_", END_MONTH)
analysis_window_text <- paste0(format(month_start, "%Y-%m-%d"), " to ", format(analysis_end, "%Y-%m-%d"))
default_out_subdir <- if (START_MONTH == "2023-01" && END_MONTH == "2023-12") {
  "mlr_validation_excess_dark_2023"
} else {
  paste0("mlr_validation_excess_dark_", analysis_label)
}

ESKOM_START_DATE <- month_start - 1L
ESKOM_END_DATE <- analysis_end + 2L

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
  "settlement_day_outputs_vj146a2",
  Sys.getenv("VJ146A2_EXCESS_DARK_OUT_SUBDIR", default_out_subdir)
)

OUT_PANEL <- file.path(OUT_DIR, "vj146a2_2023_excess_dark_daily_panel.csv")
OUT_BASELINE <- file.path(OUT_DIR, "vj146a2_2023_excess_dark_baseline_support.csv")
OUT_MODELS <- file.path(OUT_DIR, "vj146a2_2023_excess_dark_models.csv")
OUT_BINS <- file.path(OUT_DIR, "vj146a2_2023_excess_dark_extreme_bin_sensitivity.csv")
OUT_DOSE <- file.path(OUT_DIR, "vj146a2_2023_excess_dark_dose_bins.csv")
OUT_COMPARE <- file.path(OUT_DIR, "vj146a2_excess_dark_vs_existing_ravi_comparison.csv")
OUT_SCATTER <- file.path(OUT_DIR, "vj146a2_excess_dark_vs_shed_share.png")
OUT_BINS_PNG <- file.path(OUT_DIR, "vj146a2_excess_dark_top_bottom_bins.png")

EXISTING_RAVI_TABLE <- file.path(
  BASE_PATH,
  "Map Data",
  "settlement_day_outputs_vj146a2",
  "mlr_validation_2023",
  "vj146a2_2023_mlr_validation_ravi_style_table.csv"
)

missing_vj_panels <- VJ_PANEL_FILES[!file.exists(VJ_PANEL_FILES)]
if (length(missing_vj_panels) > 0) {
  stop(
    "Missing VJ yearly-keep monthly panel(s):\n  - ",
    paste(missing_vj_panels, collapse = "\n  - "),
    "\nRun VJ Stage 3b first: Rscript Builder/settlement_day_yearlykeep_filter_vj146a2.R"
  )
}
for (p in c(VJ_YEARLY_STATS_FILE, ESKOM_HOURLY)) {
  if (!file.exists(p)) stop("Input not found: ", p)
}
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

# Metric parameters. These are sample/metric definitions, not regression controls.
POP_MIN <- as.numeric(Sys.getenv("VJ146A2_EXCESS_DARK_POP_MIN", "100"))
COVERAGE_MIN <- as.numeric(Sys.getenv("VJ146A2_EXCESS_DARK_COVERAGE_MIN", "0.80"))
LOW_SHED_SHARE_MAX <- as.numeric(Sys.getenv("VJ146A2_EXCESS_DARK_BASELINE_SHED_MAX", "0"))
MIN_BASELINE_DAYS <- as.integer(Sys.getenv("VJ146A2_EXCESS_DARK_MIN_BASELINE_DAYS", "15"))
EXPECTED_P_LIT_MIN <- as.numeric(Sys.getenv("VJ146A2_EXCESS_DARK_EXPECTED_MIN", "0.70"))
STRICT_DARK_MAX <- 0.05
MOSTLY_DARK_MAX <- 0.20

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

regression_row <- function(data, outcome, predictor, model_group, metric_role = "validation") {
  sub <- data[, c(outcome, predictor), drop = FALSE]
  keep <- stats::complete.cases(sub)
  for (v in names(sub)) keep <- keep & is.finite(sub[[v]])
  sub <- sub[keep, , drop = FALSE]

  if (nrow(sub) < 6 || length(unique(sub[[outcome]])) < 2 || length(unique(sub[[predictor]])) < 2) {
    return(data.frame(
      metric_role = metric_role,
      model_group = model_group,
      outcome = outcome,
      predictor = predictor,
      n = nrow(sub),
      estimate = NA_real_,
      std_error = NA_real_,
      statistic = NA_real_,
      p_value = NA_real_,
      r = NA_real_,
      r_squared = NA_real_,
      effect_pp_per_10pp_shed = NA_real_,
      stringsAsFactors = FALSE
    ))
  }

  fit <- stats::lm(stats::as.formula(paste(outcome, "~", predictor)), data = sub)
  td <- broom::tidy(fit)
  gd <- broom::glance(fit)
  hit <- td[td$term == predictor, , drop = FALSE]
  r <- stats::cor(sub[[outcome]], sub[[predictor]])
  estimate <- hit$estimate[[1]]
  std_error <- hit$std.error[[1]]

  data.frame(
    metric_role = metric_role,
    model_group = model_group,
    outcome = outcome,
    predictor = predictor,
    n = stats::nobs(fit),
    estimate = estimate,
    std_error = std_error,
    statistic = hit$statistic[[1]],
    p_value = hit$p.value[[1]],
    r = r,
    r_squared = gd$r.squared[[1]],
    effect_pp_per_10pp_shed = estimate * 10,
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

message("Loading VJ annual keep list.")
yearly_keep <- arrow::read_parquet(VJ_YEARLY_STATS_FILE) %>%
  mutate(
    settlement_id = as.character(settlement_id),
    population_yearly = as.numeric(population),
    electrified_best_yearly = as.integer(electrified_best)
  ) %>%
  filter(electrified_best_yearly == 1L) %>%
  select(settlement_id, population_yearly, electrified_best_yearly)

if (nrow(yearly_keep) == 0) {
  stop("VJ yearly stats file has no electrified_best == 1 settlements: ", VJ_YEARLY_STATS_FILE)
}

message("Loading VJ settlement-day panel.")
sett_day <- dplyr::bind_rows(lapply(VJ_PANEL_FILES, function(path) {
  arrow::read_parquet(path) %>%
    select(any_of(c("settlement_id", "date", "population", "coverage", "p_lit_sett"))) %>%
    mutate(source_file = basename(path))
})) %>%
  mutate(
    settlement_id = as.character(settlement_id),
    date = as.Date(date),
    population = as.numeric(population),
    coverage = as.numeric(coverage),
    p_lit_sett = as.numeric(p_lit_sett)
  ) %>%
  filter(date >= month_start, date <= analysis_end) %>%
  inner_join(yearly_keep, by = "settlement_id") %>%
  mutate(
    population = coalesce(population, population_yearly),
    local_overpass_date = date + 1L,
    quality_ok = is.finite(population) &
      population > POP_MIN &
      is.finite(coverage) &
      coverage >= COVERAGE_MIN &
      is.finite(p_lit_sett)
  ) %>%
  left_join(
    eskom_windows %>% rename(local_overpass_date = date),
    by = "local_overpass_date"
  ) %>%
  select(-population_yearly, -electrified_best_yearly)

if (nrow(sett_day) == 0) {
  stop("No VJ settlement-day rows remain after applying yearly keep.")
}

message("Estimating no-MLR settlement baselines.")
baseline_support <- sett_day %>%
  filter(quality_ok) %>%
  group_by(settlement_id) %>%
  summarise(
    population = max(population, na.rm = TRUE),
    all_quality_obs_days = n_distinct(date),
    all_quality_median_p_lit = median(p_lit_sett, na.rm = TRUE),
    no_mlr_baseline_obs_days = n_distinct(date[is.finite(shed_share_1_2am_primary) & shed_share_1_2am_primary <= LOW_SHED_SHARE_MAX]),
    no_mlr_median_p_lit = {
      x <- p_lit_sett[is.finite(shed_share_1_2am_primary) & shed_share_1_2am_primary <= LOW_SHED_SHARE_MAX]
      if (length(x) == 0) NA_real_ else median(x, na.rm = TRUE)
    },
    .groups = "drop"
  ) %>%
  mutate(
    expected_p_lit = ifelse(
      is.finite(no_mlr_median_p_lit) & no_mlr_baseline_obs_days >= MIN_BASELINE_DAYS,
      no_mlr_median_p_lit,
      all_quality_median_p_lit
    ),
    baseline_method = ifelse(
      is.finite(no_mlr_median_p_lit) & no_mlr_baseline_obs_days >= MIN_BASELINE_DAYS,
      "no_mlr_median",
      "all_quality_median_fallback"
    ),
    eligible_for_metric = is.finite(expected_p_lit) & expected_p_lit >= EXPECTED_P_LIT_MIN
  )

eligible_population_total <- baseline_support %>%
  filter(eligible_for_metric) %>%
  summarise(population = safe_sum(population)) %>%
  pull(population)

if (!is.finite(eligible_population_total) || eligible_population_total <= 0) {
  stop("No eligible population remains after expected_p_lit threshold.")
}

metric_rows <- sett_day %>%
  filter(quality_ok) %>%
  inner_join(
    baseline_support %>%
      filter(eligible_for_metric) %>%
      select(settlement_id, expected_p_lit, baseline_method),
    by = "settlement_id"
  ) %>%
  mutate(
    excess_dark = pmax(0, expected_p_lit - p_lit_sett),
    observed_shortfall = expected_p_lit - p_lit_sett,
    strict_dark = p_lit_sett < STRICT_DARK_MAX,
    mostly_dark = p_lit_sett < MOSTLY_DARK_MAX
  )

message("Building daily excess-darkness panel.")
daily_panel <- metric_rows %>%
  group_by(date, local_overpass_date) %>%
  summarise(
    n_settlements = n(),
    population_observed = safe_sum(population),
    eligible_population_total = eligible_population_total,
    obs_pop_share = population_observed / eligible_population_total,
    mean_coverage = safe_mean(coverage),
    popw_expected_p_lit = safe_weighted_mean(expected_p_lit, population),
    popw_observed_p_lit = safe_weighted_mean(p_lit_sett, population),
    popw_observed_shortfall = safe_weighted_mean(observed_shortfall, population),
    popw_excess_dark_observed_denom = safe_weighted_mean(excess_dark, population),
    excess_dark_pop_equiv = safe_sum(population * excess_dark),
    popw_strict_dark_share = safe_weighted_mean(as.numeric(strict_dark), population),
    popw_mostly_dark_share = safe_weighted_mean(as.numeric(mostly_dark), population),
    n_eskom_hours_0_1am = safe_mean(n_eskom_hours_0_1am),
    shed_share_0_1am = safe_mean(shed_share_0_1am),
    mlr_mean_0_1am = safe_mean(mlr_mean_0_1am),
    n_eskom_hours_1_2am_primary = safe_mean(n_eskom_hours_1_2am_primary),
    shed_share_1_2am_primary = safe_mean(shed_share_1_2am_primary),
    mlr_mean_1_2am_primary = safe_mean(mlr_mean_1_2am_primary),
    n_eskom_hours_2_3am = safe_mean(n_eskom_hours_2_3am),
    shed_share_2_3am = safe_mean(shed_share_2_3am),
    mlr_mean_2_3am = safe_mean(mlr_mean_2_3am),
    n_eskom_hours_1_3am = safe_mean(n_eskom_hours_1_3am),
    shed_share_1_3am = safe_mean(shed_share_1_3am),
    mlr_mean_1_3am = safe_mean(mlr_mean_1_3am),
    .groups = "drop"
  ) %>%
  arrange(date) %>%
  mutate(
    vj_product_date = date,
    popw_excess_dark = excess_dark_pop_equiv / eligible_population_total,
    shed_share_product_date_minus1 = eskom_windows$shed_share_1_2am_primary[match(date - 1L, eskom_windows$date)],
    shed_share_product_date_same = eskom_windows$shed_share_1_2am_primary[match(date, eskom_windows$date)],
    shed_share_product_date_plus1_primary = shed_share_1_2am_primary,
    shed_share_product_date_plus2 = eskom_windows$shed_share_1_2am_primary[match(date + 2L, eskom_windows$date)]
  )

message("Running no-control validation models.")
model_specs <- bind_rows(
  data.frame(
    model_group = "alignment",
    predictor = c(
      "shed_share_product_date_minus1",
      "shed_share_product_date_same",
      "shed_share_product_date_plus1_primary",
      "shed_share_product_date_plus2"
    ),
    stringsAsFactors = FALSE
  ),
  data.frame(
    model_group = "window",
    predictor = c(
      "shed_share_0_1am",
      "shed_share_1_2am_primary",
      "shed_share_2_3am",
      "shed_share_1_3am"
    ),
    stringsAsFactors = FALSE
  )
)

outcome_specs <- data.frame(
  outcome = c(
    "popw_excess_dark",
    "popw_excess_dark_observed_denom",
    "excess_dark_pop_equiv",
    "popw_observed_p_lit",
    "obs_pop_share",
    "mean_coverage"
  ),
  metric_role = c(
    "headline",
    "sensitivity_observed_denominator",
    "headline_population_equivalent",
    "sanity_negative_response",
    "coverage_placebo",
    "coverage_placebo"
  ),
  stringsAsFactors = FALSE
)

models <- bind_rows(lapply(seq_len(nrow(model_specs)), function(i) {
  bind_rows(lapply(seq_len(nrow(outcome_specs)), function(j) {
    regression_row(
      daily_panel,
      outcome_specs$outcome[[j]],
      model_specs$predictor[[i]],
      model_specs$model_group[[i]],
      outcome_specs$metric_role[[j]]
    )
  }))
})) %>%
  mutate(
    conf_low = estimate - 1.96 * std_error,
    conf_high = estimate + 1.96 * std_error,
    conf_low_pp_per_10pp_shed = conf_low * 10,
    conf_high_pp_per_10pp_shed = conf_high * 10
  )

message("Building top/bottom dose-bin sensitivity.")
bin_sizes <- c(7L, 14L, 30L, 60L, 90L, 120L)
extreme_bins <- bind_rows(lapply(bin_sizes, function(n_side) {
  ranked <- daily_panel %>%
    filter(is.finite(popw_excess_dark), is.finite(shed_share_1_2am_primary)) %>%
    arrange(shed_share_1_2am_primary, local_overpass_date) %>%
    mutate(
      low_rank = row_number(),
      high_rank = row_number(desc(shed_share_1_2am_primary)),
      top_vs_bottom = case_when(
        low_rank <= n_side ~ 0L,
        high_rank <= n_side ~ 1L,
        TRUE ~ NA_integer_
      )
    ) %>%
    filter(!is.na(top_vs_bottom))

  reg <- regression_row(
    ranked,
    "popw_excess_dark",
    "top_vs_bottom",
    paste0("top", n_side, "_vs_bottom", n_side),
    "headline"
  )
  means <- ranked %>%
    group_by(top_vs_bottom) %>%
    summarise(
      mean_shed_share = mean(shed_share_1_2am_primary, na.rm = TRUE),
      mean_excess_dark = mean(popw_excess_dark, na.rm = TRUE),
      .groups = "drop"
    )

  reg %>%
    mutate(
      bin_size_per_side = n_side,
      bottom_mean_shed_share = means$mean_shed_share[match(0L, means$top_vs_bottom)],
      top_mean_shed_share = means$mean_shed_share[match(1L, means$top_vs_bottom)],
      bottom_mean_excess_dark = means$mean_excess_dark[match(0L, means$top_vs_bottom)],
      top_mean_excess_dark = means$mean_excess_dark[match(1L, means$top_vs_bottom)],
      difference_pp = estimate * 100,
      bottom_mean_excess_dark_pp = bottom_mean_excess_dark * 100,
      top_mean_excess_dark_pp = top_mean_excess_dark * 100
    )
}))

dose_bins <- daily_panel %>%
  filter(is.finite(popw_excess_dark), is.finite(shed_share_1_2am_primary)) %>%
  mutate(shed_share_quintile = dplyr::ntile(shed_share_1_2am_primary, 5)) %>%
  group_by(shed_share_quintile) %>%
  summarise(
    n_days = n(),
    min_shed_share = min(shed_share_1_2am_primary, na.rm = TRUE),
    mean_shed_share = mean(shed_share_1_2am_primary, na.rm = TRUE),
    max_shed_share = max(shed_share_1_2am_primary, na.rm = TRUE),
    mean_popw_excess_dark = mean(popw_excess_dark, na.rm = TRUE),
    mean_popw_excess_dark_pp = mean_popw_excess_dark * 100,
    mean_obs_pop_share = mean(obs_pop_share, na.rm = TRUE),
    .groups = "drop"
  )

comparison_table <- models %>%
  filter(metric_role == "headline", model_group == "alignment", predictor == "shed_share_product_date_plus1_primary", outcome == "popw_excess_dark") %>%
  transmute(
    metric = "new_excess_dark",
    outcome,
    n,
    effect_pp_per_10pp_shed,
    p_value,
    r_squared,
    r
  )

if (file.exists(EXISTING_RAVI_TABLE)) {
  existing <- read.csv(EXISTING_RAVI_TABLE, check.names = FALSE) %>%
    filter(model_type == "ravi_continuous_shed_share") %>%
    transmute(
      metric = paste0("existing_", outcome),
      outcome,
      n,
      effect_pp_per_10pp_shed = effect_pp,
      p_value,
      r_squared,
      r = sign(estimate) * sqrt(r_squared)
    )
  comparison_table <- bind_rows(comparison_table, existing)
}

message("Writing outputs.")
write.csv(daily_panel, OUT_PANEL, row.names = FALSE)
write.csv(baseline_support, OUT_BASELINE, row.names = FALSE)
write.csv(models, OUT_MODELS, row.names = FALSE)
write.csv(extreme_bins, OUT_BINS, row.names = FALSE)
write.csv(dose_bins, OUT_DOSE, row.names = FALSE)
write.csv(comparison_table, OUT_COMPARE, row.names = FALSE)

scatter_panel <- daily_panel %>%
  filter(is.finite(popw_excess_dark), is.finite(shed_share_1_2am_primary))

p_scatter <- ggplot(scatter_panel, aes(x = shed_share_1_2am_primary, y = popw_excess_dark)) +
  geom_point(alpha = 0.65, size = 1.6, color = "#2B6CB0") +
  geom_smooth(method = "lm", se = TRUE, color = "#222222", linewidth = 0.6) +
  scale_x_continuous(labels = scales::percent_format(accuracy = 1)) +
  scale_y_continuous(labels = scales::percent_format(accuracy = 0.1)) +
  labs(
    title = "VJ146A2 excess darkness vs Eskom MLR",
    subtitle = paste0(
      analysis_window_text,
      "; no controls; expected light = settlement no-MLR median; local_overpass_date = product date + 1"
    ),
    x = "Supply-normalized Eskom MLR, 01:00-02:00 SAST",
    y = "Population-weighted excess darkness"
  ) +
  theme_minimal(base_size = 11)

ggsave(OUT_SCATTER, p_scatter, width = 9.3, height = 5.6, dpi = 220)

plot_bins <- extreme_bins %>%
  filter(bin_size_per_side %in% c(7L, 30L, 60L, 120L)) %>%
  select(bin_size_per_side, bottom_mean_excess_dark_pp, top_mean_excess_dark_pp) %>%
  pivot_longer(
    c(bottom_mean_excess_dark_pp, top_mean_excess_dark_pp),
    names_to = "bin",
    values_to = "mean_excess_dark_pp"
  ) %>%
  mutate(
    bin = ifelse(bin == "top_mean_excess_dark_pp", "Top shed-share days", "Bottom shed-share days"),
    bin_size_per_side = paste0("Top/bottom ", bin_size_per_side)
  )

p_bins <- ggplot(plot_bins, aes(x = bin, y = mean_excess_dark_pp, fill = bin)) +
  geom_col(width = 0.62) +
  facet_wrap(~ bin_size_per_side, nrow = 1) +
  scale_fill_manual(values = c("Bottom shed-share days" = "#74A9CF", "Top shed-share days" = "#D95F0E")) +
  labs(
    title = "VJ146A2 excess darkness: top vs bottom Eskom MLR days",
    x = NULL,
    y = "Mean population-weighted excess darkness (pp)"
  ) +
  theme_minimal(base_size = 11) +
  theme(legend.position = "none")

ggsave(OUT_BINS_PNG, p_bins, width = 11, height = 4.8, dpi = 220)

message("Done.")
message("Output directory: ", OUT_DIR)
message("No-control headline: popw_excess_dark ~ shed_share_product_date_plus1_primary")
