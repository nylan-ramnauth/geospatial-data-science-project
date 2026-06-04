rm(list = ls())

# ============================================================
# Apply VJ146A2 Yearly-Keep Filter to Monthly Coverage Panels
# VJ Stage 3b — Yearly-keep monthly materialization
# ============================================================
#
# Purpose:  Reads VJ coverage-filtered monthly settlement-day Parquets,
#           enforces the VJ pre-Stage-2 `electrified_best == 1` keep list,
#           and writes yearly-keep monthly Parquets for validation and
#           Stage 5 parity with the October diagnostic. When Stage 2 is run
#           in production mode, the same keep list has already been applied
#           before daily pixel extraction.
# Inputs:   - Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_cov_YYYY-MM.parquet
#           - Map Data/reliability_outputs_vj146a2/yearly_settlement_stats_YYYY.parquet
# Outputs:  - Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_cov_yearlykeep_YYYY-MM.parquet
# Run:      Rscript Builder/settlement_day_yearlykeep_filter_vj146a2.R
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
IN_DIR <- file.path(BASE_PATH, "Map Data", "settlement_day_outputs_vj146a2")
OUT_DIR <- file.path(BASE_PATH, "Map Data", "settlement_day_outputs_vj146a2")
YEARLY_DIR <- file.path(BASE_PATH, "Map Data", "reliability_outputs_vj146a2")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

START_MONTH <- Sys.getenv("VJ146A2_START_MONTH", "2023-01")
END_MONTH <- Sys.getenv("VJ146A2_END_MONTH", "2023-12")
ALLOW_PARTIAL <- Sys.getenv("VJ146A2_ALLOW_PARTIAL", "0") == "1"
YEAR_LABEL <- substr(START_MONTH, 1, 4)

YEARLY_STATS_FILE <- Sys.getenv(
  "VJ146A2_YEARLY_STATS_FILE",
  file.path(YEARLY_DIR, paste0("yearly_settlement_stats_", YEAR_LABEL, ".parquet"))
)

if (!file.exists(YEARLY_STATS_FILE)) {
  stop(
    "VJ yearly stats file not found: ", YEARLY_STATS_FILE,
    "\nRun VJ pre-Stage 2 first: Rscript Builder/vj146a2_yearly_keep_build.R"
  )
}

# -----------------------------
# RUN
# -----------------------------
month_start <- as.Date(paste0(START_MONTH, "-01"))
month_end <- as.Date(paste0(END_MONTH, "-01"))
if (is.na(month_start) || is.na(month_end)) stop("Invalid START_MONTH/END_MONTH (use 'YYYY-MM').")
if (month_start > month_end) stop("START_MONTH must be <= END_MONTH.")

months_seq <- seq.Date(from = month_start, to = month_end, by = "month")
input_files <- file.path(
  IN_DIR,
  paste0("settlement_day_vj146a2_cov_", format(months_seq, "%Y-%m"), ".parquet")
)
missing_files <- input_files[!file.exists(input_files)]
if (length(missing_files) > 0 && !ALLOW_PARTIAL) {
  stop(
    "Missing VJ monthly coverage panel(s):\n  - ",
    paste(missing_files, collapse = "\n  - "),
    "\nRun VJ Stage 3 first, or set VJ146A2_ALLOW_PARTIAL=1 for an explicit partial diagnostic run."
  )
}
if (ALLOW_PARTIAL && length(missing_files) > 0) {
  message("VJ146A2_ALLOW_PARTIAL=1; proceeding with available configured months only.")
}

yearly_stats <- arrow::read_parquet(YEARLY_STATS_FILE)
required_yearly_cols <- c("settlement_id", "population", "electrified_best")
missing_yearly_cols <- setdiff(required_yearly_cols, names(yearly_stats))
if (length(missing_yearly_cols) > 0) {
  stop("VJ yearly stats file is missing required columns: ", paste(missing_yearly_cols, collapse = ", "))
}

yearly_stats <- yearly_stats %>%
  mutate(
    settlement_id = as.character(settlement_id),
    population_yearly = as.numeric(population),
    electrified_best = as.integer(electrified_best)
  )

yearly_keep <- yearly_stats %>%
  filter(electrified_best == 1L) %>%
  select(settlement_id, population_yearly, electrified_best)

if (nrow(yearly_keep) == 0) {
  stop("VJ yearly stats file has no electrified_best == 1 settlements: ", YEARLY_STATS_FILE)
}

for (i in seq_along(months_seq)) {
  m <- months_seq[i]
  m_str <- format(m, "%Y-%m")
  in_parq <- file.path(IN_DIR, paste0("settlement_day_vj146a2_cov_", m_str, ".parquet"))
  out_parq <- file.path(OUT_DIR, paste0("settlement_day_vj146a2_cov_yearlykeep_", m_str, ".parquet"))
  out_summary <- file.path(OUT_DIR, paste0("settlement_day_vj146a2_cov_yearlykeep_", m_str, "_daily_summary.csv"))

  if (!file.exists(in_parq)) {
    message("Missing input: ", in_parq, " - skipping because VJ146A2_ALLOW_PARTIAL=1")
    next
  }

  before <- arrow::read_parquet(in_parq) %>%
    mutate(settlement_id = as.character(settlement_id))

  after <- before %>%
    inner_join(yearly_keep, by = "settlement_id") %>%
    mutate(
      population = coalesce(as.numeric(population), population_yearly),
      electrified_best = as.integer(electrified_best)
    ) %>%
    select(-population_yearly)

  if (nrow(after) == 0) {
    stop("No rows remain after VJ yearly-keep filter for ", m_str, ".")
  }

  daily_summary <- after %>%
    group_by(date) %>%
    summarise(
      n_settlements = n(),
      population_sum = sum(population, na.rm = TRUE),
      mean_coverage = mean(coverage, na.rm = TRUE),
      mean_p_lit_sett = mean(p_lit_sett, na.rm = TRUE),
      popw_mean_p_lit_sett = weighted.mean(p_lit_sett, population, na.rm = TRUE),
      popw_share_dark = weighted.mean(as.numeric(p_lit_sett < 0.05), population, na.rm = TRUE),
      .groups = "drop"
    )

  arrow::write_parquet(after, out_parq)
  utils::write.csv(daily_summary, out_summary, row.names = FALSE)

  message(
    "Month ", m_str,
    " | rows: ", nrow(before), " -> ", nrow(after),
    " | settlements: ", dplyr::n_distinct(before$settlement_id), " -> ", dplyr::n_distinct(after$settlement_id),
    " | wrote: ", out_parq
  )
}

message("Done.")
