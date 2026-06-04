rm(list = ls())

# ============================================================
# 2023 VJ146A2 settlement threshold-ladder validation
# ============================================================
#
# Companion appendix-style robustness script. This does not modify the main
# validation scripts or report.
#
# Goal:
#   Test whether settlement-level validation broadens when we relax the
#   darkness definition and tighten observation coverage.
#
# Grid:
#   Coverage thresholds: 0.50, 0.75, 0.90
#   Outcomes:
#     dark_005 = p_lit < 0.05
#     dark_020 = p_lit < 0.20
#     dark_040 = p_lit < 0.40
#     darkness_cont = 1 - p_lit
#
# Outputs:
#   Map Data/settlement_day_outputs_vj146a2/
#     mlr_validation_settlement_threshold_ladder_2023/
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(arrow)
  library(data.table)
  library(dplyr)
  library(ggplot2)
  library(lmtest)
  library(sandwich)
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
  Sys.getenv("VJ146A2_SETTLEMENT_LADDER_OUT_SUBDIR", "mlr_validation_settlement_threshold_ladder_2023")
)

OUT_SAMPLE <- file.path(OUT_DIR, "vj146a2_2023_settlement_ladder_sample_summary.csv")
OUT_FE <- file.path(OUT_DIR, "vj146a2_2023_settlement_ladder_fe_results.csv")
OUT_SLOPE_SUMMARY <- file.path(OUT_DIR, "vj146a2_2023_settlement_ladder_slope_summary.csv")
OUT_BIN_SUMMARY <- file.path(OUT_DIR, "vj146a2_2023_settlement_ladder_population_bin_summary.csv")
OUT_SLOPES <- file.path(OUT_DIR, "vj146a2_2023_settlement_ladder_per_settlement_slopes.csv")
OUT_MD <- file.path(OUT_DIR, "vj146a2_2023_settlement_ladder_summary.md")
OUT_FIG_BREADTH <- file.path(OUT_DIR, "vj146a2_settlement_ladder_population_breadth.png")
OUT_FIG_FE <- file.path(OUT_DIR, "vj146a2_settlement_ladder_fe_effects.png")
OUT_FIG_BINS <- file.path(OUT_DIR, "vj146a2_settlement_ladder_population_bins.png")

missing_panels <- VJ_PANEL_FILES[!file.exists(VJ_PANEL_FILES)]
if (length(missing_panels) > 0) {
  stop("Missing VJ panel files:\n  - ", paste(missing_panels, collapse = "\n  - "))
}
if (!file.exists(GATE_FILE)) stop("Input not found: ", GATE_FILE)
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

EXCESS_LIT_FLAGS_FILE <- Sys.getenv("VJ146A2_EXCESS_LIT_FLAGS_FILE", "")
EXCESS_LIT_SCENARIO <- Sys.getenv("VJ146A2_EXCESS_LIT_SCENARIO", "annual_q3_plus_1p5_iqr")
COVERAGE_THRESHOLDS <- as.numeric(strsplit(Sys.getenv("VJ146A2_SETTLEMENT_LADDER_COVERAGE", "0.50,0.75,0.90"), ",")[[1]])
POP_MIN <- as.numeric(Sys.getenv("VJ146A2_SETTLEMENT_LADDER_POP_MIN", "100"))
MIN_OBS <- as.integer(Sys.getenv("VJ146A2_SETTLEMENT_LADDER_MIN_OBS", "50"))
NW_LAG <- as.integer(Sys.getenv("VJ146A2_SETTLEMENT_LADDER_NW_LAG", "7"))

OUTCOME_SPECS <- data.frame(
  outcome = c("dark_005", "dark_020", "dark_040", "darkness_cont"),
  outcome_label = c("p_lit < 0.05", "p_lit < 0.20", "p_lit < 0.40", "Continuous: 1 - p_lit"),
  outcome_type = c("binary", "binary", "binary", "continuous"),
  stringsAsFactors = FALSE
)

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

fmt_pct <- function(x, digits = 1) paste0(fmt_num(100 * x, digits), "%")

