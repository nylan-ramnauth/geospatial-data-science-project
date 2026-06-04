rm(list = ls())

# ============================================================
# 2023 VJ146A2 national continuous-dimming MLR validation
# ============================================================
#
# Separate concept script. This does not modify the current binary validation
# scripts or report.
#
# Goal:
#   Test whether Eskom MLR predicts national partial dimming, not only binary
#   dark-settlement outcomes.
#
# Main outcomes:
#   raw_continuous_darkness = population-weighted mean(1 - p_lit_sett)
#   signed_baseline_dimming = population-weighted mean(baseline_p_lit - p_lit_sett)
#   down_only_baseline_dimming = population-weighted mean(max(baseline_p_lit - p_lit_sett, 0))
#
# Baseline hierarchy:
#   1. settlement-month median p_lit on lowest-MLR 20% pass nights in that month
#   2. settlement annual median p_lit on lowest-MLR 20% pass nights in 2023
#   3. settlement annual median p_lit on all pass nights in 2023
#
# Outputs:
#   Map Data/settlement_day_outputs_vj146a2/
#     mlr_validation_national_dimming_2023_cov50/
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(arrow)
  library(data.table)
  library(dplyr)
  library(ggplot2)
  library(lmtest)
  library(sandwich)
  library(scales)
  library(tidyr)
})

BASE_PATH <- here::here()

VJ_PANEL_DIR <- file.path(BASE_PATH, "Map Data", "settlement_day_outputs_vj146a2")
VJ_PANEL_FILES <- file.path(
  VJ_PANEL_DIR,
  paste0("settlement_day_vj146a2_cov_yearlykeep_2023-", sprintf("%02d", 1:12), ".parquet")
)
GATE_DIR <- file.path(VJ_PANEL_DIR, "mlr_validation_demand_gate_2023_cov50")
GATE_FILE <- file.path(GATE_DIR, "vj146a2_2023_demand_gate_coverage.csv")

OUT_DIR <- file.path(
  VJ_PANEL_DIR,
  Sys.getenv("VJ146A2_NATIONAL_DIMMING_OUT_SUBDIR", "mlr_validation_national_dimming_2023_cov50")
)

OUT_DAILY <- file.path(OUT_DIR, "vj146a2_2023_national_dimming_daily.csv")
OUT_METRICS <- file.path(OUT_DIR, "vj146a2_2023_national_dimming_validation_metrics.csv")
OUT_FE <- file.path(OUT_DIR, "vj146a2_2023_national_dimming_fe_robustness.csv")
OUT_QUARTILE <- file.path(OUT_DIR, "vj146a2_2023_national_dimming_extreme_quartile.csv")
OUT_BIN <- file.path(OUT_DIR, "vj146a2_2023_national_dimming_dose_response_bins.csv")
OUT_BASELINE <- file.path(OUT_DIR, "vj146a2_2023_national_dimming_baseline_sources.csv")
OUT_SUMMARY <- file.path(OUT_DIR, "vj146a2_2023_national_dimming_summary.md")
OUT_FIG_TIME <- file.path(OUT_DIR, "vj146a2_national_dimming_timeseries.png")
OUT_FIG_DOSE <- file.path(OUT_DIR, "vj146a2_national_dimming_dose_response.png")
OUT_FIG_COEF <- file.path(OUT_DIR, "vj146a2_national_dimming_coefficient_comparison.png")

missing_panels <- VJ_PANEL_FILES[!file.exists(VJ_PANEL_FILES)]
if (length(missing_panels) > 0) {
  stop("Missing VJ panel files:\n  - ", paste(missing_panels, collapse = "\n  - "))
}
if (!file.exists(GATE_FILE)) stop("Input not found: ", GATE_FILE)
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

