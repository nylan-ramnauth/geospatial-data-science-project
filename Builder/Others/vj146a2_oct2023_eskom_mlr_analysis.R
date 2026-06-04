rm(list = ls())

# ============================================================
# Compare October 2023 VJ146A2 settlement-day signal to Eskom MLR
# Diagnostic/trial path only. Does not touch production VNP files.
# ============================================================
#
# Inputs:
#   - Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_cov_yearlykeep_2023-10.parquet
#   - ../pypsa-earth/data/za_validation/eskom_2023_hourly_clean.csv
#   - Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_full_col.gpkg
#
# Outputs:
#   - Map Data/settlement_day_outputs_vj146a2/vj146a2_oct2023_eskom_national_panel.csv
#   - Map Data/settlement_day_outputs_vj146a2/vj146a2_oct2023_eskom_large_dark_events.csv
#   - Map Data/settlement_day_outputs_vj146a2/vj146a2_oct2023_eskom_correlations.csv
#   - Map Data/settlement_day_outputs_vj146a2/vj146a2_oct2023_eskom_timeseries.png
#   - Map Data/settlement_day_outputs_vj146a2/vj146a2_oct2023_eskom_scatter.png
#   - Map Data/settlement_day_outputs_vj146a2/vj146a2_oct2023_eskom_large_events.png
#
# Run:
#   Rscript Builder/Others/vj146a2_oct2023_eskom_mlr_analysis.R
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(arrow)
  library(dplyr)
  library(sf)
  library(ggplot2)
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

OUT_DIR <- file.path(BASE_PATH, "Map Data", "settlement_day_outputs_vj146a2")
OUT_PANEL <- file.path(OUT_DIR, "vj146a2_oct2023_eskom_national_panel.csv")
OUT_EVENTS <- file.path(OUT_DIR, "vj146a2_oct2023_eskom_large_dark_events.csv")
OUT_CORR <- file.path(OUT_DIR, "vj146a2_oct2023_eskom_correlations.csv")
OUT_TS <- file.path(OUT_DIR, "vj146a2_oct2023_eskom_timeseries.png")
OUT_SCATTER <- file.path(OUT_DIR, "vj146a2_oct2023_eskom_scatter.png")
OUT_EVENTS_PNG <- file.path(OUT_DIR, "vj146a2_oct2023_eskom_large_events.png")

for (p in c(VJ_PARQUET, ESKOM_HOURLY, SETT_GPKG)) {
  if (!file.exists(p)) stop("Input not found: ", p)
}

safe_weighted_mean <- function(x, w) {
  ok <- is.finite(x) & is.finite(w) & w > 0
  if (!any(ok)) return(NA_real_)
  weighted.mean(x[ok], w[ok])
}

scale01 <- function(x) {
  rng <- range(x, na.rm = TRUE)
  if (!all(is.finite(rng)) || diff(rng) == 0) return(rep(NA_real_, length(x)))
  (x - rng[1]) / diff(rng)
}

reg_row <- function(data, y, x) {
  sub <- data %>%
    select(y = all_of(y), x = all_of(x)) %>%
    filter(is.finite(y), is.finite(x))

  if (nrow(sub) < 3 || length(unique(sub$x)) < 2 || length(unique(sub$y)) < 2) {
    return(data.frame(
      outcome = y,
      predictor = x,
      n = nrow(sub),
      cor = NA_real_,
      slope = NA_real_,
      p_value = NA_real_,
      r2 = NA_real_
    ))
  }

  fit <- lm(y ~ x, data = sub)
  sm <- summary(fit)
  data.frame(
    outcome = y,
    predictor = x,
    n = nrow(sub),
    cor = cor(sub$y, sub$x),
    slope = coef(fit)[["x"]],
    p_value = sm$coefficients["x", "Pr(>|t|)"],
    r2 = sm$r.squared
  )
}

# -----------------------------
# 1) Eskom daily 01:00-02:00 panel
# -----------------------------
eskom <- read.csv(ESKOM_HOURLY, check.names = FALSE)
eskom$datetime <- as.POSIXct(eskom[["Date Time Hour Beginning"]], tz = "Africa/Johannesburg")
if (any(is.na(eskom$datetime))) stop("Failed to parse Eskom datetime column.")

