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
  normalizePath("validation/pypsa_uptime/scripts/compare_vj146a2_localarea_daily_support_gate_sensitivity.R", mustWork = TRUE)
}
repo_dir <- normalizePath(file.path(dirname(script_path), "..", "..", ".."), mustWork = TRUE)
source(file.path(repo_dir, "validation", "scripts", "validation_paths.R"))
paths <- validation_paths(repo_dir, "pypsa_uptime")

codebase_dir <- paths$repo_root
rel_dir <- file.path(codebase_dir, "Map Data", "reliability_outputs_vj146a2")
work_data_dir <- paths$data_dir
dir.create(work_data_dir, recursive = TRUE, showWarnings = FALSE)

state_file <- file.path(rel_dir, "settlement_day_states_strict_yearlykeep_annual_excess_lit_iqr.parquet")
daily_coverage_file <- file.path(work_data_dir, "vj146a2_2023_localarea_daily_population_coverage_baseline_vs_excluded.csv")
demand_gate_file <- validation_section_data(paths, "eskom_mlr", "vj146a2_2023_demand_gate_coverage.csv")
flags_file <- validation_section_data(paths, "eskom_mlr", "vj146a2_2023_annual_iqr_excess_lit_day_flags.csv")
local_compare_file <- file.path(work_data_dir, "vj146a2_2023_localarea_uptime_excess_lit_exclusion_comparison.csv")

sett_gpkg <- file.path(
  codebase_dir,
  "Map Data", "Settlements", "GPKG",
  "south_africa_dre_atlas_settlements_simplified_full_col.gpkg"
)
sett_layer <- "settlements_simplified"
local_area_shp <- file.path(codebase_dir, "Map Data", "Local Area", "LOCAL_AREA_GCCA2025.shp")

