#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(arrow)
  library(data.table)
  library(dplyr)
  library(sf)
})

sf::sf_use_s2(FALSE)
data.table::setDTthreads(0L)

script_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
script_path <- if (length(script_arg) > 0) {
  normalizePath(sub("^--file=", "", script_arg[[1]]), mustWork = TRUE)
} else {
  normalizePath("validation/pypsa_uptime/scripts/compare_vj146a2_localarea_uptime_excess_lit_exclusion.R", mustWork = TRUE)
}
repo_dir <- normalizePath(file.path(dirname(script_path), "..", "..", ".."), mustWork = TRUE)
source(file.path(repo_dir, "validation", "scripts", "validation_paths.R"))
paths <- validation_paths(repo_dir, "pypsa_uptime")

codebase_dir <- paths$repo_root
rel_dir <- file.path(codebase_dir, "Map Data", "reliability_outputs_vj146a2")
diag_dir <- file.path(rel_dir, "diagnostics")
work_data_dir <- paths$data_dir
dir.create(work_data_dir, recursive = TRUE, showWarnings = FALSE)

flags_file <- validation_section_data(paths, "eskom_mlr", "vj146a2_2023_annual_iqr_excess_lit_day_flags.csv")
scenario_id <- "annual_q3_plus_1p5_iqr"

baseline_local_file <- file.path(rel_dir, "localarea_reliability_yearly_strict_yearlykeep_postdoe.parquet")
excluded_local_file <- file.path(rel_dir, "localarea_reliability_yearly_strict_yearlykeep_postdoe_annual_excess_lit_iqr.parquet")
baseline_state_file <- file.path(rel_dir, "settlement_day_states_strict_yearlykeep.parquet")
excluded_state_file <- file.path(rel_dir, "settlement_day_states_strict_yearlykeep_annual_excess_lit_iqr.parquet")
baseline_diag_file <- file.path(diag_dir, "diagnostic_localarea_drop_yearly_strict_yearlykeep_postdoe_2023-01_to_2023-12.parquet")
excluded_diag_file <- file.path(diag_dir, "diagnostic_localarea_drop_yearly_strict_yearlykeep_postdoe_2023-01_to_2023-12_annual_excess_lit_iqr.parquet")

sett_gpkg <- file.path(
  codebase_dir,
  "Map Data", "Settlements", "GPKG",
  "south_africa_dre_atlas_settlements_simplified_full_col.gpkg"
)
sett_layer <- "settlements_simplified"
local_area_shp <- file.path(codebase_dir, "Map Data", "Local Area", "LOCAL_AREA_GCCA2025.shp")

required_files <- c(
  flags_file,
  baseline_local_file,
  excluded_local_file,
  baseline_state_file,
  excluded_state_file,
  baseline_diag_file,
  excluded_diag_file,
  sett_gpkg,
  local_area_shp
)
missing_files <- required_files[!file.exists(required_files)]
if (length(missing_files) > 0) {
  stop("Missing required file(s):\n", paste(missing_files, collapse = "\n"))
}

first_non_na <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA_real_)
  x[[1]]
}

q_safe <- function(x, p) {
  x <- x[is.finite(x)]
  if (length(x) == 0) return(NA_real_)
  as.numeric(stats::quantile(x, probs = p, na.rm = TRUE, names = FALSE))
}

write_csv_dt <- function(x, path) {
  data.table::fwrite(x, path, na = "")
  message("Wrote: ", path)
}

load_exclusion_dates <- function(path, scenario) {
  flags <- data.table::fread(path)
  flags[, date := as.Date(date)]
  flags[["date"]][flags[["scenario"]] == scenario & flags[["remove"]] == TRUE]
}

standardize_local <- function(path, suffix) {
  dt <- data.table::as.data.table(arrow::read_parquet(path))
  dt[, year := as.Date(year)]
  keep <- c(
    "area_name", "year", "n_settlements", "kept_population", "uptime_popw",
    "sd_uptime_popw", "dark_share_popw", "mean_p_lit_popw", "cv_p_lit_popw",
    "switch_rate_popw", "mean_coverage_popw", "area_population",
    "share_population_kept"
  )
  dt <- dt[, ..keep]
  data.table::setnames(dt, setdiff(names(dt), c("area_name", "year")), paste0(setdiff(names(dt), c("area_name", "year")), "_", suffix))
  dt
}

