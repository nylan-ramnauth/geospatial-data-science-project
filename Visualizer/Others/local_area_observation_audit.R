# ============================================================
# Local Area Observation Audit
# Stage 5c — Data Coverage Audit
# ============================================================
#
# Purpose:  Validates temporal data coverage at local-area level;
#           flags local areas with insufficient observations for reliable
#           reliability estimates.
# Inputs:   - Map Data/settlement_day_outputs_rasters_blackmarbler/settlement_day_blackmarbler_cov_YYYY-MM.parquet
#           - Map Data/Local Area/LOCAL_AREA_GCCA2025.shp
# Outputs:  - Map Data/reliability_outputs_blackmarbler/localarea_observation_audit_*.csv
# Run:      Rscript Visualizer/local_area_observation_audit.R
# ============================================================

rm(list = ls())

suppressPackageStartupMessages({
  library(here)
  library(arrow)
  library(dplyr)
  library(sf)
  library(readr)
  library(stringr)
})

sf::sf_use_s2(FALSE)

# -----------------------------
# CONFIG
# -----------------------------
BASE_PATH <- here::here()
OUT_DIR <- file.path(BASE_PATH, "Map Data", "reliability_outputs_blackmarbler")
LOCAL_AREAS_SHP <- file.path(BASE_PATH, "Map Data", "Local Area", "LOCAL_AREA_GCCA2025.shp")

START_DATE <- as.Date("2023-01-01")
END_DATE <- as.Date("2023-12-31")
N_DAYS_MIN_YEAR <- 120L
AREA_COVERAGE_MIN <- 0.25

STATE_FILES <- list.files(
  OUT_DIR,
  pattern = "^settlement_day_states_strict.*\\.parquet$",
  full.names = TRUE
)
STATE_FILES <- STATE_FILES[!grepl("_hysteresis\\.parquet$", STATE_FILES)]

if (length(STATE_FILES) == 0) {
  stop("No strict state files found in: ", OUT_DIR)
}
if (!file.exists(LOCAL_AREAS_SHP)) {
  stop("Local area shapefile not found: ", LOCAL_AREAS_SHP)
}

first_non_na <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA)
  x[[1]]
}

scenario_from_file <- function(path) {
  nm <- basename(path)
  x <- str_remove(nm, "^settlement_day_states_strict")
  x <- str_remove(x, "\\.parquet$")
  x <- str_remove(x, "^_")
  ifelse(nzchar(x), x, "base")
}

local_areas <- st_read(LOCAL_AREAS_SHP, quiet = TRUE)

summaries <- vector("list", length(STATE_FILES))

