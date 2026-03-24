# run_coverage_sweep.R
# Driver: re-runs the panel builder + choropleth at each AREA_COVERAGE_MIN
# threshold, then produces a per-local-area population coverage CSV.
#
# Usage (from project root):
#   Rscript Builder/run_coverage_sweep.R

# CONFIG
THRESHOLDS <- c(0.25, 0.30, 0.40, 0.50)

run_script <- function(script_rel_path, env_vars) {
  env_str <- paste(paste0(names(env_vars), "=", env_vars), collapse = " ")
  cmd <- paste(env_str, "Rscript", script_rel_path)
  message("\n>>> ", cmd)
  rc <- system(cmd)
  if (rc != 0) stop("Script failed (exit ", rc, "): ", script_rel_path)
  invisible(rc)
}

# ── Step 1: sweep ──────────────────────────────────────────────────────────────
for (thr in THRESHOLDS) {
  tag  <- paste0("_cov", as.integer(thr * 100))
  ftag <- paste0("_cov", as.integer(thr * 100))  # kept separate for clarity

  run_script("Visualizer/reliability_panel_build_yearlykeep.R",
    c(RUN_AREA_COV_MIN  = thr,
      RUN_OUTPUT_SUFFIX = tag))

  run_script("Visualizer/reliability_choropleth_maps.R",
    c(RUN_OUTPUT_SUFFIX = tag,
      RUN_FIG_TAG       = ftag))
}

# ── Step 2: population CSV ─────────────────────────────────────────────────────
# Run panel builder with AREA_COVERAGE_MIN=0 to capture all areas
run_script("Visualizer/reliability_panel_build_yearlykeep.R",
  c(RUN_AREA_COV_MIN  = 0,
    RUN_OUTPUT_SUFFIX = "_cov0"))

library(here)
library(arrow)
library(sf)
library(dplyr)

BASE_PATH <- here::here()
OUT_DIR   <- file.path(BASE_PATH, "Map Data", "reliability_outputs_blackmarbler")
FIG_DIR   <- file.path(OUT_DIR, "figures")

local_all <- arrow::read_parquet(file.path(OUT_DIR,
  "localarea_reliability_yearly_strict_yearlykeep_postdoe_cov0.parquet"))

local_shp <- sf::st_read(
  file.path(BASE_PATH, "Map Data", "Local Area", "LOCAL_AREA_GCCA2025.shp"),
  quiet = TRUE) %>%
  sf::st_drop_geometry()

pop_csv <- local_shp %>%
  dplyr::select(area_name = LocalArea) %>%
  dplyr::left_join(
    local_all %>%
      dplyr::select(area_name, area_population, kept_population,
                    share_population_kept),
    by = "area_name") %>%
  dplyr::arrange(dplyr::desc(dplyr::coalesce(share_population_kept, -1)))

write.csv(pop_csv,
  file.path(FIG_DIR, "localarea_population_coverage.csv"),
  row.names = FALSE)
message("Saved: localarea_population_coverage.csv  (", nrow(pop_csv), " areas)")