weighted_quantile <- function(x, w, probs) {
  ok <- is.finite(x) & is.finite(w) & w > 0
  x <- x[ok]
  w <- w[ok]
  if (length(x) == 0) return(rep(NA_real_, length(probs)))
  ord <- order(x)
  x <- x[ord]
  w <- w[ord]
  cw <- cumsum(w) / sum(w)
  stats::approx(cw, x, xout = probs, rule = 2, ties = "ordered")$y
}

load_exclusion_dates <- function(path, scenario) {
  if (!nzchar(path)) return(as.Date(character()))
  if (!file.exists(path)) stop("Excess-lit flag file not found: ", path)
  read.csv(path, stringsAsFactors = FALSE) %>%
    mutate(date = as.Date(date)) %>%
    filter(scenario == !!scenario, remove) %>%
    pull(date)
}

cluster_vcov <- function(X, resid, w, cluster) {
  xw <- X * as.numeric(w)
  bread <- solve(crossprod(X, xw))
  score <- X * as.numeric(w * resid)
  score_by_cluster <- rowsum(score, group = cluster, reorder = FALSE)
  meat <- crossprod(score_by_cluster)
  n <- nrow(X)
  k <- ncol(X)
  g <- nrow(score_by_cluster)
  correction <- (g / (g - 1)) * ((n - 1) / (n - k))
  correction * bread %*% meat %*% bread
}

weighted_demean_by_id <- function(dt, cols, weight_col = "w_population") {
  for (col in cols) {
    dm_col <- paste0(col, "_dm")
    dt[, (dm_col) := {
      ww <- get(weight_col)
      xx <- get(col)
      xx - sum(ww * xx, na.rm = TRUE) / sum(ww, na.rm = TRUE)
    }, by = settlement_id]
  }
  paste0(cols, "_dm")
}

within_model <- function(data, outcome, controls = c("month_fe", "dow_fe"), weight_col = "w_population", model_label) {
  needed <- c("settlement_id", "local_overpass_date", "shed_share", outcome, controls, weight_col)
  dt <- as.data.table(data[, needed, with = FALSE])
  dt <- dt[is.finite(get(outcome)) & is.finite(shed_share) & is.finite(get(weight_col)) & get(weight_col) > 0]
  keep_ids <- dt[, .N, by = settlement_id][N >= 2, settlement_id]
  dt <- dt[settlement_id %in% keep_ids]

  rhs <- paste(c("shed_share", controls), collapse = " + ")
  mm <- model.matrix(as.formula(paste("~", rhs)), data = dt)
  mm <- mm[, colnames(mm) != "(Intercept)", drop = FALSE]
  colnames(mm) <- make.names(colnames(mm), unique = TRUE)
  dt <- cbind(dt, as.data.table(mm))

  x_cols <- colnames(mm)
  weighted_demean_by_id(dt, c(outcome, x_cols), weight_col = weight_col)
  y <- dt[[paste0(outcome, "_dm")]]
  X <- as.matrix(dt[, paste0(x_cols, "_dm"), with = FALSE])
  colnames(X) <- x_cols
  w <- dt[[weight_col]]

  nonzero <- apply(X, 2, function(z) stats::sd(z, na.rm = TRUE) > 1e-12)
  X <- X[, nonzero, drop = FALSE]
  qrx <- qr(X * sqrt(w))
  keep <- sort(qrx$pivot[seq_len(qrx$rank)])
  X <- X[, keep, drop = FALSE]

  beta <- as.numeric(solve(crossprod(X, X * w), crossprod(X, y * w)))
  names(beta) <- colnames(X)
  resid <- as.numeric(y - X %*% beta)
  vc <- cluster_vcov(X, resid, w, dt$local_overpass_date)
  se <- sqrt(diag(vc))
  names(se) <- colnames(X)

  est <- beta[["shed_share"]]
  est_se <- se[["shed_share"]]
  cluster_df <- uniqueN(dt$local_overpass_date) - 1L
  ci <- est + c(-1, 1) * stats::qt(0.975, df = cluster_df) * est_se
  p_value <- 2 * stats::pt(-abs(est / est_se), df = cluster_df)
  rss <- sum(w * resid^2, na.rm = TRUE)
  tss_within <- sum(w * y^2, na.rm = TRUE)
  y_raw <- dt[[outcome]]
  y_bar <- sum(w * y_raw, na.rm = TRUE) / sum(w, na.rm = TRUE)
  tss_full <- sum(w * (y_raw - y_bar)^2, na.rm = TRUE)

  restricted_cols <- setdiff(colnames(X), "shed_share")
  if (length(restricted_cols) > 0) {
    X_restricted <- X[, restricted_cols, drop = FALSE]
    beta_restricted <- as.numeric(solve(
      crossprod(X_restricted, X_restricted * w),
      crossprod(X_restricted, y * w)
    ))
    resid_restricted <- as.numeric(y - X_restricted %*% beta_restricted)
    rss_restricted <- sum(w * resid_restricted^2, na.rm = TRUE)
  } else {
    rss_restricted <- tss_within
  }

  data.frame(
    model = model_label,
    n_rows = nrow(dt),
    n_settlements = uniqueN(dt$settlement_id),
    n_dates = uniqueN(dt$local_overpass_date),
    effect_pp_per_10pp = est * 10,
    se_cluster_date_pp = est_se * 10,
    ci_low_pp = ci[[1]] * 10,
    ci_high_pp = ci[[2]] * 10,
    p_value = p_value,
    model_full_r2 = 1 - rss / tss_full,
    model_within_r2 = 1 - rss / tss_within,
    mlr_partial_r2 = 1 - rss / rss_restricted,
    stringsAsFactors = FALSE
  )
}

