rm(list = ls())

# ============================================================
# 2023 VJ146A2 per-settlement MLR slope heterogeneity
# ============================================================
#
# Companion appendix-style robustness script. This script does not modify the
# national validation or settlement-FE scripts.
#
# Goal:
#   Estimate one simple MLR-darkness slope per settlement:
#
#     dark_it = alpha_i + beta_i * MLR_t + error_it
#
#   Then summarize the distribution of beta_i. This asks whether the national
#   validation signal is broad-based across settlements or concentrated in a
#   small subset of places.
#
# Run:
#   Rscript Builder/vj146a2_2023_per_settlement_slope_mlr_validation.R
#
# Outputs:
#   Map Data/settlement_day_outputs_vj146a2/
#     mlr_validation_per_settlement_slopes_2023_cov50/
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

GATE_DIR <- file.path(
  VJ_PANEL_DIR,
  Sys.getenv("VJ146A2_SETTLEMENT_SLOPE_GATE_SUBDIR", "mlr_validation_demand_gate_2023_cov50")
)

OUT_DIR <- file.path(
  VJ_PANEL_DIR,
  Sys.getenv("VJ146A2_SETTLEMENT_SLOPE_OUT_SUBDIR", "mlr_validation_per_settlement_slopes_2023_cov50")
)

GATE_FILE <- file.path(GATE_DIR, "vj146a2_2023_demand_gate_coverage.csv")

OUT_SLOPES <- file.path(OUT_DIR, "vj146a2_2023_per_settlement_slopes.csv")
OUT_SUMMARY <- file.path(OUT_DIR, "vj146a2_2023_per_settlement_slope_summary.csv")
OUT_FIG <- file.path(OUT_DIR, "vj146a2_per_settlement_slope_distribution.png")
OUT_MD <- file.path(OUT_DIR, "vj146a2_2023_per_settlement_slope_summary.md")

missing_panels <- VJ_PANEL_FILES[!file.exists(VJ_PANEL_FILES)]
if (length(missing_panels) > 0) {
  stop("Missing VJ panel files:\n  - ", paste(missing_panels, collapse = "\n  - "))
}
if (!file.exists(GATE_FILE)) stop("Input not found: ", GATE_FILE)
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

EXCESS_LIT_FLAGS_FILE <- Sys.getenv("VJ146A2_EXCESS_LIT_FLAGS_FILE", "")
EXCESS_LIT_SCENARIO <- Sys.getenv("VJ146A2_EXCESS_LIT_SCENARIO", "annual_q3_plus_1p5_iqr")
COVERAGE_MIN <- as.numeric(Sys.getenv("VJ146A2_SETTLEMENT_SLOPE_COVERAGE_MIN", "0.50"))
POP_MIN <- as.numeric(Sys.getenv("VJ146A2_SETTLEMENT_SLOPE_POP_MIN", "100"))
MIN_OBS <- as.integer(Sys.getenv("VJ146A2_SETTLEMENT_SLOPE_MIN_OBS", "50"))
NW_LAG <- as.integer(Sys.getenv("VJ146A2_SETTLEMENT_SLOPE_NW_LAG", "7"))
STRICT_DARK_MAX <- as.numeric(Sys.getenv("VJ146A2_SETTLEMENT_SLOPE_STRICT_DARK_MAX", "0.05"))
MOSTLY_DARK_MAX <- as.numeric(Sys.getenv("VJ146A2_SETTLEMENT_SLOPE_MOSTLY_DARK_MAX", "0.20"))

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

safe_nw <- function(d, outcome) {
  if (nrow(d) < MIN_OBS || stats::sd(d[[outcome]], na.rm = TRUE) <= 0 || stats::sd(d$shed_share, na.rm = TRUE) <= 0) {
    return(c(se_pp = NA_real_, p_value = NA_real_))
  }

  fit <- tryCatch(lm(as.formula(paste(outcome, "~ shed_share")), data = d), error = function(e) e)
  if (inherits(fit, "error")) return(c(se_pp = NA_real_, p_value = NA_real_))

  out <- tryCatch({
    vc <- sandwich::NeweyWest(fit, lag = min(NW_LAG, nrow(d) - 2L), prewhite = FALSE, adjust = TRUE)
    ct <- lmtest::coeftest(fit, vcov. = vc)
    c(se_pp = unname(ct["shed_share", "Std. Error"]) * 10, p_value = unname(ct["shed_share", "Pr(>|t|)"]))
  }, error = function(e) c(se_pp = NA_real_, p_value = NA_real_))
  out
}

settlement_slope <- function(x, y) {
  ok <- is.finite(x) & is.finite(y)
  x <- x[ok]
  y <- y[ok]
  if (length(x) < MIN_OBS || stats::sd(x) <= 0) return(NA_real_)
  if (stats::sd(y) <= 0) return(0)
  as.numeric(stats::cov(x, y) / stats::var(x))
}

