#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
})

script_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
script_path <- if (length(script_arg) > 0) {
  normalizePath(sub("^--file=", "", script_arg[[1]]), mustWork = TRUE)
} else {
  normalizePath("validation/closeups/scripts/vj146a2_full_year_large_dark_events_brief_tables.R", mustWork = TRUE)
}
root <- normalizePath(file.path(dirname(script_path), "..", "..", ".."), mustWork = TRUE)
source(file.path(root, "validation", "scripts", "validation_paths.R"))
paths <- validation_paths(root, "closeups")
mlr_dir <- file.path(
  root,
  "Map Data/settlement_day_outputs_vj146a2/mlr_validation_2023"
)
events_path <- file.path(mlr_dir, "vj146a2_2023_mlr_validation_large_events.csv")
daily_path <- file.path(mlr_dir, "vj146a2_2023_mlr_validation_daily_panel.csv")

out_data <- paths$data_dir
dir.create(out_data, recursive = TRUE, showWarnings = FALSE)

events <- read_csv(events_path, show_col_types = FALSE) %>%
  mutate(
    vj_product_date = as.Date(vj_product_date),
    local_overpass_date = as.Date(local_overpass_date),
    population = as.numeric(population)
  ) %>%
  arrange(vj_product_date, desc(population), settlement_id)

daily <- read_csv(daily_path, show_col_types = FALSE) %>%
  mutate(date = as.Date(date))

full_events_out <- file.path(out_data, "vj146a2_full_year_large_dark_events.csv")
write_csv(events, full_events_out)

fmt_num <- function(x, digits = 0) {
  ifelse(is.na(x), "", formatC(x, format = "f", digits = digits, big.mark = ","))
}

fmt_prop <- function(x, digits = 4) {
  ifelse(is.na(x), "", formatC(x, format = "f", digits = digits))
}

md_table <- function(df) {
  if (nrow(df) == 0) {
    return("_No rows._")
  }
  knitr::kable(df, format = "pipe", align = "l")
}

event_counts <- tibble(threshold = c(5000, 10000, 50000, 100000)) %>%
  rowwise() %>%
  mutate(
    strict_events = sum(events$population >= threshold & events$strict_dark, na.rm = TRUE),
    strict_settlements = n_distinct(events$settlement_id[events$population >= threshold & events$strict_dark]),
    mostly_events = sum(events$population >= threshold & events$mostly_dark, na.rm = TRUE),
    mostly_settlements = n_distinct(events$settlement_id[events$population >= threshold & events$mostly_dark]),
    strict_events_jul_dec = sum(events$population >= threshold & events$strict_dark & events$vj_product_date >= as.Date("2023-07-01"), na.rm = TRUE),
    mostly_events_jul_dec = sum(events$population >= threshold & events$mostly_dark & events$vj_product_date >= as.Date("2023-07-01"), na.rm = TRUE)
  ) %>%
  ungroup() %>%
  transmute(
    `Population threshold` = paste0(">= ", fmt_num(threshold)),
    `Strict-dark events` = fmt_num(strict_events),
    `Strict-dark settlements` = fmt_num(strict_settlements),
    `Mostly-dark events, inclusive` = fmt_num(mostly_events),
    `Mostly-dark settlements` = fmt_num(mostly_settlements),
    `Jul-Dec strict` = fmt_num(strict_events_jul_dec),
    `Jul-Dec mostly` = fmt_num(mostly_events_jul_dec)
  )

strict_100k <- events %>%
  filter(population >= 100000, strict_dark) %>%
  arrange(vj_product_date, settlement_id) %>%
  transmute(
    Date = as.character(vj_product_date),
    `Local overpass` = as.character(local_overpass_date),
    `Settlement ID` = settlement_id,
    Settlement = village_name,
    Province = admin_cgaz_1,
    District = admin_cgaz_2,
    Population = fmt_num(population),
    p_lit_sett = fmt_prop(p_lit_sett),
    `Analysis median` = fmt_prop(analysis_median_p_lit),
    Drop = fmt_prop(drop_from_analysis_median),
    Coverage = fmt_prop(coverage),
    `Obs days` = fmt_num(analysis_obs_days),
    `MLR 01-02 MW` = fmt_num(mlr_mean_1_2am_primary, 1),
    `Shed share` = fmt_prop(shed_share_1_2am_primary)
  )

