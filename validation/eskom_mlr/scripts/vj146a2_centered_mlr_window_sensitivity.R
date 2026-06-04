#!/usr/bin/env Rscript

# Centered whole-hour Eskom MLR window sensitivity for the VJ146A2 validation.
#
# This is an exploratory companion to the recommended VJ/Eskom validation report.
# It does not modify the main report or any Reliability-Assessment pipeline output.
#
# Windows:
#   1. 01:00-02:00 preferred: the selected overpass-hour specification.
#   2. 23:00-03:00 centered 4h: nearest whole-hour 4-hour block around the
#      01:00-02:00 overpass hour. Uses hours 23, 0, 1, 2 relative to the
#      local overpass date.
#   3. 13:00-13:00 centered 24h: nearest whole-hour 24-hour block centered
#      on the same nighttime period. Uses hours 13 previous day through
#      12 on the local overpass date.
#
# Main MLR share regressor:
#   sum(Manual Load Reduction) / sum(RSA Contracted Demand)
#
# Eskom's glossary defines MLR as estimated demand reduced due to load shedding
# and/or curtailment, and RSA Contracted Demand as contracted demand rather than
# served demand. The selected-specification extract also contains a legacy
# sum-denominator ratio; this script keeps that value only to verify provenance
# of the stored column.
#
# Run from the repo root:
#   Rscript validation/eskom_mlr/scripts/vj146a2_centered_mlr_window_sensitivity.R

suppressPackageStartupMessages({
  library(data.table)
  library(dplyr)
  library(ggplot2)
  library(knitr)
  library(lmtest)
  library(patchwork)
  library(scales)
  library(sandwich)
  library(tidyr)
})

script_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
script_path <- if (length(script_arg) > 0) {
  normalizePath(sub("^--file=", "", script_arg[[1]]), mustWork = TRUE)
} else {
  normalizePath("validation/eskom_mlr/scripts/vj146a2_centered_mlr_window_sensitivity.R", mustWork = TRUE)
}
repo_dir <- normalizePath(file.path(dirname(script_path), "..", "..", ".."), mustWork = TRUE)
source(file.path(repo_dir, "validation", "scripts", "validation_paths.R"))
paths <- validation_paths(repo_dir, "eskom_mlr")

coverage_file <- file.path(paths$data_dir, "vj146a2_2023_demand_gate_coverage.csv")
flags_file <- file.path(paths$data_dir, "vj146a2_2023_annual_iqr_excess_lit_day_flags.csv")
eskom_file <- paths$eskom_hourly_csv

out_dir <- paths$data_dir
fig_dir <- file.path(paths$figures_dir, "vj146a2-centered-mlr-window-sensitivity")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

for (p in c(coverage_file, flags_file, eskom_file)) {
  if (!file.exists(p)) stop("Missing input file: ", p)
}

out_analysis <- file.path(out_dir, "vj146a2_2023_centered_mlr_window_analysis_daily.csv")
out_models <- file.path(out_dir, "vj146a2_2023_centered_mlr_window_model_summary.csv")
out_mean_mw <- file.path(out_dir, "vj146a2_2023_centered_mlr_window_mean_mw_summary.csv")
out_mwh <- file.path(out_dir, "vj146a2_2023_centered_mlr_window_full_day_mwh_summary.csv")
out_baseline_bins <- file.path(out_dir, "vj146a2_2023_centered_mlr_window_baseline_bins.csv")
out_window_defs <- file.path(out_dir, "vj146a2_2023_centered_mlr_window_definitions.csv")
out_sample_summary <- file.path(out_dir, "vj146a2_2023_centered_mlr_window_sample_summary.csv")

fig_effects <- file.path(fig_dir, "vj146a2_centered_window_effects.png")
fig_baseline <- file.path(fig_dir, "vj146a2_centered_window_baseline_relative.png")

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

fmt_num <- function(x, digits = 2) formatC(as.numeric(x), digits = digits, format = "f")

z_score <- function(x) {
  (x - mean(x, na.rm = TRUE)) / stats::sd(x, na.rm = TRUE)
}