assign_local_areas <- function(sett_sf, local_areas) {
  st_join(
    st_transform(st_point_on_surface(sett_sf), st_crs(local_areas)),
    local_areas["LocalArea"],
    left = TRUE
  ) |>
    st_drop_geometry() |>
    distinct(settlement_id, .keep_all = TRUE) |>
    transmute(
      settlement_id = as.character(settlement_id),
      area_name = as.character(LocalArea)
    )
}

message("Reading yearly local-area reliability outputs...")
baseline_local <- standardize_local(baseline_local_file, "baseline")
excluded_local <- standardize_local(excluded_local_file, "excluded")

local_compare <- merge(
  baseline_local,
  excluded_local,
  by = c("area_name", "year"),
  all = TRUE
)

local_compare[, `:=`(
  uptime_delta = uptime_popw_excluded - uptime_popw_baseline,
  uptime_delta_pp = 100 * (uptime_popw_excluded - uptime_popw_baseline),
  dark_share_delta_pp = 100 * (dark_share_popw_excluded - dark_share_popw_baseline),
  mean_p_lit_delta_pp = 100 * (mean_p_lit_popw_excluded - mean_p_lit_popw_baseline),
  mean_coverage_delta_pp = 100 * (mean_coverage_popw_excluded - mean_coverage_popw_baseline),
  kept_population_delta = kept_population_excluded - kept_population_baseline,
  share_population_kept_delta_pp = 100 * (share_population_kept_excluded - share_population_kept_baseline),
  n_settlements_delta = n_settlements_excluded - n_settlements_baseline
)]

local_compare[, abs_uptime_delta_pp := abs(uptime_delta_pp)]
setorder(local_compare, -abs_uptime_delta_pp, area_name)
local_compare[, abs_uptime_delta_pp := NULL]
write_csv_dt(local_compare, file.path(work_data_dir, "vj146a2_2023_localarea_uptime_excess_lit_exclusion_comparison.csv"))

message("Reading diagnostics...")
diag_baseline <- data.table::as.data.table(arrow::read_parquet(baseline_diag_file))
diag_excluded <- data.table::as.data.table(arrow::read_parquet(excluded_diag_file))
diag_baseline[, scenario := "baseline_no_exclusion"]
diag_excluded[, scenario := "annual_iqr_excess_lit_excluded"]
diag <- rbindlist(list(diag_baseline, diag_excluded), fill = TRUE)
write_csv_dt(diag, file.path(work_data_dir, "vj146a2_2023_localarea_reliability_support_diagnostics_baseline_vs_excluded.csv"))

message("Building LocalArea population denominators...")
local_areas <- st_read(local_area_shp, quiet = TRUE)
sett_all <- st_read(sett_gpkg, layer = sett_layer, quiet = TRUE) |>
  mutate(settlement_id = as.character(settlement_id))
if (!("population" %in% names(sett_all))) {
  stop("Settlement GPKG does not contain a population column.")
}

all_local_lookup <- assign_local_areas(sett_all, local_areas)
all_static <- sett_all |>
  st_drop_geometry() |>
  distinct(settlement_id, .keep_all = TRUE) |>
  transmute(settlement_id = as.character(settlement_id), population = as.numeric(population))
all_area_pop <- as.data.table(all_static) |>
  merge(as.data.table(all_local_lookup), by = "settlement_id", all.x = TRUE) |>
  (\(dt) dt[!is.na(area_name) & !is.na(population), .(all_settlement_population = sum(population)), by = area_name])()

state_cols <- c("settlement_id", "date", "population", "coverage", "p_lit_sett")
message("Reading baseline daily state cache...")
baseline_state <- data.table::as.data.table(arrow::read_parquet(baseline_state_file, col_select = all_of(state_cols)))
baseline_state[, settlement_id := as.character(settlement_id)]
baseline_state[, date := as.Date(date)]

analysis_static <- baseline_state[
  ,
  .(analysis_population = first_non_na(as.numeric(population))),
  by = settlement_id
]
analysis_local_lookup <- all_local_lookup |>
  filter(settlement_id %in% analysis_static$settlement_id)