settlement_slope <- function(x, y) {
  ok <- is.finite(x) & is.finite(y)
  x <- x[ok]
  y <- y[ok]
  if (length(x) < MIN_OBS || stats::sd(x) <= 0) return(NA_real_)
  if (stats::sd(y) <= 0) return(0)
  as.numeric(stats::cov(x, y) / stats::var(x))
}

safe_nw <- function(d, outcome) {
  if (nrow(d) < MIN_OBS || stats::sd(d[[outcome]], na.rm = TRUE) <= 0 || stats::sd(d$shed_share, na.rm = TRUE) <= 0) {
    return(c(se_pp = NA_real_, p_value = NA_real_))
  }
  fit <- tryCatch(lm(as.formula(paste(outcome, "~ shed_share")), data = d), error = function(e) e)
  if (inherits(fit, "error")) return(c(se_pp = NA_real_, p_value = NA_real_))
  tryCatch({
    vc <- sandwich::NeweyWest(fit, lag = min(NW_LAG, nrow(d) - 2L), prewhite = FALSE, adjust = TRUE)
    ct <- lmtest::coeftest(fit, vcov. = vc)
    c(se_pp = unname(ct["shed_share", "Std. Error"]) * 10, p_value = unname(ct["shed_share", "Pr(>|t|)"]))
  }, error = function(e) c(se_pp = NA_real_, p_value = NA_real_))
}