eskom_daily <- eskom %>%
  mutate(
    date = as.Date(datetime),
    hour = as.integer(format(datetime, "%H"))
  ) %>%
  filter(date >= as.Date("2023-10-01"), date <= as.Date("2023-10-31")) %>%
  filter(hour %in% c(1, 2)) %>%
  group_by(date) %>%
  summarise(
    n_eskom_hours = n(),
    mlr_mean_1_2am = mean(`Manual Load_Reduction(MLR)`, na.rm = TRUE),
    mlr_max_1_2am = max(`Manual Load_Reduction(MLR)`, na.rm = TRUE),
    mlr_sum_1_2am_mwh = sum(`Manual Load_Reduction(MLR)`, na.rm = TRUE),
    contracted_demand_mean_1_2am = mean(`RSA Contracted Demand`, na.rm = TRUE),
    residual_demand_mean_1_2am = mean(`Residual Demand`, na.rm = TRUE),
    ils_mean_1_2am = mean(`ILS Usage`, na.rm = TRUE),
    ios_mean_1_2am = mean(`IOS Excl ILS and MLR`, na.rm = TRUE),
    shed_share_mean = ifelse(
      mlr_mean_1_2am + contracted_demand_mean_1_2am > 0,
      mlr_mean_1_2am / (mlr_mean_1_2am + contracted_demand_mean_1_2am),
      NA_real_
    ),
    shed_share_max = ifelse(
      mlr_max_1_2am + contracted_demand_mean_1_2am > 0,
      mlr_max_1_2am / (mlr_max_1_2am + contracted_demand_mean_1_2am),
      NA_real_
    ),
    .groups = "drop"
  )

# -----------------------------
# 2) VJ national daily signal and large-settlement events
# -----------------------------
sett_day <- arrow::read_parquet(VJ_PARQUET) %>%
  mutate(
    settlement_id = as.character(settlement_id),
    date = as.Date(date),
    mostly_dark = p_lit_sett < 0.20
  )

sett_names <- sf::st_read(SETT_GPKG, quiet = TRUE) %>%
  sf::st_drop_geometry() %>%
  mutate(settlement_id = as.character(settlement_id)) %>%
  select(settlement_id, village_name, admin_cgaz_1, admin_cgaz_2)

vj_daily <- sett_day %>%
  group_by(date) %>%
  summarise(
    n_settlements = n(),
    population_sum = sum(population, na.rm = TRUE),
    mean_coverage = mean(coverage, na.rm = TRUE),
    mean_p_lit_sett = mean(p_lit_sett, na.rm = TRUE),
    median_p_lit_sett = median(p_lit_sett, na.rm = TRUE),
    popw_mean_p_lit_sett = safe_weighted_mean(p_lit_sett, population),
    share_dark = mean(dark, na.rm = TRUE),
    popw_share_dark = safe_weighted_mean(as.numeric(dark), population),
    share_mostly_dark = mean(mostly_dark, na.rm = TRUE),
    popw_share_mostly_dark = safe_weighted_mean(as.numeric(mostly_dark), population),
    mean_mean_rad_sett = mean(mean_rad_sett, na.rm = TRUE),
    median_mean_rad_sett = median(mean_rad_sett, na.rm = TRUE),
    popw_mean_rad_sett = safe_weighted_mean(mean_rad_sett, population),
    large_dark_events_10k = sum(population >= 10000 & dark, na.rm = TRUE),
    large_dark_events_50k = sum(population >= 50000 & dark, na.rm = TRUE),
    large_dark_events_100k = sum(population >= 100000 & dark, na.rm = TRUE),
    large_mostly_dark_events_10k = sum(population >= 10000 & mostly_dark, na.rm = TRUE),
    large_mostly_dark_events_50k = sum(population >= 50000 & mostly_dark, na.rm = TRUE),
    large_mostly_dark_events_100k = sum(population >= 100000 & mostly_dark, na.rm = TRUE),
    pop_strict_dark_ge10k = sum(ifelse(population >= 10000 & dark, population, 0), na.rm = TRUE),
    pop_mostly_dark_ge10k = sum(ifelse(population >= 10000 & mostly_dark, population, 0), na.rm = TRUE),
    .groups = "drop"
  )

national_panel <- vj_daily %>%
  left_join(eskom_daily, by = "date") %>%
  arrange(date)

large_events <- sett_day %>%
  filter(population >= 10000, dark | mostly_dark) %>%
  left_join(sett_names, by = "settlement_id") %>%
  left_join(eskom_daily, by = "date") %>%
  mutate(
    event_class = case_when(
      dark ~ "strict_dark_p_lit_lt_0.05",
      mostly_dark ~ "mostly_dark_p_lit_lt_0.20",
      TRUE ~ NA_character_
    ),
    drop_from_month_median = NA_real_
  )

month_baseline <- sett_day %>%
  group_by(settlement_id) %>%
  summarise(month_median_p_lit = median(p_lit_sett, na.rm = TRUE), .groups = "drop")

large_events <- large_events %>%
  select(-drop_from_month_median) %>%
  left_join(month_baseline, by = "settlement_id") %>%
  mutate(drop_from_month_median = month_median_p_lit - p_lit_sett) %>%
  arrange(desc(population), date) %>%
  select(
    date,
    settlement_id,
    village_name,
    admin_cgaz_1,
    admin_cgaz_2,
    population,
    event_class,
    p_lit_sett,
    month_median_p_lit,
    drop_from_month_median,
    coverage,
    mean_rad_sett,
    median_rad_sett,
    mlr_mean_1_2am,
    mlr_max_1_2am,
    shed_share_mean
  )

