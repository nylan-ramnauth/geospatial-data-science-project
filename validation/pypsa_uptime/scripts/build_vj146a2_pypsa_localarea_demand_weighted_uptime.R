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
  normalizePath("validation/pypsa_uptime/scripts/build_vj146a2_pypsa_localarea_demand_weighted_uptime.R", mustWork = TRUE)
}
repo_dir <- normalizePath(file.path(dirname(script_path), "..", "..", ".."), mustWork = TRUE)
source(file.path(repo_dir, "validation", "scripts", "validation_paths.R"))
paths <- validation_paths(repo_dir, "pypsa_uptime")

codebase_dir <- paths$repo_root
rel_dir <- file.path(codebase_dir, "Map Data", "reliability_outputs_vj146a2")
out_dir <- paths$data_dir
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

state_file <- file.path(rel_dir, "settlement_day_states_strict_yearlykeep_annual_excess_lit_iqr.parquet")
excess_lit_flags_file <- validation_section_data(
  paths,
  "eskom_mlr",
  "vj146a2_2023_annual_iqr_excess_lit_day_flags.csv"
)
excess_lit_scenario <- "annual_q3_plus_1p5_iqr"
sett_gpkg <- file.path(
  codebase_dir,
  "Map Data", "Settlements", "GPKG",
  "south_africa_dre_atlas_settlements_simplified_full_col.gpkg"
)
sett_layer <- "settlements_simplified"
local_area_shp <- file.path(codebase_dir, "Map Data", "Local Area", "LOCAL_AREA_GCCA2025.shp")

required_files <- c(state_file, excess_lit_flags_file, sett_gpkg, local_area_shp)
missing_files <- required_files[!file.exists(required_files)]
if (length(missing_files) > 0) {
  stop("Missing required file(s):\n", paste(missing_files, collapse = "\n"))
}

coverage_min <- 0.50
parse_gate_thresholds <- function(text) {
  vals <- as.numeric(strsplit(text, ",", fixed = TRUE)[[1]])
  vals <- vals[is.finite(vals)]
  vals <- unique(sort(vals))
  if (length(vals) == 0 || any(vals < 0 | vals > 1)) {
    stop("Invalid LocalArea demand gate thresholds: ", text)
  }
  vals
}

localarea_observed_demand_min <- as.numeric(Sys.getenv("VJ146A2_LOCALAREA_PRIMARY_DEMAND_GATE", "0.40"))
if (!is.finite(localarea_observed_demand_min) || localarea_observed_demand_min < 0 || localarea_observed_demand_min > 1) {
  stop("Invalid VJ146A2_LOCALAREA_PRIMARY_DEMAND_GATE.")
}
localarea_observed_demand_gates <- parse_gate_thresholds(Sys.getenv(
  "VJ146A2_LOCALAREA_DEMAND_GATES",
  "0.10,0.30,0.40,0.50,0.60"
))
localarea_observed_demand_gates <- unique(sort(c(localarea_observed_demand_gates, localarea_observed_demand_min)))
settlement_min_days <- 85L
threshold_strict_dark <- 0.05
threshold_mostly_dark <- 0.20
threshold_not_up <- 0.40
p_lit_thresholds <- c(0.05, 0.10, 0.20, 0.30, 0.40, 0.50, 0.60)

first_non_na <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA_real_)
  x[[1]]
}

weighted_mean_na <- function(x, w) {
  idx <- is.finite(x) & is.finite(w) & w > 0
  if (!any(idx)) return(NA_real_)
  sum(x[idx] * w[idx]) / sum(w[idx])
}

weighted_sd_na <- function(x, w) {
  idx <- is.finite(x) & is.finite(w) & w > 0
  if (sum(idx) < 2) return(NA_real_)
  mu <- weighted_mean_na(x[idx], w[idx])
  sqrt(sum(w[idx] * (x[idx] - mu)^2) / sum(w[idx]))
}

