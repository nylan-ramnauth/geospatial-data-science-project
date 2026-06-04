rm(list = ls())

# ============================================================
# 2023 VJ146A2 Eskom MLR autocorrelation robustness checks
# ============================================================
#
# Companion script for the recommended demand-gated validation.
# This script does not modify the current validation script or report.
#
# Goal:
#   Evaluate six alternatives/complements to plain OLS inference when the
#   validation panel is a daily time series:
#     1. Newey-West HAC lag sensitivity
#     2. Moving-block bootstrap
#     3. AR(1) error model
#     4. Lagged-outcome model
#     5. First-difference model
#     6. Block-permutation and circular-shift placebo tests
#
# Run:
#   Rscript Builder/vj146a2_2023_autocorr_robustness_mlr_validation.R
#
# Main inputs:
#   Map Data/settlement_day_outputs_vj146a2/mlr_validation_demand_gate_2023_cov50/
#     vj146a2_2023_demand_gate_coverage.csv
#
# Main outputs:
#   Map Data/settlement_day_outputs_vj146a2/mlr_validation_autocorr_robustness_2023_cov50/
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(broom)
  library(lmtest)
  library(sandwich)
  library(nlme)
})

BASE_PATH <- here::here()

IN_DIR <- file.path(
  BASE_PATH,
  "Map Data",
  "settlement_day_outputs_vj146a2",
  Sys.getenv("VJ146A2_AUTOCORR_INPUT_SUBDIR", "mlr_validation_demand_gate_2023_cov50")
)

OUT_DIR <- file.path(
  BASE_PATH,
  "Map Data",
  "settlement_day_outputs_vj146a2",
  Sys.getenv("VJ146A2_AUTOCORR_OUT_SUBDIR", "mlr_validation_autocorr_robustness_2023_cov50")
)

COVERAGE_FILE <- file.path(IN_DIR, "vj146a2_2023_demand_gate_coverage.csv")

OUT_MAIN <- file.path(OUT_DIR, "vj146a2_2023_autocorr_robustness_summary.csv")
OUT_HAC <- file.path(OUT_DIR, "vj146a2_2023_hac_lag_sensitivity.csv")
OUT_BOOT <- file.path(OUT_DIR, "vj146a2_2023_moving_block_bootstrap.csv")
OUT_AR1 <- file.path(OUT_DIR, "vj146a2_2023_ar1_error_models.csv")
OUT_LAGGED <- file.path(OUT_DIR, "vj146a2_2023_lagged_outcome_models.csv")
OUT_DIFF <- file.path(OUT_DIR, "vj146a2_2023_first_difference_models.csv")
OUT_BLOCK_PLACEBO <- file.path(OUT_DIR, "vj146a2_2023_block_permutation_placebo.csv")
OUT_CIRCULAR_PLACEBO <- file.path(OUT_DIR, "vj146a2_2023_circular_shift_placebo.csv")
OUT_MLR_ACF <- file.path(OUT_DIR, "vj146a2_2023_mlr_autocorrelation.csv")
OUT_MD <- file.path(OUT_DIR, "vj146a2_2023_autocorr_robustness_summary.md")

OUT_EFFECTS_PNG <- file.path(OUT_DIR, "vj146a2_autocorr_robustness_effects.png")
OUT_HAC_PNG <- file.path(OUT_DIR, "vj146a2_hac_lag_sensitivity.png")
OUT_BOOT_PNG <- file.path(OUT_DIR, "vj146a2_moving_block_bootstrap_distribution.png")

if (!file.exists(COVERAGE_FILE)) stop("Input not found: ", COVERAGE_FILE)
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

EXCESS_LIT_FLAGS_FILE <- Sys.getenv("VJ146A2_EXCESS_LIT_FLAGS_FILE", "")
EXCESS_LIT_SCENARIO <- Sys.getenv("VJ146A2_EXCESS_LIT_SCENARIO", "annual_q3_plus_1p5_iqr")
PREDICTOR <- "shed_share_1_2am_primary"
OUTCOMES <- c("popw_strict_dark_share", "popw_mostly_dark_share")
OUTCOME_LABELS <- c(
  popw_strict_dark_share = "Strict dark: p_lit < 0.05",
  popw_mostly_dark_share = "Mostly dark: p_lit < 0.20"
)