EXCESS_LIT_FLAGS_FILE <- Sys.getenv("VJ146A2_EXCESS_LIT_FLAGS_FILE", "")
EXCESS_LIT_SCENARIO <- Sys.getenv("VJ146A2_EXCESS_LIT_SCENARIO", "annual_q3_plus_1p5_iqr")
SETTLEMENT_COVERAGE_MIN <- as.numeric(Sys.getenv("VJ146A2_NATIONAL_DIMMING_SETTLEMENT_COVERAGE_MIN", "0.50"))
POP_MIN <- as.numeric(Sys.getenv("VJ146A2_NATIONAL_DIMMING_POP_MIN", "100"))
LOW_MLR_SHARE <- as.numeric(Sys.getenv("VJ146A2_NATIONAL_DIMMING_LOW_MLR_SHARE", "0.20"))
MIN_MONTH_BASELINE_OBS <- as.integer(Sys.getenv("VJ146A2_NATIONAL_DIMMING_MIN_MONTH_BASELINE_OBS", "2"))
MIN_ANNUAL_LOW_BASELINE_OBS <- as.integer(Sys.getenv("VJ146A2_NATIONAL_DIMMING_MIN_ANNUAL_LOW_BASELINE_OBS", "5"))
MIN_ANNUAL_ALL_BASELINE_OBS <- as.integer(Sys.getenv("VJ146A2_NATIONAL_DIMMING_MIN_ANNUAL_ALL_BASELINE_OBS", "10"))
NW_LAG <- as.integer(Sys.getenv("VJ146A2_NATIONAL_DIMMING_NW_LAG", "7"))

if (!is.finite(SETTLEMENT_COVERAGE_MIN) || SETTLEMENT_COVERAGE_MIN < 0 || SETTLEMENT_COVERAGE_MIN > 1) {
  stop("Invalid settlement coverage threshold.")
}
if (!is.finite(LOW_MLR_SHARE) || LOW_MLR_SHARE <= 0 || LOW_MLR_SHARE > 1) {
  stop("Invalid low-MLR baseline share.")
}

theme_report <- function(base_size = 10.5) {
  theme_minimal(base_size = base_size) +
    theme(
      panel.grid.minor = element_blank(),
      plot.title.position = "plot",
      plot.title = element_text(face = "bold", size = base_size + 2),
      plot.subtitle = element_text(color = "#4A5568"),
      axis.title = element_text(color = "#2D3748"),
      axis.text = element_text(color = "#2D3748"),
      legend.position = "bottom",
      legend.title = element_blank()
    )
}

fmt_num <- function(x, digits = 3) {
  ifelse(is.na(x), "NA", formatC(as.numeric(x), digits = digits, format = "f"))
}

fmt_p <- function(x) {
  ifelse(
    is.na(x),
    "NA",
    ifelse(as.numeric(x) < 0.001, formatC(as.numeric(x), digits = 2, format = "e"), fmt_num(x, 3))
  )
}

safe_weighted_mean <- function(x, w) {
  ok <- is.finite(x) & is.finite(w) & w > 0
  if (!any(ok)) return(NA_real_)
  stats::weighted.mean(x[ok], w[ok])
}

safe_sum <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) == 0) return(0)
  sum(x)
}