analysis_area_pop <- merge(
  analysis_static,
  as.data.table(analysis_local_lookup),
  by = "settlement_id",
  all.x = TRUE
)[
  !is.na(area_name) & !is.na(analysis_population),
  .(analysis_area_population = sum(analysis_population)),
  by = area_name
]
analysis_area_pop <- merge(analysis_area_pop, all_area_pop, by = "area_name", all.x = TRUE)
analysis_area_pop[, analysis_population_share_of_all_settlement_pop := analysis_area_population / all_settlement_population]

lookup_dt <- as.data.table(analysis_local_lookup)
lookup_dt <- lookup_dt[!is.na(area_name)]
setkey(lookup_dt, settlement_id)
setkey(analysis_area_pop, area_name)

excluded_dates <- load_exclusion_dates(flags_file, scenario_id)
excluded_dates_table <- data.table(
  scenario = scenario_id,
  n_excluded_dates = length(excluded_dates),
  excluded_dates = paste(as.character(sort(excluded_dates)), collapse = ";")
)
write_csv_dt(excluded_dates_table, file.path(work_data_dir, "vj146a2_2023_annual_iqr_excess_lit_excluded_dates_used_for_reliability.csv"))

summarize_daily_coverage <- function(state_dt, scenario, excluded_dates_to_drop = as.Date(character())) {
  dt <- copy(state_dt)
  if (length(excluded_dates_to_drop) > 0) {
    dt <- dt[!(date %in% excluded_dates_to_drop)]
  }
  dt <- merge(dt, lookup_dt, by = "settlement_id", all.x = FALSE, allow.cartesian = TRUE)
  dt[, population := as.numeric(population)]
  dt[, coverage_clipped := fifelse(is.na(coverage), NA_real_, pmin(pmax(as.numeric(coverage), 0), 1))]
  dt[, observed := !is.na(p_lit_sett)]
  dt[, coverage_ge50 := !is.na(coverage) & coverage >= 0.5]

  daily <- dt[
    ,
    .(
      n_settlements = uniqueN(settlement_id),
      n_settlements_observed = uniqueN(settlement_id[observed == TRUE]),
      n_settlements_coverage_ge50 = uniqueN(settlement_id[coverage_ge50 == TRUE]),
      observed_population = sum(fifelse(observed == TRUE, population, 0), na.rm = TRUE),
      coverage_ge50_population = sum(fifelse(coverage_ge50 == TRUE, population, 0), na.rm = TRUE),
      coverage_weighted_population = sum(fifelse(!is.na(coverage_clipped), population * coverage_clipped, 0), na.rm = TRUE)
    ),
    by = .(area_name, date)
  ]
  daily[, scenario := scenario]
  daily <- merge(daily, analysis_area_pop, by = "area_name", all.x = TRUE)
  daily[, `:=`(
    observed_population_share = observed_population / analysis_area_population,
    coverage_ge50_population_share = coverage_ge50_population / analysis_area_population,
    coverage_weighted_population_share = coverage_weighted_population / analysis_area_population,
    observed_population_share_of_all_settlement_pop = observed_population / all_settlement_population,
    coverage_ge50_population_share_of_all_settlement_pop = coverage_ge50_population / all_settlement_population
  )]
  setcolorder(
    daily,
    c(
      "scenario", "area_name", "date", "analysis_area_population",
      "all_settlement_population", "analysis_population_share_of_all_settlement_pop",
      setdiff(names(daily), c("scenario", "area_name", "date", "analysis_area_population", "all_settlement_population", "analysis_population_share_of_all_settlement_pop"))
    )
  )
  daily[]
}

message("Summarizing baseline daily coverage...")
baseline_daily <- summarize_daily_coverage(baseline_state, "baseline_no_exclusion")
rm(baseline_state)
gc()

message("Reading excluded daily state cache...")
excluded_state <- data.table::as.data.table(arrow::read_parquet(excluded_state_file, col_select = all_of(state_cols)))
excluded_state[, settlement_id := as.character(settlement_id)]
excluded_state[, date := as.Date(date)]

message("Summarizing excluded daily coverage...")
excluded_daily <- summarize_daily_coverage(excluded_state, "annual_iqr_excess_lit_excluded", excluded_dates)
rm(excluded_state)
gc()