summarise_slopes <- function(slopes, outcome, label, coverage_min, pop_bin = "All") {
  slope_col <- paste0("slope_", outcome, "_pp")
  p_col <- paste0("p_", outcome)
  ok <- is.finite(slopes[[slope_col]])
  positive <- ok & slopes[[slope_col]] > 0
  sig_positive <- positive & is.finite(slopes[[p_col]]) & slopes[[p_col]] < 0.05
  wq <- weighted_quantile(slopes[[slope_col]][ok], slopes$population[ok], c(0.10, 0.25, 0.50, 0.75, 0.90))

  data.frame(
    coverage_min = coverage_min,
    outcome = outcome,
    outcome_label = label,
    pop_bin = pop_bin,
    settlements_estimable = sum(ok),
    population_estimable = sum(slopes$population[ok], na.rm = TRUE),
    unweighted_mean_slope_pp = mean(slopes[[slope_col]][ok], na.rm = TRUE),
    population_weighted_mean_slope_pp = stats::weighted.mean(slopes[[slope_col]][ok], slopes$population[ok], na.rm = TRUE),
    median_slope_pp = stats::median(slopes[[slope_col]][ok], na.rm = TRUE),
    weighted_p10_slope_pp = wq[[1]],
    weighted_p25_slope_pp = wq[[2]],
    weighted_median_slope_pp = wq[[3]],
    weighted_p75_slope_pp = wq[[4]],
    weighted_p90_slope_pp = wq[[5]],
    share_settlements_positive = mean(positive[ok], na.rm = TRUE),
    share_population_positive = sum(slopes$population[positive], na.rm = TRUE) / sum(slopes$population[ok], na.rm = TRUE),
    share_settlements_sig_positive = mean(sig_positive[ok], na.rm = TRUE),
    share_population_sig_positive = sum(slopes$population[sig_positive], na.rm = TRUE) / sum(slopes$population[ok], na.rm = TRUE),
    stringsAsFactors = FALSE
  )
}

message("Loading pass-night gate file.")
exclusion_dates <- load_exclusion_dates(EXCESS_LIT_FLAGS_FILE, EXCESS_LIT_SCENARIO)
gate <- fread(GATE_FILE) %>%
  mutate(date = as.Date(date), local_overpass_date = as.Date(local_overpass_date)) %>%
  filter(gate_tier == "pass", is.finite(shed_share_1_2am_primary), !date %in% exclusion_dates) %>%
  select(date, local_overpass_date, shed_share = shed_share_1_2am_primary)

message("Loading settlement-day VJ parquets.")
panel_all <- rbindlist(lapply(VJ_PANEL_FILES, function(path) {
  as.data.table(arrow::read_parquet(
    path,
    col_select = c("settlement_id", "date", "coverage", "p_lit_sett", "population", "electrified_best")
  ))
}), use.names = TRUE, fill = TRUE)

panel_all[, settlement_id := as.character(settlement_id)]
panel_all[, date := as.Date(date)]
panel_all[, population := as.numeric(population)]
panel_all[, coverage := as.numeric(coverage)]
panel_all[, p_lit_sett := as.numeric(p_lit_sett)]

panel_all <- panel_all %>%
  filter(
    electrified_best == 1,
    population > POP_MIN,
    is.finite(coverage),
    is.finite(p_lit_sett),
    is.finite(population)
  ) %>%
  inner_join(gate, by = "date") %>%
  mutate(
    dark_005 = as.numeric(p_lit_sett < 0.05),
    dark_020 = as.numeric(p_lit_sett < 0.20),
    dark_040 = as.numeric(p_lit_sett < 0.40),
    darkness_cont = 1 - p_lit_sett,
    month_fe = factor(format(local_overpass_date, "%Y-%m")),
    dow_fe = factor(weekdays(local_overpass_date), levels = c("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")),
    w_population = population,
    pop_bin = cut(
      population,
      breaks = c(100, 1000, 10000, 100000, Inf),
      labels = c("101-1k", "1k-10k", "10k-100k", ">100k"),
      include.lowest = TRUE,
      right = TRUE
    )
  ) %>%
  as.data.table()

sample_summary <- list()
fe_results <- list()
slope_rows <- list()
slope_summary <- list()
bin_summary <- list()