load_exclusion_dates <- function(path, scenario) {
  if (!nzchar(path)) return(as.Date(character()))
  if (!file.exists(path)) stop("Excess-lit flag file not found: ", path)
  read.csv(path, stringsAsFactors = FALSE) %>%
    mutate(date = as.Date(date)) %>%
    filter(scenario == !!scenario, remove) %>%
    pull(date)
}

summarise_outcome <- function(slopes, outcome_stub, label) {
  slope_col <- paste0("slope_", outcome_stub, "_pp_per_10pp")
  p_col <- paste0("p_", outcome_stub)
  n_dark_col <- paste0("n_", outcome_stub)
  baseline_col <- paste0("mean_", outcome_stub)
  ok <- is.finite(slopes[[slope_col]])
  positive <- ok & slopes[[slope_col]] > 0
  sig_positive <- positive & is.finite(slopes[[p_col]]) & slopes[[p_col]] < 0.05
  wq <- weighted_quantile(slopes[[slope_col]][ok], slopes$population[ok], c(0.10, 0.25, 0.50, 0.75, 0.90))

  data.frame(
    outcome = outcome_stub,
    outcome_label = label,
    settlements_total = nrow(slopes),
    settlements_estimable = sum(ok),
    settlements_with_any_dark = sum(slopes[[n_dark_col]] > 0, na.rm = TRUE),
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
    weighted_mean_baseline_dark = stats::weighted.mean(slopes[[baseline_col]][ok], slopes$population[ok], na.rm = TRUE),
    stringsAsFactors = FALSE
  )
}

message("Loading Eskom/VJ national pass-night gate file.")
exclusion_dates <- load_exclusion_dates(EXCESS_LIT_FLAGS_FILE, EXCESS_LIT_SCENARIO)
gate <- fread(GATE_FILE) %>%
  mutate(date = as.Date(date), local_overpass_date = as.Date(local_overpass_date)) %>%
  filter(gate_tier == "pass", is.finite(shed_share_1_2am_primary), !date %in% exclusion_dates) %>%
  select(date, local_overpass_date, shed_share = shed_share_1_2am_primary)

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

message("Building per-settlement sample.")
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
    mostly_dark = as.integer(p_lit_sett < MOSTLY_DARK_MAX)
  ) %>%
  as.data.table()

message("Estimating one MLR slope per settlement.")
slopes <- panel[, {
  d <- .SD
  strict_nw <- safe_nw(d, "strict_dark")
  mostly_nw <- safe_nw(d, "mostly_dark")

  .(
    population = max(population, na.rm = TRUE),
    n_obs = .N,
    mean_mlr = mean(shed_share, na.rm = TRUE),
    mean_strict = mean(strict_dark, na.rm = TRUE),
    mean_mostly = mean(mostly_dark, na.rm = TRUE),
    n_strict = sum(strict_dark == 1, na.rm = TRUE),
    n_mostly = sum(mostly_dark == 1, na.rm = TRUE),
    slope_strict_pp_per_10pp = settlement_slope(shed_share, strict_dark) * 10,
    slope_mostly_pp_per_10pp = settlement_slope(shed_share, mostly_dark) * 10,
    se_strict_nw_pp = strict_nw[["se_pp"]],
    p_strict = strict_nw[["p_value"]],
    se_mostly_nw_pp = mostly_nw[["se_pp"]],
    p_mostly = mostly_nw[["p_value"]]
  )
}, by = settlement_id]

slopes <- slopes[n_obs >= MIN_OBS]

summary <- rbind(
  summarise_outcome(slopes, "strict", "Strict dark: p_lit < 0.05"),
  summarise_outcome(slopes, "mostly", "Mostly dark: p_lit < 0.20")
)

message("Writing outputs.")
fwrite(slopes, OUT_SLOPES)
fwrite(summary, OUT_SUMMARY)

plot_df <- rbind(
  slopes[, .(
    settlement_id,
    population,
    outcome = "Strict dark",
    slope_pp = slope_strict_pp_per_10pp
  )],
  slopes[, .(
    settlement_id,
    population,
    outcome = "Mostly dark",
    slope_pp = slope_mostly_pp_per_10pp
  )]
)
plot_df <- plot_df[is.finite(slope_pp)]
plot_df[, outcome := factor(outcome, levels = c("Mostly dark", "Strict dark"))]

plot_limits <- weighted_quantile(plot_df$slope_pp, plot_df$population, c(0.01, 0.99))
summary_plot <- summary %>%
  transmute(
    outcome = ifelse(outcome == "strict", "Strict dark", "Mostly dark"),
    weighted_mean = population_weighted_mean_slope_pp,
    share_pop_positive = share_population_positive
  ) %>%
  mutate(outcome = factor(outcome, levels = c("Mostly dark", "Strict dark")))

