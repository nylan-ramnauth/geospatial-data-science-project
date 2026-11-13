rm(list = ls())

# ============================================================
# Diagnose Cape Town Citywide Pixel-IQR Signal Against Schedule
# ============================================================
#
# Purpose:  Summarises daily citywide pixel-IQR dark signal from the
#           step-03 state rasters and compares it with total Cape Town
#           schedule area-minutes by date. This is a citywide diagnostic,
#           not the block-level schedule validation.
# Inputs:   - pixel_iqr_pipeline/data/daily_states/cape_town_pixel_iqr_state_YYYY-MM-DD.tif
#           - cape_town_schedule_validation/data/inputs/Loadshedding_schedule.csv
# Outputs:  - pixel_iqr_pipeline/reports/cape_town_pixel_iqr_citywide_schedule_signal_daily.csv
#           - pixel_iqr_pipeline/reports/cape_town_pixel_iqr_citywide_schedule_signal_regression.csv
#           - pixel_iqr_pipeline/reports/cape_town_pixel_iqr_citywide_schedule_signal_bins.csv
#           - pixel_iqr_pipeline/figures/cape_town_pixel_iqr_citywide_schedule_signal.png
#           - pixel_iqr_pipeline/figures/cape_town_pixel_iqr_citywide_schedule_signal_overlay.png
#           - pixel_iqr_pipeline/figures/cape_town_pixel_iqr_citywide_schedule_signal_scatter.png
#           - pixel_iqr_pipeline/figures/cape_town_pixel_iqr_citywide_schedule_signal_bins.png
# Run:      Rscript cape_town_schedule_validation/pixel_iqr_pipeline/scripts/diagnose_citywide_pixel_iqr_schedule_signal.R
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(terra)
  library(dplyr)
  library(tidyr)
  library(ggplot2)
})

# -----------------------------
# CONFIG
# -----------------------------
BASE_PATH <- here::here()
MODULE_DIR <- file.path(BASE_PATH, "cape_town_schedule_validation", "pixel_iqr_pipeline")

