rm(list = ls())

# ============================================================
# Visualize Cape Town Block Schedule Validation Specifications
# ============================================================
#
# Purpose:  Reads the simple block-level validation outputs from script 06
#           and writes exploratory figures for coefficient stability,
#           scheduled-vs-unscheduled means, binned load-shedding intensity,
#           and block heterogeneity.
# Inputs:   - pixel_iqr_pipeline/reports/cape_town_pixel_iqr_block_schedule_validation_*.csv
# Outputs:  - pixel_iqr_pipeline/figures/cape_town_pixel_iqr_block_schedule_validation_*.png
# Run:      Rscript cape_town_schedule_validation/pixel_iqr_pipeline/scripts/visualize_block_schedule_validation_pixel_iqr_dark_vj146a2.R
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(dplyr)
  library(ggplot2)
})

# -----------------------------
# CONFIG
# -----------------------------
BASE_PATH <- here::here()
MODULE_DIR <- file.path(BASE_PATH, "cape_town_schedule_validation", "pixel_iqr_pipeline")
REPORT_DIR <- Sys.getenv("VJ146A2_PIXEL_IQR_REPORT_DIR", file.path(MODULE_DIR, "reports"))
FIGURE_DIR <- Sys.getenv("VJ146A2_PIXEL_IQR_FIGURE_DIR", file.path(MODULE_DIR, "figures"))
dir.create(FIGURE_DIR, recursive = TRUE, showWarnings = FALSE)

REGRESSIONS_CSV <- file.path(REPORT_DIR, "cape_town_pixel_iqr_block_schedule_validation_regressions.csv")
MEANS_CSV <- file.path(REPORT_DIR, "cape_town_pixel_iqr_block_schedule_validation_means.csv")
BINS_CSV <- file.path(REPORT_DIR, "cape_town_pixel_iqr_block_schedule_validation_bins.csv")
BLOCK_SUMMARY_CSV <- file.path(REPORT_DIR, "cape_town_pixel_iqr_block_schedule_validation_block_summary.csv")

FIG_COEFS <- file.path(FIGURE_DIR, "cape_town_pixel_iqr_block_schedule_validation_coefficients.png")
FIG_MEANS <- file.path(FIGURE_DIR, "cape_town_pixel_iqr_block_schedule_validation_means.png")
FIG_BINS <- file.path(FIGURE_DIR, "cape_town_pixel_iqr_block_schedule_validation_bins.png")
FIG_BLOCKS <- file.path(FIGURE_DIR, "cape_town_pixel_iqr_block_schedule_validation_blocks.png")

# -----------------------------
# HELPERS
# -----------------------------
fmt_pp <- function(x, digits = 2) {
  paste0(format(round(x, digits), nsmall = digits, trim = TRUE), " pp")
}

read_required <- function(path) {
  if (!file.exists(path)) stop("Missing required input: ", path, "\nRun script 06 first.")
  read.csv(path, stringsAsFactors = FALSE)
}

theme_validation <- function(base_size = 10.5) {
  theme_minimal(base_size = base_size) +
    theme(
      panel.grid.minor = element_blank(),
      plot.title = element_text(face = "bold"),
      legend.position = "bottom"
    )
}

# -----------------------------
# 1) READ OUTPUTS
# -----------------------------
regressions <- read_required(REGRESSIONS_CSV)
means <- read_required(MEANS_CSV)
bins <- read_required(BINS_CSV)
block_summary <- read_required(BLOCK_SUMMARY_CSV)

spec_levels <- c(
  "No FE",
  "Block FE",
  "Date FE",
  "Month FE",
  "Day-of-week FE",
  "Block + month FE",
  "Block + day-of-week FE",
  "Month + day-of-week FE",
  "Block + month + day-of-week FE",
  "Block + date FE"
)

reg_plot <- regressions %>%
  filter(exposure %in% c("any_overpass_sched", "overpass_sched_minutes", "any_day_sched", "day_sched_minutes")) %>%
  mutate(
    spec_label = factor(spec_label, levels = spec_levels),
    exposure_label = factor(
      exposure_label,
      levels = c(
        "Any overpass schedule",
        "Overpass scheduled minutes",
        "Any full-day schedule",
        "Full-day scheduled minutes"
      )
    )
  )

# -----------------------------
# 2) COEFFICIENT STABILITY
# -----------------------------
p_coefs <- ggplot(reg_plot, aes(x = spec_label, y = scaled_effect_pp, color = exposure_label)) +
  geom_hline(yintercept = 0, color = "#4A5568", linewidth = 0.35) +
  geom_errorbar(aes(ymin = ci_low_pp, ymax = ci_high_pp), width = 0, linewidth = 0.45, alpha = 0.82) +
  geom_point(size = 2.0, alpha = 0.94) +
  facet_wrap(~ exposure_label, ncol = 2, scales = "free_y") +
  scale_y_continuous(labels = function(x) fmt_pp(x, 2)) +
  scale_color_manual(values = c(
    "Any overpass schedule" = "#B22222",
    "Overpass scheduled minutes" = "#7F1D1D",
    "Any full-day schedule" = "#2F5D7C",
    "Full-day scheduled minutes" = "#4E79A7"
  )) +
  labs(
    title = "Cape Town block-level schedule validation coefficients",
    subtitle = "Outcome is p_dark_iqr_block by VJ product date. Schedule exposure uses the inferred local overpass date.",
    x = NULL,
    y = "Estimated effect on dark share",
    color = NULL
  ) +
  theme_validation() +
  theme(
    axis.text.x = element_text(angle = 45, hjust = 1),
    legend.position = "none"
  )