# -----------------------------
# 3) Correlations and simple regressions
# -----------------------------
outcomes <- c(
  "popw_share_dark",
  "popw_share_mostly_dark",
  "share_dark",
  "share_mostly_dark",
  "popw_mean_p_lit_sett",
  "mean_p_lit_sett",
  "popw_mean_rad_sett",
  "large_dark_events_10k",
  "large_mostly_dark_events_10k",
  "pop_strict_dark_ge10k",
  "pop_mostly_dark_ge10k"
)

predictors <- c("mlr_mean_1_2am", "mlr_max_1_2am", "shed_share_mean")

correlations <- bind_rows(lapply(outcomes, function(y) {
  bind_rows(lapply(predictors, function(x) reg_row(national_panel, y, x)))
})) %>%
  arrange(outcome, predictor)

# -----------------------------
# 4) Plots
# -----------------------------
plot_panel <- national_panel %>%
  mutate(
    mlr_norm = scale01(mlr_mean_1_2am),
    mostly_dark_norm = scale01(popw_share_mostly_dark),
    dark_norm = scale01(popw_share_dark),
    inv_p_lit_norm = scale01(1 - popw_mean_p_lit_sett),
    inv_rad_norm = scale01(-popw_mean_rad_sett)
  )

ts_long <- bind_rows(
  plot_panel %>% select(date, value = mlr_norm) %>% mutate(metric = "MLR mean, 01:00-02:00"),
  plot_panel %>% select(date, value = mostly_dark_norm) %>% mutate(metric = "Pop-w mostly dark"),
  plot_panel %>% select(date, value = dark_norm) %>% mutate(metric = "Pop-w strict dark"),
  plot_panel %>% select(date, value = inv_p_lit_norm) %>% mutate(metric = "1 - pop-w p_lit")
)

p_ts <- ggplot(ts_long, aes(x = date, y = value, color = metric)) +
  geom_line(linewidth = 1) +
  geom_point(size = 2) +
  scale_y_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.25)) +
  labs(
    title = "October 2023 Eskom MLR vs VJ146A2 settlement signal",
    subtitle = "All series min-max scaled over available VJ dates; Eskom uses 01:00-02:00 SAST",
    x = NULL,
    y = "Scaled value"
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom")

p_scatter <- ggplot(national_panel, aes(x = mlr_mean_1_2am)) +
  geom_point(aes(y = popw_share_mostly_dark, color = "Mostly dark"), size = 2.3, alpha = 0.85) +
  geom_smooth(aes(y = popw_share_mostly_dark, color = "Mostly dark"), method = "lm", se = FALSE, linewidth = 0.8) +
  geom_point(aes(y = popw_share_dark, color = "Strict dark"), size = 2.3, alpha = 0.85) +
  geom_smooth(aes(y = popw_share_dark, color = "Strict dark"), method = "lm", se = FALSE, linewidth = 0.8) +
  labs(
    title = "VJ146A2 darkness share vs Eskom MLR",
    subtitle = "Daily national population-weighted settlement shares, October 2023",
    x = "Mean Eskom MLR, 01:00-02:00 (MW)",
    y = "Population-weighted share"
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom")

p_events <- ggplot(national_panel, aes(x = date)) +
  geom_col(aes(y = scale01(mlr_mean_1_2am)), fill = "grey75", width = 0.85) +
  geom_line(aes(y = scale01(large_mostly_dark_events_10k), color = "Large mostly-dark events >=10k"), linewidth = 1) +
  geom_point(aes(y = scale01(large_mostly_dark_events_10k), color = "Large mostly-dark events >=10k"), size = 2) +
  geom_line(aes(y = scale01(large_dark_events_10k), color = "Large strict-dark events >=10k"), linewidth = 1) +
  geom_point(aes(y = scale01(large_dark_events_10k), color = "Large strict-dark events >=10k"), size = 2) +
  labs(
    title = "Large-settlement dark events vs Eskom MLR",
    subtitle = "Grey bars: MLR mean scaled 0-1; lines: event counts scaled 0-1",
    x = NULL,
    y = "Scaled value"
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "bottom")

# -----------------------------
# 5) Write outputs
# -----------------------------
utils::write.csv(national_panel, OUT_PANEL, row.names = FALSE)
utils::write.csv(large_events, OUT_EVENTS, row.names = FALSE)
utils::write.csv(correlations, OUT_CORR, row.names = FALSE)

ggsave(OUT_TS, p_ts, width = 10, height = 5.5, dpi = 180)
ggsave(OUT_SCATTER, p_scatter, width = 7, height = 5.5, dpi = 180)
ggsave(OUT_EVENTS_PNG, p_events, width = 10, height = 5.5, dpi = 180)

message("Wrote national panel: ", OUT_PANEL)
message("Wrote large events: ", OUT_EVENTS)
message("Wrote correlations: ", OUT_CORR)
message("Wrote plot: ", OUT_TS)
message("Wrote plot: ", OUT_SCATTER)
message("Wrote plot: ", OUT_EVENTS_PNG)

message("Top correlations with MLR mean:")
print(correlations %>%
  filter(predictor == "mlr_mean_1_2am") %>%
  arrange(desc(abs(cor))) %>%
  head(12))

message("National panel head:")
print(head(national_panel, 10))