daily_coverage <- rbindlist(list(baseline_daily, excluded_daily), use.names = TRUE, fill = TRUE)
setorder(daily_coverage, area_name, scenario, date)
write_csv_dt(daily_coverage, file.path(work_data_dir, "vj146a2_2023_localarea_daily_population_coverage_baseline_vs_excluded.csv"))

coverage_summary <- daily_coverage[
  ,
  .(
    n_calendar_dates_in_scope = .N,
    n_dates_any_observed = sum(observed_population_share > 0, na.rm = TRUE),
    n_dates_observed_pop_ge50 = sum(observed_population_share >= 0.5, na.rm = TRUE),
    share_dates_observed_pop_ge50 = mean(observed_population_share >= 0.5, na.rm = TRUE),
    n_dates_coverage_ge50_pop_ge50 = sum(coverage_ge50_population_share >= 0.5, na.rm = TRUE),
    share_dates_coverage_ge50_pop_ge50 = mean(coverage_ge50_population_share >= 0.5, na.rm = TRUE),
    min_observed_pop_share = min(observed_population_share, na.rm = TRUE),
    p10_observed_pop_share = q_safe(observed_population_share, 0.10),
    median_observed_pop_share = stats::median(observed_population_share, na.rm = TRUE),
    mean_observed_pop_share = mean(observed_population_share, na.rm = TRUE),
    min_coverage_ge50_pop_share = min(coverage_ge50_population_share, na.rm = TRUE),
    p10_coverage_ge50_pop_share = q_safe(coverage_ge50_population_share, 0.10),
    median_coverage_ge50_pop_share = stats::median(coverage_ge50_population_share, na.rm = TRUE),
    mean_coverage_ge50_pop_share = mean(coverage_ge50_population_share, na.rm = TRUE),
    min_coverage_weighted_pop_share = min(coverage_weighted_population_share, na.rm = TRUE),
    p10_coverage_weighted_pop_share = q_safe(coverage_weighted_population_share, 0.10),
    median_coverage_weighted_pop_share = stats::median(coverage_weighted_population_share, na.rm = TRUE),
    mean_coverage_weighted_pop_share = mean(coverage_weighted_population_share, na.rm = TRUE),
    analysis_area_population = first(analysis_area_population),
    all_settlement_population = first(all_settlement_population),
    analysis_population_share_of_all_settlement_pop = first(analysis_population_share_of_all_settlement_pop)
  ),
  by = .(scenario, area_name)
]
setorder(coverage_summary, area_name, scenario)
write_csv_dt(coverage_summary, file.path(work_data_dir, "vj146a2_2023_localarea_daily_population_coverage_summary_baseline_vs_excluded.csv"))

coverage_summary_wide <- dcast(
  coverage_summary,
  area_name + analysis_area_population + all_settlement_population + analysis_population_share_of_all_settlement_pop ~ scenario,
  value.var = setdiff(names(coverage_summary), c("scenario", "area_name", "analysis_area_population", "all_settlement_population", "analysis_population_share_of_all_settlement_pop"))
)
for (metric in c(
  "n_calendar_dates_in_scope",
  "n_dates_any_observed",
  "n_dates_observed_pop_ge50",
  "share_dates_observed_pop_ge50",
  "n_dates_coverage_ge50_pop_ge50",
  "share_dates_coverage_ge50_pop_ge50",
  "mean_observed_pop_share",
  "mean_coverage_ge50_pop_share",
  "mean_coverage_weighted_pop_share"
)) {
  before_col <- paste0(metric, "_baseline_no_exclusion")
  after_col <- paste0(metric, "_annual_iqr_excess_lit_excluded")
  if (before_col %in% names(coverage_summary_wide) && after_col %in% names(coverage_summary_wide)) {
    coverage_summary_wide[, (paste0(metric, "_delta")) := get(after_col) - get(before_col)]
  }
}
write_csv_dt(coverage_summary_wide, file.path(work_data_dir, "vj146a2_2023_localarea_daily_population_coverage_summary_wide_baseline_vs_excluded.csv"))

