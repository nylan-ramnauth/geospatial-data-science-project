#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
  library(readr)
  library(stringr)
  library(tidyr)
})

script_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
script_path <- if (length(script_arg) > 0) {
  normalizePath(sub("^--file=", "", script_arg[[1]]), mustWork = TRUE)
} else {
  normalizePath("validation/closeups/scripts/vj146a2_full_year_plot_gif_candidate_screen.R", mustWork = TRUE)
}
root <- normalizePath(file.path(dirname(script_path), "..", "..", ".."), mustWork = TRUE)
source(file.path(root, "validation", "scripts", "validation_paths.R"))
paths <- validation_paths(root, "closeups")
settlement_dir <- file.path(
  root,
  "Map Data/settlement_day_outputs_vj146a2"
)
mlr_dir <- file.path(settlement_dir, "mlr_validation_2023")
events_path <- file.path(mlr_dir, "vj146a2_2023_mlr_validation_large_events.csv")
priority_existing_path <- file.path(paths$data_dir, "vj146a2_full_year_diverse_pixel_closeup_candidates.csv")

out_data <- paths$data_dir
out_report <- paths$reports_dir
dir.create(out_data, recursive = TRUE, showWarnings = FALSE)
dir.create(out_report, recursive = TRUE, showWarnings = FALSE)

coverage_min <- as.numeric(Sys.getenv("VJ146A2_CANDIDATE_MIN_COVERAGE", "0.80"))
obs_min <- as.numeric(Sys.getenv("VJ146A2_CANDIDATE_MIN_OBS_DAYS", "180"))
large_pop_min <- as.numeric(Sys.getenv("VJ146A2_CANDIDATE_LARGE_POP_MIN", "50000"))
secondary_pop_min <- as.numeric(Sys.getenv("VJ146A2_CANDIDATE_SECONDARY_POP_MIN", "10000"))

month_files <- file.path(
  settlement_dir,
  sprintf("settlement_day_vj146a2_cov_yearlykeep_2023-%02d.parquet", 1:12)
)
missing_files <- month_files[!file.exists(month_files)]
if (length(missing_files) > 0) {
  stop("Missing yearlykeep monthly panels:\n", paste(missing_files, collapse = "\n"))
}

message("Reading ", length(month_files), " yearlykeep monthly panels")
panel <- lapply(month_files, function(path) {
  read_parquet(
    path,
    col_select = c(
      settlement_id, date, coverage, p_lit_sett, mean_rad_sett,
      median_rad_sett, population, lon, lat
    ),
    as_data_frame = TRUE
  )
}) %>%
  bind_rows() %>%
  mutate(
    settlement_id = as.character(settlement_id),
    date = as.Date(date)
  ) %>%
  arrange(settlement_id, date)

events <- read_csv(events_path, show_col_types = FALSE) %>%
  mutate(
    settlement_id = as.character(settlement_id),
    vj_product_date = as.Date(vj_product_date),
    local_overpass_date = as.Date(local_overpass_date)
  )

existing_priority <- read_csv(priority_existing_path, show_col_types = FALSE) %>%
  transmute(
    existing_priority = TRUE,
    settlement_id = as.character(settlement_id),
    vj_product_date = as.Date(vj_product_date)
  )
existing_priority_settlements <- unique(existing_priority$settlement_id)

panel_lookup <- panel %>%
  select(
    settlement_id,
    date,
    coverage,
    p_lit_sett,
    mean_rad_sett,
    median_rad_sett
  )

