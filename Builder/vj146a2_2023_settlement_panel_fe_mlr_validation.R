rm(list = ls())

# ============================================================
# 2023 VJ146A2 settlement-panel within estimator robustness
# ============================================================
#
# Companion robustness script. This script does not modify the national
# validation script or the report.
#
# Goal:
#   Estimate whether the national Eskom MLR validation signal survives a
#   settlement-level within-group estimator:
#
#     dark_it = beta * MLR_t + settlement FE_i + calendar controls_t + e_it
#
#   MLR varies only by date, so inference is clustered by local overpass date.
#   This avoids treating settlement-night rows as independent national shocks.
#
# Run:
#   Rscript Builder/vj146a2_2023_settlement_panel_fe_mlr_validation.R
#
# Outputs:
#   Map Data/settlement_day_outputs_vj146a2/
#     mlr_validation_settlement_panel_fe_2023_cov50/
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(arrow)
  library(data.table)
  library(dplyr)
  library(ggplot2)
})

BASE_PATH <- here::here()

VJ_PANEL_DIR <- file.path(BASE_PATH, "Map Data", "settlement_day_outputs_vj146a2")
VJ_PANEL_FILES <- file.path(
  VJ_PANEL_DIR,
  paste0("settlement_day_vj146a2_cov_yearlykeep_2023-", sprintf("%02d", 1:12), ".parquet")
)

GATE_DIR <- file.path(
  VJ_PANEL_DIR,
  Sys.getenv("VJ146A2_PANEL_FE_GATE_SUBDIR", "mlr_validation_demand_gate_2023_cov50")
)

OUT_DIR <- file.path(
  VJ_PANEL_DIR,
  Sys.getenv("VJ146A2_PANEL_FE_OUT_SUBDIR", "mlr_validation_settlement_panel_fe_2023_cov50")
)

GATE_FILE <- file.path(GATE_DIR, "vj146a2_2023_demand_gate_coverage.csv")

OUT_RESULTS <- file.path(OUT_DIR, "vj146a2_2023_settlement_panel_fe_results.csv")
OUT_SAMPLE <- file.path(OUT_DIR, "vj146a2_2023_settlement_panel_fe_sample_summary.csv")
OUT_FIG <- file.path(OUT_DIR, "vj146a2_settlement_panel_fe_effects.png")
OUT_MD <- file.path(OUT_DIR, "vj146a2_2023_settlement_panel_fe_summary.md")

missing_panels <- VJ_PANEL_FILES[!file.exists(VJ_PANEL_FILES)]
if (length(missing_panels) > 0) {
  stop("Missing VJ panel files:\n  - ", paste(missing_panels, collapse = "\n  - "))
}
if (!file.exists(GATE_FILE)) stop("Input not found: ", GATE_FILE)
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

COVERAGE_MIN <- as.numeric(Sys.getenv("VJ146A2_PANEL_FE_COVERAGE_MIN", "0.50"))
POP_MIN <- as.numeric(Sys.getenv("VJ146A2_PANEL_FE_POP_MIN", "100"))
STRICT_DARK_MAX <- as.numeric(Sys.getenv("VJ146A2_PANEL_FE_STRICT_DARK_MAX", "0.05"))
MOSTLY_DARK_MAX <- as.numeric(Sys.getenv("VJ146A2_PANEL_FE_MOSTLY_DARK_MAX", "0.20"))

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
    is.na(x), "NA",
    ifelse(x < 0.01, "<0.01", ifelse(x < 0.05, "<0.05", fmt_num(x, 3)))
  )
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

weighted_cor <- function(x, y, w) {
  ok <- is.finite(x) & is.finite(y) & is.finite(w) & w > 0
  x <- x[ok]
  y <- y[ok]
  w <- w[ok]
  if (length(x) < 3) return(NA_real_)
  mx <- sum(w * x) / sum(w)
  my <- sum(w * y) / sum(w)
  cov_xy <- sum(w * (x - mx) * (y - my))
  vx <- sum(w * (x - mx)^2)
  vy <- sum(w * (y - my)^2)
  if (vx <= 0 || vy <= 0) return(NA_real_)
  cov_xy / sqrt(vx * vy)
}

weighted_residualize <- function(v, Z, w) {
  if (is.null(Z) || ncol(Z) == 0) return(as.numeric(v))
  beta <- solve(crossprod(Z, Z * w), crossprod(Z, v * w))
  as.numeric(v - Z %*% beta)
}