yearly_common <- local_compare[!is.na(uptime_popw_baseline) & !is.na(uptime_popw_excluded)]
national_yearly_summary <- yearly_common[
  ,
  .(
    n_localareas_baseline = sum(!is.na(uptime_popw_baseline)),
    n_localareas_excluded = sum(!is.na(uptime_popw_excluded)),
    n_localareas_common = .N,
    popw_uptime_baseline = weighted.mean(uptime_popw_baseline, area_population_baseline, na.rm = TRUE),
    popw_uptime_excluded = weighted.mean(uptime_popw_excluded, area_population_excluded, na.rm = TRUE),
    popw_uptime_delta_pp = 100 * (
      weighted.mean(uptime_popw_excluded, area_population_excluded, na.rm = TRUE) -
        weighted.mean(uptime_popw_baseline, area_population_baseline, na.rm = TRUE)
    ),
    median_localarea_uptime_baseline = median(uptime_popw_baseline, na.rm = TRUE),
    median_localarea_uptime_excluded = median(uptime_popw_excluded, na.rm = TRUE),
    median_localarea_uptime_delta_pp = 100 * median(uptime_popw_excluded - uptime_popw_baseline, na.rm = TRUE),
    min_localarea_uptime_delta_pp = min(uptime_delta_pp, na.rm = TRUE),
    max_localarea_uptime_delta_pp = max(uptime_delta_pp, na.rm = TRUE),
    n_localareas_uptime_increased = sum(uptime_delta_pp > 0, na.rm = TRUE),
    n_localareas_uptime_decreased = sum(uptime_delta_pp < 0, na.rm = TRUE),
    min_share_population_kept_excluded = min(share_population_kept_excluded, na.rm = TRUE),
    n_localareas_share_population_kept_ge50_excluded = sum(share_population_kept_excluded >= 0.5, na.rm = TRUE),
    n_excluded_dates = length(excluded_dates)
  )
]
write_csv_dt(national_yearly_summary, file.path(work_data_dir, "vj146a2_2023_localarea_uptime_excess_lit_exclusion_national_summary.csv"))

national_daily_coverage <- daily_coverage[
  ,
  .(
    analysis_area_population = sum(analysis_area_population),
    all_settlement_population = sum(all_settlement_population),
    observed_population = sum(observed_population),
    coverage_ge50_population = sum(coverage_ge50_population),
    coverage_weighted_population = sum(coverage_weighted_population)
  ),
  by = .(scenario, date)
]
national_daily_coverage[, `:=`(
  observed_population_share = observed_population / analysis_area_population,
  coverage_ge50_population_share = coverage_ge50_population / analysis_area_population,
  coverage_weighted_population_share = coverage_weighted_population / analysis_area_population
)]
national_daily_summary <- national_daily_coverage[
  ,
  .(
    n_dates = .N,
    n_dates_any_observed = sum(observed_population_share > 0, na.rm = TRUE),
    n_dates_observed_pop_ge50 = sum(observed_population_share >= 0.5, na.rm = TRUE),
    n_dates_coverage_ge50_pop_ge50 = sum(coverage_ge50_population_share >= 0.5, na.rm = TRUE),
    min_observed_pop_share = min(observed_population_share, na.rm = TRUE),
    p10_observed_pop_share = q_safe(observed_population_share, 0.10),
    median_observed_pop_share = median(observed_population_share, na.rm = TRUE),
    mean_observed_pop_share = mean(observed_population_share, na.rm = TRUE),
    min_coverage_ge50_pop_share = min(coverage_ge50_population_share, na.rm = TRUE),
    p10_coverage_ge50_pop_share = q_safe(coverage_ge50_population_share, 0.10),
    median_coverage_ge50_pop_share = median(coverage_ge50_population_share, na.rm = TRUE),
    mean_coverage_ge50_pop_share = mean(coverage_ge50_population_share, na.rm = TRUE)
  ),
  by = scenario
]
write_csv_dt(national_daily_coverage, file.path(work_data_dir, "vj146a2_2023_national_daily_population_coverage_baseline_vs_excluded.csv"))
write_csv_dt(national_daily_summary, file.path(work_data_dir, "vj146a2_2023_national_daily_population_coverage_summary_baseline_vs_excluded.csv"))

message("Done.")