for (i in seq_along(STATE_FILES)) {
  p <- STATE_FILES[i]
  scenario <- scenario_from_file(p)
  cat("\nReading:", basename(p), "| scenario:", scenario, "\n")

  dat <- arrow::read_parquet(
    p,
    col_select = any_of(c(
      "settlement_id", "date", "p_lit_sett", "electrified_after_doe_strict",
      "population", "lon", "lat"
    ))
  ) %>%
    mutate(
      settlement_id = as.character(settlement_id),
      date = as.Date(date)
    ) %>%
    filter(date >= START_DATE, date <= END_DATE)

  if (!"electrified_after_doe_strict" %in% names(dat)) {
    stop("Missing electrified_after_doe_strict in ", basename(p))
  }
  if (!"population" %in% names(dat)) dat$population <- NA_real_
  if (!"lon" %in% names(dat)) dat$lon <- NA_real_
  if (!"lat" %in% names(dat)) dat$lat <- NA_real_

  sett_static <- dat %>%
    group_by(settlement_id) %>%
    summarise(
      population = suppressWarnings(as.numeric(first_non_na(population))),
      lon = suppressWarnings(as.numeric(first_non_na(lon))),
      lat = suppressWarnings(as.numeric(first_non_na(lat))),
      .groups = "drop"
    ) %>%
    mutate(population = ifelse(is.na(population), 0, population))

  sett_points <- sett_static %>%
    filter(!is.na(lon), !is.na(lat)) %>%
    st_as_sf(coords = c("lon", "lat"), crs = 4326, remove = FALSE)

  lookup <- st_join(
    st_transform(sett_points, st_crs(local_areas)),
    local_areas["LocalArea"],
    left = TRUE
  ) %>%
    st_drop_geometry() %>%
    transmute(settlement_id, local_area = as.character(LocalArea)) %>%
    arrange(settlement_id, local_area) %>%
    distinct(settlement_id, .keep_all = TRUE)

  sett_static <- sett_static %>%
    left_join(lookup, by = "settlement_id") %>%
    mutate(local_area = ifelse(is.na(local_area) | local_area == "", "UNMATCHED", local_area))

  day_sett <- dat %>%
    transmute(
      settlement_id,
      obs_any = !is.na(p_lit_sett),
      obs_post_doe = !is.na(p_lit_sett) & electrified_after_doe_strict == 1L
    ) %>%
    group_by(settlement_id) %>%
    summarise(
      n_obs_any = sum(obs_any, na.rm = TRUE),
      n_obs_post_doe = sum(obs_post_doe, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(
      n_obs_any = as.integer(n_obs_any),
      n_obs_post_doe = as.integer(n_obs_post_doe)
    ) %>%
    mutate(support_ok_year = n_obs_post_doe >= N_DAYS_MIN_YEAR)

  sett_enriched <- sett_static %>%
    left_join(day_sett, by = "settlement_id") %>%
    mutate(
      n_obs_any = ifelse(is.na(n_obs_any), 0L, n_obs_any),
      n_obs_post_doe = ifelse(is.na(n_obs_post_doe), 0L, n_obs_post_doe),
      support_ok_year = ifelse(is.na(support_ok_year), FALSE, support_ok_year)
    )

  area_sum <- sett_enriched %>%
    group_by(local_area) %>%
    summarise(
      scenario = scenario,
      n_settlements_total = n_distinct(settlement_id),
      n_settlements_with_any_obs = sum(n_obs_any > 0, na.rm = TRUE),
      n_settlements_support_ok = sum(support_ok_year, na.rm = TRUE),
      population_total = sum(population, na.rm = TRUE),
      population_support_ok = sum(ifelse(support_ok_year, population, 0), na.rm = TRUE),
      n_obs_any = sum(.data$n_obs_any, na.rm = TRUE),
      n_obs_post_doe_support_ok = sum(ifelse(.data$support_ok_year, .data$n_obs_post_doe, 0L), na.rm = TRUE),
      n_obs_post_doe = sum(.data$n_obs_post_doe, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(
      share_population_kept = ifelse(population_total > 0, population_support_ok / population_total, NA_real_),
      passes_area_coverage_filter = !is.na(share_population_kept) & share_population_kept >= AREA_COVERAGE_MIN,
      mean_n_days_post_doe_per_settlement = ifelse(
        n_settlements_total > 0,
        n_obs_post_doe / n_settlements_total,
        NA_real_
      ),
      mean_n_days_post_doe_per_support_settlement = ifelse(
        n_settlements_support_ok > 0,
        n_obs_post_doe_support_ok / n_settlements_support_ok,
        NA_real_
      ),
      mean_obs_post_doe_per_support_settlement = ifelse(
        n_settlements_support_ok > 0,
        n_obs_post_doe_support_ok / n_settlements_support_ok,
        NA_real_
      )
    ) %>%
    arrange(local_area)

  summaries[[i]] <- area_sum
}

out <- bind_rows(summaries) %>%
  mutate(
    start_date = START_DATE,
    end_date = END_DATE,
    n_days_min_year = N_DAYS_MIN_YEAR,
    area_coverage_min = AREA_COVERAGE_MIN
  )

out_file <- file.path(
  OUT_DIR,
  paste0("localarea_observation_audit_", format(START_DATE, "%Y-%m-%d"), "_to_", format(END_DATE, "%Y-%m-%d"), ".csv")
)
readr::write_csv(out, out_file)

cat("\nWrote:", out_file, "\n")
cat("Rows:", nrow(out), "\n")

cat("\nLowest n_obs_post_doe_support_ok (first 20 rows):\n")
print(out %>% arrange(n_obs_post_doe_support_ok) %>% head(20))