STATE_DIR <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_DAILY_STATE_DIR",
  file.path(MODULE_DIR, "data", "daily_states")
)
SCHEDULE_CSV <- Sys.getenv(
  "CAPE_TOWN_LOADSHEDDING_SCHEDULE_CSV",
  file.path(BASE_PATH, "cape_town_schedule_validation", "data", "inputs", "Loadshedding_schedule.csv")
)
REPORT_DIR <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_REPORT_DIR",
  file.path(MODULE_DIR, "reports")
)
FIGURE_DIR <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_FIGURE_DIR",
  file.path(MODULE_DIR, "figures")
)
dir.create(REPORT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(FIGURE_DIR, recursive = TRUE, showWarnings = FALSE)

MIN_OBSERVED_PIXELS <- suppressWarnings(as.numeric(Sys.getenv("VJ146A2_CITY_SIGNAL_MIN_OBSERVED", "1000")))
if (!is.finite(MIN_OBSERVED_PIXELS)) {
  stop("Invalid VJ146A2_CITY_SIGNAL_MIN_OBSERVED; expected finite numeric.")
}

DAILY_OUT <- file.path(REPORT_DIR, "cape_town_pixel_iqr_citywide_schedule_signal_daily.csv")
REGRESSION_OUT <- file.path(REPORT_DIR, "cape_town_pixel_iqr_citywide_schedule_signal_regression.csv")
BINS_OUT <- file.path(REPORT_DIR, "cape_town_pixel_iqr_citywide_schedule_signal_bins.csv")
FIGURE_OUT <- file.path(FIGURE_DIR, "cape_town_pixel_iqr_citywide_schedule_signal.png")
FIGURE_OVERLAY_OUT <- file.path(FIGURE_DIR, "cape_town_pixel_iqr_citywide_schedule_signal_overlay.png")
FIGURE_SCATTER_OUT <- file.path(FIGURE_DIR, "cape_town_pixel_iqr_citywide_schedule_signal_scatter.png")
FIGURE_BINS_OUT <- file.path(FIGURE_DIR, "cape_town_pixel_iqr_citywide_schedule_signal_bins.png")

# -----------------------------
# HELPERS
# -----------------------------
get_state_date <- function(path) {
  as.Date(sub("^cape_town_pixel_iqr_state_", "", sub("[.]tif$", "", basename(path))))
}

global_sum <- function(r, layer_name) {
  as.numeric(terra::global(r[[layer_name]], "sum", na.rm = TRUE)[1, 1])
}

fmt_pp <- function(x, digits = 2) {
  paste0(format(round(x, digits), nsmall = digits, trim = TRUE), " pp")
}

# -----------------------------
# 1) CITYWIDE DAILY PIXEL SIGNAL
# -----------------------------
state_files <- list.files(
  STATE_DIR,
  pattern = "^cape_town_pixel_iqr_state_[0-9]{4}-[0-9]{2}-[0-9]{2}[.]tif$",
  full.names = TRUE
)
if (length(state_files) == 0) {
  stop("No daily pixel-IQR state rasters found in: ", STATE_DIR)
}
state_files <- state_files[order(state_files)]

daily_signal <- lapply(state_files, function(path) {
  r <- terra::rast(path)
  required_layers <- c("observed_iqr", "dark_iqr", "bright_excluded_iqr", "rad_observed")
  missing_layers <- setdiff(required_layers, names(r))
  if (length(missing_layers) > 0) {
    stop("Missing layer(s) in ", basename(path), ": ", paste(missing_layers, collapse = ", "))
  }

  data.frame(
    date = get_state_date(path),
    observed_iqr = global_sum(r, "observed_iqr"),
    dark_iqr = global_sum(r, "dark_iqr"),
    bright_excluded_iqr = global_sum(r, "bright_excluded_iqr"),
    rad_observed = global_sum(r, "rad_observed")
  )
}) %>%
  bind_rows() %>%
  mutate(
    dark_share = ifelse(observed_iqr > 0, dark_iqr / observed_iqr, NA_real_),
    bright_share = ifelse(
      observed_iqr + bright_excluded_iqr > 0,
      bright_excluded_iqr / (observed_iqr + bright_excluded_iqr),
      NA_real_
    )
  )

# -----------------------------
# 2) CITYWIDE SCHEDULE INTENSITY
# -----------------------------
if (!file.exists(SCHEDULE_CSV)) {
  stop("Cape Town load-shedding schedule CSV not found: ", SCHEDULE_CSV)
}

schedule <- read.csv(SCHEDULE_CSV, stringsAsFactors = FALSE) %>%
  mutate(
    date = as.Date(Date),
    minutes = suppressWarnings(as.numeric(Minutes))
  ) %>%
  filter(!is.na(date), is.finite(minutes))

schedule_daily <- schedule %>%
  group_by(date) %>%
  summarise(
    scheduled_area_minutes = sum(minutes, na.rm = TRUE),
    scheduled_events = n(),
    scheduled_areas = n_distinct(Circuit),
    .groups = "drop"
  )

diagnostic <- daily_signal %>%
  left_join(schedule_daily, by = "date") %>%
  mutate(
    scheduled_area_minutes = coalesce(scheduled_area_minutes, 0),
    scheduled_events = coalesce(scheduled_events, 0L),
    scheduled_areas = coalesce(scheduled_areas, 0L),
    analysis_sample = is.finite(dark_share) & observed_iqr >= MIN_OBSERVED_PIXELS
  )

analysis <- diagnostic %>%
  filter(analysis_sample)
if (nrow(analysis) < 3) {
  stop("Too few analysis-sample days after observed-pixel filter.")
}

fit <- lm(dark_share ~ scheduled_area_minutes, data = analysis)
fit_summary <- summary(fit)
correlation <- cor(analysis$dark_share, analysis$scheduled_area_minutes, use = "complete.obs")

regression <- data.frame(
  min_observed_pixels = MIN_OBSERVED_PIXELS,
  n_days = nrow(analysis),
  correlation = correlation,
  r_squared = fit_summary$r.squared,
  intercept = unname(coef(fit)[1]),
  slope = unname(coef(fit)[2]),
  mean_dark_share_scheduled = mean(analysis$dark_share[analysis$scheduled_area_minutes > 0], na.rm = TRUE),
  mean_dark_share_not_scheduled = mean(analysis$dark_share[analysis$scheduled_area_minutes == 0], na.rm = TRUE)
)

write.csv(diagnostic, DAILY_OUT, row.names = FALSE)
write.csv(regression, REGRESSION_OUT, row.names = FALSE)

# -----------------------------
# 3) BINNED SUMMARY
# -----------------------------
baseline <- analysis %>%
  filter(scheduled_area_minutes == 0) %>%
  summarise(
    baseline_n = n(),
    baseline_mean_dark = mean(dark_share, na.rm = TRUE),
    baseline_se_dark = stats::sd(dark_share, na.rm = TRUE) / sqrt(baseline_n),
    .groups = "drop"
  )

positive_bins <- analysis %>%
  filter(scheduled_area_minutes > 0) %>%
  mutate(scheduled_bin = dplyr::ntile(scheduled_area_minutes, 10)) %>%
  group_by(scheduled_bin) %>%
  summarise(
    n = n(),
    mean_scheduled_area_minutes = mean(scheduled_area_minutes, na.rm = TRUE),
    mean_dark_share = mean(dark_share, na.rm = TRUE),
    se_dark_share = stats::sd(dark_share, na.rm = TRUE) / sqrt(n),
    .groups = "drop"
  ) %>%
  mutate(
    baseline_n = baseline$baseline_n,
    baseline_mean_dark = baseline$baseline_mean_dark,
    baseline_se_dark = baseline$baseline_se_dark,
    excess_dark_pp = (mean_dark_share - baseline_mean_dark) * 100,
    excess_se_pp = sqrt(se_dark_share^2 + baseline_se_dark^2) * 100,
    ci_low_pp = excess_dark_pp - 1.96 * excess_se_pp,
    ci_high_pp = excess_dark_pp + 1.96 * excess_se_pp
  )

baseline_bin <- baseline %>%
  transmute(
    scheduled_bin = 0L,
    n = baseline_n,
    mean_scheduled_area_minutes = 0,
    mean_dark_share = baseline_mean_dark,
    se_dark_share = baseline_se_dark,
    baseline_n,
    baseline_mean_dark,
    baseline_se_dark,
    excess_dark_pp = 0,
    excess_se_pp = 0,
    ci_low_pp = 0,
    ci_high_pp = 0
  )

schedule_bins <- bind_rows(baseline_bin, positive_bins) %>%
  arrange(scheduled_bin)
write.csv(schedule_bins, BINS_OUT, row.names = FALSE)

# -----------------------------
# 4) FIGURES
# -----------------------------
label_text <- paste0(
  "Analysis days: ", regression$n_days,
  " | corr = ", sprintf("%.3f", regression$correlation),
  " | R2 = ", sprintf("%.3f", regression$r_squared),
  " | min observed pixels = ", format(MIN_OBSERVED_PIXELS, scientific = FALSE)
)

overlay_df <- diagnostic %>%
  mutate(
    dark_share_norm = dark_share / max(dark_share, na.rm = TRUE),
    scheduled_area_minutes_norm = scheduled_area_minutes / max(scheduled_area_minutes, na.rm = TRUE)
  ) %>%
  select(date, analysis_sample, dark_share_norm, scheduled_area_minutes_norm) %>%
  tidyr::pivot_longer(
    cols = c(dark_share_norm, scheduled_area_minutes_norm),
    names_to = "series",
    values_to = "normalized_value"
  ) %>%
  mutate(
    series = recode(
      series,
      dark_share_norm = "Pixel-IQR dark share",
      scheduled_area_minutes_norm = "Scheduled area-minutes"
    )
  )

p_overlay <- ggplot(overlay_df, aes(x = date, y = normalized_value, color = series)) +
  geom_line(linewidth = 0.55, alpha = 0.86, na.rm = TRUE) +
  geom_point(size = 0.7, alpha = 0.70, na.rm = TRUE) +
  scale_y_continuous(labels = scales::percent_format(accuracy = 1), limits = c(0, NA)) +
  scale_color_manual(values = c(
    "Pixel-IQR dark share" = "#B22222",
    "Scheduled area-minutes" = "#2F5D7C"
  )) +
  labs(
    title = "Cape Town normalized daily dark signal and scheduled load shedding",
    subtitle = label_text,
    x = NULL,
    y = "Max-normalized daily value",
    color = NULL
  ) +
  theme_minimal(base_size = 11) +
  theme(
    plot.title = element_text(face = "bold"),
    panel.grid.minor = element_blank(),
    legend.position = "bottom",
    plot.margin = grid::unit(c(5, 12, 5, 18), "pt")
  )

p_scatter <- ggplot(analysis, aes(x = scheduled_area_minutes, y = dark_share)) +
  geom_point(aes(size = observed_iqr), alpha = 0.65, color = "#2f5d7c") +
  geom_smooth(method = "lm", se = TRUE, color = "#111827", linewidth = 0.7) +
  scale_y_continuous(labels = scales::percent_format(accuracy = 0.1)) +
  scale_size_continuous(name = "Observed pixels", range = c(1.5, 5)) +
  labs(
    title = "Daily citywide association",
    x = "Scheduled area-minutes",
    y = "Citywide dark share"
  ) +
  theme_minimal(base_size = 11) +
  theme(
    plot.title = element_text(face = "bold"),
    panel.grid.minor = element_blank(),
    legend.position = "bottom",
    plot.margin = grid::unit(c(5, 12, 5, 18), "pt")
  )

p_bins <- ggplot(schedule_bins, aes(x = mean_scheduled_area_minutes, y = excess_dark_pp)) +
  geom_hline(yintercept = 0, color = "#4A5568", linewidth = 0.35) +
  geom_errorbar(aes(ymin = ci_low_pp, ymax = ci_high_pp), width = 0, linewidth = 0.5, alpha = 0.82) +
  geom_line(color = "#B22222", linewidth = 0.65, alpha = 0.86) +
  geom_point(aes(size = n), color = "#B22222", alpha = 0.92) +
  geom_text(
    aes(label = paste0("n=", n)),
    nudge_y = 0.045,
    size = 2.8,
    color = "#374151",
    check_overlap = TRUE
  ) +
  scale_x_continuous(labels = scales::comma) +
  scale_y_continuous(labels = function(x) fmt_pp(x, 2)) +
  scale_size_continuous(range = c(1.8, 4.2), guide = "none") +
  labs(
    title = "Citywide pixel-IQR darkening rises with scheduled load-shedding intensity",
    subtitle = "Zero is the mean of no-schedule days; positive-schedule days are split into ten equal-count bins.",
    x = "Average scheduled area-minutes within bin",
    y = "Dark-share increase vs no-schedule days"
  ) +
  theme_minimal(base_size = 11) +
  theme(
    plot.title = element_text(face = "bold"),
    panel.grid.minor = element_blank(),
    plot.margin = grid::unit(c(5, 12, 5, 18), "pt")
  )

ggsave(FIGURE_OVERLAY_OUT, p_overlay, width = 8.8, height = 4.9, dpi = 320)
ggsave(FIGURE_SCATTER_OUT, p_scatter, width = 8.8, height = 5.2, dpi = 320)
ggsave(FIGURE_BINS_OUT, p_bins, width = 8.8, height = 5.2, dpi = 320)

png(FIGURE_OUT, width = 1500, height = 1700, res = 160)
grid::grid.newpage()
grid::pushViewport(grid::viewport(layout = grid::grid.layout(nrow = 3, ncol = 1)))
grid::pushViewport(grid::viewport(layout.pos.row = 1, layout.pos.col = 1))
print(p_overlay, newpage = FALSE)
grid::popViewport()
grid::pushViewport(grid::viewport(layout.pos.row = 2, layout.pos.col = 1))
print(p_scatter, newpage = FALSE)
grid::popViewport()
grid::pushViewport(grid::viewport(layout.pos.row = 3, layout.pos.col = 1))
print(p_bins, newpage = FALSE)
grid::popViewport(2)
dev.off()

SHOW_PLOTS <- Sys.getenv("VJ146A2_SHOW_PLOTS", ifelse(interactive(), "1", "0")) == "1"
if (SHOW_PLOTS) {
  print(p_overlay)
  print(p_scatter)
  print(p_bins)
}

cat("Wrote daily diagnostic:", DAILY_OUT, "\n")
cat("Wrote regression summary:", REGRESSION_OUT, "\n")
cat("Wrote schedule bins:", BINS_OUT, "\n")
cat("Wrote figure:", FIGURE_OUT, "\n")
cat("Wrote overlay figure:", FIGURE_OVERLAY_OUT, "\n")
cat("Wrote scatter figure:", FIGURE_SCATTER_OUT, "\n")
cat("Wrote bin figure:", FIGURE_BINS_OUT, "\n")
cat(
  "Correlation:", sprintf("%.6f", regression$correlation),
  "| R2:", sprintf("%.6f", regression$r_squared),
  "| n:", regression$n_days,
  "\n"
)