weighted_demean_by_id <- function(dt, cols, weight_col = "w") {
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

within_lpm <- function(data, outcome, controls = character(), weight_col = "w", model_label) {
  needed <- c("settlement_id", "local_overpass_date", "shed_share", outcome, controls, weight_col)
  dt <- as.data.table(data[, needed, with = FALSE])
  dt <- dt[is.finite(get(outcome)) & is.finite(shed_share) & is.finite(get(weight_col)) & get(weight_col) > 0]

  obs_by_settlement <- dt[, .N, by = settlement_id]
  keep_ids <- obs_by_settlement[N >= 2, settlement_id]
  dt <- dt[settlement_id %in% keep_ids]

  formula_rhs <- paste(c("shed_share", controls), collapse = " + ")
  mm <- model.matrix(as.formula(paste("~", formula_rhs)), data = dt)
  mm <- mm[, colnames(mm) != "(Intercept)", drop = FALSE]
  colnames(mm) <- make.names(colnames(mm), unique = TRUE)

  mm_dt <- as.data.table(mm)
  dt <- cbind(dt, mm_dt)
  x_cols <- colnames(mm)
  dm_cols <- weighted_demean_by_id(dt, c(outcome, x_cols), weight_col = weight_col)
  y_dm_col <- paste0(outcome, "_dm")
  x_dm_cols <- paste0(x_cols, "_dm")

  y <- dt[[y_dm_col]]
  X <- as.matrix(dt[, ..x_dm_cols])
  colnames(X) <- x_cols
  w <- dt[[weight_col]]

  nonzero <- apply(X, 2, function(z) stats::sd(z, na.rm = TRUE) > 1e-12)
  X <- X[, nonzero, drop = FALSE]
  x_cols <- colnames(X)

  qrx <- qr(X * sqrt(w))
  keep <- sort(qrx$pivot[seq_len(qrx$rank)])
  X <- X[, keep, drop = FALSE]
  x_cols <- colnames(X)

  xtwx <- crossprod(X, X * w)
  xtwy <- crossprod(X, y * w)
  beta <- as.numeric(solve(xtwx, xtwy))
  names(beta) <- x_cols
  resid <- as.numeric(y - X %*% beta)
  vc <- cluster_vcov(X, resid, w, dt$local_overpass_date)
  se <- sqrt(diag(vc))
  names(se) <- x_cols

  coef_name <- "shed_share"
  if (!coef_name %in% names(beta)) {
    stop("shed_share coefficient was dropped as collinear in model: ", model_label)
  }

  est <- beta[[coef_name]]
  est_se <- se[[coef_name]]
  t_stat <- est / est_se
  cluster_df <- uniqueN(dt$local_overpass_date) - 1L
  ci <- est + c(-1, 1) * stats::qt(0.975, df = cluster_df) * est_se
  p_value <- 2 * stats::pt(-abs(t_stat), df = cluster_df)

  shed_x <- X[, coef_name]
  other_x <- X[, colnames(X) != coef_name, drop = FALSE]
  y_partial <- weighted_residualize(y, other_x, w)
  shed_partial <- weighted_residualize(shed_x, other_x, w)
  partial_corr_shed <- weighted_cor(y_partial, shed_partial, w)
  partial_r2_shed <- partial_corr_shed^2

  tss <- sum(w * y^2, na.rm = TRUE)
  rss <- sum(w * resid^2, na.rm = TRUE)

  data.frame(
    outcome = outcome,
    model = model_label,
    weight = weight_col,
    n_rows = nrow(dt),
    n_settlements = uniqueN(dt$settlement_id),
    n_dates = uniqueN(dt$local_overpass_date),
    effect_pp_per_10pp_mlr = est * 10,
    se_cluster_date_pp = est_se * 10,
    ci_low_pp = ci[[1]] * 10,
    ci_high_pp = ci[[2]] * 10,
    z_stat = t_stat,
    cluster_df = cluster_df,
    p_value = p_value,
    model_within_r2 = 1 - rss / tss,
    partial_corr_shed = partial_corr_shed,
    partial_r2_shed = partial_r2_shed,
    controls = ifelse(length(controls) == 0, "Settlement FE only", paste(c("Settlement FE", controls), collapse = " + ")),
    stringsAsFactors = FALSE
  )
}

message("Loading Eskom/VJ national pass-night gate file.")
gate <- fread(GATE_FILE) %>%
  mutate(
    date = as.Date(date),
    local_overpass_date = as.Date(local_overpass_date)
  ) %>%
  filter(gate_tier == "pass", is.finite(shed_share_1_2am_primary)) %>%
  select(date, local_overpass_date, shed_share = shed_share_1_2am_primary, observed_demand_share)

message("Loading settlement-day VJ parquets.")
panel <- rbindlist(lapply(VJ_PANEL_FILES, function(path) {
  as.data.table(arrow::read_parquet(
    path,
    col_select = c("settlement_id", "date", "coverage", "p_lit_sett", "population", "electrified_best")
  ))
}), use.names = TRUE, fill = TRUE)

panel[, settlement_id := as.character(settlement_id)]
panel[, date := as.Date(date)]
panel[, population := as.numeric(population)]
panel[, coverage := as.numeric(coverage)]
panel[, p_lit_sett := as.numeric(p_lit_sett)]

message("Building settlement panel sample.")
panel <- panel %>%
  filter(
    electrified_best == 1,
    population > POP_MIN,
    coverage >= COVERAGE_MIN,
    is.finite(p_lit_sett),
    is.finite(population)
  ) %>%
  inner_join(gate, by = "date") %>%
  mutate(
    strict_dark = as.integer(p_lit_sett < STRICT_DARK_MAX),
    mostly_dark = as.integer(p_lit_sett < MOSTLY_DARK_MAX),
    month_fe = factor(format(local_overpass_date, "%Y-%m")),
    dow_fe = factor(
      weekdays(local_overpass_date),
      levels = c("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
    ),
    quarter_fe = factor(paste0("Q", ((as.integer(format(local_overpass_date, "%m")) - 1) %/% 3) + 1)),
    w_population = population,
    w_unweighted = 1
  ) %>%
  as.data.table()

sample_summary <- data.frame(
  metric = c(
    "coverage_min",
    "population_min",
    "pass_dates",
    "panel_rows",
    "settlements",
    "mean_rows_per_settlement",
    "median_rows_per_settlement",
    "weighted_mean_strict_dark",
    "weighted_mean_mostly_dark",
    "mean_mlr_shed_share"
  ),
  value = c(
    COVERAGE_MIN,
    POP_MIN,
    uniqueN(panel$local_overpass_date),
    nrow(panel),
    uniqueN(panel$settlement_id),
    mean(panel[, .N, by = settlement_id]$N),
    stats::median(panel[, .N, by = settlement_id]$N),
    stats::weighted.mean(panel$strict_dark, panel$w_population),
    stats::weighted.mean(panel$mostly_dark, panel$w_population),
    mean(unique(panel[, .(local_overpass_date, shed_share)])$shed_share)
  )
)

message("Estimating within-settlement panel models with date-clustered SEs.")
model_specs <- list(
  list(label = "Settlement FE only", controls = character()),
  list(label = "Settlement FE + month FE", controls = c("month_fe")),
  list(label = "Settlement FE + DOW FE", controls = c("dow_fe")),
  list(label = "Settlement FE + month + DOW FE", controls = c("month_fe", "dow_fe"))
)

outcomes <- c("strict_dark", "mostly_dark")
weights <- c("w_population", "w_unweighted")

results <- rbindlist(lapply(outcomes, function(outcome) {
  rbindlist(lapply(weights, function(weight_col) {
    rbindlist(lapply(model_specs, function(spec) {
      within_lpm(panel, outcome, controls = spec$controls, weight_col = weight_col, model_label = spec$label)
    }), use.names = TRUE)
  }), use.names = TRUE)
}), use.names = TRUE)

results[, outcome_label := fifelse(outcome == "strict_dark", "Strict dark: p_lit < 0.05", "Mostly dark: p_lit < 0.20")]
results[, weight_label := fifelse(weight == "w_population", "Population-weighted", "Unweighted")]

message("Writing outputs.")
fwrite(results, OUT_RESULTS)
fwrite(sample_summary, OUT_SAMPLE)

plot_df <- results %>%
  filter(weight == "w_population") %>%
  mutate(
    outcome_short = ifelse(outcome == "strict_dark", "Strict dark", "Mostly dark"),
    model = factor(
      model,
      levels = rev(c(
        "Settlement FE only",
        "Settlement FE + month FE",
        "Settlement FE + DOW FE",
        "Settlement FE + month + DOW FE"
      ))
    ),
    outcome_short = factor(outcome_short, levels = c("Mostly dark", "Strict dark"))
  )

color_strict <- "#B22222"
color_mostly <- "#E69F00"

p <- ggplot(plot_df, aes(x = effect_pp_per_10pp_mlr, y = model, color = outcome_short)) +
  geom_vline(xintercept = 0, linewidth = 0.35, color = "#4A5568") +
  geom_errorbar(
    aes(xmin = ci_low_pp, xmax = ci_high_pp),
    orientation = "y",
    width = 0.16,
    linewidth = 0.7,
    position = position_dodge(width = 0.52)
  ) +
  geom_point(size = 2.1, position = position_dodge(width = 0.52)) +
  scale_color_manual(values = c("Strict dark" = color_strict, "Mostly dark" = color_mostly)) +
  scale_x_continuous(labels = function(x) paste0(fmt_num(x, 1), " pp")) +
  labs(
    title = "Settlement Fixed-Effects Robustness",
    subtitle = "Within-settlement LPM; standard errors clustered by local overpass date",
    x = "Effect per 10 pp Eskom MLR",
    y = NULL,
    color = NULL
  ) +
  theme_report()

ggsave(OUT_FIG, p, width = 8.1, height = 4.8, dpi = 300)

main <- results %>%
  filter(weight == "w_population", model == "Settlement FE + month + DOW FE") %>%
  arrange(outcome)

md <- c(
  "# VJ146A2 Settlement-Panel Fixed-Effects Robustness",
  "",
  paste0("- Date: ", Sys.Date()),
  paste0("- Input VJ panel directory: `", VJ_PANEL_DIR, "`"),
  paste0("- Input gate file: `", GATE_FILE, "`"),
  paste0("- Output directory: `", OUT_DIR, "`"),
  "",
  "## Design",
  "",
  "This appendix-style robustness check estimates a settlement-level within-group linear probability model. The dependent variable is a settlement-night binary darkness indicator. The key regressor is national Eskom MLR shed share on the matched local overpass date.",
  "",
  "The preferred panel robustness specification is:",
  "",
  "`dark_it = beta * MLR_t + settlement FE_i + month FE_t + day-of-week FE_t + error_it`",
  "",
  "Because Eskom MLR varies only by date, all standard errors are clustered by local overpass date. This is essential: settlement-night rows do not represent independent national load-shedding shocks.",
  "",
  "## Sample",
  "",
  paste0("- Pass dates: ", sample_summary$value[sample_summary$metric == "pass_dates"], "."),
  paste0("- Settlement-night rows: ", format(as.numeric(sample_summary$value[sample_summary$metric == "panel_rows"]), big.mark = ","), "."),
  paste0("- Settlements: ", format(as.numeric(sample_summary$value[sample_summary$metric == "settlements"]), big.mark = ","), "."),
  paste0("- Coverage rule: settlement-night coverage >= ", COVERAGE_MIN, "."),
  paste0("- Population rule: population > ", POP_MIN, "."),
  "",
  "## Preferred Population-Weighted Result",
  "",
  paste0(
    "- Strict dark: effect ",
    fmt_num(main$effect_pp_per_10pp_mlr[main$outcome == "strict_dark"], 3),
    " pp per 10 pp MLR; date-clustered SE ",
    fmt_num(main$se_cluster_date_pp[main$outcome == "strict_dark"], 3),
    "; 95% CI [",
    fmt_num(main$ci_low_pp[main$outcome == "strict_dark"], 3),
    ", ",
    fmt_num(main$ci_high_pp[main$outcome == "strict_dark"], 3),
    "]; p ",
    fmt_p(main$p_value[main$outcome == "strict_dark"]),
    "; within R2 ",
    fmt_num(main$model_within_r2[main$outcome == "strict_dark"], 4),
    "; partial correlation ",
    fmt_num(main$partial_corr_shed[main$outcome == "strict_dark"], 3),
    "."
  ),
  paste0(
    "- Mostly dark: effect ",
    fmt_num(main$effect_pp_per_10pp_mlr[main$outcome == "mostly_dark"], 3),
    " pp per 10 pp MLR; date-clustered SE ",
    fmt_num(main$se_cluster_date_pp[main$outcome == "mostly_dark"], 3),
    "; 95% CI [",
    fmt_num(main$ci_low_pp[main$outcome == "mostly_dark"], 3),
    ", ",
    fmt_num(main$ci_high_pp[main$outcome == "mostly_dark"], 3),
    "]; p ",
    fmt_p(main$p_value[main$outcome == "mostly_dark"]),
    "; within R2 ",
    fmt_num(main$model_within_r2[main$outcome == "mostly_dark"], 4),
    "; partial correlation ",
    fmt_num(main$partial_corr_shed[main$outcome == "mostly_dark"], 3),
    "."
  ),
  "",
  "## Interpretation",
  "",
  "The within-settlement estimator asks whether the same settlements are darker on nights with higher national Eskom MLR. It is a useful robustness check, but it should not replace the national-night validation headline because the treatment variable is national and the effective identifying variation is still date-level.",
  "",
  "The correct reading is therefore: the aggregate validation signal is also visible within settlements after absorbing permanent settlement differences and calendar controls."
)

writeLines(md, OUT_MD)

message("Done.")
message("Summary: ", OUT_MD)