load_exclusion_dates <- function(path, scenario) {
  if (!nzchar(path)) return(as.Date(character()))
  if (!file.exists(path)) stop("Excess-lit flag file not found: ", path)
  read.csv(path, stringsAsFactors = FALSE) %>%
    mutate(date = as.Date(date)) %>%
    filter(scenario == !!scenario, remove) %>%
    pull(date)
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

z_score <- function(x) {
  (x - mean(x, na.rm = TRUE)) / stats::sd(x, na.rm = TRUE)
}

fit_nw <- function(data, outcome, controls = NULL, model_label = "Baseline") {
  needed <- c(outcome, "shed_share_1_2am_primary", controls)
  sub <- data %>%
    filter(if_all(all_of(needed), ~ !is.na(.x))) %>%
    filter(is.finite(.data[[outcome]]), is.finite(shed_share_1_2am_primary))

  if (nrow(sub) < 30 ||
      stats::sd(sub[[outcome]], na.rm = TRUE) <= 0 ||
      stats::sd(sub$shed_share_1_2am_primary, na.rm = TRUE) <= 0) {
    return(data.frame(
      model = model_label,
      outcome = outcome,
      n = nrow(sub),
      effect_pp_per_10pp = NA_real_,
      se_nw_pp = NA_real_,
      ci_low_pp = NA_real_,
      ci_high_pp = NA_real_,
      p_value = NA_real_,
      pearson_r = NA_real_,
      spearman_rho = NA_real_,
      auc_any_shed = NA_real_,
      r_squared = NA_real_,
      adj_r_squared = NA_real_,
      rmse_pp = NA_real_,
      mae_pp = NA_real_,
      stringsAsFactors = FALSE
    ))
  }

  rhs <- paste(c("shed_share_1_2am_primary", controls), collapse = " + ")
  fit <- lm(as.formula(paste(outcome, "~", rhs)), data = sub)
  vc <- NeweyWest(fit, lag = NW_LAG, prewhite = FALSE, adjust = TRUE)
  ct <- coeftest(fit, vcov. = vc)
  coef_row <- ct["shed_share_1_2am_primary", ]
  slope <- unname(coef(fit)[["shed_share_1_2am_primary"]])
  se <- unname(coef_row[["Std. Error"]])
  ci <- slope + c(-1, 1) * stats::qnorm(0.975) * se
  resid <- residuals(fit)

  data.frame(
    model = model_label,
    outcome = outcome,
    n = nobs(fit),
    effect_pp_per_10pp = slope * 10,
    se_nw_pp = se * 10,
    ci_low_pp = ci[[1]] * 10,
    ci_high_pp = ci[[2]] * 10,
    p_value = unname(coef_row[["Pr(>|t|)"]]),
    pearson_r = safe_cor(sub[[outcome]], sub$shed_share_1_2am_primary, "pearson"),
    spearman_rho = safe_cor(sub[[outcome]], sub$shed_share_1_2am_primary, "spearman"),
    auc_any_shed = auc_rank(sub$any_shed_1_2am, sub[[outcome]]),
    r_squared = summary(fit)$r.squared,
    adj_r_squared = summary(fit)$adj.r.squared,
    rmse_pp = sqrt(mean(resid^2)) * 100,
    mae_pp = mean(abs(resid)) * 100,
    stringsAsFactors = FALSE
  )
}

message("Loading demand-gated pass nights.")
exclusion_dates <- load_exclusion_dates(EXCESS_LIT_FLAGS_FILE, EXCESS_LIT_SCENARIO)
gate <- read.csv(GATE_FILE, stringsAsFactors = FALSE) %>%
  mutate(
    date = as.Date(date),
    local_overpass_date = as.Date(local_overpass_date),
    shed_share_1_2am_primary = as.numeric(shed_share_1_2am_primary),
    any_shed_1_2am = as.integer(any_shed_1_2am),
    month = format(date, "%Y-%m"),
    month_fe = factor(month),
    dow_fe = factor(
      weekdays(date),
      levels = c("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
    )
  ) %>%
  filter(gate_tier == "pass", is.finite(shed_share_1_2am_primary), !date %in% exclusion_dates)

if (nrow(gate) == 0) stop("No demand-gated pass nights found.")

message("Loading settlement-day VJ panels.")
panel <- rbindlist(lapply(VJ_PANEL_FILES, function(p) {
  as.data.table(arrow::read_parquet(p))
}), use.names = TRUE, fill = TRUE) %>%
  mutate(
    settlement_id = as.character(settlement_id),
    date = as.Date(date),
    population = as.numeric(population),
    coverage = as.numeric(coverage),
    p_lit_sett = as.numeric(p_lit_sett)
  ) %>%
  filter(
    date %in% gate$date,
    is.finite(p_lit_sett),
    is.finite(coverage),
    coverage >= SETTLEMENT_COVERAGE_MIN,
    is.finite(population),
    population > POP_MIN
  ) %>%
  inner_join(
    gate %>%
      select(date, shed_share_1_2am_primary, any_shed_1_2am, gate_demand_share, month, month_fe, dow_fe),
    by = "date"
  )

if (nrow(panel) == 0) stop("No settlement-day rows remain after filtering.")

message("Selecting low-MLR baseline dates.")
low_dates_month <- gate %>%
  group_by(month) %>%
  arrange(shed_share_1_2am_primary, date, .by_group = TRUE) %>%
  mutate(low_mlr_month = row_number() <= max(1L, ceiling(n() * LOW_MLR_SHARE))) %>%
  ungroup() %>%
  select(date, low_mlr_month)

low_dates_annual <- gate %>%
  arrange(shed_share_1_2am_primary, date) %>%
  mutate(low_mlr_annual = row_number() <= max(1L, ceiling(n() * LOW_MLR_SHARE))) %>%
  select(date, low_mlr_annual)

panel <- panel %>%
  left_join(low_dates_month, by = "date") %>%
  left_join(low_dates_annual, by = "date")

message("Computing settlement baselines.")
baseline_month <- panel %>%
  filter(low_mlr_month) %>%
  group_by(settlement_id, month) %>%
  summarise(
    month_low_obs = n(),
    baseline_month_low = median(p_lit_sett, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    baseline_month_low = ifelse(month_low_obs >= MIN_MONTH_BASELINE_OBS, baseline_month_low, NA_real_)
  )

baseline_annual_low <- panel %>%
  filter(low_mlr_annual) %>%
  group_by(settlement_id) %>%
  summarise(
    annual_low_obs = n(),
    baseline_annual_low = median(p_lit_sett, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    baseline_annual_low = ifelse(annual_low_obs >= MIN_ANNUAL_LOW_BASELINE_OBS, baseline_annual_low, NA_real_)
  )

baseline_annual_all <- panel %>%
  group_by(settlement_id) %>%
  summarise(
    annual_all_obs = n(),
    baseline_annual_all = median(p_lit_sett, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    baseline_annual_all = ifelse(annual_all_obs >= MIN_ANNUAL_ALL_BASELINE_OBS, baseline_annual_all, NA_real_)
  )

panel <- panel %>%
  left_join(baseline_month, by = c("settlement_id", "month")) %>%
  left_join(baseline_annual_low, by = "settlement_id") %>%
  left_join(baseline_annual_all, by = "settlement_id") %>%
  mutate(
    baseline_p_lit = coalesce(baseline_month_low, baseline_annual_low, baseline_annual_all),
    baseline_source = case_when(
      is.finite(baseline_month_low) ~ "settlement_month_low_mlr",
      is.finite(baseline_annual_low) ~ "settlement_annual_low_mlr",
      is.finite(baseline_annual_all) ~ "settlement_annual_all_pass",
      TRUE ~ "missing"
    ),
    raw_continuous_darkness = 1 - p_lit_sett,
    signed_baseline_dimming = baseline_p_lit - p_lit_sett,
    down_only_baseline_dimming = pmax(signed_baseline_dimming, 0)
  ) %>%
  filter(is.finite(baseline_p_lit))

baseline_sources <- panel %>%
  distinct(settlement_id, baseline_source, population) %>%
  group_by(baseline_source) %>%
  summarise(
    settlements = n(),
    population = sum(population, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    settlement_share = settlements / sum(settlements),
    population_share = population / sum(population)
  )

message("Aggregating national dimming outcomes.")
daily <- panel %>%
  group_by(date) %>%
  summarise(
    observed_settlements = n_distinct(settlement_id),
    observed_population = safe_sum(population),
    raw_continuous_darkness = safe_weighted_mean(raw_continuous_darkness, population),
    signed_baseline_dimming = safe_weighted_mean(signed_baseline_dimming, population),
    down_only_baseline_dimming = safe_weighted_mean(down_only_baseline_dimming, population),
    baseline_mean_p_lit = safe_weighted_mean(baseline_p_lit, population),
    observed_mean_p_lit = safe_weighted_mean(p_lit_sett, population),
    share_population_negative_signed = safe_weighted_mean(as.numeric(signed_baseline_dimming < 0), population),
    share_population_positive_dimming = safe_weighted_mean(as.numeric(signed_baseline_dimming > 0), population),
    .groups = "drop"
  ) %>%
  right_join(gate, by = "date") %>%
  arrange(date) %>%
  mutate(
    observed_population_share_vs_max = observed_population / max(observed_population, na.rm = TRUE)
  )

outcome_labels <- c(
  popw_strict_dark_share = "Strict dark: p_lit < 0.05",
  popw_mostly_dark_share = "Mostly dark: p_lit < 0.20",
  raw_continuous_darkness = "Raw continuous darkness: 1 - p_lit",
  signed_baseline_dimming = "Signed baseline dimming",
  down_only_baseline_dimming = "Down-only baseline dimming"
)

outcomes <- names(outcome_labels)

message("Estimating validation regressions.")
metrics <- bind_rows(lapply(outcomes, function(outcome) {
  fit_nw(daily, outcome, model_label = "Baseline OLS + Newey-West")
})) %>%
  mutate(outcome_label = outcome_labels[outcome])

fe_specs <- data.frame(
  model_label = c("Baseline OLS + Newey-West", "Month FE", "Day-of-week FE", "Month + DOW FE"),
  controls = I(list(NULL, "month_fe", "dow_fe", c("month_fe", "dow_fe"))),
  stringsAsFactors = FALSE
)

fe_results <- bind_rows(lapply(seq_len(nrow(fe_specs)), function(i) {
  bind_rows(lapply(outcomes, function(outcome) {
    fit_nw(
      daily,
      outcome,
      controls = fe_specs$controls[[i]],
      model_label = fe_specs$model_label[[i]]
    )
  }))
})) %>%
  mutate(outcome_label = outcome_labels[outcome])

message("Computing extreme-quartile checks.")
quartile_base <- daily %>%
  filter(is.finite(shed_share_1_2am_primary)) %>%
  arrange(shed_share_1_2am_primary) %>%
  mutate(
    rank_id = row_number(),
    n_total = n(),
    quartile_group = case_when(
      rank_id <= floor(n_total * 0.25) ~ "Bottom quartile",
      rank_id > n_total - floor(n_total * 0.25) ~ "Top quartile",
      TRUE ~ "Middle"
    )
  ) %>%
  filter(quartile_group %in% c("Bottom quartile", "Top quartile"))

quartile_results <- bind_rows(lapply(outcomes, function(outcome) {
  d <- quartile_base %>%
    filter(is.finite(.data[[outcome]])) %>%
    group_by(quartile_group) %>%
    summarise(
      n = n(),
      mean_shed_share = mean(shed_share_1_2am_primary),
      mean_outcome = mean(.data[[outcome]]),
      se_outcome = stats::sd(.data[[outcome]]) / sqrt(n),
      .groups = "drop"
    )

  if (!all(c("Bottom quartile", "Top quartile") %in% d$quartile_group)) {
    return(data.frame(outcome = outcome, outcome_label = outcome_labels[[outcome]], stringsAsFactors = FALSE))
  }

  wide <- tidyr::pivot_wider(
    d,
    names_from = quartile_group,
    values_from = c(n, mean_shed_share, mean_outcome, se_outcome),
    names_glue = "{.value}_{quartile_group}"
  )

  diff <- wide$`mean_outcome_Top quartile` - wide$`mean_outcome_Bottom quartile`
  se_diff <- sqrt(wide$`se_outcome_Top quartile`^2 + wide$`se_outcome_Bottom quartile`^2)
  data.frame(
    outcome = outcome,
    outcome_label = outcome_labels[[outcome]],
    n_bottom = wide$`n_Bottom quartile`,
    n_top = wide$`n_Top quartile`,
    mean_shed_bottom = wide$`mean_shed_share_Bottom quartile`,
    mean_shed_top = wide$`mean_shed_share_Top quartile`,
    bottom_mean_pp = wide$`mean_outcome_Bottom quartile` * 100,
    top_mean_pp = wide$`mean_outcome_Top quartile` * 100,
    top_minus_bottom_pp = diff * 100,
    se_diff_pp = se_diff * 100,
    ci_low_pp = (diff - 1.96 * se_diff) * 100,
    ci_high_pp = (diff + 1.96 * se_diff) * 100,
    stringsAsFactors = FALSE
  )
}))

message("Computing dose-response bins.")
bin_df <- daily %>%
  filter(is.finite(shed_share_1_2am_primary)) %>%
  mutate(shed_decile = ntile(shed_share_1_2am_primary, 10)) %>%
  select(date, shed_decile, shed_share_1_2am_primary, all_of(outcomes)) %>%
  pivot_longer(all_of(outcomes), names_to = "outcome", values_to = "value") %>%
  mutate(outcome_label = outcome_labels[outcome]) %>%
  filter(is.finite(value)) %>%
  group_by(outcome, outcome_label, shed_decile) %>%
  summarise(
    n = n(),
    mean_shed = mean(shed_share_1_2am_primary),
    mean_value = mean(value),
    se_value = stats::sd(value) / sqrt(n),
    ci_low = mean_value - 1.96 * se_value,
    ci_high = mean_value + 1.96 * se_value,
    .groups = "drop"
  )

message("Writing tables.")
write.csv(daily, OUT_DAILY, row.names = FALSE)
write.csv(metrics, OUT_METRICS, row.names = FALSE)
write.csv(fe_results, OUT_FE, row.names = FALSE)
write.csv(quartile_results, OUT_QUARTILE, row.names = FALSE)
write.csv(bin_df, OUT_BIN, row.names = FALSE)
write.csv(baseline_sources, OUT_BASELINE, row.names = FALSE)

message("Writing figures.")
color_eskom <- "#1A1A1A"
color_down <- "#8B1A1A"
color_signed <- "#0072B2"
color_raw <- "#D55E00"

ts_df <- daily %>%
  filter(is.finite(shed_share_1_2am_primary), is.finite(down_only_baseline_dimming)) %>%
  mutate(
    shed_z = z_score(shed_share_1_2am_primary),
    dimming_z = z_score(down_only_baseline_dimming),
    quarter = factor(
      c("Jan-Mar", "Apr-Jun", "Jul-Sep", "Oct-Dec")[((as.integer(format(date, "%m")) - 1) %/% 3) + 1],
      levels = c("Jan-Mar", "Apr-Jun", "Jul-Sep", "Oct-Dec")
    )
  ) %>%
  select(date, quarter, shed_z, dimming_z) %>%
  pivot_longer(c(shed_z, dimming_z), names_to = "series", values_to = "value") %>%
  mutate(
    series = recode(series, shed_z = "Eskom MLR", dimming_z = "Down-only national dimming"),
    series = factor(series, levels = c("Eskom MLR", "Down-only national dimming"))
  ) %>%
  group_by(series, quarter) %>%
  arrange(date, .by_group = TRUE) %>%
  mutate(run_id = cumsum(c(TRUE, diff(date) > 1))) %>%
  ungroup()

p_time <- ggplot(ts_df, aes(x = date, y = value, color = series, group = interaction(series, quarter, run_id))) +
  geom_hline(yintercept = 0, color = "#CBD5E0", linewidth = 0.28) +
  geom_line(linewidth = 0.52, alpha = 0.78) +
  geom_point(size = 0.96, alpha = 0.68) +
  facet_wrap(~ quarter, ncol = 1, scales = "free_x") +
  scale_color_manual(values = c("Eskom MLR" = color_eskom, "Down-only national dimming" = color_down)) +
  scale_x_date(date_breaks = "1 month", date_labels = "%b") +
  labs(
    title = "Eskom MLR and national baseline-relative dimming move together",
    subtitle = "Demand-gated pass nights only; both series are standardized over matched days; no rolling mean.",
    x = NULL,
    y = "Standard deviations from series mean",
    color = NULL
  ) +
  theme_report(base_size = 9.4) +
  theme(strip.text = element_text(face = "bold", color = "#2D3748"))

ggsave(OUT_FIG_TIME, p_time, width = 9.5, height = 8.8, dpi = 240)

dose_plot <- bin_df %>%
  filter(outcome %in% c("raw_continuous_darkness", "signed_baseline_dimming", "down_only_baseline_dimming")) %>%
  mutate(
    outcome_label = factor(
      outcome_label,
      levels = c(
        "Raw continuous darkness: 1 - p_lit",
        "Signed baseline dimming",
        "Down-only baseline dimming"
      )
    )
  )

p_dose <- ggplot(dose_plot, aes(x = mean_shed, y = mean_value, color = outcome_label)) +
  geom_hline(yintercept = 0, color = "#4A5568", linewidth = 0.32) +
  geom_errorbar(aes(ymin = ci_low, ymax = ci_high), width = 0, linewidth = 0.50, alpha = 0.82) +
  geom_line(linewidth = 0.65, alpha = 0.84) +
  geom_point(size = 2.0, alpha = 0.92) +
  scale_x_continuous(labels = percent_format(accuracy = 1)) +
  scale_y_continuous(labels = percent_format(accuracy = 0.1)) +
  scale_color_manual(values = c(
    "Raw continuous darkness: 1 - p_lit" = color_raw,
    "Signed baseline dimming" = color_signed,
    "Down-only baseline dimming" = color_down
  )) +
  labs(
    title = "Continuous national dimming rises with Eskom MLR intensity",
    subtitle = "Matched pass nights are split into 10 equal-count bins by MLR shed share.",
    x = "Average Eskom MLR shed share within bin, 01:00-02:00 SAST",
    y = "Population-weighted national outcome",
    color = NULL
  ) +
  theme_report(base_size = 10.0)

ggsave(OUT_FIG_DOSE, p_dose, width = 9.2, height = 5.6, dpi = 240)

coef_plot <- metrics %>%
  mutate(
    outcome_label = factor(outcome_label, levels = outcome_labels[outcomes])
  )

p_coef <- ggplot(coef_plot, aes(x = effect_pp_per_10pp, y = outcome_label, color = outcome_label)) +
  geom_vline(xintercept = 0, color = "#4A5568", linewidth = 0.34) +
  geom_errorbar(aes(xmin = ci_low_pp, xmax = ci_high_pp), width = 0.15, linewidth = 0.68, orientation = "y") +
  geom_point(size = 2.4) +
  geom_text(aes(label = paste0(fmt_num(effect_pp_per_10pp, 2), " pp")), nudge_y = 0.18, size = 3.0, show.legend = FALSE) +
  scale_color_manual(values = c(
    "Strict dark: p_lit < 0.05" = "#B22222",
    "Mostly dark: p_lit < 0.20" = "#E69F00",
    "Raw continuous darkness: 1 - p_lit" = color_raw,
    "Signed baseline dimming" = color_signed,
    "Down-only baseline dimming" = color_down
  )) +
  labs(
    title = "Continuous dimming gives a national robustness metric",
    subtitle = paste0("OLS coefficients with Newey-West HAC standard errors, lag ", NW_LAG, "."),
    x = "Effect per 10 pp Eskom MLR, percentage points",
    y = NULL,
    color = NULL
  ) +
  theme_report(base_size = 10.0) +
  theme(legend.position = "none")

ggsave(OUT_FIG_COEF, p_coef, width = 9.2, height = 5.4, dpi = 240)

main_table <- metrics %>%
  transmute(
    outcome_label,
    n,
    pearson_r,
    r_squared,
    spearman_rho,
    auc_any_shed,
    effect_pp_per_10pp,
    se_nw_pp,
    ci_low_pp,
    ci_high_pp,
    p_value,
    rmse_pp,
    mae_pp
  )

summary_lines <- c(
  "# VJ146A2 National Continuous Dimming Validation",
  "",
  paste0("- Date: ", Sys.Date()),
  paste0("- Input gate file: `", GATE_FILE, "`"),
  paste0("- Output directory: `", OUT_DIR, "`"),
  paste0("- Demand-gated pass nights: ", nrow(gate), "."),
  paste0("- Settlement-night coverage threshold: ", percent(SETTLEMENT_COVERAGE_MIN, accuracy = 1), "."),
  paste0("- Low-MLR baseline share: bottom ", percent(LOW_MLR_SHARE, accuracy = 1), " of pass nights."),
  "",
  "## Baseline Source Coverage",
  "",
  "| Baseline source | Settlements | Settlement share | Population share |",
  "|---|---:|---:|---:|"
)

baseline_lines <- apply(baseline_sources, 1, function(r) {
  paste0(
    "| ", r[["baseline_source"]],
    " | ", format(as.numeric(r[["settlements"]]), big.mark = ","),
    " | ", percent(as.numeric(r[["settlement_share"]]), accuracy = 0.1),
    " | ", percent(as.numeric(r[["population_share"]]), accuracy = 0.1),
    " |"
  )
})

summary_lines <- c(
  summary_lines,
  baseline_lines,
  "",
  "## Headline Metrics",
  "",
  "| Outcome | N | Pearson r | R2 | Spearman rho | AUC any MLR | Effect per 10 pp MLR | NW SE | p | RMSE | MAE |",
  "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
)

metric_lines <- apply(main_table, 1, function(r) {
  paste0(
    "| ", r[["outcome_label"]],
    " | ", r[["n"]],
    " | ", fmt_num(r[["pearson_r"]], 3),
    " | ", fmt_num(r[["r_squared"]], 3),
    " | ", fmt_num(r[["spearman_rho"]], 3),
    " | ", fmt_num(r[["auc_any_shed"]], 3),
    " | ", fmt_num(r[["effect_pp_per_10pp"]], 2), " pp",
    " | ", fmt_num(r[["se_nw_pp"]], 2), " pp",
    " | ", fmt_p(r[["p_value"]]),
    " | ", fmt_num(r[["rmse_pp"]], 2), " pp",
    " | ", fmt_num(r[["mae_pp"]], 2), " pp",
    " |"
  )
})

preferred <- metrics %>% filter(outcome == "down_only_baseline_dimming") %>% slice(1)
signed <- metrics %>% filter(outcome == "signed_baseline_dimming") %>% slice(1)
raw <- metrics %>% filter(outcome == "raw_continuous_darkness") %>% slice(1)

summary_lines <- c(
  summary_lines,
  metric_lines,
  "",
  "## Interpretation",
  "",
  paste0(
    "The preferred down-only baseline-relative dimming metric has Pearson r = ",
    fmt_num(preferred$pearson_r, 3),
    ", R2 = ",
    fmt_num(preferred$r_squared, 3),
    ", and an effect of ",
    fmt_num(preferred$effect_pp_per_10pp, 2),
    " percentage points per 10 pp Eskom MLR with Newey-West SE ",
    fmt_num(preferred$se_nw_pp, 2),
    " pp."
  ),
  paste0(
    "The signed dimming metric has effect ",
    fmt_num(signed$effect_pp_per_10pp, 2),
    " pp and Pearson r = ",
    fmt_num(signed$pearson_r, 3),
    "; raw continuous darkness has effect ",
    fmt_num(raw$effect_pp_per_10pp, 2),
    " pp and Pearson r = ",
    fmt_num(raw$pearson_r, 3),
    "."
  ),
  "",
  "This script is intended for decision-making before adding continuous dimming to the main report. It does not replace the current binary headline specification.",
  "",
  "## Output Files",
  "",
  "- `vj146a2_2023_national_dimming_daily.csv`",
  "- `vj146a2_2023_national_dimming_validation_metrics.csv`",
  "- `vj146a2_2023_national_dimming_fe_robustness.csv`",
  "- `vj146a2_2023_national_dimming_extreme_quartile.csv`",
  "- `vj146a2_2023_national_dimming_dose_response_bins.csv`",
  "- `vj146a2_2023_national_dimming_baseline_sources.csv`",
  "- `vj146a2_national_dimming_timeseries.png`",
  "- `vj146a2_national_dimming_dose_response.png`",
  "- `vj146a2_national_dimming_coefficient_comparison.png`"
)

writeLines(summary_lines, OUT_SUMMARY)

message("Done.")
message("Summary: ", OUT_SUMMARY)