load_removed_dates <- function(path, scenario) {
  flags <- fread(path)
  if (!all(c("scenario", "date", "remove") %in% names(flags))) {
    stop("Excess-lit flag file is missing required columns: ", path)
  }
  flags[, date := as.Date(date)]
  scenario_name <- scenario
  flags[scenario == scenario_name & remove == TRUE, unique(date)]
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

message("Building settlement to LocalArea lookup.")
local_areas <- st_read(local_area_shp, quiet = TRUE)
sett_sf <- st_read(sett_gpkg, layer = sett_layer, quiet = TRUE) |>
  mutate(settlement_id = as.character(settlement_id))

lookup <- as.data.table(assign_local_areas(sett_sf, local_areas))
sett_static <- sett_sf |>
  st_drop_geometry() |>
  distinct(settlement_id, .keep_all = TRUE) |>
  transmute(
    settlement_id = as.character(settlement_id),
    demand = as.numeric(demand),
    population_gpkg = as.numeric(population)
  )

message("Loading excess-lit-screened VJ146A2 daily state cache.")
state <- as.data.table(arrow::read_parquet(
  state_file,
  col_select = c(
    "settlement_id", "date", "population", "coverage", "p_lit_sett",
    "lit_day", "dark_day", "electrified_after_doe_strict"
  )
))
state[, settlement_id := as.character(settlement_id)]
state[, date := as.Date(date)]
state[, lit_day := as.numeric(lit_day)]
state[, dark_day := as.numeric(dark_day)]
state[, population := as.numeric(population)]
state[, coverage := as.numeric(coverage)]

dt <- merge(state, as.data.table(sett_static), by = "settlement_id", all.x = TRUE)
dt <- merge(dt, lookup, by = "settlement_id", all.x = TRUE)
dt <- dt[!is.na(area_name) & is.finite(demand) & demand > 0]
dt[, post_doe := electrified_after_doe_strict == 1L]

removed_dates <- load_removed_dates(excess_lit_flags_file, excess_lit_scenario)
observed_dates <- sort(unique(dt[!is.na(p_lit_sett), date]))
analysis_dates <- observed_dates[!(observed_dates %in% removed_dates)]
if (length(analysis_dates) == 0) {
  stop("No observed VJ146A2 dates remain after excess-lit screen: ", excess_lit_scenario)
}
dt <- dt[date %in% analysis_dates]

area_demand <- unique(dt[, .(area_name, settlement_id, demand)])[
  ,
  .(
    area_demand = sum(demand, na.rm = TRUE),
    demand_universe_settlements = uniqueN(settlement_id)
  ),
  by = area_name
]

area_population <- dt[
  ,
  .(population = first_non_na(population)),
  by = .(area_name, settlement_id)
][
  ,
  .(area_population = sum(population, na.rm = TRUE)),
  by = area_name
]

daily_metrics <- dt[
  ,
  .(
    observed_demand = sum(ifelse(post_doe & !is.na(p_lit_sett), demand, 0), na.rm = TRUE),
    observed_population = sum(ifelse(post_doe & !is.na(p_lit_sett), population, 0), na.rm = TRUE),
    n_observed_settlements = uniqueN(settlement_id[post_doe & !is.na(p_lit_sett)]),
    strict_dark_005_share_demandw_day = weighted_mean_na(
      as.numeric(p_lit_sett < threshold_strict_dark),
      ifelse(post_doe, demand, NA_real_)
    ),
    mostly_dark_020_share_demandw_day = weighted_mean_na(
      as.numeric(p_lit_sett < threshold_mostly_dark),
      ifelse(post_doe, demand, NA_real_)
    ),
    not_up_040_share_demandw_day = weighted_mean_na(
      as.numeric(p_lit_sett < threshold_not_up),
      ifelse(post_doe, demand, NA_real_)
    )
  ),
  by = .(area_name, date)
]
daily_metrics <- merge(daily_metrics, area_demand, by = "area_name", all.x = TRUE)
daily_metrics <- merge(daily_metrics, area_population, by = "area_name", all.x = TRUE)
daily_metrics[, `:=`(
  observed_demand_share = observed_demand / area_demand,
  observed_population_share = observed_population / area_population
)]
daily_metrics[, localarea_demand_gate := observed_demand_share >= localarea_observed_demand_min]
daily_metrics[, `:=`(
  availability_005_demandw_day = 1 - strict_dark_005_share_demandw_day,
  availability_020_demandw_day = 1 - mostly_dark_020_share_demandw_day,
  availability_040_demandw_day = 1 - not_up_040_share_demandw_day,
  n_eligible_settlements = demand_universe_settlements,
  excess_lit_screen = excess_lit_scenario
)]
setorder(daily_metrics, area_name, date)

dt_gated <- merge(
  dt,
  daily_metrics[, .(area_name, date, observed_demand_share, observed_population_share, localarea_demand_gate)],
  by = c("area_name", "date"),
  all.x = TRUE
)[localarea_demand_gate == TRUE]

settlement_metrics <- dt_gated[
  !is.na(p_lit_sett) & electrified_after_doe_strict == 1L,
  .(
    n_days_obs = .N,
    n_lit_days = sum(lit_day == 1, na.rm = TRUE),
    n_dark_days = sum(dark_day == 1, na.rm = TRUE),
    uptime = mean(lit_day, na.rm = TRUE),
    dark_share = mean(dark_day, na.rm = TRUE),
    mean_p_lit = mean(p_lit_sett, na.rm = TRUE),
    sd_p_lit = if (.N >= 2) stats::sd(p_lit_sett, na.rm = TRUE) else NA_real_,
    mean_coverage = mean(coverage, na.rm = TRUE),
    demand = first_non_na(demand),
    population = first_non_na(population)
  ),
  by = .(area_name, settlement_id)
]
settlement_metrics[, cv_p_lit := ifelse(is.finite(mean_p_lit) & mean_p_lit > 0, sd_p_lit / mean_p_lit, NA_real_)]
settlement_metrics[, support_ok := n_days_obs >= settlement_min_days]
settlement_kept <- settlement_metrics[support_ok == TRUE]

settlement_first_metrics <- settlement_kept[
  ,
  .(
    n_settlements = uniqueN(settlement_id),
    kept_demand = sum(demand, na.rm = TRUE),
    kept_population = sum(population, na.rm = TRUE),
    uptime_demandw_settlement_first = weighted_mean_na(uptime, demand),
    sd_uptime_demandw = weighted_sd_na(uptime, demand),
    dark_share_demandw = weighted_mean_na(dark_share, demand),
    cv_p_lit_demandw = weighted_mean_na(cv_p_lit, demand),
    mean_coverage_demandw = weighted_mean_na(mean_coverage, demand),
    mean_n_days_obs_demandw = weighted_mean_na(n_days_obs, demand),
    min_n_days_obs = as.numeric(min(n_days_obs, na.rm = TRUE)),
    median_n_days_obs = as.numeric(stats::median(n_days_obs, na.rm = TRUE))
  ),
  by = area_name
]

daily_first_metrics <- daily_metrics[
  localarea_demand_gate == TRUE,
  .(
    strict_dark_005_share_demandw = mean(strict_dark_005_share_demandw_day, na.rm = TRUE),
    mostly_dark_020_share_demandw = mean(mostly_dark_020_share_demandw_day, na.rm = TRUE),
    not_up_040_share_demandw = mean(not_up_040_share_demandw_day, na.rm = TRUE),
    availability_005_demandw = mean(availability_005_demandw_day, na.rm = TRUE),
    availability_020_demandw = mean(availability_020_demandw_day, na.rm = TRUE),
    availability_040_demandw = mean(availability_040_demandw_day, na.rm = TRUE),
    n_dates_daily_first = .N,
    mean_observed_demand_share_daily_first = mean(observed_demand_share, na.rm = TRUE),
    min_observed_demand_share_daily_first = min(observed_demand_share, na.rm = TRUE),
    median_observed_demand_share_daily_first = stats::median(observed_demand_share, na.rm = TRUE)
  ),
  by = area_name
]
daily_first_metrics[, availability_040_demandw_daily_first := availability_040_demandw]

localarea_metrics <- merge(settlement_first_metrics, daily_first_metrics, by = "area_name", all = TRUE)
localarea_metrics <- merge(localarea_metrics, area_demand, by = "area_name", all.y = TRUE)
localarea_metrics <- merge(localarea_metrics, area_population, by = "area_name", all.x = TRUE)
localarea_metrics[, `:=`(
  share_demand_kept = kept_demand / area_demand,
  share_population_kept = kept_population / area_population,
  uptime_demandw = uptime_demandw_settlement_first,
  delta_availability_040_daily_minus_settlement_first = availability_040_demandw_daily_first - uptime_demandw_settlement_first,
  demand_gate_threshold = localarea_observed_demand_min,
  settlement_coverage_min = coverage_min,
  settlement_min_days = settlement_min_days,
  excess_lit_screen = excess_lit_scenario,
  year = as.Date("2023-01-01")
)]

support_summary <- daily_metrics[
  ,
  .(
    n_calendar_dates = .N,
    n_dates_any_observed = sum(observed_demand_share > 0, na.rm = TRUE),
    n_dates_demand_ge40 = sum(localarea_demand_gate, na.rm = TRUE),
    share_dates_demand_ge40 = mean(localarea_demand_gate, na.rm = TRUE),
    mean_observed_demand_share = mean(observed_demand_share, na.rm = TRUE),
    median_observed_demand_share = median(observed_demand_share, na.rm = TRUE),
    p10_observed_demand_share = as.numeric(stats::quantile(observed_demand_share, 0.10, na.rm = TRUE)),
    mean_observed_population_share = mean(observed_population_share, na.rm = TRUE)
  ),
  by = area_name
]

localarea_metrics <- merge(localarea_metrics, support_summary, by = "area_name", all.x = TRUE)
setcolorder(
  localarea_metrics,
  c(
    "area_name", "year",
    "strict_dark_005_share_demandw", "availability_005_demandw",
    "mostly_dark_020_share_demandw", "availability_020_demandw",
    "not_up_040_share_demandw", "availability_040_demandw",
    "availability_040_demandw_daily_first",
    "uptime_demandw_settlement_first", "uptime_demandw",
    "delta_availability_040_daily_minus_settlement_first",
    "sd_uptime_demandw", "dark_share_demandw", "cv_p_lit_demandw",
    "mean_coverage_demandw", "n_settlements",
    "kept_demand", "area_demand", "share_demand_kept",
    "kept_population", "area_population", "share_population_kept",
    "mean_n_days_obs_demandw", "min_n_days_obs", "median_n_days_obs",
    "n_dates_daily_first", "mean_observed_demand_share_daily_first",
    "min_observed_demand_share_daily_first", "median_observed_demand_share_daily_first",
    "n_calendar_dates", "n_dates_any_observed", "n_dates_demand_ge40",
    "share_dates_demand_ge40", "mean_observed_demand_share",
    "median_observed_demand_share", "p10_observed_demand_share",
    "mean_observed_population_share", "demand_gate_threshold",
    "settlement_coverage_min", "settlement_min_days", "excess_lit_screen",
    "demand_universe_settlements"
  )
)
setorder(localarea_metrics, availability_040_demandw)

out_csv <- file.path(out_dir, "vj146a2_2023_pypsa_localarea_demand_weighted_uptime.csv")
out_parquet <- file.path(out_dir, "vj146a2_2023_pypsa_localarea_demand_weighted_uptime.parquet")
out_support <- file.path(out_dir, "vj146a2_2023_pypsa_localarea_daily_demand_support.csv")
out_daily_audit <- file.path(out_dir, "vj146a2_2023_pypsa_localarea_daily_demand_weighted_uptime_audit.csv")
out_daily_audit_parquet <- file.path(out_dir, "vj146a2_2023_pypsa_localarea_daily_demand_weighted_uptime_audit.parquet")
out_gate_sensitivity <- file.path(out_dir, "vj146a2_2023_pypsa_localarea_demand_weighted_uptime_gate_sensitivity.csv")
out_gate_sensitivity_parquet <- file.path(out_dir, "vj146a2_2023_pypsa_localarea_demand_weighted_uptime_gate_sensitivity.parquet")
out_daily_gate_audit <- file.path(out_dir, "vj146a2_2023_pypsa_localarea_daily_demand_weighted_uptime_gate_sensitivity_audit.csv")
out_daily_gate_audit_parquet <- file.path(out_dir, "vj146a2_2023_pypsa_localarea_daily_demand_weighted_uptime_gate_sensitivity_audit.parquet")
out_p_lit_threshold_sensitivity <- file.path(out_dir, "vj146a2_2023_pypsa_localarea_p_lit_threshold_sensitivity.csv")
out_p_lit_threshold_sensitivity_parquet <- file.path(out_dir, "vj146a2_2023_pypsa_localarea_p_lit_threshold_sensitivity.parquet")
out_daily_p_lit_threshold_audit <- file.path(out_dir, "vj146a2_2023_pypsa_localarea_daily_p_lit_threshold_sensitivity_audit.csv")
out_daily_p_lit_threshold_audit_parquet <- file.path(out_dir, "vj146a2_2023_pypsa_localarea_daily_p_lit_threshold_sensitivity_audit.parquet")

daily_audit <- copy(daily_metrics)[
  ,
  .(
    area_name,
    date,
    observed_demand,
    area_demand,
    observed_demand_share,
    localarea_demand_gate,
    strict_dark_005_share_demandw_day,
    mostly_dark_020_share_demandw_day,
    not_up_040_share_demandw_day,
    availability_005_demandw_day,
    availability_020_demandw_day,
    availability_040_demandw_day,
    n_observed_settlements,
    n_eligible_settlements,
    excess_lit_screen
  )
]

gate_sensitivity <- rbindlist(lapply(localarea_observed_demand_gates, function(gate_threshold) {
  out <- daily_metrics[
    observed_demand_share >= gate_threshold,
    .(
      strict_dark_005_share_demandw = mean(strict_dark_005_share_demandw_day, na.rm = TRUE),
      mostly_dark_020_share_demandw = mean(mostly_dark_020_share_demandw_day, na.rm = TRUE),
      not_up_040_share_demandw = mean(not_up_040_share_demandw_day, na.rm = TRUE),
      availability_005_demandw = mean(availability_005_demandw_day, na.rm = TRUE),
      availability_020_demandw = mean(availability_020_demandw_day, na.rm = TRUE),
      availability_040_demandw = mean(availability_040_demandw_day, na.rm = TRUE),
      n_dates_daily_first = .N,
      mean_observed_demand_share_daily_first = mean(observed_demand_share, na.rm = TRUE),
      min_observed_demand_share_daily_first = min(observed_demand_share, na.rm = TRUE),
      median_observed_demand_share_daily_first = stats::median(observed_demand_share, na.rm = TRUE)
    ),
    by = area_name
  ]
  out <- merge(out, area_demand, by = "area_name", all.y = TRUE)
  out <- merge(out, area_population, by = "area_name", all.x = TRUE)
  support <- daily_metrics[
    ,
    .(
      n_calendar_dates = .N,
      n_dates_any_observed = sum(observed_demand_share > 0, na.rm = TRUE),
      n_dates_demand_gate = sum(observed_demand_share >= gate_threshold, na.rm = TRUE),
      share_dates_demand_gate = mean(observed_demand_share >= gate_threshold, na.rm = TRUE),
      mean_observed_demand_share = mean(observed_demand_share, na.rm = TRUE),
      median_observed_demand_share = stats::median(observed_demand_share, na.rm = TRUE),
      p10_observed_demand_share = as.numeric(stats::quantile(observed_demand_share, 0.10, na.rm = TRUE)),
      mean_observed_population_share = mean(observed_population_share, na.rm = TRUE)
    ),
    by = area_name
  ]
  out <- merge(out, support, by = "area_name", all.x = TRUE)
  out[, `:=`(
    year = as.Date("2023-01-01"),
    demand_gate_threshold = gate_threshold,
    excess_lit_screen = excess_lit_scenario,
    settlement_coverage_min = coverage_min
  )]
  setcolorder(
    out,
    c(
      "area_name", "year", "demand_gate_threshold",
      "strict_dark_005_share_demandw", "availability_005_demandw",
      "mostly_dark_020_share_demandw", "availability_020_demandw",
      "not_up_040_share_demandw", "availability_040_demandw",
      "n_dates_daily_first", "mean_observed_demand_share_daily_first",
      "min_observed_demand_share_daily_first", "median_observed_demand_share_daily_first",
      "area_demand", "area_population", "n_calendar_dates", "n_dates_any_observed",
      "n_dates_demand_gate", "share_dates_demand_gate", "mean_observed_demand_share",
      "median_observed_demand_share", "p10_observed_demand_share",
      "mean_observed_population_share", "settlement_coverage_min",
      "excess_lit_screen", "demand_universe_settlements"
    )
  )
  out
}), use.names = TRUE)
setorder(gate_sensitivity, demand_gate_threshold, availability_040_demandw)

daily_gate_audit <- rbindlist(lapply(localarea_observed_demand_gates, function(gate_threshold) {
  out <- copy(daily_audit)
  out[, demand_gate_threshold := gate_threshold]
  out[, localarea_demand_gate := observed_demand_share >= gate_threshold]
  setcolorder(out, c("area_name", "date", "demand_gate_threshold"))
  out
}), use.names = TRUE)
setorder(daily_gate_audit, demand_gate_threshold, area_name, date)

daily_p_lit_threshold_audit <- rbindlist(lapply(p_lit_thresholds, function(p_lit_threshold) {
  threshold_value <- p_lit_threshold
  out <- dt[
    ,
    .(
      observed_demand = sum(ifelse(post_doe & !is.na(p_lit_sett), demand, 0), na.rm = TRUE),
      n_observed_settlements = uniqueN(settlement_id[post_doe & !is.na(p_lit_sett)]),
      not_up_share_demandw_day = weighted_mean_na(
        as.numeric(p_lit_sett < threshold_value),
        ifelse(post_doe, demand, NA_real_)
      )
    ),
    by = .(area_name, date)
  ]
  out <- merge(out, area_demand, by = "area_name", all.x = TRUE)
  out[, `:=`(
    p_lit_threshold = threshold_value,
    observed_demand_share = observed_demand / area_demand,
    availability_demandw_day = 1 - not_up_share_demandw_day,
    n_eligible_settlements = demand_universe_settlements,
    excess_lit_screen = excess_lit_scenario
  )]
  out[, localarea_demand_gate := observed_demand_share >= localarea_observed_demand_min]
  out[
    ,
    .(
      area_name,
      date,
      p_lit_threshold,
      observed_demand,
      area_demand,
      observed_demand_share,
      localarea_demand_gate,
      not_up_share_demandw_day,
      availability_demandw_day,
      n_observed_settlements,
      n_eligible_settlements,
      excess_lit_screen
    )
  ]
}), use.names = TRUE)
setorder(daily_p_lit_threshold_audit, area_name, date, p_lit_threshold)

p_lit_threshold_sensitivity <- daily_p_lit_threshold_audit[
  localarea_demand_gate == TRUE,
  .(
    not_up_share_demandw = mean(not_up_share_demandw_day, na.rm = TRUE),
    availability_demandw = mean(availability_demandw_day, na.rm = TRUE),
    n_dates_daily_first = .N,
    mean_observed_demand_share_daily_first = mean(observed_demand_share, na.rm = TRUE),
    min_observed_demand_share_daily_first = min(observed_demand_share, na.rm = TRUE),
    median_observed_demand_share_daily_first = stats::median(observed_demand_share, na.rm = TRUE)
  ),
  by = .(area_name, p_lit_threshold)
]
p_lit_threshold_sensitivity <- merge(p_lit_threshold_sensitivity, area_demand, by = "area_name", all.x = TRUE)
p_lit_threshold_sensitivity <- merge(p_lit_threshold_sensitivity, area_population, by = "area_name", all.x = TRUE)
p_lit_threshold_sensitivity[, `:=`(
  year = as.Date("2023-01-01"),
  demand_gate_threshold = localarea_observed_demand_min,
  excess_lit_screen = excess_lit_scenario,
  settlement_coverage_min = coverage_min
)]
setcolorder(
  p_lit_threshold_sensitivity,
  c(
    "area_name", "year", "p_lit_threshold", "not_up_share_demandw",
    "availability_demandw", "n_dates_daily_first",
    "mean_observed_demand_share_daily_first",
    "min_observed_demand_share_daily_first",
    "median_observed_demand_share_daily_first",
    "area_demand", "area_population", "demand_gate_threshold",
    "excess_lit_screen", "settlement_coverage_min",
    "demand_universe_settlements"
  )
)
setorder(p_lit_threshold_sensitivity, area_name, p_lit_threshold)

fwrite(localarea_metrics, out_csv, na = "")
arrow::write_parquet(localarea_metrics, out_parquet)
fwrite(daily_metrics, out_support, na = "")
fwrite(daily_audit, out_daily_audit, na = "")
arrow::write_parquet(daily_audit, out_daily_audit_parquet)
fwrite(gate_sensitivity, out_gate_sensitivity, na = "")
arrow::write_parquet(gate_sensitivity, out_gate_sensitivity_parquet)
fwrite(daily_gate_audit, out_daily_gate_audit, na = "")
arrow::write_parquet(daily_gate_audit, out_daily_gate_audit_parquet)
fwrite(p_lit_threshold_sensitivity, out_p_lit_threshold_sensitivity, na = "")
arrow::write_parquet(p_lit_threshold_sensitivity, out_p_lit_threshold_sensitivity_parquet)
fwrite(daily_p_lit_threshold_audit, out_daily_p_lit_threshold_audit, na = "")
arrow::write_parquet(daily_p_lit_threshold_audit, out_daily_p_lit_threshold_audit_parquet)

message("Wrote: ", out_csv)
message("Wrote: ", out_parquet)
message("Wrote: ", out_support)
message("Wrote: ", out_daily_audit)
message("Wrote: ", out_daily_audit_parquet)
message("Wrote: ", out_gate_sensitivity)
message("Wrote: ", out_gate_sensitivity_parquet)
message("Wrote: ", out_daily_gate_audit)
message("Wrote: ", out_daily_gate_audit_parquet)
message("Wrote: ", out_p_lit_threshold_sensitivity)
message("Wrote: ", out_p_lit_threshold_sensitivity_parquet)
message("Wrote: ", out_daily_p_lit_threshold_audit)
message("Wrote: ", out_daily_p_lit_threshold_audit_parquet)

national <- localarea_metrics[
  ,
  .(
    n_localareas = .N,
    n_localareas_share_demand_ge50 = sum(share_demand_kept >= 0.50, na.rm = TRUE),
    min_share_demand_kept = min(share_demand_kept, na.rm = TRUE),
    demand_weighted_availability_040_daily_first = weighted_mean_na(availability_040_demandw, area_demand),
    demand_weighted_not_up_040_daily_first = weighted_mean_na(not_up_040_share_demandw, area_demand),
    demand_weighted_uptime_settlement_first = weighted_mean_na(uptime_demandw_settlement_first, area_demand),
    median_localarea_availability_040_daily_first = median(availability_040_demandw, na.rm = TRUE),
    median_localarea_uptime_settlement_first = median(uptime_demandw_settlement_first, na.rm = TRUE),
    mean_n_days_obs_demandw = weighted_mean_na(mean_n_days_obs_demandw, area_demand)
  )
]
print(national)

national_by_gate <- gate_sensitivity[
  ,
  .(
    n_localareas = .N,
    total_gated_localarea_days = sum(n_dates_daily_first, na.rm = TRUE),
    demand_weighted_availability_040_daily_first = weighted_mean_na(availability_040_demandw, area_demand),
    demand_weighted_not_up_040_daily_first = weighted_mean_na(not_up_040_share_demandw, area_demand),
    median_localarea_availability_040_daily_first = median(availability_040_demandw, na.rm = TRUE)
  ),
  by = demand_gate_threshold
]
print(national_by_gate)

national_by_p_lit_threshold <- p_lit_threshold_sensitivity[
  ,
  .(
    n_localareas = .N,
    total_gated_localarea_days = sum(n_dates_daily_first, na.rm = TRUE),
    demand_weighted_not_up = weighted_mean_na(not_up_share_demandw, area_demand),
    demand_weighted_availability = weighted_mean_na(availability_demandw, area_demand),
    median_localarea_not_up = median(not_up_share_demandw, na.rm = TRUE),
    median_localarea_availability = median(availability_demandw, na.rm = TRUE)
  ),
  by = p_lit_threshold
]
print(national_by_p_lit_threshold)
