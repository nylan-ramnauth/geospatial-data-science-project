# ============================================================
# Apply Coverage Filter to VJ146A2 Settlement-Day Panel
# VJ Stage 3 — Coverage Filtering
# ============================================================
#
# Purpose:  Reads the no-coverage-filter VJ146A2 Parquet panels from Stage 2
#           after the pre-Stage-2 yearly-keep settlement prefilter, applies
#           the daily coverage threshold filter, and writes filtered panels
#           for use in downstream reliability analysis.
# Inputs:   - Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_nocov_YYYY-MM.parquet
# Outputs:  - Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_cov_YYYY-MM.parquet
# Run:      Rscript Builder/settlement_day_coverage_filter_vj146a2.R
# ============================================================

rm(list = ls())

suppressPackageStartupMessages({
  library(here)
  library(dplyr)
  library(arrow)
})

# -----------------------------
# CONFIG (EDIT)
# -----------------------------
BASE_PATH <- here::here()
IN_DIR    <- file.path(BASE_PATH, "Map Data", "settlement_day_outputs_vj146a2")
OUT_DIR   <- file.path(BASE_PATH, "Map Data", "settlement_day_outputs_vj146a2")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

START_MONTH <- Sys.getenv("VJ146A2_START_MONTH", "2023-01")
END_MONTH   <- Sys.getenv("VJ146A2_END_MONTH", "2023-12")

MIN_COVERAGE <- 0.5  # tweak for sensitivity
# FALSE = area-weighted coverage (default/production).
# TRUE  = cell-count coverage (fraction of touching pixels that are valid);
#         more sensitive to small settlements; use for sensitivity checks only.
USE_COUNT_COVERAGE <- FALSE

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

  in_parq <- file.path(IN_DIR, paste0("settlement_day_vj146a2_nocov_", m_str, ".parquet"))
  out_parq <- file.path(OUT_DIR, paste0("settlement_day_vj146a2_cov_", m_str, ".parquet"))

  if (!file.exists(in_parq)) {
    cat("Missing input:", in_parq, "- skipping\n")
    next
  }

  sett_day <- arrow::read_parquet(in_parq)

  # coverage = fraction of settlement geographic area (m²) with valid satellite
  # observations that day; computed in Stage 2 as valid_area_m2 / area_m2
  cover_col <- if (USE_COUNT_COVERAGE) "coverage_count" else "coverage"
  if (!cover_col %in% names(sett_day)) stop("Coverage column not found even after recompute: ", cover_col)

  before_n <- nrow(sett_day)
  before_sett <- dplyr::n_distinct(sett_day$settlement_id)
  before_counts <- sett_day %>%
    count(settlement_id, name = "n_days_before")
  sett_day <- sett_day %>%
    filter(.data[[cover_col]] >= MIN_COVERAGE)
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
      partially_retained_sett = sum(n_days_after > 0L & n_days_after < n_days_before)
    )

  arrow::write_parquet(sett_day, out_parq)
  cat("Month:", m_str, "\n")
  cat("Filtered by", cover_col, ">=", MIN_COVERAGE, "\n")
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
