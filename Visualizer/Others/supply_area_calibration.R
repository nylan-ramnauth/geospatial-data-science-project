# ============================================================
# Supply Area Yearly Calibration (Province-Level)
# Stage 4 — Area-Level Calibration
# ============================================================
#
# Purpose:  Province-level grid search over electrification thresholds;
#           calibrates against official electrification targets per admin1
#           area to produce area-adjusted threshold estimates.
# Inputs:   - Map Data/reliability_outputs_blackmarbler/yearly_settlement_stats_YYYY.parquet
#           - Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_simplified_full_col.gpkg
#           - Map Data/Boundaries/boundaries_outputs/south_africa_admin1.shp
# Outputs:  - Map Data/reliability_outputs_blackmarbler/supply_area_calibration_*.csv
# Run:      Rscript Visualizer/supply_area_calibration.R
# ============================================================

rm(list = ls())

suppressPackageStartupMessages({
  library(here)
  library(sf)
  library(dplyr)
  library(data.table)
  library(arrow)
  library(readr)
})

sf::sf_use_s2(FALSE)

# -----------------------------
# CONFIG
# -----------------------------
BASE_PATH <- here::here()
OUT_DIR <- file.path(BASE_PATH, "Map Data", "reliability_outputs_blackmarbler")

YEAR_LABEL <- "2023"
YEARLY_STATS_FILE <- file.path(OUT_DIR, paste0("yearly_settlement_stats_", YEAR_LABEL, ".parquet"))
SETT_GPKG <- file.path(BASE_PATH, "Map Data", "Settlements", "GPKG", "south_africa_dre_atlas_settlements_simplified_full_col.gpkg")
SETT_LAYER <- "settlements_simplified"
AREA_SHP <- file.path(BASE_PATH, "Map Data", "Boundaries", "boundaries_outputs", "south_africa_admin1.shp")
AREA_NAME_COL <- "NAME_1"

# Fill this file with official targets (share in [0,1]).
TARGET_FILE <- file.path(OUT_DIR, paste0("admin1_official_targets_", YEAR_LABEL, ".csv"))

# National anchor (World Bank / chosen benchmark)
NATIONAL_TARGET_SHARE <- 0.877

# Calibration controls
REQUIRE_SUPPORT_OK <- TRUE
TAU_GRID <- seq(0.20, 0.80, by = 0.005)      # global threshold candidate grid
DELTA_GRID <- seq(-0.3, 0.3, by = 0.005)   # area adjustment around global threshold
LAMBDA_DELTA <- 0                          # shrink area adjustments toward zero
MU_NATIONAL <- 0                         # enforce national anchor
MIN_AREA_POP <- 10000                         # drop tiny areas from optimization

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

log_step <- function(...) {
  cat(format(Sys.time(), "%H:%M:%S"), "-", ..., "\n")
  flush.console()
}

share_ge_threshold <- function(p, pop, threshold) {
  total <- sum(pop, na.rm = TRUE)
  if (!is.finite(total) || total <= 0) return(NA_real_)
  sum(pop[p >= threshold], na.rm = TRUE) / total
}

coalesce_num <- function(x, y, default = NA_real_) {
  out <- dplyr::coalesce(x, y)
  if (all(is.na(out)) && !is.na(default)) out <- rep(default, length(out))
  out
}

normalize_area_name <- function(x) {
  x <- as.character(x)
  x <- trimws(x)
  dplyr::recode(
    x,
    "KwaZulu-Natal" = "KwaZulu Natal",
    "Nothern Cape" = "Northern Cape",
    .default = x
  )
}

# -----------------------------
# LOAD MODEL DATA
# -----------------------------
if (!file.exists(YEARLY_STATS_FILE)) stop("Missing yearly stats file: ", YEARLY_STATS_FILE)
if (!file.exists(SETT_GPKG)) stop("Missing settlements file: ", SETT_GPKG)
if (!file.exists(AREA_SHP)) stop("Missing area shapefile: ", AREA_SHP)