load_exclusion_dates <- function(path, scenario) {
  if (!nzchar(path)) return(as.Date(character()))
  if (!file.exists(path)) stop("Excess-lit flag file not found: ", path)
  read.csv(path, stringsAsFactors = FALSE) %>%
    mutate(date = as.Date(date)) %>%
    filter(scenario == !!scenario, remove) %>%
    pull(date)
}

outcome_label <- function(outcome_name) {
  unname(OUTCOME_LABELS[[outcome_name]])
}

NW_LAGS <- as.integer(strsplit(Sys.getenv("VJ146A2_AUTOCORR_NW_LAGS", "0,1,3,5,7,14,21,30"), ",")[[1]])
MAIN_NW_LAG <- as.integer(Sys.getenv("VJ146A2_AUTOCORR_MAIN_NW_LAG", "7"))
BOOT_B <- as.integer(Sys.getenv("VJ146A2_AUTOCORR_BOOT_B", "2000"))
BOOT_BLOCK_SIZE <- as.integer(Sys.getenv("VJ146A2_AUTOCORR_BOOT_BLOCK_SIZE", "14"))
PLACEBO_B <- as.integer(Sys.getenv("VJ146A2_AUTOCORR_PLACEBO_B", "2000"))
PLACEBO_BLOCK_SIZE <- as.integer(Sys.getenv("VJ146A2_AUTOCORR_PLACEBO_BLOCK_SIZE", "14"))
SEED <- as.integer(Sys.getenv("VJ146A2_AUTOCORR_SEED", "20260603"))

set.seed(SEED)

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

fmt_p <- function(p) {
  ifelse(
    is.na(p), "NA",
    ifelse(p < 0.01, "<0.01", ifelse(p < 0.05, "<0.05", fmt_num(p, 3)))
  )
}

effect_scale <- function(x) x * 10

safe_cor <- function(x, y) {
  ok <- is.finite(x) & is.finite(y)
  if (sum(ok) < 3 || length(unique(x[ok])) < 2 || length(unique(y[ok])) < 2) return(NA_real_)
  cor(x[ok], y[ok])
}

safe_acf <- function(x, lag) {
  x <- as.numeric(x)
  if (length(x) <= lag + 2 || stats::sd(x, na.rm = TRUE) == 0) return(NA_real_)
  as.numeric(stats::acf(x, lag.max = lag, plot = FALSE, na.action = na.pass)$acf[lag + 1])
}

make_panel <- function(data, outcome) {
  data %>%
    transmute(
      local_overpass_date = as.Date(local_overpass_date),
      month = as.Date(paste0(format(as.Date(local_overpass_date), "%Y-%m"), "-01")),
      outcome = .data[[outcome]],
      shed_share = .data[[PREDICTOR]]
    ) %>%
    filter(is.finite(outcome), is.finite(shed_share)) %>%
    arrange(local_overpass_date) %>%
    mutate(
      day_num = as.numeric(local_overpass_date - min(local_overpass_date, na.rm = TRUE)),
      row_id = row_number()
    )
}

lm_hac_result <- function(panel, method_label, nw_lag = MAIN_NW_LAG, formula = outcome ~ shed_share) {
  fit <- lm(formula, data = panel)
  vc <- sandwich::NeweyWest(fit, lag = nw_lag, prewhite = FALSE, adjust = TRUE)
  ct <- lmtest::coeftest(fit, vcov. = vc)
  coef_name <- "shed_share"
  est <- unname(stats::coef(fit)[coef_name])
  se <- unname(ct[coef_name, "Std. Error"])
  p <- unname(ct[coef_name, "Pr(>|t|)"])
  ci <- est + c(-1, 1) * stats::qnorm(0.975) * se

  data.frame(
    method = method_label,
    n = stats::nobs(fit),
    effect_pp_per_10pp = effect_scale(est),
    se_pp_per_10pp = effect_scale(se),
    ci_low_pp_per_10pp = effect_scale(ci[1]),
    ci_high_pp_per_10pp = effect_scale(ci[2]),
    p_value = p,
    r_squared = summary(fit)$r.squared,
    adj_r_squared = summary(fit)$adj.r.squared,
    notes = paste0("OLS coefficient; Newey-West HAC lag ", nw_lag, "."),
    stringsAsFactors = FALSE
  )
}

make_moving_block_indices <- function(n, block_size) {
  starts <- sample.int(n, size = ceiling(n / block_size), replace = TRUE)
  idx <- unlist(lapply(starts, function(s) ((s - 1L + seq_len(block_size) - 1L) %% n) + 1L))
  idx[seq_len(n)]
}