for (cov_min in COVERAGE_THRESHOLDS) {
  message("Running coverage threshold >= ", cov_min)
  panel <- panel_all[coverage >= cov_min]
  sample_summary[[as.character(cov_min)]] <- data.frame(
    coverage_min = cov_min,
    n_rows = nrow(panel),
    n_settlements = uniqueN(panel$settlement_id),
    n_dates = uniqueN(panel$local_overpass_date),
    population_sum_unique = panel[, .(population = max(population, na.rm = TRUE)), by = settlement_id][, sum(population, na.rm = TRUE)],
    mean_rows_per_settlement = mean(panel[, .N, by = settlement_id]$N),
    median_rows_per_settlement = stats::median(panel[, .N, by = settlement_id]$N)
  )

  cov_fe <- list()
  for (i in seq_len(nrow(OUTCOME_SPECS))) {
    outcome <- OUTCOME_SPECS$outcome[[i]]
    label <- OUTCOME_SPECS$outcome_label[[i]]
    cov_fe[[outcome]] <- rbind(
      cbind(
        coverage_min = cov_min,
        outcome = outcome,
        outcome_label = label,
        within_model(panel, outcome, controls = character(), model_label = "Settlement FE only")
      ),
      cbind(
        coverage_min = cov_min,
        outcome = outcome,
        outcome_label = label,
        within_model(panel, outcome, controls = c("month_fe", "dow_fe"), model_label = "Settlement FE + month + DOW FE")
      )
    )
  }
  fe_results[[as.character(cov_min)]] <- rbindlist(cov_fe, use.names = TRUE)

  slopes <- panel[, {
    d <- .SD
    out <- list(
      population = max(population, na.rm = TRUE),
      pop_bin = as.character(pop_bin[which.max(population)]),
      n_obs = .N
    )
    for (outcome in OUTCOME_SPECS$outcome) {
      slope <- settlement_slope(d$shed_share, d[[outcome]]) * 10
      nw <- safe_nw(d, outcome)
      out[[paste0("slope_", outcome, "_pp")]] <- slope
      out[[paste0("se_", outcome, "_pp")]] <- nw[["se_pp"]]
      out[[paste0("p_", outcome)]] <- nw[["p_value"]]
      out[[paste0("mean_", outcome)]] <- mean(d[[outcome]], na.rm = TRUE)
    }
    out
  }, by = settlement_id]
  slopes <- slopes[n_obs >= MIN_OBS]
  slopes[, coverage_min := cov_min]
  slope_rows[[as.character(cov_min)]] <- slopes

  for (i in seq_len(nrow(OUTCOME_SPECS))) {
    outcome <- OUTCOME_SPECS$outcome[[i]]
    label <- OUTCOME_SPECS$outcome_label[[i]]
    slope_summary[[paste(cov_min, outcome, sep = "_")]] <- summarise_slopes(slopes, outcome, label, cov_min)
    bin_summary[[paste(cov_min, outcome, sep = "_")]] <- rbindlist(lapply(sort(unique(slopes$pop_bin)), function(bin) {
      summarise_slopes(slopes[pop_bin == bin], outcome, label, cov_min, pop_bin = bin)
    }), use.names = TRUE)
  }
}

sample_summary <- rbindlist(sample_summary, use.names = TRUE)
fe_results <- rbindlist(fe_results, use.names = TRUE)
slopes_all <- rbindlist(slope_rows, use.names = TRUE, fill = TRUE)
slope_summary <- rbindlist(slope_summary, use.names = TRUE)
bin_summary <- rbindlist(bin_summary, use.names = TRUE)

message("Writing tables.")
fwrite(sample_summary, OUT_SAMPLE)
fwrite(fe_results, OUT_FE)
fwrite(slopes_all, OUT_SLOPES)
fwrite(slope_summary, OUT_SLOPE_SUMMARY)
fwrite(bin_summary, OUT_BIN_SUMMARY)

message("Writing figures.")
plot_breadth <- slope_summary %>%
  mutate(
    coverage_label = paste0("Coverage >= ", fmt_pct(coverage_min, 0)),
    outcome_label = factor(outcome_label, levels = OUTCOME_SPECS$outcome_label)
  )