color_strict <- "#B22222"
color_mostly <- "#E69F00"

p <- ggplot(plot_df, aes(x = slope_pp, weight = population, fill = outcome)) +
  geom_vline(xintercept = 0, color = "#2D3748", linewidth = 0.35) +
  geom_histogram(bins = 70, alpha = 0.78, color = "white", linewidth = 0.12) +
  geom_vline(
    data = summary_plot,
    aes(xintercept = weighted_mean, color = outcome),
    linewidth = 0.8,
    linetype = "dashed"
  ) +
  facet_wrap(~ outcome, ncol = 1, scales = "free_y") +
  coord_cartesian(xlim = plot_limits) +
  scale_fill_manual(values = c("Strict dark" = color_strict, "Mostly dark" = color_mostly)) +
  scale_color_manual(values = c("Strict dark" = "#7A1116", "Mostly dark" = "#9A5F00")) +
  scale_x_continuous(labels = function(x) paste0(fmt_num(x, 1), " pp")) +
  scale_y_continuous(labels = function(x) paste0(fmt_num(x / 1e6, 0), "M")) +
  labs(
    title = "Settlement-level slopes show a positive tail and a large zero-response mass",
    subtitle = "Population-weighted histogram, trimmed to the weighted 1st-99th percentile range; dashed line is the population-weighted mean",
    x = "Settlement-level effect per 10 pp Eskom MLR",
    y = "Population mass",
    fill = NULL,
    color = NULL
  ) +
  theme_report(base_size = 10)

ggsave(OUT_FIG, p, width = 8.0, height = 6.3, dpi = 300)

strict <- summary %>% filter(outcome == "strict")
mostly <- summary %>% filter(outcome == "mostly")

md <- c(
  "# VJ146A2 Per-Settlement MLR Slope Heterogeneity",
  "",
  paste0("- Date: ", Sys.Date()),
  paste0("- Input gate file: `", GATE_FILE, "`"),
  paste0("- Output directory: `", OUT_DIR, "`"),
  paste0("- Minimum observations per settlement: ", MIN_OBS, "."),
  paste0("- Coverage rule: settlement-night coverage >= ", COVERAGE_MIN, "."),
  paste0("- Population rule: population > ", POP_MIN, "."),
  "",
  "## Design",
  "",
  "This diagnostic estimates one simple MLR-darkness slope per settlement: `dark_it = alpha_i + beta_i * MLR_t + error_it`. It then summarizes the distribution of settlement-level slopes. Constant-outcome settlements are retained with zero slopes, because never being observed dark is informative for breadth.",
  "",
  "The result is a heterogeneity diagnostic, not a replacement for the national validation regression.",
  "",
  "## Strict Dark",
  "",
  paste0("- Estimable settlements: ", format(strict$settlements_estimable, big.mark = ","), "."),
  paste0("- Population-weighted mean slope: ", fmt_num(strict$population_weighted_mean_slope_pp, 3), " pp per 10 pp MLR."),
  paste0("- Median settlement slope: ", fmt_num(strict$median_slope_pp, 3), " pp."),
  paste0("- Weighted median slope: ", fmt_num(strict$weighted_median_slope_pp, 3), " pp."),
  paste0("- Share of settlements with positive slope: ", fmt_pct(strict$share_settlements_positive), "."),
  paste0("- Share of population in positive-slope settlements: ", fmt_pct(strict$share_population_positive), "."),
  paste0("- Share of population in significantly positive settlements: ", fmt_pct(strict$share_population_sig_positive), "."),
  "",
  "## Mostly Dark",
  "",
  paste0("- Estimable settlements: ", format(mostly$settlements_estimable, big.mark = ","), "."),
  paste0("- Population-weighted mean slope: ", fmt_num(mostly$population_weighted_mean_slope_pp, 3), " pp per 10 pp MLR."),
  paste0("- Median settlement slope: ", fmt_num(mostly$median_slope_pp, 3), " pp."),
  paste0("- Weighted median slope: ", fmt_num(mostly$weighted_median_slope_pp, 3), " pp."),
  paste0("- Share of settlements with positive slope: ", fmt_pct(mostly$share_settlements_positive), "."),
  paste0("- Share of population in positive-slope settlements: ", fmt_pct(mostly$share_population_positive), "."),
  paste0("- Share of population in significantly positive settlements: ", fmt_pct(mostly$share_population_sig_positive), "."),
  "",
  "## Interpretation",
  "",
  "The diagnostic asks whether the national validation signal is broad-based. The key quantities are the share of population living in positive-slope settlements and the population-weighted mean local slope. Individual settlement p-values should not be overinterpreted because Eskom MLR is a national date-level regressor and nearby dates are serially persistent."
)

writeLines(md, OUT_MD)

message("Done.")
message("Summary: ", OUT_MD)
