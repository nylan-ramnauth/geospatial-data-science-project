rm(list = ls())

# ============================================================
# Cape Town Block Schedule Validation Specifications
# Pixel-IQR Stage 6 - Simple block-day validation regressions
# ============================================================
#
# Purpose:  Joins the Cape Town pixel-IQR block-day panel to the Cape Town
#           load-shedding schedule and runs simple OLS specifications.
#           The main outcome is p_dark_iqr_block.
#           The VJ product date is shifted forward by default so schedule
#           exposure is measured on the inferred local overpass date.
# Inputs:   - pixel_iqr_pipeline/data/stage3_block_iqr_cov/
#             block_day_vj146a2_pixel_iqr_cov_YYYY-MM.parquet
#           - cape_town_schedule_validation/data/inputs/Loadshedding_schedule.csv
# Outputs:  - pixel_iqr_pipeline/reports/cape_town_pixel_iqr_block_schedule_validation_panel.csv
#           - pixel_iqr_pipeline/reports/cape_town_pixel_iqr_block_schedule_validation_regressions.csv
#           - pixel_iqr_pipeline/reports/cape_town_pixel_iqr_block_schedule_validation_means.csv
#           - pixel_iqr_pipeline/reports/cape_town_pixel_iqr_block_schedule_validation_bins.csv
#           - pixel_iqr_pipeline/reports/cape_town_pixel_iqr_block_schedule_validation_block_summary.csv
# Run:      Rscript cape_town_schedule_validation/pixel_iqr_pipeline/scripts/06_block_schedule_validation_specs_pixel_iqr_dark_vj146a2.R
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(arrow)
  library(dplyr)
})

# -----------------------------
# CONFIG
# -----------------------------
BASE_PATH <- here::here()
MODULE_DIR <- file.path(BASE_PATH, "cape_town_schedule_validation", "pixel_iqr_pipeline")

BLOCK_PANEL_DIR <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_BLOCK_COV_DIR",
  file.path(MODULE_DIR, "data", "stage3_block_iqr_cov")
)
SCHEDULE_CSV <- Sys.getenv(
  "CAPE_TOWN_LOADSHEDDING_SCHEDULE_CSV",
  file.path(BASE_PATH, "cape_town_schedule_validation", "data", "inputs", "Loadshedding_schedule.csv")
)
REPORT_DIR <- Sys.getenv(
  "VJ146A2_PIXEL_IQR_REPORT_DIR",
  file.path(MODULE_DIR, "reports")
)
dir.create(REPORT_DIR, recursive = TRUE, showWarnings = FALSE)

OVERPASS_START <- Sys.getenv("CAPE_TOWN_OVERPASS_START", "01:00:00")
OVERPASS_END <- Sys.getenv("CAPE_TOWN_OVERPASS_END", "02:00:00")
TIMEZONE <- Sys.getenv("CAPE_TOWN_TIMEZONE", "Africa/Johannesburg")
EXPOSURE_DATE_SHIFT_DAYS <- as.integer(Sys.getenv("CAPE_TOWN_EXPOSURE_DATE_SHIFT_DAYS", "1"))
if (is.na(EXPOSURE_DATE_SHIFT_DAYS)) {
  stop("CAPE_TOWN_EXPOSURE_DATE_SHIFT_DAYS must be an integer.")
}

PANEL_OUT <- file.path(REPORT_DIR, "cape_town_pixel_iqr_block_schedule_validation_panel.csv")
REGRESSIONS_OUT <- file.path(REPORT_DIR, "cape_town_pixel_iqr_block_schedule_validation_regressions.csv")
MEANS_OUT <- file.path(REPORT_DIR, "cape_town_pixel_iqr_block_schedule_validation_means.csv")
BINS_OUT <- file.path(REPORT_DIR, "cape_town_pixel_iqr_block_schedule_validation_bins.csv")
BLOCK_SUMMARY_OUT <- file.path(REPORT_DIR, "cape_town_pixel_iqr_block_schedule_validation_block_summary.csv")