log_step("Reading yearly settlement stats:", YEARLY_STATS_FILE)
ys <- arrow::read_parquet(YEARLY_STATS_FILE) |> as.data.frame()
required_ys <- c("settlement_id", "p_lit_sett_year", "population")
missing_ys <- setdiff(required_ys, names(ys))
if (length(missing_ys) > 0) stop("Missing required columns in yearly stats: ", paste(missing_ys, collapse = ", "))

ys <- ys |>
  mutate(
    settlement_id = as.character(settlement_id),
    p_lit_sett_year = as.numeric(p_lit_sett_year),
    population = as.numeric(population)
  )
ys$population[is.na(ys$population)] <- 0
if ("support_ok" %in% names(ys)) {
  ys$support_ok <- as.logical(ys$support_ok)
} else {
  ys$support_ok <- TRUE
}
if ("electrified_best" %in% names(ys)) {
  ys$electrified_best <- as.integer(ys$electrified_best)
} else {
  ys$electrified_best <- NA_integer_
}

log_step("Reading settlement geometry and joining yearly stats")
sett <- sf::st_read(SETT_GPKG, layer = SETT_LAYER, quiet = TRUE) |>
  mutate(settlement_id = as.character(settlement_id)) |>
  dplyr::select(settlement_id) |>
  left_join(ys, by = "settlement_id")

if (REQUIRE_SUPPORT_OK) {
  sett <- sett |>
    filter(!is.na(support_ok), support_ok == TRUE)
}

sett <- sett |>
  filter(!is.na(p_lit_sett_year), !is.na(population), population > 0)

if (nrow(sett) == 0) stop("No settlements available after filtering.")

log_step("Assigning admin-1 area by spatial join")
area_sf <- sf::st_read(AREA_SHP, quiet = TRUE)
if (!(AREA_NAME_COL %in% names(area_sf))) stop("Area layer missing column: ", AREA_NAME_COL)

sett_supply <- st_join(
  st_transform(sett, st_crs(area_sf)),
  area_sf[AREA_NAME_COL],
  left = TRUE
) |>
  mutate(area_name = .data[[AREA_NAME_COL]]) |>
  dplyr::select(-all_of(AREA_NAME_COL)) |>
  st_drop_geometry() |>
  mutate(area_name = normalize_area_name(area_name)) |>
  filter(!is.na(area_name))

if (nrow(sett_supply) == 0) stop("No settlements matched to admin-1 areas.")

area_base <- sett_supply |>
  group_by(area_name) |>
  summarise(
    n_settlements = n(),
    population_total = sum(population, na.rm = TRUE),
    share_model_current = if ("electrified_best" %in% names(sett_supply)) {
      sum(ifelse(electrified_best == 1L, population, 0), na.rm = TRUE) / sum(population, na.rm = TRUE)
    } else {
      NA_real_
    },
    .groups = "drop"
  ) |>
  arrange(desc(population_total))

log_step("Admin-1 areas in model:", nrow(area_base))

# -----------------------------
# TARGET FILE (official data)
# -----------------------------
if (!file.exists(TARGET_FILE)) {
  template <- area_base |>
    transmute(
      area_name,
      target_share = NA_real_,
      weight = 1.0,
      active = 1L,
      notes = "",
      population_total,
      share_model_current
    )
  readr::write_csv(template, TARGET_FILE)
  stop(
    "Target file created: ", TARGET_FILE, "\n",
    "Fill column 'target_share' with official rates in [0,1], then rerun."
  )
}

targets <- readr::read_csv(TARGET_FILE, show_col_types = FALSE) |>
  as.data.frame()

if (!("area_name" %in% names(targets)) && ("SupplyArea" %in% names(targets))) {
  targets$area_name <- as.character(targets$SupplyArea)
}
if (!("weight" %in% names(targets))) {
  targets$weight <- 1.0
}
if (!("active" %in% names(targets))) {
  targets$active <- 1L
}

targets <- targets |>
  mutate(
    area_name = as.character(area_name),
    target_share = as.numeric(target_share),
    weight = as.numeric(weight),
    active = as.integer(active)
  )