p_breadth <- ggplot(plot_breadth, aes(x = outcome_label, y = share_population_positive, color = coverage_label, group = coverage_label)) +
  geom_hline(yintercept = 0.5, color = "#4A5568", linewidth = 0.32, linetype = "dotted") +
  geom_line(linewidth = 0.75) +
  geom_point(size = 2.2) +
  scale_y_continuous(labels = function(x) fmt_pct(x, 0), limits = c(0, max(plot_breadth$share_population_positive, na.rm = TRUE) * 1.15)) +
  labs(
    title = "Relaxed darkness thresholds broaden settlement-level detection",
    subtitle = "Share of population living in settlements with positive local MLR-darkness slopes",
    x = NULL,
    y = "Population share with positive slope",
    color = NULL
  ) +
  theme_report(base_size = 9.8) +
  theme(axis.text.x = element_text(angle = 20, hjust = 1))
ggsave(OUT_FIG_BREADTH, p_breadth, width = 8.4, height = 4.7, dpi = 300)

p_fe <- fe_results %>%
  filter(model == "Settlement FE + month + DOW FE") %>%
  mutate(
    coverage_label = paste0("Coverage >= ", fmt_pct(coverage_min, 0)),
    outcome_label = factor(outcome_label, levels = OUTCOME_SPECS$outcome_label)
  ) %>%
  ggplot(aes(x = outcome_label, y = effect_pp_per_10pp, color = coverage_label, group = coverage_label)) +
  geom_hline(yintercept = 0, color = "#4A5568", linewidth = 0.32) +
  geom_errorbar(aes(ymin = ci_low_pp, ymax = ci_high_pp), width = 0.12, linewidth = 0.6, position = position_dodge(width = 0.4)) +
  geom_point(size = 2.0, position = position_dodge(width = 0.4)) +
  scale_y_continuous(labels = function(x) paste0(fmt_num(x, 1), " pp")) +
  labs(
    title = "Settlement fixed-effects slopes are stable across coverage thresholds",
    subtitle = "Population-weighted within-settlement models with month and day-of-week controls; SE clustered by date",
    x = NULL,
    y = "Effect per 10 pp MLR",
    color = NULL
  ) +
  theme_report(base_size = 9.8) +
  theme(axis.text.x = element_text(angle = 20, hjust = 1))
ggsave(OUT_FIG_FE, p_fe, width = 8.4, height = 4.7, dpi = 300)

p_bins <- bin_summary %>%
  filter(coverage_min == 0.50) %>%
  mutate(
    outcome_label = factor(outcome_label, levels = OUTCOME_SPECS$outcome_label),
    pop_bin = factor(pop_bin, levels = c("101-1k", "1k-10k", "10k-100k", ">100k"))
  ) %>%
  ggplot(aes(x = outcome_label, y = share_population_positive, fill = pop_bin)) +
  geom_col(position = position_dodge(width = 0.72), width = 0.65) +
  scale_y_continuous(labels = function(x) fmt_pct(x, 0), limits = c(0, 1)) +
  labs(
    title = "Detection breadth differs by settlement population size",
    subtitle = "Coverage >= 50%; bars show population share with positive local slopes within each size bin",
    x = NULL,
    y = "Population share with positive slope",
    fill = "Population bin"
  ) +
  theme_report(base_size = 9.5) +
  theme(axis.text.x = element_text(angle = 20, hjust = 1), legend.position = "bottom")
ggsave(OUT_FIG_BINS, p_bins, width = 8.4, height = 4.8, dpi = 300)

main_rows <- slope_summary %>%
  filter(coverage_min == 0.50) %>%
  arrange(match(outcome, OUTCOME_SPECS$outcome))

fe_main <- fe_results %>%
  filter(coverage_min == 0.50, model == "Settlement FE + month + DOW FE") %>%
  arrange(match(outcome, OUTCOME_SPECS$outcome))