# -----------------------------
# HELPERS
# -----------------------------
fit_spec <- function(data, exposure, spec_id, spec_label, fe_rhs, scale_to_pp) {
  rhs_terms <- c(exposure, fe_rhs)
  rhs_terms <- rhs_terms[nzchar(rhs_terms)]
  rhs <- paste(rhs_terms, collapse = " + ")
  fit <- stats::lm(stats::as.formula(paste("p_dark_iqr_block ~", rhs)), data = data)
  fit_sum <- summary(fit)
  coef_table <- coef(fit_sum)

  if (!exposure %in% rownames(coef_table)) {
    return(data.frame(
      exposure = exposure,
      spec_id = spec_id,
      spec_label = spec_label,
      formula = paste("p_dark_iqr_block ~", rhs),
      n = stats::nobs(fit),
      r_squared = fit_sum$r.squared,
      adj_r_squared = fit_sum$adj.r.squared,
      estimate = NA_real_,
      std_error = NA_real_,
      statistic = NA_real_,
      p_value = NA_real_,
      scaled_effect_pp = NA_real_,
      scaled_se_pp = NA_real_,
      ci_low_pp = NA_real_,
      ci_high_pp = NA_real_
    ))
  }

  estimate <- coef_table[exposure, "Estimate"]
  std_error <- coef_table[exposure, "Std. Error"]

  data.frame(
    exposure = exposure,
    spec_id = spec_id,
    spec_label = spec_label,
    formula = paste("p_dark_iqr_block ~", rhs),
    n = stats::nobs(fit),
    r_squared = fit_sum$r.squared,
    adj_r_squared = fit_sum$adj.r.squared,
    estimate = estimate,
    std_error = std_error,
    statistic = coef_table[exposure, "t value"],
    p_value = coef_table[exposure, "Pr(>|t|)"],
    scaled_effect_pp = estimate * scale_to_pp * 100,
    scaled_se_pp = std_error * scale_to_pp * 100,
    ci_low_pp = (estimate - 1.96 * std_error) * scale_to_pp * 100,
    ci_high_pp = (estimate + 1.96 * std_error) * scale_to_pp * 100
  )
}

make_bins <- function(data, exposure, exposure_label) {
  baseline <- data %>%
    filter(.data[[exposure]] == 0) %>%
    summarise(
      bin = 0L,
      n = n(),
      mean_exposure = 0,
      mean_dark = mean(p_dark_iqr_block, na.rm = TRUE),
      se_dark = stats::sd(p_dark_iqr_block, na.rm = TRUE) / sqrt(n),
      .groups = "drop"
    )

  positive <- data %>%
    filter(.data[[exposure]] > 0) %>%
    mutate(bin = dplyr::ntile(.data[[exposure]], 10)) %>%
    group_by(bin) %>%
    summarise(
      n = n(),
      mean_exposure = mean(.data[[exposure]], na.rm = TRUE),
      mean_dark = mean(p_dark_iqr_block, na.rm = TRUE),
      se_dark = stats::sd(p_dark_iqr_block, na.rm = TRUE) / sqrt(n),
      .groups = "drop"
    )

  base_mean <- baseline$mean_dark
  base_se <- baseline$se_dark

  bind_rows(baseline, positive) %>%
    mutate(
      exposure = exposure,
      exposure_label = exposure_label,
      baseline_n = baseline$n,
      baseline_mean_dark = base_mean,
      baseline_se_dark = base_se,
      excess_dark_pp = (mean_dark - base_mean) * 100,
      excess_se_pp = sqrt(se_dark^2 + base_se^2) * 100,
      ci_low_pp = excess_dark_pp - 1.96 * excess_se_pp,
      ci_high_pp = excess_dark_pp + 1.96 * excess_se_pp
    )
}

# -----------------------------
# 1) LOAD BLOCK PANEL
# -----------------------------
block_files <- list.files(
  BLOCK_PANEL_DIR,
  pattern = "^block_day_vj146a2_pixel_iqr_cov_[0-9]{4}-[0-9]{2}[.]parquet$",
  full.names = TRUE
)
if (length(block_files) == 0) {
  stop("No block-day coverage parquet files found in: ", BLOCK_PANEL_DIR)
}

block_panel <- bind_rows(lapply(sort(block_files), arrow::read_parquet)) %>%
  mutate(
    date = as.Date(date),
    vj_product_date = date,
    local_overpass_date = date + EXPOSURE_DATE_SHIFT_DAYS,
    block_id = as.integer(block_id),
    circuit = as.character(circuit)
  )

required_cols <- c("date", "vj_product_date", "local_overpass_date", "block_id", "circuit", "p_dark_iqr_block", "coverage_iqr")
missing_cols <- setdiff(required_cols, names(block_panel))
if (length(missing_cols) > 0) {
  stop("Block panel missing columns: ", paste(missing_cols, collapse = ", "))
}

# -----------------------------
# 2) BUILD SCHEDULE EXPOSURES
# -----------------------------
if (!file.exists(SCHEDULE_CSV)) stop("Schedule CSV not found: ", SCHEDULE_CSV)

