# ============================================================
# DOE Population Summary
# Stage 5b — Population-Weighted DOE Summary
# ============================================================
#
# Purpose:  Computes population-weighted Date of Electrification (DOE)
#           summary statistics from Stage 3 outputs.
# Inputs:   - Map Data/reliability_outputs_blackmarbler/settlement_reliability_yearly_*.parquet
# Outputs:  - Map Data/reliability_outputs_blackmarbler/doe_population_summary_*.csv
# Run:      Rscript Visualizer/doe_population_summary.R
# ============================================================

rm(list = ls())

suppressPackageStartupMessages({
  library(here)
  library(arrow)
  library(dplyr)
  library(stringr)
  library(readr)
})

# -----------------------------
# CONFIG
# -----------------------------
BASE_PATH <- here::here()
OUT_DIR <- file.path(BASE_PATH, "Map Data", "reliability_outputs_blackmarbler")
END_DATE <- as.Date("2023-12-31")

# Default scans strict state caches (including optional suffixed runs).
STATE_FILES <- list.files(
  OUT_DIR,
  pattern = "^settlement_day_states_strict.*\\.parquet$",
  full.names = TRUE
)

if (length(STATE_FILES) == 0) {
  stop("No strict states parquet files found in: ", OUT_DIR)
}

first_non_na <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA)
  x[[1]]
}

summarize_file <- function(path, end_date) {
  cols <- c("settlement_id", "date", "population", "doe_strict", "electrified_after_doe_strict")
  dat <- arrow::read_parquet(path, col_select = any_of(cols))

  if (!"doe_strict" %in% names(dat)) dat$doe_strict <- as.Date(NA)
  if (!"electrified_after_doe_strict" %in% names(dat)) dat$electrified_after_doe_strict <- NA_integer_
  if (!"population" %in% names(dat)) dat$population <- NA_real_

  dat <- dat %>%
    mutate(
      settlement_id = as.character(settlement_id),
      date = as.Date(date),
      doe_strict = as.Date(doe_strict)
    ) %>%
    filter(date <= end_date)

  sett <- dat %>%
    group_by(settlement_id) %>%
    summarise(
      population = suppressWarnings(as.numeric(first_non_na(population))),
      doe_strict = first_non_na(doe_strict),
      has_doe_fallback = if ("electrified_after_doe_strict" %in% names(dat)) {
        any(electrified_after_doe_strict == 1L, na.rm = TRUE)
      } else {
        FALSE
      },
      .groups = "drop"
    ) %>%
    mutate(
      population = if_else(is.na(population), 0, population),
      has_doe = if_else(!is.na(doe_strict), doe_strict <= end_date, has_doe_fallback)
    )

  n_sett <- nrow(sett)
  n_sett_doe <- sum(sett$has_doe, na.rm = TRUE)
  pop_total <- sum(sett$population, na.rm = TRUE)
  pop_doe <- sum(sett$population[sett$has_doe], na.rm = TRUE)

  tibble(
    file = basename(path),
    scenario = str_remove(str_remove(basename(path), "^settlement_day_states_strict"), "\\.parquet$"),
    end_date = end_date,
    n_settlements_total = n_sett,
    n_settlements_doe1 = n_sett_doe,
    share_settlements_doe1 = ifelse(n_sett > 0, n_sett_doe / n_sett, NA_real_),
    population_total = pop_total,
    population_doe1 = pop_doe,
    share_population_doe1 = ifelse(pop_total > 0, pop_doe / pop_total, NA_real_)
  )
}

summary_tbl <- bind_rows(lapply(STATE_FILES, summarize_file, end_date = END_DATE)) %>%
  mutate(
    scenario = if_else(scenario == "", "base", scenario)
  ) %>%
  arrange(file)

out_csv <- file.path(
  OUT_DIR,
  paste0("doe_population_summary_", format(END_DATE, "%Y-%m-%d"), ".csv")
)

readr::write_csv(summary_tbl, out_csv)

cat("DOE=1 population summary (end date:", format(END_DATE), ")\n")
print(summary_tbl, n = Inf)
cat("\nSaved:", out_csv, "\n")