block_bootstrap_result <- function(panel, block_size = BOOT_BLOCK_SIZE, b = BOOT_B) {
  n <- nrow(panel)
  beta <- numeric(b)
  for (i in seq_len(b)) {
    idx <- make_moving_block_indices(n, block_size)
    boot_fit <- lm(outcome ~ shed_share, data = panel[idx, , drop = FALSE])
    beta[[i]] <- unname(coef(boot_fit)["shed_share"])
  }

  fit <- lm(outcome ~ shed_share, data = panel)
  est <- unname(coef(fit)["shed_share"])
  se <- stats::sd(beta, na.rm = TRUE)
  ci <- stats::quantile(beta, probs = c(0.025, 0.975), na.rm = TRUE, names = FALSE)
  p <- 2 * min(
    (1 + sum(beta <= 0, na.rm = TRUE)) / (length(beta) + 1),
    (1 + sum(beta >= 0, na.rm = TRUE)) / (length(beta) + 1)
  )
  p <- min(max(p, 0), 1)

  list(
    summary = data.frame(
      method = "Moving-block bootstrap",
      n = n,
      block_size = block_size,
      replications = b,
      effect_pp_per_10pp = effect_scale(est),
      se_pp_per_10pp = effect_scale(se),
      ci_low_pp_per_10pp = effect_scale(ci[1]),
      ci_high_pp_per_10pp = effect_scale(ci[2]),
      p_value = p,
      notes = paste0("Circular moving-block bootstrap, block size ", block_size, ", B=", b, "."),
      stringsAsFactors = FALSE
    ),
    draws = beta
  )
}

ar1_error_result <- function(panel) {
  fit <- tryCatch(
    nlme::gls(
      outcome ~ shed_share,
      data = panel,
      correlation = nlme::corCAR1(form = ~ day_num),
      method = "ML",
      control = nlme::glsControl(msMaxIter = 200, returnObject = TRUE)
    ),
    error = function(e) e
  )

  if (inherits(fit, "error")) {
    return(data.frame(
      method = "AR(1) error model",
      n = nrow(panel),
      effect_pp_per_10pp = NA_real_,
      se_pp_per_10pp = NA_real_,
      ci_low_pp_per_10pp = NA_real_,
      ci_high_pp_per_10pp = NA_real_,
      p_value = NA_real_,
      ar1_phi_per_day = NA_real_,
      notes = paste0("nlme::gls corCAR1 failed: ", fit$message),
      stringsAsFactors = FALSE
    ))
  }

  tt <- summary(fit)$tTable
  est <- unname(tt["shed_share", "Value"])
  se <- unname(tt["shed_share", "Std.Error"])
  p <- unname(tt["shed_share", "p-value"])
  ci <- est + c(-1, 1) * stats::qnorm(0.975) * se
  phi <- unname(coef(fit$modelStruct$corStruct, unconstrained = FALSE))

  data.frame(
    method = "AR(1) error model",
    n = nrow(panel),
    effect_pp_per_10pp = effect_scale(est),
    se_pp_per_10pp = effect_scale(se),
    ci_low_pp_per_10pp = effect_scale(ci[1]),
    ci_high_pp_per_10pp = effect_scale(ci[2]),
    p_value = p,
    ar1_phi_per_day = phi,
    notes = "Feasible GLS with continuous-time AR(1) residual correlation over calendar-day distance.",
    stringsAsFactors = FALSE
  )
}

lagged_outcome_result <- function(panel, nw_lag = MAIN_NW_LAG) {
  d <- panel %>%
    arrange(local_overpass_date) %>%
    mutate(
      lag_date = lag(local_overpass_date),
      lag_outcome = ifelse(local_overpass_date == lag_date + 1L, lag(outcome), NA_real_)
    ) %>%
    filter(is.finite(lag_outcome))

  fit <- lm_hac_result(
    d,
    method_label = "Lagged-outcome model",
    nw_lag = nw_lag,
    formula = outcome ~ shed_share + lag_outcome
  )

  lag_fit <- lm(outcome ~ shed_share + lag_outcome, data = d)
  lag_vc <- sandwich::NeweyWest(lag_fit, lag = nw_lag, prewhite = FALSE, adjust = TRUE)
  lag_ct <- lmtest::coeftest(lag_fit, vcov. = lag_vc)

  fit$lag_outcome_coef <- unname(coef(lag_fit)["lag_outcome"])
  fit$lag_outcome_se <- unname(lag_ct["lag_outcome", "Std. Error"])
  fit$notes <- paste0(
    "Controls for prior calendar-day outcome when the previous calendar day is observed; Newey-West HAC lag ",
    nw_lag,
    "."
  )
  fit
}

