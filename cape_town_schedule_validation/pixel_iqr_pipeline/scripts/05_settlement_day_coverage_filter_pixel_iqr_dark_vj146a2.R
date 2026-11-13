rm(list = ls())

# ============================================================
# Apply Coverage Filter to Cape Town Pixel-IQR Settlement-Day Panel
# Pixel-IQR Stage 5 - Coverage filtering
# ============================================================
#
# Purpose:  Mirrors the VJ146A2 coverage-filter step for the Cape Town
#           pixel-IQR measurement panel. It filters by observed pixel-IQR
#           coverage and preserves measurement columns only.
# Inputs:   - pixel_iqr_pipeline/data/stage2_pixel_iqr_nocov/
#             settlement_day_vj146a2_pixel_iqr_nocov_YYYY-MM.parquet
# Outputs:  - pixel_iqr_pipeline/data/stage3_pixel_iqr_cov/
#             settlement_day_vj146a2_pixel_iqr_cov_YYYY-MM.parquet
# Run:      Rscript cape_town_schedule_validation/pixel_iqr_pipeline/scripts/05_settlement_day_coverage_filter_pixel_iqr_dark_vj146a2.R
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(dplyr)
  library(arrow)
})

# -----------------------------
# CONFIG
# -----------------------------
BASE_PATH <- here::here()
MODULE_DIR <- file.path(BASE_PATH, "cape_town_schedule_validation", "pixel_iqr_pipeline")

IN_DIR <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_NOCOV_DIR",
  file.path(MODULE_DIR, "data", "stage2_pixel_iqr_nocov")
)
OUT_DIR <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_COV_DIR",
  file.path(MODULE_DIR, "data", "stage3_pixel_iqr_cov")
)
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

START_MONTH <- Sys.getenv("VJ146A2_START_MONTH", "2023-01")
END_MONTH <- Sys.getenv("VJ146A2_END_MONTH", "2023-12")

MIN_COVERAGE_IQR <- as.numeric(Sys.getenv("VJ146A2_MIN_COVERAGE_IQR", "0.5"))
# FALSE = area-weighted observed-IQR coverage (default/production).
# TRUE  = cell-count coverage (fraction of touching pixels observed).
USE_COUNT_COVERAGE <- Sys.getenv("VJ146A2_USE_COUNT_COVERAGE", "0") == "1"

if (!is.finite(MIN_COVERAGE_IQR)) stop("Invalid VJ146A2_MIN_COVERAGE_IQR; expected finite numeric.")

# -----------------------------
# RUN
# -----------------------------
month_start <- as.Date(paste0(START_MONTH, "-01"))
month_end <- as.Date(paste0(END_MONTH, "-01"))
if (is.na(month_start) || is.na(month_end)) stop("Invalid START_MONTH/END_MONTH (use 'YYYY-MM').")
if (month_start > month_end) stop("START_MONTH must be <= END_MONTH.")
months_seq <- seq.Date(from = month_start, to = month_end, by = "month")

for (mi in seq_along(months_seq)) {
  m <- months_seq[mi]
  m_str <- format(m, "%Y-%m")

  in_parq <- file.path(
    IN_DIR,
    paste0("settlement_day_vj146a2_pixel_iqr_nocov_", m_str, ".parquet")
  )
  out_parq <- file.path(
    OUT_DIR,
    paste0("settlement_day_vj146a2_pixel_iqr_cov_", m_str, ".parquet")
  )

  if (!file.exists(in_parq)) {
    cat("Missing input:", in_parq, "- skipping\n")
    next
  }

  sett_day <- arrow::read_parquet(in_parq)
  cover_col <- if (USE_COUNT_COVERAGE) "coverage_count_iqr" else "coverage_iqr"
  if (!cover_col %in% names(sett_day)) stop("Coverage column not found: ", cover_col)
  if (!"target_family" %in% names(sett_day)) stop("Input is missing target_family: ", in_parq)
  if (any(sett_day$target_family != "pixel_iqr_dark", na.rm = TRUE)) {
    stop("Unexpected target_family value in: ", in_parq)
  }

  before_n <- nrow(sett_day)
  before_sett <- dplyr::n_distinct(sett_day$settlement_id)
  before_counts <- sett_day %>%
    count(settlement_id, name = "n_days_before")

  sett_day <- sett_day %>%
    filter(.data[[cover_col]] >= MIN_COVERAGE_IQR)

  after_n <- nrow(sett_day)
  after_sett <- dplyr::n_distinct(sett_day$settlement_id)
  after_counts <- sett_day %>%
    count(settlement_id, name = "n_days_after")

  retention_summary <- before_counts %>%
    left_join(after_counts, by = "settlement_id") %>%
    mutate(n_days_after = coalesce(n_days_after, 0L)) %>%
    summarise(
      dropped_sett = sum(n_days_after == 0L),
      fully_retained_sett = sum(n_days_after == n_days_before),
      partially_retained_sett = sum(n_days_after > 0L & n_days_after < n_days_before),
      .groups = "drop"
    )

  arrow::write_parquet(sett_day, out_parq)
  cat("Month:", m_str, "\n")
  cat("Filtered by", cover_col, ">=", MIN_COVERAGE_IQR, "\n")
  cat("Rows:", before_n, "->", after_n, "\n")
  cat("Unique settlements:", before_sett, "->", after_sett, "\n")
  cat(
    "Settlements dropped/partial/full:",
    retention_summary$dropped_sett,
    retention_summary$partially_retained_sett,
    retention_summary$fully_retained_sett,
    "\n"
  )
  cat("Wrote:", out_parq, "\n")
}