schedule <- read.csv(SCHEDULE_CSV, stringsAsFactors = FALSE) %>%
  mutate(
    local_overpass_date = as.Date(Date),
    circuit = as.character(Circuit),
    minutes = suppressWarnings(as.numeric(Minutes)),
    start_time = as.POSIXct(paste(Date, Time), tz = TIMEZONE),
    end_time = start_time + minutes * 60
  ) %>%
  filter(
    !is.na(local_overpass_date),
    is.finite(minutes),
    local_overpass_date >= min(block_panel$local_overpass_date, na.rm = TRUE),
    local_overpass_date <= max(block_panel$local_overpass_date, na.rm = TRUE)
  )

day_exposure <- schedule %>%
  group_by(local_overpass_date, circuit) %>%
  summarise(
    day_sched_minutes = sum(minutes, na.rm = TRUE),
    day_sched_events = n(),
    .groups = "drop"
  )

overpass_windows <- block_panel %>%
  distinct(local_overpass_date, circuit) %>%
  mutate(
    win_start = as.POSIXct(paste(local_overpass_date, OVERPASS_START), tz = TIMEZONE),
    win_end = as.POSIXct(paste(local_overpass_date, OVERPASS_END), tz = TIMEZONE)
  )

overpass_exposure <- overpass_windows %>%
  left_join(schedule %>% select(circuit, start_time, end_time), by = "circuit", relationship = "many-to-many") %>%
  mutate(
    overlap_seconds = pmax(0, as.numeric(pmin(win_end, end_time) - pmax(win_start, start_time)))
  ) %>%
  group_by(local_overpass_date, circuit) %>%
  summarise(
    overpass_sched_minutes = sum(overlap_seconds, na.rm = TRUE) / 60,
    .groups = "drop"
  )

analysis <- block_panel %>%
  left_join(day_exposure, by = c("local_overpass_date", "circuit")) %>%
  left_join(overpass_exposure, by = c("local_overpass_date", "circuit")) %>%
  mutate(
    day_sched_minutes = coalesce(day_sched_minutes, 0),
    day_sched_events = coalesce(day_sched_events, 0L),
    overpass_sched_minutes = coalesce(overpass_sched_minutes, 0),
    any_day_sched = as.integer(day_sched_minutes > 0),
    any_overpass_sched = as.integer(overpass_sched_minutes > 0),
    month = format(local_overpass_date, "%Y-%m"),
    dow = weekdays(local_overpass_date),
    block_f = factor(block_id),
    date_f = factor(local_overpass_date),
    month_f = factor(month),
    dow_f = factor(dow, levels = c("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"))
  )

write.csv(
  analysis %>%
    select(
      date, vj_product_date, local_overpass_date, block_id, circuit, p_dark_iqr_block, coverage_iqr,
      n_observed_iqr, n_dark_iqr, day_sched_minutes, day_sched_events,
      overpass_sched_minutes, any_day_sched, any_overpass_sched, month, dow
    ),
  PANEL_OUT,
  row.names = FALSE
)

# -----------------------------
# 3) RUN REGRESSIONS
# -----------------------------
specs <- data.frame(
  spec_id = c(
    "none",
    "block_fe",
    "date_fe",
    "month_fe",
    "dow_fe",
    "block_month_fe",
    "block_dow_fe",
    "month_dow_fe",
    "block_month_dow_fe",
    "block_date_fe"
  ),
  spec_label = c(
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
  ),
  fe_rhs = c(
    "",
    "block_f",
    "date_f",
    "month_f",
    "dow_f",
    "block_f + month_f",
    "block_f + dow_f",
    "month_f + dow_f",
    "block_f + month_f + dow_f",
    "block_f + date_f"
  ),
  stringsAsFactors = FALSE
)

exposures <- data.frame(
  exposure = c("any_overpass_sched", "overpass_sched_minutes", "any_day_sched", "day_sched_minutes"),
  exposure_label = c(
    "Any overpass schedule",
    "Overpass scheduled minutes",
    "Any full-day schedule",
    "Full-day scheduled minutes"
  ),
  scale_to_pp = c(1, 60, 1, 1000),
  scale_label = c(
    "pp for scheduled 01:00-02:00",
    "pp per 60 overpass minutes",
    "pp for any scheduled minutes that date",
    "pp per 1000 full-day scheduled minutes"
  ),
  stringsAsFactors = FALSE
)

regressions <- bind_rows(lapply(seq_len(nrow(exposures)), function(ei) {
  bind_rows(lapply(seq_len(nrow(specs)), function(si) {
    fit_spec(
      data = analysis,
      exposure = exposures$exposure[ei],
      spec_id = specs$spec_id[si],
      spec_label = specs$spec_label[si],
      fe_rhs = specs$fe_rhs[si],
      scale_to_pp = exposures$scale_to_pp[ei]
    )
  })) %>%
    mutate(
      exposure_label = exposures$exposure_label[ei],
      scale_label = exposures$scale_label[ei]
    )
}))