event_windows <- events %>%
  mutate(
    prev_date = vj_product_date - 1,
    next_date = vj_product_date + 1
  ) %>%
  left_join(
    panel_lookup %>%
      rename(
        prev_date = date,
        prev_coverage = coverage,
        prev_p_lit = p_lit_sett,
        prev_mean_rad = mean_rad_sett,
        prev_median_rad = median_rad_sett
      ),
    by = c("settlement_id", "prev_date")
  ) %>%
  left_join(
    panel_lookup %>%
      rename(
        next_date = date,
        next_coverage = coverage,
        next_p_lit = p_lit_sett,
        next_mean_rad = mean_rad_sett,
        next_median_rad = median_rad_sett
      ),
    by = c("settlement_id", "next_date")
  ) %>%
  mutate(
    event_coverage = coverage,
    event_p_lit = p_lit_sett,
    has_prev_next = !is.na(prev_p_lit) & !is.na(next_p_lit),
    min_window_coverage = pmin(prev_coverage, event_coverage, next_coverage, na.rm = FALSE),
    mean_neighbor_p_lit = (prev_p_lit + next_p_lit) / 2,
    min_neighbor_p_lit = pmin(prev_p_lit, next_p_lit, na.rm = FALSE),
    max_neighbor_p_lit = pmax(prev_p_lit, next_p_lit, na.rm = FALSE),
    neighbor_drop = mean_neighbor_p_lit - event_p_lit,
    recovery_drop = next_p_lit - event_p_lit,
    onset_drop = prev_p_lit - event_p_lit,
    enough_obs = analysis_obs_days >= obs_min,
    enough_coverage_3day = has_prev_next & min_window_coverage >= coverage_min,
    sharp_dip = enough_coverage_3day &
      enough_obs &
      event_p_lit < 0.20 &
      min_neighbor_p_lit >= 0.45 &
      neighbor_drop >= 0.40,
    sustained_episode = enough_coverage_3day &
      enough_obs &
      event_p_lit < 0.20 &
      mean_neighbor_p_lit < 0.35,
    score = log1p(population) +
      pmax(drop_from_analysis_median, 0) * 2 +
      pmax(neighbor_drop, 0) * 2 +
      min_window_coverage +
      if_else(strict_dark, 1, 0) +
      coalesce(shed_share_1_2am_primary, 0) * 2,
    candidate_type = case_when(
      sharp_dip ~ "notebook_sharp_three_day_dip",
      sustained_episode ~ "gif_sustained_high_coverage_episode",
      enough_coverage_3day & enough_obs ~ "usable_three_day_window",
      TRUE ~ "not_recommended"
    )
  ) %>%
  left_join(existing_priority, by = c("settlement_id", "vj_product_date")) %>%
  mutate(existing_priority = coalesce(existing_priority, FALSE))

screened_path <- file.path(out_data, "vj146a2_full_year_plot_gif_candidate_screen.csv")
write_csv(event_windows, screened_path)

select_diverse <- function(df, n) {
  df %>%
    arrange(desc(score), vj_product_date) %>%
    group_by(settlement_id) %>%
    slice_head(n = 1) %>%
    ungroup() %>%
    slice_head(n = n)
}

new_notebook <- event_windows %>%
  filter(
    !settlement_id %in% existing_priority_settlements,
    population >= large_pop_min,
    sharp_dip
  ) %>%
  select_diverse(15)

new_gif <- event_windows %>%
  filter(
    !settlement_id %in% existing_priority_settlements,
    population >= large_pop_min,
    sustained_episode
  ) %>%
  select_diverse(15)

secondary <- event_windows %>%
  filter(
    !settlement_id %in% existing_priority_settlements,
    population >= secondary_pop_min,
    population < large_pop_min,
    sharp_dip,
    min_window_coverage >= 0.90,
    analysis_obs_days >= 220
  ) %>%
  select_diverse(15)

recommended <- bind_rows(
  new_notebook %>% mutate(recommendation_group = "large_notebook_sharp_dip"),
  new_gif %>% mutate(recommendation_group = "large_gif_sustained_episode"),
  secondary %>% mutate(recommendation_group = "secondary_10k_50k_sharp_dip")
) %>%
  arrange(recommendation_group, desc(score))

recommended_path <- file.path(out_data, "vj146a2_full_year_additional_plot_gif_candidates.csv")
write_csv(recommended, recommended_path)

fmt_num <- function(x, digits = 0) {
  ifelse(is.na(x), "", formatC(x, format = "f", digits = digits, big.mark = ","))
}
fmt_prop <- function(x, digits = 4) {
  ifelse(is.na(x), "", formatC(x, format = "f", digits = digits))
}
md_table <- function(df) {
  if (nrow(df) == 0) {
    return("_No rows met the criteria._")
  }
  knitr::kable(df, format = "pipe", align = "l")
}
report_cols <- function(df) {
  df %>%
    transmute(
      Date = as.character(vj_product_date),
      `Local overpass` = as.character(local_overpass_date),
      `Settlement ID` = settlement_id,
      Settlement = village_name,
      Province = admin_cgaz_1,
      District = admin_cgaz_2,
      Population = fmt_num(population),
      Class = event_class,
      `Prev p_lit` = fmt_prop(prev_p_lit),
      `Event p_lit` = fmt_prop(event_p_lit),
      `Next p_lit` = fmt_prop(next_p_lit),
      `Min 3-day coverage` = fmt_prop(min_window_coverage),
      `Obs days` = fmt_num(analysis_obs_days),
      `Neighbor drop` = fmt_prop(neighbor_drop),
      `Shed share` = fmt_prop(shed_share_1_2am_primary)
    )
}