required_files <- c(
  state_file,
  daily_coverage_file,
  demand_gate_file,
  flags_file,
  local_compare_file,
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

weighted_mean_na <- function(x, w) {
  idx <- is.finite(x) & is.finite(w)
  if (!any(idx)) return(NA_real_)
  sum(x[idx] * w[idx]) / sum(w[idx])
}

write_csv_dt <- function(x, path) {
  data.table::fwrite(x, path, na = "")
  message("Wrote: ", path)
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

message("Loading exclusion dates and support gates.")
flags <- data.table::fread(flags_file)
flags[, date := as.Date(date)]
excluded_dates <- flags[scenario == "annual_q3_plus_1p5_iqr" & remove == TRUE, date]

daily_coverage <- data.table::fread(daily_coverage_file)
daily_coverage[, date := as.Date(date)]
localarea_pop_gate <- daily_coverage[
  scenario == "annual_iqr_excess_lit_excluded",
  .(area_name, date, observed_population_share, localarea_pop_gate_50 = observed_population_share >= 0.50)
]

demand_gate <- data.table::fread(demand_gate_file)
demand_gate[, date := as.Date(date)]
demand_gate_dates <- demand_gate[
  observed_demand_share >= 0.40 & !(date %in% excluded_dates),
  .(date, observed_demand_share, national_demand_gate_40 = TRUE)
]

message("Building LocalArea lookup.")
local_areas <- st_read(local_area_shp, quiet = TRUE)
sett_all <- st_read(sett_gpkg, layer = sett_layer, quiet = TRUE) |>
  mutate(settlement_id = as.character(settlement_id))
lookup_dt <- as.data.table(assign_local_areas(sett_all, local_areas))
lookup_dt <- lookup_dt[!is.na(area_name)]
setkey(lookup_dt, settlement_id)

message("Loading excess-lit-excluded daily state cache.")
state <- data.table::as.data.table(arrow::read_parquet(
  state_file,
  col_select = c(
    "settlement_id", "date", "population", "p_lit_sett", "lit_day",
    "electrified_after_doe_strict"
  )
))
state[, settlement_id := as.character(settlement_id)]
state[, date := as.Date(date)]
state <- state[!(date %in% excluded_dates)]
state <- merge(state, lookup_dt, by = "settlement_id", all.x = FALSE, allow.cartesian = TRUE)
state[, population := as.numeric(population)]
state[, lit_day := as.numeric(lit_day)]

area_pop <- state[
  ,
  .(population = first_non_na(population)),
  by = .(area_name, settlement_id)
][
  !is.na(population),
  .(area_population = sum(population)),
  by = area_name
]

compute_area_uptime <- function(dt, scenario_id) {
  sett <- dt[
    !is.na(p_lit_sett) & electrified_after_doe_strict == 1L,
    .(
      n_days_obs = .N,
      n_lit_days = sum(lit_day == 1, na.rm = TRUE),
      uptime = mean(lit_day, na.rm = TRUE),
      population = first_non_na(population)
    ),
    by = .(area_name, settlement_id)
  ]
  sett[, support_ok := n_days_obs >= 85]
  sett_ok <- sett[support_ok == TRUE & !is.na(population)]

  area <- sett_ok[
    ,
    .(
      n_settlements = uniqueN(settlement_id),
      kept_population = sum(population, na.rm = TRUE),
      uptime_popw = weighted_mean_na(uptime, population),
      mean_settlement_n_days_obs_popw = weighted_mean_na(n_days_obs, population),
      min_settlement_n_days_obs = as.numeric(min(n_days_obs, na.rm = TRUE)),
      median_settlement_n_days_obs = as.numeric(stats::median(n_days_obs, na.rm = TRUE))
    ),
    by = area_name
  ]
  area <- merge(area, area_pop, by = "area_name", all.y = TRUE)
  area[, share_population_kept := kept_population / area_population]
  area[, scenario := scenario_id]
  area[]
}

message("Computing scenario: excess-lit exclusion only.")
scenario_current <- copy(state)
area_current <- compute_area_uptime(scenario_current, "excess_lit_only_current_stage5")

message("Computing scenario: LocalArea-day observed population >= 50%.")
scenario_local50 <- merge(
  state,
  localarea_pop_gate[, .(area_name, date, localarea_pop_gate_50)],
  by = c("area_name", "date"),
  all.x = TRUE
)[localarea_pop_gate_50 == TRUE]
area_local50 <- compute_area_uptime(scenario_local50, "excess_lit_plus_localarea_pop_day_ge50")

message("Computing scenario: national observed demand >= 40%.")
scenario_demand40 <- merge(
  state,
  demand_gate_dates[, .(date, national_demand_gate_40)],
  by = "date",
  all.x = FALSE
)
area_demand40 <- compute_area_uptime(scenario_demand40, "excess_lit_plus_national_demand_day_ge40")

area_sensitivity <- rbindlist(list(area_current, area_local50, area_demand40), use.names = TRUE, fill = TRUE)
setcolorder(area_sensitivity, c("scenario", setdiff(names(area_sensitivity), "scenario")))
setorder(area_sensitivity, area_name, scenario)
write_csv_dt(area_sensitivity, file.path(work_data_dir, "vj146a2_2023_localarea_uptime_daily_support_gate_sensitivity.csv"))

current_wide <- dcast(
  area_sensitivity,
  area_name ~ scenario,
  value.var = c("uptime_popw", "share_population_kept", "mean_settlement_n_days_obs_popw")
)
for (scenario_id in c("excess_lit_plus_localarea_pop_day_ge50", "excess_lit_plus_national_demand_day_ge40")) {
  current_wide[, (paste0("uptime_delta_pp_", scenario_id)) :=
    100 * (get(paste0("uptime_popw_", scenario_id)) - get("uptime_popw_excess_lit_only_current_stage5"))]
  current_wide[, (paste0("share_population_kept_delta_pp_", scenario_id)) :=
    100 * (get(paste0("share_population_kept_", scenario_id)) - get("share_population_kept_excess_lit_only_current_stage5"))]
}
write_csv_dt(current_wide, file.path(work_data_dir, "vj146a2_2023_localarea_uptime_daily_support_gate_sensitivity_wide.csv"))

scenario_date_summary <- data.table(
  scenario = c(
    "excess_lit_only_current_stage5",
    "excess_lit_plus_localarea_pop_day_ge50",
    "excess_lit_plus_national_demand_day_ge40"
  ),
  date_scope_description = c(
    "Retained dates after annual-IQR excess-lit removal; no LocalArea-day population gate",
    "Area-specific retained dates where LocalArea observed population share >= 50%",
    "Retained dates where national validation observed demand share >= 40%"
  ),
  n_unique_dates = c(
    uniqueN(state$date[!is.na(state$p_lit_sett)]),
    uniqueN(scenario_local50$date[!is.na(scenario_local50$p_lit_sett)]),
    uniqueN(scenario_demand40$date[!is.na(scenario_demand40$p_lit_sett)])
  ),
  n_area_dates_with_any_rows = c(
    state[!is.na(p_lit_sett), uniqueN(paste(area_name, date))],
    scenario_local50[!is.na(p_lit_sett), uniqueN(paste(area_name, date))],
    scenario_demand40[!is.na(p_lit_sett), uniqueN(paste(area_name, date))]
  )
)
write_csv_dt(scenario_date_summary, file.path(work_data_dir, "vj146a2_2023_localarea_daily_support_gate_date_counts.csv"))

national_summary <- area_sensitivity[
  !is.na(uptime_popw) & !is.na(area_population),
  .(
    n_localareas_with_uptime = sum(!is.na(uptime_popw)),
    n_localareas_share_kept_ge50 = sum(share_population_kept >= 0.50, na.rm = TRUE),
    min_share_population_kept = min(share_population_kept, na.rm = TRUE),
    median_share_population_kept = median(share_population_kept, na.rm = TRUE),
    popw_uptime = weighted.mean(uptime_popw, area_population, na.rm = TRUE),
    median_localarea_uptime = median(uptime_popw, na.rm = TRUE),
    mean_settlement_n_days_obs_popw_national = weighted.mean(mean_settlement_n_days_obs_popw, area_population, na.rm = TRUE)
  ),
  by = scenario
]
base_popw <- national_summary[scenario == "excess_lit_only_current_stage5", popw_uptime]
national_summary[, popw_uptime_delta_pp_vs_current := 100 * (popw_uptime - base_popw)]
write_csv_dt(national_summary, file.path(work_data_dir, "vj146a2_2023_localarea_uptime_daily_support_gate_national_summary.csv"))

message("Done.")