write.csv(regressions, REGRESSIONS_OUT, row.names = FALSE)

# -----------------------------
# 4) SIMPLE SUMMARIES
# -----------------------------
means <- bind_rows(
  analysis %>%
    group_by(any_overpass_sched) %>%
    summarise(
      exposure = "any_overpass_sched",
      exposure_label = "Any overpass schedule",
      exposure_value = any_overpass_sched[1],
      n = n(),
      mean_dark = mean(p_dark_iqr_block, na.rm = TRUE),
      median_dark = median(p_dark_iqr_block, na.rm = TRUE),
      share_nonzero = mean(p_dark_iqr_block > 0, na.rm = TRUE),
      .groups = "drop"
    ),
  analysis %>%
    group_by(any_day_sched) %>%
    summarise(
      exposure = "any_day_sched",
      exposure_label = "Any full-day schedule",
      exposure_value = any_day_sched[1],
      n = n(),
      mean_dark = mean(p_dark_iqr_block, na.rm = TRUE),
      median_dark = median(p_dark_iqr_block, na.rm = TRUE),
      share_nonzero = mean(p_dark_iqr_block > 0, na.rm = TRUE),
      .groups = "drop"
    )
)
write.csv(means, MEANS_OUT, row.names = FALSE)

bins <- bind_rows(
  make_bins(analysis, "day_sched_minutes", "Full-day scheduled minutes"),
  make_bins(analysis, "overpass_sched_minutes", "Overpass scheduled minutes")
)
write.csv(bins, BINS_OUT, row.names = FALSE)

block_summary <- analysis %>%
  group_by(block_id, circuit) %>%
  summarise(
    n = n(),
    mean_coverage = mean(coverage_iqr, na.rm = TRUE),
    mean_dark = mean(p_dark_iqr_block, na.rm = TRUE),
    overpass_scheduled_rows = sum(any_overpass_sched == 1, na.rm = TRUE),
    full_day_scheduled_rows = sum(any_day_sched == 1, na.rm = TRUE),
    mean_dark_overpass_scheduled = mean(p_dark_iqr_block[any_overpass_sched == 1], na.rm = TRUE),
    mean_dark_overpass_not_scheduled = mean(p_dark_iqr_block[any_overpass_sched == 0], na.rm = TRUE),
    overpass_diff_pp = (mean_dark_overpass_scheduled - mean_dark_overpass_not_scheduled) * 100,
    .groups = "drop"
  )
write.csv(block_summary, BLOCK_SUMMARY_OUT, row.names = FALSE)

# -----------------------------
# 5) CONSOLE SUMMARY
# -----------------------------
preferred <- regressions %>%
  filter(exposure == "any_overpass_sched", spec_id == "block_date_fe")
preferred_minutes <- regressions %>%
  filter(exposure == "overpass_sched_minutes", spec_id == "block_date_fe")

cat("Wrote analysis panel:", PANEL_OUT, "\n")
cat("Wrote regressions:", REGRESSIONS_OUT, "\n")
cat("Wrote means:", MEANS_OUT, "\n")
cat("Wrote bins:", BINS_OUT, "\n")
cat("Wrote block summary:", BLOCK_SUMMARY_OUT, "\n")
cat(
  "Exposure date shift:",
  EXPOSURE_DATE_SHIFT_DAYS,
  "day(s); date is VJ product date; local_overpass_date is exposure date.\n"
)
cat("Rows:", nrow(analysis), "| blocks:", dplyr::n_distinct(analysis$block_id), "| VJ dates:", dplyr::n_distinct(analysis$date), "\n")
cat(
  "Preferred binary overpass + block/date FE:",
  sprintf("%.3f pp", preferred$scaled_effect_pp),
  "SE", sprintf("%.3f pp", preferred$scaled_se_pp),
  "p", format(preferred$p_value, scientific = TRUE),
  "R2", sprintf("%.3f", preferred$r_squared),
  "\n"
)
cat(
  "Preferred minutes overpass + block/date FE:",
  sprintf("%.3f pp per 60 min", preferred_minutes$scaled_effect_pp),
  "SE", sprintf("%.3f pp", preferred_minutes$scaled_se_pp),
  "p", format(preferred_minutes$p_value, scientific = TRUE),
  "R2", sprintf("%.3f", preferred_minutes$r_squared),
  "\n"
)