md <- c(
  "# VJ146A2 Settlement Threshold-Ladder Validation",
  "",
  paste0("- Date: ", Sys.Date()),
  paste0("- Input gate file: `", GATE_FILE, "`"),
  paste0("- Output directory: `", OUT_DIR, "`"),
  paste0("- Coverage thresholds: ", paste(COVERAGE_THRESHOLDS, collapse = ", "), "."),
  paste0("- Minimum observations per settlement for slope summaries: ", MIN_OBS, "."),
  "",
  "## Main Question",
  "",
  "Does the settlement-level validation signal broaden when the darkness definition is relaxed, and is it stable when the settlement-night coverage threshold is increased?",
  "",
  "## Coverage >= 50% Summary",
  "",
  paste0(
    "- `p_lit < 0.05`: population-weighted mean local slope ",
    fmt_num(main_rows$population_weighted_mean_slope_pp[main_rows$outcome == "dark_005"], 3),
    " pp; population positive ",
    fmt_pct(main_rows$share_population_positive[main_rows$outcome == "dark_005"]),
    "; weighted median ",
    fmt_num(main_rows$weighted_median_slope_pp[main_rows$outcome == "dark_005"], 3),
    " pp."
  ),
  paste0(
    "- `p_lit < 0.20`: population-weighted mean local slope ",
    fmt_num(main_rows$population_weighted_mean_slope_pp[main_rows$outcome == "dark_020"], 3),
    " pp; population positive ",
    fmt_pct(main_rows$share_population_positive[main_rows$outcome == "dark_020"]),
    "; weighted median ",
    fmt_num(main_rows$weighted_median_slope_pp[main_rows$outcome == "dark_020"], 3),
    " pp."
  ),
  paste0(
    "- `p_lit < 0.40`: population-weighted mean local slope ",
    fmt_num(main_rows$population_weighted_mean_slope_pp[main_rows$outcome == "dark_040"], 3),
    " pp; population positive ",
    fmt_pct(main_rows$share_population_positive[main_rows$outcome == "dark_040"]),
    "; weighted median ",
    fmt_num(main_rows$weighted_median_slope_pp[main_rows$outcome == "dark_040"], 3),
    " pp."
  ),
  paste0(
    "- `1 - p_lit`: population-weighted mean local slope ",
    fmt_num(main_rows$population_weighted_mean_slope_pp[main_rows$outcome == "darkness_cont"], 3),
    " pp; population positive ",
    fmt_pct(main_rows$share_population_positive[main_rows$outcome == "darkness_cont"]),
    "; weighted median ",
    fmt_num(main_rows$weighted_median_slope_pp[main_rows$outcome == "darkness_cont"], 3),
    " pp."
  ),
  "",
  "## Preferred Settlement FE + Month + DOW Results, Coverage >= 50%",
  "",
  paste0(
    "- `p_lit < 0.05`: ",
    fmt_num(fe_main$effect_pp_per_10pp[fe_main$outcome == "dark_005"], 3),
    " pp, SE ",
    fmt_num(fe_main$se_cluster_date_pp[fe_main$outcome == "dark_005"], 3),
    "."
  ),
  paste0(
    "- `p_lit < 0.20`: ",
    fmt_num(fe_main$effect_pp_per_10pp[fe_main$outcome == "dark_020"], 3),
    " pp, SE ",
    fmt_num(fe_main$se_cluster_date_pp[fe_main$outcome == "dark_020"], 3),
    "."
  ),
  paste0(
    "- `p_lit < 0.40`: ",
    fmt_num(fe_main$effect_pp_per_10pp[fe_main$outcome == "dark_040"], 3),
    " pp, SE ",
    fmt_num(fe_main$se_cluster_date_pp[fe_main$outcome == "dark_040"], 3),
    "."
  ),
  paste0(
    "- `1 - p_lit`: ",
    fmt_num(fe_main$effect_pp_per_10pp[fe_main$outcome == "darkness_cont"], 3),
    " pp, SE ",
    fmt_num(fe_main$se_cluster_date_pp[fe_main$outcome == "darkness_cont"], 3),
    "."
  ),
  "",
  "## Interpretation",
  "",
  "Relaxing the darkness threshold should be interpreted as a detection-breadth check, not a replacement for the strict national validation headline. Higher thresholds and continuous darkness can capture partial urban dimming that strict binary darkness misses. Coverage thresholds test whether this settlement-level story is robust to requiring cleaner settlement-night observation support."
)
writeLines(md, OUT_MD)

message("Done.")
message("Summary: ", OUT_MD)