safe_p <- function(x) {
  ifelse(
    is.na(x), NA_character_,
    ifelse(x < 0.001, formatC(x, digits = 2, format = "e"), fmt_num(x, 3))
  )
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

fit_hac_share <- function(data, outcome, exposure_label, nw_lag = 7L) {
  sub <- data %>%
    filter(
      exposure == exposure_label,
      is.finite(.data[[outcome]]),
      is.finite(shed_share)
    )

  fit <- lm(as.formula(paste(outcome, "~ shed_share")), data = sub)
  vc <- sandwich::NeweyWest(fit, lag = nw_lag, prewhite = FALSE, adjust = TRUE)
  ct <- lmtest::coeftest(fit, vcov. = vc)
  b <- unname(coef(fit)[["shed_share"]])
  se <- unname(ct["shed_share", "Std. Error"])
  ci <- b + c(-1, 1) * stats::qnorm(0.975) * se

  data.frame(
    exposure = exposure_label,
    outcome = outcome,
    n = stats::nobs(fit),
    nw_lag = nw_lag,
    mean_shed_share = mean(sub$shed_share, na.rm = TRUE),
    max_shed_share = max(sub$shed_share, na.rm = TRUE),
    mean_mlr_mwh = mean(sub$mlr_sum_mwh, na.rm = TRUE),
    effect_pp_per_10pp_share = b * 10,
    se_pp_per_10pp_share = se * 10,
    ci_low_pp_per_10pp_share = ci[[1]] * 10,
    ci_high_pp_per_10pp_share = ci[[2]] * 10,
    p_value = unname(ct["shed_share", "Pr(>|t|)"]),
    pearson_r = cor(sub[[outcome]], sub$shed_share, use = "complete.obs"),
    spearman_rho = suppressWarnings(cor(sub[[outcome]], sub$shed_share, use = "complete.obs", method = "spearman")),
    r_squared = summary(fit)$r.squared,
    auc_any_shed = auc_rank(sub$any_shed_1_2am, sub[[outcome]]),
    stringsAsFactors = FALSE
  )
}

fit_hac_mwh <- function(data, outcome, exposure_label = "13:00-13:00 centered 24h", nw_lag = 7L) {
  sub <- data %>%
    filter(
      exposure == exposure_label,
      is.finite(.data[[outcome]]),
      is.finite(mlr_sum_mwh)
    ) %>%
    mutate(mlr_sum_gwh = mlr_sum_mwh / 1000)

  fit <- lm(as.formula(paste(outcome, "~ mlr_sum_gwh")), data = sub)
  vc <- sandwich::NeweyWest(fit, lag = nw_lag, prewhite = FALSE, adjust = TRUE)
  ct <- lmtest::coeftest(fit, vcov. = vc)
  b <- unname(coef(fit)[["mlr_sum_gwh"]])
  se <- unname(ct["mlr_sum_gwh", "Std. Error"])

  data.frame(
    exposure = exposure_label,
    outcome = outcome,
    n = stats::nobs(fit),
    nw_lag = nw_lag,
    mean_daily_mlr_gwh = mean(sub$mlr_sum_gwh, na.rm = TRUE),
    max_daily_mlr_gwh = max(sub$mlr_sum_gwh, na.rm = TRUE),
    effect_pp_per_10_gwh = b * 1000,
    se_pp_per_10_gwh = se * 1000,
    p_value = unname(ct["mlr_sum_gwh", "Pr(>|t|)"]),
    pearson_r = cor(sub[[outcome]], sub$mlr_sum_gwh, use = "complete.obs"),
    spearman_rho = suppressWarnings(cor(sub[[outcome]], sub$mlr_sum_gwh, use = "complete.obs", method = "spearman")),
    r_squared = summary(fit)$r.squared,
    stringsAsFactors = FALSE
  )
}

fit_hac_mean_mw <- function(data, outcome, exposure_label, nw_lag = 7L) {
  sub <- data %>%
    filter(
      exposure == exposure_label,
      is.finite(.data[[outcome]]),
      is.finite(mlr_mean_mw)
    )

  fit <- lm(as.formula(paste(outcome, "~ mlr_mean_mw")), data = sub)
  vc <- sandwich::NeweyWest(fit, lag = nw_lag, prewhite = FALSE, adjust = TRUE)
  ct <- lmtest::coeftest(fit, vcov. = vc)
  b <- unname(coef(fit)[["mlr_mean_mw"]])
  se <- unname(ct["mlr_mean_mw", "Std. Error"])

  data.frame(
    exposure = exposure_label,
    outcome = outcome,
    n = stats::nobs(fit),
    nw_lag = nw_lag,
    mean_mlr_mw = mean(sub$mlr_mean_mw, na.rm = TRUE),
    max_mlr_mw = max(sub$mlr_mean_mw, na.rm = TRUE),
    effect_pp_per_1000mw = b * 100000,
    se_pp_per_1000mw = se * 100000,
    p_value = unname(ct["mlr_mean_mw", "Pr(>|t|)"]),
    pearson_r = cor(sub[[outcome]], sub$mlr_mean_mw, use = "complete.obs"),
    spearman_rho = suppressWarnings(cor(sub[[outcome]], sub$mlr_mean_mw, use = "complete.obs", method = "spearman")),
    r_squared = summary(fit)$r.squared,
    stringsAsFactors = FALSE
  )
}

make_exposure <- function(local_overpass_dates, window_label, offsets) {
  spec <- data.table(offset_hour = offsets)
  grid <- CJ(local_overpass_date = local_overpass_dates, row_id = seq_len(nrow(spec)), unique = TRUE)
  grid <- cbind(grid, spec[grid$row_id])
  grid[, eskom_date := local_overpass_date + (offset_hour %/% 24L)]
  grid[, hour := offset_hour %% 24L]

  x <- merge(
    grid,
    eskom[, .(eskom_date, hour, mlr_mw, contracted_mw)],
    by = c("eskom_date", "hour"),
    all.x = TRUE
  )

  x[, .(
    n_hours = sum(!is.na(mlr_mw)),
    mlr_mean_mw = mean(mlr_mw, na.rm = TRUE),
    mlr_sum_mwh = sum(mlr_mw, na.rm = TRUE),
    contracted_sum_mwh = sum(contracted_mw, na.rm = TRUE),
    shed_share = sum(mlr_mw, na.rm = TRUE) / sum(contracted_mw, na.rm = TRUE),
    legacy_shed_share = sum(mlr_mw, na.rm = TRUE) /
      (sum(mlr_mw, na.rm = TRUE) + sum(contracted_mw, na.rm = TRUE))
  ), by = local_overpass_date][, exposure := window_label][]
}

message("Reading selected VJ/Eskom demand-gate coverage file.")
coverage <- fread(coverage_file)
coverage[, date := as.Date(date)]
coverage[, local_overpass_date := as.Date(local_overpass_date)]

message("Reading annual-IQR excess-lit flags.")
flags <- fread(flags_file)
flags[, date := as.Date(date)]
excluded_dates <- flags[scenario == "annual_q3_plus_1p5_iqr" & remove == TRUE, date]

message("Reading Eskom hourly file with text-preserving parser.")
eskom <- data.table(read.csv(eskom_file, check.names = FALSE, stringsAsFactors = FALSE))
eskom[, datetime_text := as.character(`Date Time Hour Beginning`)]
eskom[, eskom_date := as.Date(substr(datetime_text, 1, 10))]
eskom[, hour := as.integer(substr(datetime_text, 12, 13))]
eskom[, mlr_mw := as.numeric(`Manual Load_Reduction(MLR)`)]
eskom[, contracted_mw := as.numeric(`RSA Contracted Demand`)]

if (any(is.na(eskom$eskom_date)) || any(is.na(eskom$hour))) {
  stop("Failed to parse Eskom local date/hour. Check Date Time Hour Beginning.")
}

analysis_base <- coverage[
  gate_tier == "pass" &
    !(date %in% excluded_dates) &
    is.finite(shed_share_1_2am_primary) &
    is.finite(popw_strict_dark_share) &
    is.finite(popw_mostly_dark_share)
]

window_definitions <- data.frame(
  exposure = c(
    "01:00-02:00 preferred",
    "23:00-03:00 centered 4h",
    "13:00-13:00 centered 24h"
  ),
  hours_relative_to_local_overpass_date = c(
    "1",
    "-1,0,1,2",
    "-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1,0,1,2,3,4,5,6,7,8,9,10,11,12"
  ),
  interpretation = c(
    "Selected overpass-hour exposure used in the recommended report.",
    "Whole-hour 4-hour sensitivity around the overpass hour, using 23:00 previous day through 02:00 on local_overpass_date.",
    "Whole-hour 24-hour sensitivity around the nighttime period, using 13:00 previous day through 12:00 on local_overpass_date."
  )
)
fwrite(window_definitions, out_window_defs)

message("Computing centered whole-hour exposure windows.")
exposures <- rbindlist(
  list(
    make_exposure(analysis_base$local_overpass_date, "01:00-02:00 preferred", 1L),
    make_exposure(analysis_base$local_overpass_date, "23:00-03:00 centered 4h", -1:2),
    make_exposure(analysis_base$local_overpass_date, "13:00-13:00 centered 24h", -11:12)
  ),
  use.names = TRUE
)

check <- merge(
  analysis_base[, .(local_overpass_date, stored = shed_share_1_2am_primary)],
  exposures[
    exposure == "01:00-02:00 preferred",
    .(local_overpass_date, corrected_shed_share = shed_share, legacy_shed_share)
  ],
  by = "local_overpass_date"
)
max_legacy_preferred_recompute_diff <- max(abs(check$stored - check$legacy_shed_share), na.rm = TRUE)
max_corrected_preferred_vs_stored_diff <- max(abs(check$stored - check$corrected_shed_share), na.rm = TRUE)
if (max_legacy_preferred_recompute_diff > 1e-10) {
  stop(
    "Legacy preferred exposure recomputation does not match stored selected column; max diff = ",
    max_legacy_preferred_recompute_diff
  )
}

analysis_daily <- merge(analysis_base, exposures, by = "local_overpass_date", allow.cartesian = TRUE) %>%
  mutate(
    exposure = factor(
      exposure,
      levels = c("01:00-02:00 preferred", "23:00-03:00 centered 4h", "13:00-13:00 centered 24h")
    )
  )

fwrite(analysis_daily, out_analysis)

sample_summary <- analysis_daily %>%
  group_by(exposure) %>%
  summarise(
    n_dates = n(),
    min_vj_product_date = min(date),
    max_vj_product_date = max(date),
    mean_hours_present = mean(n_hours),
    mean_shed_share = mean(shed_share, na.rm = TRUE),
    max_shed_share = max(shed_share, na.rm = TRUE),
    mean_mlr_mean_mw = mean(mlr_mean_mw, na.rm = TRUE),
    max_mlr_mean_mw = max(mlr_mean_mw, na.rm = TRUE),
    mean_mlr_mwh = mean(mlr_sum_mwh, na.rm = TRUE),
    mean_legacy_shed_share = mean(legacy_shed_share, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    annual_iqr_removed_dates = length(excluded_dates),
    max_legacy_preferred_recompute_diff = max_legacy_preferred_recompute_diff,
    max_corrected_preferred_vs_stored_diff = max_corrected_preferred_vs_stored_diff
  )
fwrite(sample_summary, out_sample_summary)

outcomes <- c(
  "popw_strict_dark_share",
  "popw_mostly_dark_share",
  "demandw_strict_dark_share",
  "demandw_mostly_dark_share",
  "demandw_down_only_z"
)

outcome_labels <- c(
  popw_strict_dark_share = "Popw strict dark",
  popw_mostly_dark_share = "Popw mostly dark",
  demandw_strict_dark_share = "Demandw strict dark",
  demandw_mostly_dark_share = "Demandw mostly dark",
  demandw_down_only_z = "Demandw down-only z"
)

message("Fitting HAC models.")
model_summary <- bind_rows(lapply(outcomes, function(outcome) {
  bind_rows(lapply(levels(analysis_daily$exposure), function(exposure_label) {
    fit_hac_share(analysis_daily, outcome, exposure_label)
  }))
})) %>%
  mutate(outcome_label = recode(outcome, !!!outcome_labels))
fwrite(model_summary, out_models)

mean_mw_summary <- bind_rows(lapply(outcomes, function(outcome) {
  bind_rows(lapply(levels(analysis_daily$exposure), function(exposure_label) {
    fit_hac_mean_mw(analysis_daily, outcome, exposure_label)
  }))
})) %>%
  mutate(outcome_label = recode(outcome, !!!outcome_labels))
fwrite(mean_mw_summary, out_mean_mw)

full_day_mwh_summary <- bind_rows(lapply(outcomes, function(outcome) {
  fit_hac_mwh(analysis_daily, outcome)
})) %>%
  mutate(outcome_label = recode(outcome, !!!outcome_labels))
fwrite(full_day_mwh_summary, out_mwh)

message("Building baseline-relative bins.")
baseline_bins <- bind_rows(lapply(levels(analysis_daily$exposure), function(exposure_label) {
  d <- analysis_daily %>%
    filter(exposure == exposure_label, is.finite(shed_share))

  baseline_df <- d %>%
    filter(shed_share == 0) %>%
    select(popw_strict_dark_share, popw_mostly_dark_share) %>%
    pivot_longer(everything(), names_to = "outcome", values_to = "dark_share") %>%
    mutate(outcome_label = recode(outcome, !!!outcome_labels)) %>%
    group_by(outcome, outcome_label) %>%
    summarise(
      baseline_n = n(),
      baseline_mean = mean(dark_share),
      baseline_se = stats::sd(dark_share) / sqrt(baseline_n),
      .groups = "drop"
    )

  positive_bin_df <- d %>%
    filter(shed_share > 0) %>%
    mutate(shed_bin = ntile(shed_share, 10)) %>%
    select(shed_bin, shed_share, popw_strict_dark_share, popw_mostly_dark_share) %>%
    pivot_longer(
      c(popw_strict_dark_share, popw_mostly_dark_share),
      names_to = "outcome",
      values_to = "dark_share"
    ) %>%
    mutate(outcome_label = recode(outcome, !!!outcome_labels)) %>%
    group_by(outcome, outcome_label, shed_bin) %>%
    summarise(
      n = n(),
      mean_shed = mean(shed_share),
      mean_dark = mean(dark_share),
      se_dark = stats::sd(dark_share) / sqrt(n),
      .groups = "drop"
    ) %>%
    left_join(baseline_df, by = c("outcome", "outcome_label")) %>%
    mutate(
      exposure = exposure_label,
      excess_pp = (mean_dark - baseline_mean) * 100,
      excess_se_pp = sqrt(se_dark^2 + baseline_se^2) * 100,
      ci_low_pp = excess_pp - 1.96 * excess_se_pp,
      ci_high_pp = excess_pp + 1.96 * excess_se_pp
    )

  baseline_points <- baseline_df %>%
    transmute(
      exposure = exposure_label,
      outcome,
      outcome_label,
      shed_bin = 0L,
      n = baseline_n,
      mean_shed = 0,
      mean_dark = baseline_mean,
      baseline_n,
      baseline_mean,
      baseline_se,
      excess_pp = 0,
      excess_se_pp = 0,
      ci_low_pp = 0,
      ci_high_pp = 0
    )

  bind_rows(
    baseline_points,
    positive_bin_df %>%
      select(
        exposure, outcome, outcome_label, shed_bin, n, mean_shed, mean_dark,
        baseline_n, baseline_mean, baseline_se, excess_pp, excess_se_pp,
        ci_low_pp, ci_high_pp
      )
  )
})) %>%
  mutate(
    exposure = factor(exposure, levels = levels(analysis_daily$exposure)),
    outcome_label = factor(outcome_label, levels = c("Popw mostly dark", "Popw strict dark"))
  )
fwrite(baseline_bins, out_baseline_bins)

message("Writing figures.")
color_eskom <- "#1A1A1A"
color_strict <- "#B22222"
color_mostly <- "#E69F00"

effect_plot_df <- model_summary %>%
  filter(outcome %in% c("popw_strict_dark_share", "popw_mostly_dark_share", "demandw_strict_dark_share", "demandw_mostly_dark_share")) %>%
  mutate(
    outcome_label = factor(
      outcome_label,
      levels = c("Popw strict dark", "Popw mostly dark", "Demandw strict dark", "Demandw mostly dark")
    ),
    exposure = factor(exposure, levels = levels(analysis_daily$exposure))
  )

p_effect <- ggplot(effect_plot_df, aes(x = effect_pp_per_10pp_share, y = outcome_label, color = exposure)) +
  geom_errorbar(
    aes(xmin = ci_low_pp_per_10pp_share, xmax = ci_high_pp_per_10pp_share),
    width = 0.16,
    linewidth = 0.55,
    orientation = "y",
    position = position_dodge(width = 0.62)
  ) +
  geom_point(size = 2.4, position = position_dodge(width = 0.62)) +
  scale_color_manual(values = c(
    "01:00-02:00 preferred" = "#1A1A1A",
    "23:00-03:00 centered 4h" = "#B22222",
    "13:00-13:00 centered 24h" = "#2B6CB0"
  )) +
  labs(
    title = "Centered Eskom MLR windows preserve the VJ darkness signal",
    subtitle = "OLS slopes use Newey-West HAC standard errors with 7-day lag; same 267 standard validation days.",
    x = "Effect per 10 pp Eskom MLR / RSA contracted demand (percentage points)",
    y = NULL,
    color = NULL
  ) +
  theme_report(base_size = 10.2)

ggsave(fig_effects, p_effect, width = 8.2, height = 4.9, dpi = 320)
ggsave(sub("\\.png$", ".pdf", fig_effects), p_effect, width = 8.2, height = 4.9)

p_baseline <- ggplot(
  baseline_bins %>% filter(outcome %in% c("popw_strict_dark_share", "popw_mostly_dark_share")),
  aes(x = mean_shed, y = excess_pp, color = outcome_label)
) +
  geom_hline(yintercept = 0, color = "#4A5568", linewidth = 0.35) +
  geom_errorbar(aes(ymin = ci_low_pp, ymax = ci_high_pp), width = 0, linewidth = 0.45, alpha = 0.82) +
  geom_line(linewidth = 0.65, alpha = 0.82) +
  geom_point(aes(size = n), alpha = 0.94) +
  facet_wrap(~ exposure, ncol = 1) +
  scale_x_continuous(labels = percent_format(accuracy = 1)) +
  scale_y_continuous(labels = function(x) paste0(fmt_num(x, 1), " pp")) +
  scale_color_manual(values = c("Popw strict dark" = color_strict, "Popw mostly dark" = color_mostly)) +
  scale_size_continuous(range = c(1.8, 3.8), guide = "none") +
  labs(
    title = "MLR windows show a similar baseline-relative darkness gradient",
    subtitle = "Zero is the mean of no-MLR standard validation nights inside each window; positive-MLR nights are split into ten equal-count bins.",
    x = "Average Eskom MLR / RSA contracted demand within bin",
    y = "Increase in dark population share vs no-MLR nights",
    color = NULL
  ) +
  theme_report(base_size = 9.5) +
  theme(strip.text = element_text(face = "bold", color = "#2D3748"))

ggsave(fig_baseline, p_baseline, width = 8.2, height = 8.9, dpi = 320)
ggsave(sub("\\.png$", ".pdf", fig_baseline), p_baseline, width = 8.2, height = 8.9)

make_timing_plot <- function(exposure_label) {
  d <- analysis_daily %>%
    filter(
      exposure == exposure_label,
      is.finite(shed_share),
      is.finite(popw_strict_dark_share)
    ) %>%
    arrange(date)

  stats_row <- model_summary %>%
    filter(exposure == exposure_label, outcome == "popw_strict_dark_share") %>%
    slice(1)

  ts_df <- d %>%
    mutate(
      shed_z = z_score(shed_share),
      strict_z = z_score(popw_strict_dark_share),
      q_num = ((as.integer(format(date, "%m")) - 1) %/% 3) + 1,
      quarter = factor(
        c("Jan-Mar", "Apr-Jun", "Jul-Sep", "Oct-Dec")[q_num],
        levels = c("Jan-Mar", "Apr-Jun", "Jul-Sep", "Oct-Dec")
      )
    ) %>%
    select(date, quarter, shed_z, strict_z) %>%
    pivot_longer(c(shed_z, strict_z), names_to = "series", values_to = "value") %>%
    mutate(
      series = recode(series, shed_z = "Eskom MLR", strict_z = "VJ strict darkness"),
      series = factor(series, levels = c("Eskom MLR", "VJ strict darkness"))
    ) %>%
    group_by(series, quarter) %>%
    arrange(date, .by_group = TRUE) %>%
    mutate(run_id = cumsum(c(TRUE, diff(date) > 1))) %>%
    ungroup()

  all_dates <- data.frame(date = seq(as.Date("2023-01-01"), as.Date("2023-12-31"), by = "day")) %>%
    mutate(
      in_validation_sample = date %in% d$date,
      q_num = ((as.integer(format(date, "%m")) - 1) %/% 3) + 1,
      quarter = factor(
        c("Jan-Mar", "Apr-Jun", "Jul-Sep", "Oct-Dec")[q_num],
        levels = c("Jan-Mar", "Apr-Jun", "Jul-Sep", "Oct-Dec")
      ),
      xmin = date - 0.45,
      xmax = date + 0.45
    )

  missing_dates <- all_dates %>% filter(!in_validation_sample)
  y_floor <- -2.18
  y_strip_top <- -1.88
  y_top <- max(3.2, ceiling(max(ts_df$value, na.rm = TRUE) * 10) / 10 + 0.12)

  ggplot(ts_df, aes(x = date, y = value, color = series, group = interaction(series, quarter, run_id))) +
    geom_rect(
      data = missing_dates,
      aes(xmin = xmin, xmax = xmax, ymin = y_floor, ymax = y_strip_top),
      inherit.aes = FALSE,
      fill = "#A0AEC0",
      alpha = 0.24
    ) +
    geom_hline(yintercept = 0, color = "#CBD5E0", linewidth = 0.28) +
    geom_line(linewidth = 0.50, alpha = 0.78) +
    geom_point(alpha = 0.70, size = 0.98) +
    facet_wrap(~ quarter, ncol = 1, scales = "free_x") +
    scale_color_manual(values = c("Eskom MLR" = color_eskom, "VJ strict darkness" = color_strict)) +
    scale_x_date(date_breaks = "1 month", date_labels = "%b") +
    scale_y_continuous(limits = c(y_floor, y_top), breaks = -2:floor(y_top)) +
    labs(
      title = paste0("Daily Eskom MLR and VJ strict darkness: ", exposure_label),
      subtitle = paste0(
        "Sample: ", nrow(d), " standard validation days; both series standardized over the same days.\n",
        "Gray ticks show excluded dates. r = ", fmt_num(stats_row$pearson_r, 3),
        ", R2 = ", fmt_num(stats_row$r_squared, 3), "."
      ),
      x = NULL,
      y = "Standard deviations from\nseries mean",
      color = NULL
    ) +
    theme_report(base_size = 9.4) +
    theme(
      legend.position = "bottom",
      strip.text = element_text(face = "bold", color = "#2D3748"),
      panel.spacing = unit(0.8, "lines"),
      plot.margin = margin(5.5, 5.5, 18, 5.5)
    )
}

timing_files <- c(
  "01:00-02:00 preferred" = file.path(fig_dir, "vj146a2_centered_window_timing_preferred_01_02.png"),
  "23:00-03:00 centered 4h" = file.path(fig_dir, "vj146a2_centered_window_timing_centered_4h.png"),
  "13:00-13:00 centered 24h" = file.path(fig_dir, "vj146a2_centered_window_timing_centered_24h.png")
)

for (label in names(timing_files)) {
  p_time <- make_timing_plot(label)
  ggsave(timing_files[[label]], p_time, width = 8.2, height = 9.2, dpi = 320)
  ggsave(sub("\\.png$", ".pdf", timing_files[[label]]), p_time, width = 8.2, height = 9.2)
}

message("Wrote:")
message("  ", out_analysis)
message("  ", out_models)
message("  ", out_mean_mw)
message("  ", out_mwh)
message("  ", out_baseline_bins)
message("  ", fig_dir)