summary_tbl <- event_windows %>%
  summarise(
    total_events = n(),
    n_with_prev_next = sum(has_prev_next, na.rm = TRUE),
    n_enough_coverage_3day = sum(enough_coverage_3day, na.rm = TRUE),
    n_enough_obs_and_coverage = sum(coalesce(enough_coverage_3day, FALSE) & coalesce(enough_obs, FALSE)),
    n_sharp_dips = sum(sharp_dip, na.rm = TRUE),
    n_sustained = sum(sustained_episode, na.rm = TRUE),
    n_large_sharp_dips = sum(sharp_dip & population >= large_pop_min, na.rm = TRUE),
    n_large_sustained = sum(sustained_episode & population >= large_pop_min, na.rm = TRUE)
  ) %>%
  transmute(
    `Large-event rows screened` = fmt_num(total_events),
    `Rows with prev+next data` = fmt_num(n_with_prev_next),
    `Rows passing 3-day coverage screen` = fmt_num(n_enough_coverage_3day),
    `Rows passing observation+coverage screen` = fmt_num(n_enough_obs_and_coverage),
    `Sharp three-day dips` = fmt_num(n_sharp_dips),
    `Sustained high-coverage episodes` = fmt_num(n_sustained),
    `Large sharp dips >=50k` = fmt_num(n_large_sharp_dips),
    `Large sustained episodes >=50k` = fmt_num(n_large_sustained)
  )

report_path <- file.path(out_report, "2026-06-03-vj-full-year-additional-plot-gif-candidates.md")
report <- c(
  "# VJ146A2 Full-Year Additional Plot/GIF Candidates",
  "",
  "**Date:** 2026-06-03  ",
  "**Status:** Working candidate screen  ",
  "**Input events:** `6-codebases/repos/Reliability-Assessment/Map Data/settlement_day_outputs_vj146a2/mlr_validation_2023/vj146a2_2023_mlr_validation_large_events.csv`  ",
  "**Underlying panel:** `6-codebases/repos/Reliability-Assessment/Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_cov_yearlykeep_2023-MM.parquet`  ",
  "**Screened event table:** `validation/closeups/data/vj146a2_full_year_plot_gif_candidate_screen.csv`  ",
  "**Recommended candidates:** `validation/closeups/data/vj146a2_full_year_additional_plot_gif_candidates.csv`  ",
  "**Related reports:** `validation/closeups/reports/2026-06-03-vj-full-year-dark-events-brief.md`, `validation/eskom_mlr/reports/2026-06-03-vj-full-year-mlr-validation-calibration.md`  ",
  "",
  "## Method",
  "",
  "This screen starts from the full-year large-event table and joins each event to the same settlement's previous-day and next-day rows in the VJ yearlykeep coverage-filtered monthly panels. This is stricter than ranking event days alone: a candidate is useful for a notebook or GIF only if the surrounding days actually exist in the panel and have enough valid coverage.",
  "",
  paste0("- Minimum coverage on each of previous/event/next day: `", coverage_min, "`."),
  paste0("- Minimum full-year retained observations for the settlement: `", obs_min, "`."),
  "- `notebook_sharp_three_day_dip`: event `p_lit_sett < 0.20`, both neighboring days `p_lit_sett >= 0.45`, and average neighbor-to-event drop at least `0.40`.",
  "- `gif_sustained_high_coverage_episode`: event `p_lit_sett < 0.20`, previous/event/next rows all available with enough coverage, but neighboring days are also dark on average. These are less ideal for a before/after contrast panel but useful for an animated sequence.",
  "- Settlement IDs already present in the 15 priority candidates from the full-year brief are excluded here so this list surfaces additional settlements.",
  "",
  "## Screen Summary",
  md_table(summary_tbl),
  "",
  "## Additional Large Settlements For Notebook Panels",
  "",
  "These are new `population >= 50,000` candidates with clean previous/event/next observations and a visible one-day drop.",
  "",
  md_table(report_cols(new_notebook)),
  "",
  "## Additional Large Settlements For GIFs",
  "",
  "These are new `population >= 50,000` candidates with strong coverage but a sustained dark spell rather than a clean one-day dip.",
  "",
  md_table(report_cols(new_gif)),
  "",
  "## Secondary 10k-50k Candidates",
  "",
  "These are smaller settlements with very clean support. They are useful if the notebook needs a broader size gradient.",
  "",
  md_table(report_cols(secondary)),
  "",
  "## Interpretation",
  "",
  "The notebook list is better for side-by-side before/event/after panels because both neighboring days are visibly brighter. The GIF list is better for multi-day sequences because the dark state often persists into neighboring days. Neither list confirms blackouts by itself; both lists only identify high-support candidates for raw-pixel inspection."
)

writeLines(report, report_path)

message("Wrote ", screened_path)
message("Wrote ", recommended_path)
message("Wrote ", report_path)