ggsave(FIG_COEFS, p_coefs, width = 11.2, height = 7.2, dpi = 320)

# -----------------------------
# 3) SCHEDULED VS UNSCHEDULED MEANS
# -----------------------------
means_plot <- means %>%
  mutate(
    status = ifelse(exposure_value == 1, "Scheduled", "Not scheduled"),
    exposure_label = factor(exposure_label, levels = c("Any overpass schedule", "Any full-day schedule"))
  )

p_means <- ggplot(means_plot, aes(x = status, y = mean_dark, fill = status)) +
  geom_col(width = 0.64) +
  geom_text(aes(label = paste0("n=", n)), vjust = -0.5, size = 3.2, color = "#374151") +
  facet_wrap(~ exposure_label, nrow = 1) +
  scale_y_continuous(labels = scales::percent_format(accuracy = 0.1), expand = expansion(mult = c(0, 0.12))) +
  scale_fill_manual(values = c("Not scheduled" = "#8FA3C4", "Scheduled" = "#B22222")) +
  labs(
    title = "Scheduled block-days are darker, especially at overpass time",
    x = NULL,
    y = "Mean p_dark_iqr_block",
    fill = NULL
  ) +
  theme_validation()

ggsave(FIG_MEANS, p_means, width = 8.2, height = 4.8, dpi = 320)

# -----------------------------
# 4) BINNED INTENSITY PLOT
# -----------------------------
bins_plot <- bins %>%
  filter(exposure == "day_sched_minutes") %>%
  mutate(bin_label = ifelse(bin == 0, "No schedule", paste0("Bin ", bin)))

p_bins <- ggplot(bins_plot, aes(x = mean_exposure, y = excess_dark_pp)) +
  geom_hline(yintercept = 0, color = "#4A5568", linewidth = 0.35) +
  geom_errorbar(aes(ymin = ci_low_pp, ymax = ci_high_pp), width = 0, linewidth = 0.5, alpha = 0.82) +
  geom_line(color = "#B22222", linewidth = 0.65, alpha = 0.86) +
  geom_point(aes(size = n), color = "#B22222", alpha = 0.92) +
  geom_text(aes(label = paste0("n=", n)), nudge_y = 0.08, size = 3.0, color = "#374151", check_overlap = TRUE) +
  scale_x_continuous(labels = scales::comma) +
  scale_y_continuous(labels = function(x) fmt_pp(x, 2)) +
  scale_size_continuous(range = c(1.9, 4.4), guide = "none") +
  labs(
    title = "Block-level darkening rises with scheduled load-shedding intensity",
    subtitle = "No-schedule rows are the baseline; exposure uses the inferred local overpass date.",
    x = "Average full-day scheduled minutes within bin",
    y = "Dark-share increase vs no-schedule block-days"
  ) +
  theme_validation()

ggsave(FIG_BINS, p_bins, width = 8.8, height = 5.2, dpi = 320)

# -----------------------------
# 5) BLOCK HETEROGENEITY
# -----------------------------
blocks_plot <- block_summary %>%
  mutate(
    circuit = factor(circuit, levels = circuit[order(overpass_diff_pp)]),
    positive = overpass_diff_pp >= 0
  )

p_blocks <- ggplot(blocks_plot, aes(x = overpass_diff_pp, y = circuit, fill = positive)) +
  geom_vline(xintercept = 0, color = "#4A5568", linewidth = 0.35) +
  geom_col(width = 0.7) +
  geom_text(aes(label = fmt_pp(overpass_diff_pp, 2)), hjust = -0.08, size = 3.0, color = "#374151") +
  scale_x_continuous(labels = function(x) fmt_pp(x, 1), expand = expansion(mult = c(0.05, 0.18))) +
  scale_fill_manual(values = c("TRUE" = "#B22222", "FALSE" = "#8FA3C4"), guide = "none") +
  labs(
    title = "Overpass-scheduled darkening varies by Cape Town block",
    subtitle = "Difference in mean p_dark_iqr_block between overpass-scheduled and not-overpass-scheduled rows.",
    x = "Scheduled minus not scheduled at 01:00-02:00",
    y = NULL
  ) +
  theme_validation()

ggsave(FIG_BLOCKS, p_blocks, width = 8.4, height = 6.1, dpi = 320)

SHOW_PLOTS <- Sys.getenv("VJ146A2_SHOW_PLOTS", ifelse(interactive(), "1", "0")) == "1"
if (SHOW_PLOTS) {
  print(p_coefs)
  print(p_means)
  print(p_bins)
  print(p_blocks)
}

cat("Wrote coefficient figure:", FIG_COEFS, "\n")
cat("Wrote means figure:", FIG_MEANS, "\n")
cat("Wrote bins figure:", FIG_BINS, "\n")
cat("Wrote block heterogeneity figure:", FIG_BLOCKS, "\n")