first_difference_result <- function(panel, nw_lag = MAIN_NW_LAG) {
  d <- panel %>%
    arrange(local_overpass_date) %>%
    mutate(
      lag_date = lag(local_overpass_date),
      d_outcome = ifelse(local_overpass_date == lag_date + 1L, outcome - lag(outcome), NA_real_),
      d_shed_share = ifelse(local_overpass_date == lag_date + 1L, shed_share - lag(shed_share), NA_real_)
    ) %>%
    filter(is.finite(d_outcome), is.finite(d_shed_share))

  names_for_fit <- d %>% transmute(outcome = d_outcome, shed_share = d_shed_share)
  fit <- lm_hac_result(
    names_for_fit,
    method_label = "First-difference model",
    nw_lag = nw_lag,
    formula = outcome ~ shed_share
  )
  fit$notes <- paste0(
    "Uses consecutive observed calendar-day changes only; Newey-West HAC lag ",
    nw_lag,
    "."
  )
  fit
}

block_permutation_placebo <- function(panel, block_size = PLACEBO_BLOCK_SIZE, b = PLACEBO_B) {
  n <- nrow(panel)
  actual <- unname(coef(lm(outcome ~ shed_share, data = panel))["shed_share"])
  block_id <- ceiling(seq_len(n) / block_size)
  block_levels <- unique(block_id)
  beta <- numeric(b)

  for (i in seq_len(b)) {
    perm <- sample(block_levels, length(block_levels), replace = FALSE)
    perm_idx <- unlist(lapply(perm, function(k) which(block_id == k)), use.names = FALSE)
    x_perm <- panel$shed_share[perm_idx][seq_len(n)]
    beta[[i]] <- unname(coef(lm(panel$outcome ~ x_perm))["x_perm"])
  }

  empirical_p <- (1 + sum(abs(beta) >= abs(actual), na.rm = TRUE)) / (b + 1)

  data.frame(
    method = "Block-permutation placebo",
    n = n,
    block_size = block_size,
    replications = b,
    actual_effect_pp_per_10pp = effect_scale(actual),
    placebo_mean_effect_pp_per_10pp = effect_scale(mean(beta, na.rm = TRUE)),
    placebo_sd_effect_pp_per_10pp = effect_scale(sd(beta, na.rm = TRUE)),
    empirical_p_value = empirical_p,
    placebo_ci_low_pp_per_10pp = effect_scale(quantile(beta, 0.025, na.rm = TRUE, names = FALSE)),
    placebo_ci_high_pp_per_10pp = effect_scale(quantile(beta, 0.975, na.rm = TRUE, names = FALSE)),
    notes = paste0("Permutes ", block_size, "-observation blocks of the Eskom series against the VJ series."),
    stringsAsFactors = FALSE
  )
}

circular_shift_placebo <- function(panel) {
  n <- nrow(panel)
  actual <- unname(coef(lm(outcome ~ shed_share, data = panel))["shed_share"])
  shifts <- seq_len(n - 1L)

  bind_rows(lapply(shifts, function(k) {
    x_shift <- panel$shed_share[((seq_len(n) - 1L + k) %% n) + 1L]
    beta <- unname(coef(lm(panel$outcome ~ x_shift))["x_shift"])
    effective_shift <- ifelse(k <= floor(n / 2), k, k - n)
    data.frame(
      shift_observed_rows = effective_shift,
      effect_pp_per_10pp = effect_scale(beta),
      actual_effect_pp_per_10pp = effect_scale(actual),
      abs_at_least_actual = abs(beta) >= abs(actual),
      stringsAsFactors = FALSE
    )
  }))
}

message("Reading demand-gated validation panel: ", COVERAGE_FILE)
exclusion_dates <- load_exclusion_dates(EXCESS_LIT_FLAGS_FILE, EXCESS_LIT_SCENARIO)
raw <- read.csv(COVERAGE_FILE, stringsAsFactors = FALSE) %>%
  mutate(
    date = as.Date(date),
    local_overpass_date = as.Date(local_overpass_date),
    gate_tier = as.character(gate_tier)
  )