if (!("area_name" %in% names(targets)) || !("target_share" %in% names(targets))) {
  stop("Target file must contain at least: area_name, target_share")
}

calib_tbl <- area_base |>
  left_join(targets |> dplyr::select(area_name, target_share, weight, active), by = "area_name") |>
  mutate(
    weight = coalesce_num(weight, 1.0, default = 1.0),
    active = coalesce(as.integer(active), 1L),
    in_optimization = active == 1L & !is.na(target_share) & population_total >= MIN_AREA_POP
  )

if (sum(calib_tbl$in_optimization, na.rm = TRUE) == 0) {
  stop("No admin-1 rows available for optimization. Check target_share/active/MIN_AREA_POP.")
}

log_step("Areas with optimization targets:", sum(calib_tbl$in_optimization, na.rm = TRUE))

# -----------------------------
# BUILD AREA CACHE
# -----------------------------
area_names <- calib_tbl$area_name
area_cache <- lapply(area_names, function(a) {
  d <- sett_supply |> dplyr::filter(area_name == a) |> dplyr::select(p_lit_sett_year, population)
  list(
    area = a,
    p = d$p_lit_sett_year,
    pop = d$population,
    pop_total = sum(d$population, na.rm = TRUE)
  )
})
names(area_cache) <- area_names

target_map <- setNames(calib_tbl$target_share, calib_tbl$area_name)
weight_map <- setNames(calib_tbl$weight, calib_tbl$area_name)
opt_map <- setNames(calib_tbl$in_optimization, calib_tbl$area_name)

# -----------------------------
# CALIBRATION SEARCH
# -----------------------------
log_step("Running calibration grid search | tau:", length(TAU_GRID), "| delta:", length(DELTA_GRID))

scan_rows <- vector("list", length(TAU_GRID))

for (i in seq_along(TAU_GRID)) {
  tau <- TAU_GRID[i]
  area_pred <- numeric(length(area_names))
  area_delta <- numeric(length(area_names))
  area_loss <- numeric(length(area_names))
  names(area_pred) <- area_names
  names(area_delta) <- area_names
  names(area_loss) <- area_names

  for (a in area_names) {
    cache <- area_cache[[a]]

    if (isTRUE(opt_map[[a]])) {
      dloss <- vapply(DELTA_GRID, function(delta) {
        s <- share_ge_threshold(cache$p, cache$pop, tau + delta)
        w <- weight_map[[a]]
        t <- target_map[[a]]
        w * (s - t)^2 + LAMBDA_DELTA * (delta^2)
      }, numeric(1))

      k <- which.min(dloss)
      best_delta <- DELTA_GRID[k]
      best_share <- share_ge_threshold(cache$p, cache$pop, tau + best_delta)
      best_loss <- dloss[k]
    } else {
      best_delta <- 0
      best_share <- share_ge_threshold(cache$p, cache$pop, tau)
      best_loss <- 0
    }

    area_pred[[a]] <- best_share
    area_delta[[a]] <- best_delta
    area_loss[[a]] <- best_loss
  }

  area_pop <- vapply(area_cache, `[[`, numeric(1), "pop_total")
  pred_nat <- sum(area_pred * area_pop, na.rm = TRUE) / sum(area_pop, na.rm = TRUE)
  nat_penalty <- MU_NATIONAL * (pred_nat - NATIONAL_TARGET_SHARE)^2
  obj <- sum(area_loss, na.rm = TRUE) + nat_penalty

  scan_rows[[i]] <- data.table(
    tau_global = tau,
    objective = obj,
    area_loss_sum = sum(area_loss, na.rm = TRUE),
    national_pred = pred_nat,
    national_target = NATIONAL_TARGET_SHARE,
    national_abs_error = abs(pred_nat - NATIONAL_TARGET_SHARE),
    national_penalty = nat_penalty
  )
}

scan_dt <- rbindlist(scan_rows)
setorder(scan_dt, objective, national_abs_error)
best <- scan_dt[1]

