#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(data.table)
  library(dplyr)
  library(ggplot2)
  library(lmtest)
  library(sandwich)
  library(scales)
})

script_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
script_path <- if (length(script_arg) > 0) {
  normalizePath(sub("^--file=", "", script_arg[[1]]), mustWork = TRUE)
} else {
  normalizePath("validation/eskom_mlr/scripts/vj146a2_stage_binned_mlr_validation.R", mustWork = TRUE)
}
repo_dir <- normalizePath(file.path(dirname(script_path), "..", "..", ".."), mustWork = TRUE)
source(file.path(repo_dir, "validation", "scripts", "validation_paths.R"))
paths <- validation_paths(repo_dir, "eskom_mlr")

coverage_file <- file.path(paths$data_dir, "vj146a2_2023_demand_gate_coverage.csv")
flags_file <- file.path(paths$data_dir, "vj146a2_2023_annual_iqr_excess_lit_day_flags.csv")
out_dir <- paths$data_dir
fig_dir <- file.path(paths$figures_dir, "vj146a2-stage-binned-validation")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(coverage_file)) stop("Missing coverage file: ", coverage_file)
if (!file.exists(flags_file)) stop("Missing annual-IQR flags file: ", flags_file)

expected_stage_user_off <- data.table(
  implied_stage = 0:8,
  stage_label = paste0("Stage ", 0:8),
  expected_users_without_power_share = c(0, 0.06, 0.125, 0.19, 0.25, 0.31, 0.37, 0.44, 0.50)
)

fit_nw <- function(data, outcome, rhs, term_filter = NULL, nw_lag = 7L, scale = 100) {
  sub <- data[is.finite(get(outcome))]
  fit <- stats::lm(stats::as.formula(paste(outcome, "~", rhs)), data = sub)
  vc <- sandwich::NeweyWest(fit, lag = nw_lag, prewhite = FALSE, adjust = TRUE)
  ct <- lmtest::coeftest(fit, vcov. = vc)
  out <- data.table(
    term = rownames(ct),
    estimate = ct[, 1],
    std_error = ct[, 2],
    statistic = ct[, 3],
    p_value = ct[, 4]
  )
  if (!is.null(term_filter)) out <- out[grepl(term_filter, term)]
  out[, `:=`(
    outcome = outcome,
    rhs = rhs,
    n = stats::nobs(fit),
    r_squared = summary(fit)$r.squared,
    estimate_scaled = estimate * scale,
    std_error_scaled = std_error * scale,
    ci_low_scaled = (estimate - 1.96 * std_error) * scale,
    ci_high_scaled = (estimate + 1.96 * std_error) * scale
  )]
  out[]
}

coverage <- fread(coverage_file)
coverage[, date := as.Date(date)]
coverage[, dow := weekdays(date)]

flags <- fread(flags_file)
flags[, date := as.Date(date)]
excluded_dates <- flags[scenario == "annual_q3_plus_1p5_iqr" & remove == TRUE, date]

analysis <- coverage[
  gate_tier == "pass" &
    !(date %in% excluded_dates) &
    is.finite(shed_share_1_2am_primary) &
    is.finite(mlr_mean_1_2am_primary)
]
analysis[, implied_stage := fifelse(
  mlr_mean_1_2am_primary <= 0,
  0L,
  pmin(8L, as.integer(ceiling(mlr_mean_1_2am_primary / 1000)))
)]
analysis[, stage_label := paste0("Stage ", implied_stage)]
analysis[, stage_factor := stats::relevel(factor(stage_label), ref = "Stage 0")]

stage_summary <- analysis[
  ,
  .(
    n = .N,
    min_mlr_mw = min(mlr_mean_1_2am_primary, na.rm = TRUE),
    mean_mlr_mw = mean(mlr_mean_1_2am_primary, na.rm = TRUE),
    max_mlr_mw = max(mlr_mean_1_2am_primary, na.rm = TRUE),
    mean_mlr_share = mean(shed_share_1_2am_primary, na.rm = TRUE),
    popw_strict_dark_share = mean(popw_strict_dark_share, na.rm = TRUE),
    popw_mostly_dark_share = mean(popw_mostly_dark_share, na.rm = TRUE),
    demandw_strict_dark_share = mean(demandw_strict_dark_share, na.rm = TRUE),
    demandw_mostly_dark_share = mean(demandw_mostly_dark_share, na.rm = TRUE),
    demandw_down_only_z = mean(demandw_down_only_z, na.rm = TRUE),
    se_popw_strict_dark_share = stats::sd(popw_strict_dark_share, na.rm = TRUE) / sqrt(.N),
    se_popw_mostly_dark_share = stats::sd(popw_mostly_dark_share, na.rm = TRUE) / sqrt(.N),
    se_demandw_down_only_z = stats::sd(demandw_down_only_z, na.rm = TRUE) / sqrt(.N)
  ),
  by = .(implied_stage, stage_label)
]
stage_summary <- merge(stage_summary, expected_stage_user_off, by = c("implied_stage", "stage_label"), all.x = TRUE)
stage_summary[, `:=`(
  strict_capture_ratio_vs_expected = fifelse(
    expected_users_without_power_share > 0,
    popw_strict_dark_share / expected_users_without_power_share,
    NA_real_
  ),
  mostly_capture_ratio_vs_expected = fifelse(
    expected_users_without_power_share > 0,
    popw_mostly_dark_share / expected_users_without_power_share,
    NA_real_
  )
)]
setorder(stage_summary, implied_stage)