analysis <- raw %>%
  filter(gate_tier == "pass", !date %in% exclusion_dates)

panels <- setNames(lapply(OUTCOMES, function(outcome) make_panel(analysis, outcome)), OUTCOMES)

message("Running Newey-West lag sensitivity.")
hac_lag <- bind_rows(lapply(OUTCOMES, function(outcome) {
  panel <- panels[[outcome]]
  label <- outcome_label(outcome)
  bind_rows(lapply(NW_LAGS, function(lag_k) {
    lm_hac_result(panel, method_label = "Newey-West HAC lag sensitivity", nw_lag = lag_k) %>%
      mutate(nw_lag = lag_k)
  })) %>%
    mutate(outcome = outcome, outcome_label = label, .before = 1)
}))

message("Running moving-block bootstrap.")
boot_summaries <- list()
boot_draws <- list()
for (outcome in OUTCOMES) {
  label <- outcome_label(outcome)
  res <- block_bootstrap_result(panels[[outcome]], block_size = BOOT_BLOCK_SIZE, b = BOOT_B)
  boot_summaries[[outcome]] <- res$summary %>%
    mutate(outcome = outcome, outcome_label = label, .before = 1)
  boot_draws[[outcome]] <- data.frame(
    outcome = outcome,
    outcome_label = label,
    draw = seq_along(res$draws),
    effect_pp_per_10pp = effect_scale(res$draws)
  )
}
boot_summary <- bind_rows(boot_summaries)
boot_draws_df <- bind_rows(boot_draws)

message("Running AR(1) error models.")
ar1_summary <- bind_rows(lapply(OUTCOMES, function(outcome) {
  label <- outcome_label(outcome)
  ar1_error_result(panels[[outcome]]) %>%
    mutate(outcome = outcome, outcome_label = label, .before = 1)
}))

message("Running lagged-outcome models.")
lagged_summary <- bind_rows(lapply(OUTCOMES, function(outcome) {
  label <- outcome_label(outcome)
  lagged_outcome_result(panels[[outcome]], nw_lag = MAIN_NW_LAG) %>%
    mutate(outcome = outcome, outcome_label = label, .before = 1)
}))

message("Running first-difference models.")
diff_summary <- bind_rows(lapply(OUTCOMES, function(outcome) {
  label <- outcome_label(outcome)
  first_difference_result(panels[[outcome]], nw_lag = MAIN_NW_LAG) %>%
    mutate(outcome = outcome, outcome_label = label, .before = 1)
}))

message("Running block-permutation placebo.")
block_placebo <- bind_rows(lapply(OUTCOMES, function(outcome) {
  label <- outcome_label(outcome)
  block_permutation_placebo(panels[[outcome]], block_size = PLACEBO_BLOCK_SIZE, b = PLACEBO_B) %>%
    mutate(outcome = outcome, outcome_label = label, .before = 1)
}))

message("Running circular-shift placebo.")
circular_placebo <- bind_rows(lapply(OUTCOMES, function(outcome) {
  label <- outcome_label(outcome)
  circular_shift_placebo(panels[[outcome]]) %>%
    mutate(outcome = outcome, outcome_label = label, .before = 1)
}))

message("Computing MLR autocorrelation on pass sample.")
mlr_panel <- panels[[OUTCOMES[[1]]]]
mlr_acf <- data.frame(
  lag_days = 1:30,
  autocorrelation = sapply(1:30, function(k) safe_acf(mlr_panel$shed_share, k))
)

baseline <- bind_rows(lapply(OUTCOMES, function(outcome) {
  label <- outcome_label(outcome)
  lm_hac_result(panels[[outcome]], method_label = "Baseline OLS + Newey-West", nw_lag = MAIN_NW_LAG) %>%
    mutate(outcome = outcome, outcome_label = label, .before = 1)
}))

main_summary <- bind_rows(
  baseline,
  boot_summary %>%
    select(outcome, outcome_label, method, n, effect_pp_per_10pp, se_pp_per_10pp,
           ci_low_pp_per_10pp, ci_high_pp_per_10pp, p_value, notes),
  ar1_summary %>%
    select(outcome, outcome_label, method, n, effect_pp_per_10pp, se_pp_per_10pp,
           ci_low_pp_per_10pp, ci_high_pp_per_10pp, p_value, notes),
  lagged_summary %>%
    select(outcome, outcome_label, method, n, effect_pp_per_10pp, se_pp_per_10pp,
           ci_low_pp_per_10pp, ci_high_pp_per_10pp, p_value, notes),
  diff_summary %>%
    select(outcome, outcome_label, method, n, effect_pp_per_10pp, se_pp_per_10pp,
           ci_low_pp_per_10pp, ci_high_pp_per_10pp, p_value, notes)
)

