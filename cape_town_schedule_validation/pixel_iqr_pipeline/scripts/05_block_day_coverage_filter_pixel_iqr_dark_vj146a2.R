rm(list = ls())

# ============================================================
# Apply Coverage Filter to Cape Town Pixel-IQR Block-Day Panel
# Pixel-IQR Stage 5B - Schedule-block coverage filtering
# ============================================================
#
# Purpose:  Filters the Cape Town schedule-block pixel-IQR panel by
#           observed pixel-IQR coverage. This is the block-level analogue
#           of the settlement coverage filter.
# Inputs:   - pixel_iqr_pipeline/data/stage2_block_iqr_nocov/
#             block_day_vj146a2_pixel_iqr_nocov_YYYY-MM.parquet
# Outputs:  - pixel_iqr_pipeline/data/stage3_block_iqr_cov/
#             block_day_vj146a2_pixel_iqr_cov_YYYY-MM.parquet
# Run:      Rscript cape_town_schedule_validation/pixel_iqr_pipeline/scripts/05_block_day_coverage_filter_pixel_iqr_dark_vj146a2.R
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
  "VJ146A2_PIXEL_IQR_BLOCK_NOCOV_DIR",
  file.path(MODULE_DIR, "data", "stage2_block_iqr_nocov")
)
OUT_DIR <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_BLOCK_COV_DIR",
  file.path(MODULE_DIR, "data", "stage3_block_iqr_cov")
)
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

START_MONTH <- Sys.getenv("VJ146A2_START_MONTH", "2023-01")
END_MONTH <- Sys.getenv("VJ146A2_END_MONTH", "2023-12")

MIN_COVERAGE_IQR <- as.numeric(Sys.getenv("VJ146A2_MIN_COVERAGE_IQR", "0.5"))
# FALSE = area-weighted observed-IQR coverage (default/production).
# TRUE  = cell-count coverage (fraction of touching pixels observed).
USE_COUNT_COVERAGE <- Sys.getenv("VJ146A2_USE_COUNT_COVERAGE", "0") == "1"

if (!is.finite(MIN_COVERAGE_IQR)) stop("Invalid VJ146A2_MIN_COVERAGE_IQR; expected finite numeric.")

MAX_DATES_PER_MONTH <- suppressWarnings(as.integer(Sys.getenv("VJ146A2_MAX_DATES_PER_MONTH", "")))
if (!is.finite(MAX_DATES_PER_MONTH)) MAX_DATES_PER_MONTH <- NA_integer_
SMOKE_MODE <- !is.na(MAX_DATES_PER_MONTH)
OUTPUT_SUFFIX <- if (SMOKE_MODE) "_smoke" else ""
if (SMOKE_MODE) {
  IN_DIR <- file.path(IN_DIR, "smoke")
  OUT_DIR <- file.path(OUT_DIR, "smoke")
}
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

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
    paste0("block_day_vj146a2_pixel_iqr_nocov", OUTPUT_SUFFIX, "_", m_str, ".parquet")
  )
  out_parq <- file.path(
    OUT_DIR,
    paste0("block_day_vj146a2_pixel_iqr_cov", OUTPUT_SUFFIX, "_", m_str, ".parquet")
  )

  if (!file.exists(in_parq)) {
    cat("Missing input:", in_parq, "- skipping\n")
    next
  }

  block_day <- arrow::read_parquet(in_parq)
  cover_col <- if (USE_COUNT_COVERAGE) "coverage_count_iqr" else "coverage_iqr"
  if (!cover_col %in% names(block_day)) stop("Coverage column not found: ", cover_col)
  if (!"target_family" %in% names(block_day)) stop("Input is missing target_family: ", in_parq)
  if (any(block_day$target_family != "pixel_iqr_dark_block", na.rm = TRUE)) {
    stop("Unexpected target_family value in: ", in_parq)
  }

  before_n <- nrow(block_day)
  before_blocks <- dplyr::n_distinct(block_day$block_id)
  before_counts <- block_day %>%
    count(block_id, name = "n_days_before")

  block_day <- block_day %>%
    filter(.data[[cover_col]] >= MIN_COVERAGE_IQR)

  after_n <- nrow(block_day)
  after_blocks <- dplyr::n_distinct(block_day$block_id)
  after_counts <- block_day %>%
    count(block_id, name = "n_days_after")

  retention_summary <- before_counts %>%
    left_join(after_counts, by = "block_id") %>%
    mutate(n_days_after = coalesce(n_days_after, 0L)) %>%
    summarise(
      dropped_blocks = sum(n_days_after == 0L),
      fully_retained_blocks = sum(n_days_after == n_days_before),
      partially_retained_blocks = sum(n_days_after > 0L & n_days_after < n_days_before),
      .groups = "drop"
    )

  arrow::write_parquet(block_day, out_parq)
  cat("Month:", m_str, "\n")
  cat("Filtered by", cover_col, ">=", MIN_COVERAGE_IQR, "\n")
  cat("Rows:", before_n, "->", after_n, "\n")
  cat("Unique blocks:", before_blocks, "->", after_blocks, "\n")
  cat(
    "Blocks dropped/partial/full:",
    retention_summary$dropped_blocks,
    retention_summary$partially_retained_blocks,
    retention_summary$fully_retained_blocks,
    "\n"
  )
  cat("Wrote:", out_parq, "\n")
}