outcomes <- c(
  "popw_strict_dark_share",
  "popw_mostly_dark_share",
  "demandw_strict_dark_share",
  "demandw_mostly_dark_share",
  "demandw_down_only_z"
)

categorical_results <- rbindlist(lapply(outcomes, function(outcome) {
  scale <- if (outcome == "demandw_down_only_z") 1 else 100
  fit_nw(analysis, outcome, "stage_factor", term_filter = "^stage_factor", scale = scale)
}), fill = TRUE)
categorical_results[, stage_label := sub("^stage_factor", "", term)]
categorical_results[, stage_label := gsub("`", "", stage_label, fixed = TRUE)]

ordinal_results <- rbindlist(lapply(outcomes, function(outcome) {
  scale <- if (outcome == "demandw_down_only_z") 1 else 100
  fit_nw(analysis, outcome, "implied_stage", term_filter = "^implied_stage$", scale = scale)
}), fill = TRUE)

ordinal_fe_results <- rbindlist(lapply(outcomes, function(outcome) {
  scale <- if (outcome == "demandw_down_only_z") 1 else 100
  fit_nw(
    analysis,
    outcome,
    "implied_stage + factor(month) + factor(dow)",
    term_filter = "^implied_stage$",
    scale = scale
  )
}), fill = TRUE)
ordinal_fe_results[, rhs := "implied_stage + month FE + day-of-week FE"]

correlations <- rbindlist(lapply(outcomes, function(outcome) {
  data.table(
    outcome = outcome,
    n = sum(is.finite(analysis[[outcome]])),
    pearson_r = stats::cor(analysis$implied_stage, analysis[[outcome]], use = "complete.obs", method = "pearson"),
    spearman_r = stats::cor(analysis$implied_stage, analysis[[outcome]], use = "complete.obs", method = "spearman")
  )
}))

fwrite(stage_summary, file.path(out_dir, "vj146a2_2023_stage_binned_mlr_stage_summary.csv"), na = "")
fwrite(categorical_results, file.path(out_dir, "vj146a2_2023_stage_binned_mlr_categorical_regression.csv"), na = "")
fwrite(ordinal_results, file.path(out_dir, "vj146a2_2023_stage_binned_mlr_ordinal_regression.csv"), na = "")
fwrite(ordinal_fe_results, file.path(out_dir, "vj146a2_2023_stage_binned_mlr_ordinal_fe_regression.csv"), na = "")
fwrite(correlations, file.path(out_dir, "vj146a2_2023_stage_binned_mlr_correlations.csv"), na = "")

plot_df <- stage_summary |>
  transmute(
    implied_stage,
    stage_label = factor(stage_label, levels = paste0("Stage ", sort(unique(implied_stage)))),
    `Strict dark` = popw_strict_dark_share,
    `Mostly dark` = popw_mostly_dark_share,
    `Down-only dimming z` = demandw_down_only_z,
    `Expected users without power` = expected_users_without_power_share
  ) |>
  tidyr::pivot_longer(
    cols = c("Strict dark", "Mostly dark", "Expected users without power"),
    names_to = "metric",
    values_to = "share"
  )

p_stage <- ggplot(plot_df, aes(x = stage_label, y = share, group = metric, color = metric)) +
  geom_line(linewidth = 0.65) +
  geom_point(size = 2.1) +
  geom_text(
    data = stage_summary,
    aes(x = factor(stage_label, levels = paste0("Stage ", sort(unique(implied_stage)))), y = -0.015, label = paste0("n=", n)),
    inherit.aes = FALSE,
    size = 3,
    color = "grey35"
  ) +
  scale_y_continuous(labels = scales::label_percent(accuracy = 1), limits = c(-0.025, NA)) +
  scale_color_manual(values = c(
    "Expected users without power" = "#2D3748",
    "Strict dark" = "#C0392B",
    "Mostly dark" = "#E67E22"
  )) +
  labs(
    title = "VJ146A2 darkness rises with implied Eskom load-shedding stage",
    subtitle = "Standard validation nights: demand gate pass, annual-IQR excess-lit dates removed",
    x = "Implied stage from 01:00-02:00 Eskom MLR MW",
    y = "Share",
    color = NULL,
    caption = "Implied stage = ceiling(MLR MW / 1000), with zero MLR as Stage 0. Expected user-off shares use the Wikipedia stage table."
  ) +
  theme_minimal(base_size = 10.5) +
  theme(
    panel.grid.minor = element_blank(),
    legend.position = "bottom",
    plot.title.position = "plot"
  )

ggsave(
  file.path(fig_dir, "vj146a2_stage_binned_mlr_darkness_vs_stage.png"),
  p_stage,
  width = 7.4,
  height = 4.8,
  units = "in",
  dpi = 320
)
ggsave(
  file.path(fig_dir, "vj146a2_stage_binned_mlr_darkness_vs_stage.pdf"),
  p_stage,
  width = 7.4,
  height = 4.8,
  units = "in"
)

message("Wrote stage-binned MLR validation outputs.")