readr_write_csv <- function(x, path) {
  utils::write.csv(x, path, row.names = FALSE)
}

message("Writing CSV outputs.")
readr_write_csv(main_summary, OUT_MAIN)
readr_write_csv(hac_lag, OUT_HAC)
readr_write_csv(boot_summary, OUT_BOOT)
readr_write_csv(ar1_summary, OUT_AR1)
readr_write_csv(lagged_summary, OUT_LAGGED)
readr_write_csv(diff_summary, OUT_DIFF)
readr_write_csv(block_placebo, OUT_BLOCK_PLACEBO)
readr_write_csv(circular_placebo, OUT_CIRCULAR_PLACEBO)
readr_write_csv(mlr_acf, OUT_MLR_ACF)

message("Writing figures.")
effects_plot <- main_summary %>%
  mutate(method = factor(
    method,
    levels = c(
      "Baseline OLS + Newey-West",
      "Moving-block bootstrap",
      "AR(1) error model",
      "Lagged-outcome model",
      "First-difference model"
    )
  )) %>%
  ggplot(aes(x = effect_pp_per_10pp, y = method, color = outcome_label)) +
  geom_vline(xintercept = 0, linewidth = 0.4, color = "#4A5568") +
  geom_errorbar(aes(xmin = ci_low_pp_per_10pp, xmax = ci_high_pp_per_10pp),
                width = 0.16, linewidth = 0.7, position = position_dodge(width = 0.5),
                orientation = "y") +
  geom_point(size = 2.2, position = position_dodge(width = 0.5)) +
  scale_color_manual(values = c("Strict dark: p_lit < 0.05" = "#A3292F", "Mostly dark: p_lit < 0.20" = "#D99322")) +
  labs(
    title = "Autocorrelation Robustness Checks",
    subtitle = "Effects are percentage-point changes in dark population share per 10 percentage-point increase in Eskom MLR shed share",
    x = "Effect, pp per 10 pp MLR",
    y = NULL,
    color = NULL
  ) +
  theme_report()
ggsave(OUT_EFFECTS_PNG, effects_plot, width = 8.2, height = 4.8, dpi = 300)

hac_plot <- hac_lag %>%
  ggplot(aes(x = nw_lag, y = se_pp_per_10pp, color = outcome_label)) +
  geom_line(linewidth = 0.8) +
  geom_point(size = 2) +
  scale_color_manual(values = c("Strict dark: p_lit < 0.05" = "#A3292F", "Mostly dark: p_lit < 0.20" = "#D99322")) +
  labs(
    title = "Newey-West Standard Errors Are Stable Across Lag Choices",
    subtitle = "Lag 7 is the current report choice",
    x = "Newey-West lag",
    y = "SE, pp per 10 pp MLR"
  ) +
  theme_report()
ggsave(OUT_HAC_PNG, hac_plot, width = 7.2, height = 4.4, dpi = 300)

placebo_plot <- boot_draws_df %>%
  ggplot(aes(x = effect_pp_per_10pp, fill = outcome_label)) +
  geom_histogram(bins = 45, alpha = 0.70, position = "identity") +
  geom_vline(
    data = block_placebo,
    aes(xintercept = actual_effect_pp_per_10pp, color = outcome_label),
    linewidth = 0.8
  ) +
  facet_wrap(~ outcome_label, ncol = 1, scales = "free_y") +
  scale_fill_manual(values = c("Strict dark: p_lit < 0.05" = "#A3292F", "Mostly dark: p_lit < 0.20" = "#D99322")) +
  scale_color_manual(values = c("Strict dark: p_lit < 0.05" = "#6B1418", "Mostly dark: p_lit < 0.20" = "#8C5A0E")) +
  labs(
    title = "Moving-Block Bootstrap Distribution",
    subtitle = "Vertical lines show the observed same-night slope",
    x = "Effect, pp per 10 pp MLR",
    y = "Bootstrap draws"
  ) +
  theme_report() +
  theme(legend.position = "none")
ggsave(OUT_BOOT_PNG, placebo_plot, width = 7.2, height = 5.8, dpi = 300)