log_step(
  "Best tau:", round(best$tau_global, 4),
  "| national_pred:", round(best$national_pred, 4),
  "| abs_error:", round(best$national_abs_error, 4)
)

# Recompute area-level results at best tau
tau_best <- best$tau_global
area_out <- vector("list", length(area_names))

for (j in seq_along(area_names)) {
  a <- area_names[j]
  cache <- area_cache[[a]]
  w <- weight_map[[a]]
  t <- target_map[[a]]
  opt_on <- isTRUE(opt_map[[a]])

  if (opt_on) {
    dloss <- vapply(DELTA_GRID, function(delta) {
      s <- share_ge_threshold(cache$p, cache$pop, tau_best + delta)
      w * (s - t)^2 + LAMBDA_DELTA * (delta^2)
    }, numeric(1))
    k <- which.min(dloss)
    delta_best <- DELTA_GRID[k]
    share_cal <- share_ge_threshold(cache$p, cache$pop, tau_best + delta_best)
  } else {
    delta_best <- 0
    share_cal <- share_ge_threshold(cache$p, cache$pop, tau_best)
  }

  share_tau0 <- share_ge_threshold(cache$p, cache$pop, tau_best)
  area_out[[j]] <- data.table(
    area_name = a,
    population_total = cache$pop_total,
    target_share = t,
    in_optimization = opt_on,
    weight = w,
    share_model_current = calib_tbl$share_model_current[match(a, calib_tbl$area_name)],
    share_model_tau_global = share_tau0,
    delta_area = delta_best,
    threshold_area = tau_best + delta_best,
    share_model_calibrated = share_cal,
    abs_error_calibrated = ifelse(!is.na(t), abs(share_cal - t), NA_real_)
  )
}

area_res <- rbindlist(area_out)
setorder(area_res, -population_total)

nat_before <- with(area_res, sum(share_model_current * population_total, na.rm = TRUE) / sum(population_total, na.rm = TRUE))
nat_tau <- with(area_res, sum(share_model_tau_global * population_total, na.rm = TRUE) / sum(population_total, na.rm = TRUE))
nat_after <- with(area_res, sum(share_model_calibrated * population_total, na.rm = TRUE) / sum(population_total, na.rm = TRUE))

summary_tbl <- data.table(
  year = YEAR_LABEL,
  national_target_share = NATIONAL_TARGET_SHARE,
  national_share_current = nat_before,
  national_share_tau_global = nat_tau,
  national_share_calibrated = nat_after,
  tau_global_best = tau_best,
  lambda_delta = LAMBDA_DELTA,
  mu_national = MU_NATIONAL,
  min_area_pop = MIN_AREA_POP,
  n_areas_total = nrow(area_res),
  n_areas_optimized = sum(area_res$in_optimization, na.rm = TRUE),
  objective_best = best$objective
)

# -----------------------------
# SAVE
# -----------------------------
scan_csv <- file.path(OUT_DIR, paste0("admin1_calibration_tau_scan_", YEAR_LABEL, ".csv"))
best_csv <- file.path(OUT_DIR, paste0("admin1_calibration_results_", YEAR_LABEL, ".csv"))
summary_csv <- file.path(OUT_DIR, paste0("admin1_calibration_summary_", YEAR_LABEL, ".csv"))

fwrite(scan_dt, scan_csv)
fwrite(area_res, best_csv)
fwrite(summary_tbl, summary_csv)

arrow::write_parquet(scan_dt, sub("\\.csv$", ".parquet", scan_csv))
arrow::write_parquet(area_res, sub("\\.csv$", ".parquet", best_csv))
arrow::write_parquet(summary_tbl, sub("\\.csv$", ".parquet", summary_csv))

log_step("Saved:", scan_csv)
log_step("Saved:", best_csv)
log_step("Saved:", summary_csv)

cat("\n=== Calibration summary ===\n")
print(summary_tbl)
cat("\nTop area rows (by population):\n")
print(area_res[1:min(20, nrow(area_res))])