mostly_100k <- events %>%
  filter(population >= 100000, mostly_dark) %>%
  group_by(settlement_id, village_name, admin_cgaz_1, admin_cgaz_2, population) %>%
  summarise(
    events = n(),
    strict = sum(strict_dark, na.rm = TRUE),
    first_date = min(vj_product_date),
    last_date = max(vj_product_date),
    min_p_lit = min(p_lit_sett, na.rm = TRUE),
    median_event_p_lit = median(p_lit_sett, na.rm = TRUE),
    median_coverage = median(coverage, na.rm = TRUE),
    max_shed_share = max(shed_share_1_2am_primary, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(desc(events), desc(population)) %>%
  transmute(
    `Settlement ID` = settlement_id,
    Settlement = village_name,
    Province = admin_cgaz_1,
    District = admin_cgaz_2,
    Population = fmt_num(population),
    Events = fmt_num(events),
    Strict = fmt_num(strict),
    `First date` = as.character(first_date),
    `Last date` = as.character(last_date),
    `Min p_lit` = fmt_prop(min_p_lit),
    `Median p_lit on event days` = fmt_prop(median_event_p_lit),
    `Median coverage` = fmt_prop(median_coverage),
    `Max shed share` = fmt_prop(max_shed_share)
  )

recurring_strict_50k <- events %>%
  filter(population >= 50000, strict_dark) %>%
  group_by(settlement_id, village_name, admin_cgaz_1, admin_cgaz_2, population) %>%
  summarise(
    strict_events = n(),
    first_date = min(vj_product_date),
    last_date = max(vj_product_date),
    min_p_lit = min(p_lit_sett, na.rm = TRUE),
    median_coverage = median(coverage, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(desc(strict_events), desc(population)) %>%
  slice_head(n = 20) %>%
  transmute(
    `Settlement ID` = settlement_id,
    Settlement = village_name,
    Province = admin_cgaz_1,
    District = admin_cgaz_2,
    Population = fmt_num(population),
    `Strict events` = fmt_num(strict_events),
    `First date` = as.character(first_date),
    `Last date` = as.character(last_date),
    `Min p_lit` = fmt_prop(min_p_lit),
    `Median coverage` = fmt_prop(median_coverage)
  )

clusters_50k <- events %>%
  filter(population >= 50000, mostly_dark) %>%
  group_by(vj_product_date, local_overpass_date) %>%
  summarise(
    mostly_events = n(),
    strict_events = sum(strict_dark, na.rm = TRUE),
    affected_population_sum = sum(population, na.rm = TRUE),
    max_population = max(population, na.rm = TRUE),
    mean_shed_share = mean(shed_share_1_2am_primary, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(desc(mostly_events), desc(affected_population_sum), vj_product_date) %>%
  slice_head(n = 20) %>%
  transmute(
    Date = as.character(vj_product_date),
    `Local overpass` = as.character(local_overpass_date),
    `Mostly events >=50k` = fmt_num(mostly_events),
    `Strict events >=50k` = fmt_num(strict_events),
    `Affected population sum` = fmt_num(affected_population_sum),
    `Largest settlement pop.` = fmt_num(max_population),
    `Mean shed share` = fmt_prop(mean_shed_share)
  )

priority <- events %>%
  filter(population >= 50000) %>%
  mutate(
    size_score = log1p(population) / max(log1p(population), na.rm = TRUE),
    darkness_score = pmax(0, drop_from_analysis_median),
    coverage_score = pmin(coverage, 1),
    shed_score = coalesce(shed_share_1_2am_primary, 0),
    strict_bonus = if_else(strict_dark, 0.35, 0),
    score = size_score + darkness_score + coverage_score + strict_bonus + shed_score
  ) %>%
  arrange(desc(score), vj_product_date) %>%
  group_by(settlement_id) %>%
  slice_head(n = 1) %>%
  ungroup()

priority_diverse <- bind_rows(
  priority %>% filter(strict_dark, population >= 100000) %>% slice_max(score, n = 3, with_ties = FALSE),
  priority %>% filter(!settlement_id %in% c(30250, 76354, 73644), mostly_dark, population >= 100000) %>% slice_max(score, n = 5, with_ties = FALSE),
  priority %>% filter(strict_dark, population >= 50000, population < 100000) %>% slice_max(score, n = 5, with_ties = FALSE),
  priority %>% filter(vj_product_date >= as.Date("2023-07-01"), population >= 50000) %>% slice_max(score, n = 5, with_ties = FALSE)
) %>%
  distinct(settlement_id, .keep_all = TRUE) %>%
  arrange(desc(score)) %>%
  slice_head(n = 15)

priority_out <- file.path(out_data, "vj146a2_full_year_diverse_pixel_closeup_candidates.csv")
write_csv(priority_diverse, priority_out)

priority_table <- priority_diverse %>%
  transmute(
    Date = as.character(vj_product_date),
    `Local overpass` = as.character(local_overpass_date),
    `Settlement ID` = settlement_id,
    Settlement = village_name,
    Province = admin_cgaz_1,
    District = admin_cgaz_2,
    Population = fmt_num(population),
    Class = event_class,
    p_lit = fmt_prop(p_lit_sett),
    Median = fmt_prop(analysis_median_p_lit),
    Drop = fmt_prop(drop_from_analysis_median),
    Coverage = fmt_prop(coverage),
    `Obs days` = fmt_num(analysis_obs_days),
    `MLR MW` = fmt_num(mlr_mean_1_2am_primary, 1),
    `Shed share` = fmt_prop(shed_share_1_2am_primary)
  )

monthly_counts <- events %>%
  mutate(month = format(vj_product_date, "%Y-%m")) %>%
  group_by(month) %>%
  summarise(
    strict_events = sum(strict_dark, na.rm = TRUE),
    mostly_events = sum(mostly_dark, na.rm = TRUE),
    settlements = n_distinct(settlement_id),
    .groups = "drop"
  ) %>%
  transmute(
    Month = month,
    `Strict-dark events` = fmt_num(strict_events),
    `Mostly-dark events, inclusive` = fmt_num(mostly_events),
    `Settlements with any event` = fmt_num(settlements)
  )

coverage_note <- daily %>%
  summarise(
    n_days = n(),
    min_date = min(date),
    max_date = max(date),
    n_quality_min = min(n_quality_settlements, na.rm = TRUE),
    n_quality_median = median(n_quality_settlements, na.rm = TRUE),
    n_quality_max = max(n_quality_settlements, na.rm = TRUE)
  )

out <- c(
  "# Generated Full-Year Large Dark Event Tables",
  "",
  paste0("Events source: `", events_path, "`"),
  paste0("Full work copy: `", full_events_out, "`"),
  paste0("Priority candidates: `", priority_out, "`"),
  "",
  "## Coverage Note",
  md_table(coverage_note %>% transmute(
    `Daily panel days` = fmt_num(n_days),
    `Min date` = as.character(min_date),
    `Max date` = as.character(max_date),
    `Min daily quality settlements` = fmt_num(n_quality_min),
    `Median daily quality settlements` = fmt_num(n_quality_median),
    `Max daily quality settlements` = fmt_num(n_quality_max)
  )),
  "",
  "## Event Counts",
  md_table(event_counts),
  "",
  "## Monthly Counts",
  md_table(monthly_counts),
  "",
  "## Strict >100k",
  md_table(strict_100k),
  "",
  "## Mostly >100k",
  md_table(mostly_100k),
  "",
  "## Recurring Strict >50k",
  md_table(recurring_strict_50k),
  "",
  "## Clustered Dates >50k",
  md_table(clusters_50k),
  "",
  "## Priority Candidates",
  md_table(priority_table)
)

writeLines(out, file.path(out_data, "vj146a2_full_year_large_dark_events_tables.md"))

message("Wrote ", full_events_out)
message("Wrote ", priority_out)
message("Wrote ", file.path(out_data, "vj146a2_full_year_large_dark_events_tables.md"))