message("Writing markdown summary.")
strict_main <- main_summary %>% filter(outcome == "popw_strict_dark_share")
mostly_main <- main_summary %>% filter(outcome == "popw_mostly_dark_share")

one_line <- function(d, method_name) {
  row <- d %>% filter(method == method_name) %>% slice(1)
  paste0(
    "- ", method_name, ": effect ", fmt_num(row$effect_pp_per_10pp, 3),
    " pp, SE ", fmt_num(row$se_pp_per_10pp, 3),
    ", 95% CI [", fmt_num(row$ci_low_pp_per_10pp, 3), ", ",
    fmt_num(row$ci_high_pp_per_10pp, 3), "], p ", fmt_p(row$p_value),
    ", N=", row$n, "."
  )
}

md_lines <- c(
  "# VJ146A2 Eskom MLR Autocorrelation Robustness",
  "",
  paste0("- Date: ", Sys.Date()),
  paste0("- Input: `", COVERAGE_FILE, "`"),
  paste0("- Output directory: `", OUT_DIR, "`"),
  paste0("- Sample: demand-gated pass nights with finite Eskom MLR and VJ outcome."),
  paste0("- Seed: ", SEED, "; moving-block bootstrap B=", BOOT_B, ", block size=", BOOT_BLOCK_SIZE, "."),
  "",
  "## What This Script Tests",
  "",
  "This is a companion robustness analysis. It does not replace OLS; it asks whether the validation result survives standard time-series concerns about serial correlation.",
  "",
  "1. Newey-West HAC lag sensitivity.",
  "2. Moving-block bootstrap.",
  "3. AR(1) residual error model using `nlme::gls` with continuous AR(1) correlation over calendar days.",
  "4. Lagged-outcome model using the previous observed calendar day.",
  "5. First-difference model using consecutive observed calendar days.",
  "6. Block-permutation and circular-shift placebo tests.",
  "",
  "## Strict-Dark Outcome",
  "",
  one_line(strict_main, "Baseline OLS + Newey-West"),
  one_line(strict_main, "Moving-block bootstrap"),
  one_line(strict_main, "AR(1) error model"),
  one_line(strict_main, "Lagged-outcome model"),
  one_line(strict_main, "First-difference model"),
  "",
  "## Mostly-Dark Outcome",
  "",
  one_line(mostly_main, "Baseline OLS + Newey-West"),
  one_line(mostly_main, "Moving-block bootstrap"),
  one_line(mostly_main, "AR(1) error model"),
  one_line(mostly_main, "Lagged-outcome model"),
  one_line(mostly_main, "First-difference model"),
  "",
  "## Placebo Tests",
  "",
  paste0(
    "- Block permutation, strict dark: empirical p=",
    fmt_p(block_placebo$empirical_p_value[block_placebo$outcome == "popw_strict_dark_share"]),
    "; observed effect ",
    fmt_num(block_placebo$actual_effect_pp_per_10pp[block_placebo$outcome == "popw_strict_dark_share"], 3),
    " pp."
  ),
  paste0(
    "- Block permutation, mostly dark: empirical p=",
    fmt_p(block_placebo$empirical_p_value[block_placebo$outcome == "popw_mostly_dark_share"]),
    "; observed effect ",
    fmt_num(block_placebo$actual_effect_pp_per_10pp[block_placebo$outcome == "popw_mostly_dark_share"], 3),
    " pp."
  ),
  "",
  "## MLR Persistence",
  "",
  paste0("- MLR autocorrelation at lag 1: ", fmt_num(mlr_acf$autocorrelation[mlr_acf$lag_days == 1], 3), "."),
  paste0("- MLR autocorrelation at lag 3: ", fmt_num(mlr_acf$autocorrelation[mlr_acf$lag_days == 3], 3), "."),
  paste0("- MLR autocorrelation at lag 7: ", fmt_num(mlr_acf$autocorrelation[mlr_acf$lag_days == 7], 3), "."),
  "",
  "## Interpretation Guardrail",
  "",
  "Autocorrelation does not by itself invalidate the OLS slope. It mainly invalidates iid standard errors and can signal omitted dynamics. The robustness checks here test whether the same positive validation relationship remains under alternative inference, residual-correlation, dynamic, differenced, and placebo designs."
)

writeLines(md_lines, OUT_MD)

message("Done.")
message("Summary: ", OUT_MD)
