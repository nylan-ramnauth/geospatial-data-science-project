rm(list = ls())

# ============================================================
# Build Settlement-Day Panel from Daily VIIRS GeoTIFFs
# Stage 2 — Panel Construction
# ============================================================
#
# Purpose:  Reads settlement polygons and daily VIIRS GeoTIFFs; loops
#           month-by-month and computes area-weighted lit/valid pixel
#           extractions per settlement-day (no coverage filter applied).
# Inputs:   - Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_full_col.gpkg
#           - blackmarbler/out_vnp46a2_sa_daily/*.tif  (from Stage 0)
# Outputs:  - Map Data/settlement_day_outputs_rasters_blackmarbler/settlement_day_blackmarbler_nocov_YYYY-MM.parquet
#           - Map Data/settlement_day_outputs_rasters_blackmarbler/settlement_month_blackmarbler_nocov_YYYY-MM.gpkg
# Run:      Rscript Builder/settlement_day_panel_build.R
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(sf)
  library(dplyr)
  library(arrow)
  library(terra)
  library(stringr)
})

sf::sf_use_s2(FALSE)

# -----------------------------
# PATHS (EDIT)
# -----------------------------
BASE_PATH <- here::here()

# Settlements (full geometry)
SETT_GPKG <- file.path(BASE_PATH, "Map Data", "Settlements", "GPKG", "south_africa_dre_atlas_settlements_full_col.gpkg")

# NO-GAP rasters (BRDF, no gap-fill)
RAST_DIR <- file.path(BASE_PATH, "blackmarbler", "out_vnp46a2_sa_daily")

# Output folder
OUT_DIR <- file.path(BASE_PATH, "Map Data", "settlement_day_outputs_rasters_blackmarbler")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

OUT_LAYER <- "settlement_month"

# -----------------------------
# PARAMETERS (EDIT)
# -----------------------------
MIN_COVERAGE <- 0.50  # drop settlement-days with coverage below this share
MAX_TIFS <- NA_integer_  # set to an integer (e.g., 1) for a quick smoke test; NA = all files
APPLY_COVERAGE_FILTER <- FALSE  # set TRUE to filter by MIN_COVERAGE inside this script
DEBUG <- FALSE  # set TRUE to run lookup test after precomputing settlement areas
START_MONTH <- "2023-01"
END_MONTH   <- "2023-12"
AREA_CRS <- "+proj=aea +lat_1=-18 +lat_2=-32 +lat_0=0 +lon_0=24 +datum=WGS84 +units=m +no_defs"

# -----------------------------
# HELPERS
# -----------------------------
get_date <- function(path) {
  m <- str_match(basename(path), "(\\d{4}-\\d{2}-\\d{2})")
  if (is.na(m[, 2])) stop("Could not parse date from filename: ", basename(path))
  as.Date(m[, 2])
}

pick_valid_band <- function(r) {
  if ("valid" %in% names(r)) return(r[["valid"]])
  if (terra::nlyr(r) >= 3) return(r[[3]])  # rad, lit, valid
  if (terra::nlyr(r) >= 2) return(r[[2]])  # rad, valid
  stop("Could not locate valid band; expected at least 2 bands.")
}

pick_lit_band <- function(r) {
  if ("lit" %in% names(r)) return(r[["lit"]])
  if (terra::nlyr(r) >= 3) return(r[[2]])  # assume rad, lit, valid
  stop("Could not locate lit band; ensure EXPORT_LIT_BAND=TRUE.")
}

# -----------------------------
# 1) READ SETTLEMENTS
# -----------------------------
sett <- st_read(SETT_GPKG, quiet = TRUE) %>% st_make_valid()
stopifnot("settlement_id" %in% names(sett))
sett_v <- terra::vect(sett)

# -----------------------------
# 2) LIST DAILY RASTERS
# -----------------------------
tifs <- list.files(RAST_DIR, pattern = "\\.tif$", full.names = TRUE, ignore.case = TRUE)
stopifnot(length(tifs) > 0)
tifs <- tifs[order(tifs)]
if (!is.na(MAX_TIFS)) {
  tifs <- head(tifs, MAX_TIFS)
  message("TEST MODE: limiting to ", length(tifs), " raster(s)")
}

# -----------------------------
# 3) ALIGN CRS (SETTLEMENTS -> RASTER CRS)
# -----------------------------
r0 <- terra::rast(tifs[1])
if (is.na(terra::crs(r0))) stop("Raster CRS is missing.")
sett_v <- terra::project(sett_v, terra::crs(r0))
cell_area_r <- terra::cellSize(r0, unit = "m")
names(cell_area_r) <- "cell_area_m2"
cell_area_mean <- terra::global(cell_area_r, "mean", na.rm = TRUE)[1, 1]
if (!is.finite(cell_area_mean) || cell_area_mean <= 0) {
  stop("cellSize() returned invalid cell areas. Check raster CRS/resolution.")
}

# -----------------------------
# 3.5) PREFLIGHT CHECKS (FAST)
# -----------------------------
month_start <- as.Date(paste0(START_MONTH, "-01"))
month_end <- as.Date(paste0(END_MONTH, "-01"))
if (is.na(month_start) || is.na(month_end)) stop("Invalid START_MONTH/END_MONTH (use 'YYYY-MM').")
if (month_start > month_end) stop("START_MONTH must be <= END_MONTH.")

months_seq <- seq.Date(from = month_start, to = month_end, by = "month")

tif_dates <- as.Date(vapply(tifs, get_date, numeric(1)), origin = "1970-01-01")
tif_map <- setNames(tifs, format(tif_dates, "%Y-%m-%d"))


range_start <- month_start
range_end <- seq.Date(from = month_end, by = "month", length.out = 2)[2] - 1
in_range <- tif_dates >= range_start & tif_dates <= range_end
if (!any(in_range)) {
  stop("No rasters found in date range ", START_MONTH, " to ", END_MONTH, ".")
}

test_f <- tifs[which(in_range)[1]]
test_r <- terra::rast(test_f)
bn <- names(test_r)
if (!("lit" %in% bn) && terra::nlyr(test_r) < 3) {
  stop("Lit band not found (need band named 'lit' or at least 3 layers).")
}
if (!("valid" %in% bn) && terra::nlyr(test_r) < 2) {
  stop("Valid band not found (need band named 'valid' or at least 2 layers).")
}

test_sett <- sett_v[1]
test_v <- pick_valid_band(test_r)
test_ex <- terra::extract(test_v, test_sett, fun = sum, na.rm = TRUE, exact = TRUE)
if (nrow(test_ex) == 0) stop("Preflight failed: extraction returned no rows.")
cat("Preflight OK:", basename(test_f), "\n")

# -----------------------------
# 4) PRECOMPUTE SETTLEMENT AREA + N_MAX (DIAGNOSTIC)
# -----------------------------
area_crs <- sf::st_crs(AREA_CRS)
if (is.na(area_crs)) stop("AREA_CRS is invalid: ", AREA_CRS)
sett_area_m2 <- as.numeric(st_area(st_transform(sett, AREA_CRS)))
if (any(!is.finite(sett_area_m2)) || any(sett_area_m2 <= 0)) {
  stop("Invalid settlement areas after transform to AREA_CRS.")
}
ones_r <- terra::init(r0[[1]], 1)
ex_nmax <- terra::extract(
  ones_r,
  sett_v,
  fun = function(x, ...) length(x),
  exact = FALSE,
  touches = TRUE
)
if (length(ex_nmax[[2]]) != nrow(sett) || any(is.na(ex_nmax[[2]]))) {
  stop("n_max extraction failed or returned unexpected length.")
}
sett_area_tbl <- tibble(
  settlement_id = sett$settlement_id,
  area_m2 = sett_area_m2,
  n_max = ex_nmax[[2]]
)

if (DEBUG) {
  # Pick one existing and one missing date to verify tif_map lookup
  test_existing <- names(tif_map)[1]
  test_missing  <- "2023-07-26"   # known missing date in 2023 data

  test_lookup <- function(d_str) {
    cat("\nTesting:", d_str, "\n")

    f <- tif_map[d_str]

    if (length(f) == 0L || is.na(f)) {
      cat(" -> correctly detected as MISSING\n")
      return(invisible(NULL))
    }

    f <- unname(f)
    cat(" -> found file:", basename(f), "\n")

    # try opening raster
    r <- terra::rast(f)
    cat(" -> raster opened OK, layers:", terra::nlyr(r), "\n")
  }

  test_lookup(test_existing)
  test_lookup(test_missing)
}



# -----------------------------
# 5) MONTH LOOP WITH DAILY PROCESSING
# -----------------------------
for (mi in seq_along(months_seq)) {
  m <- months_seq[mi]
  m_str <- format(m, "%Y-%m")
  cat("=== Month", m_str, "===\n")

  next_month <- seq.Date(from = m, by = "month", length.out = 2)[2]
  m_last <- next_month - 1
  days_in_month <- seq.Date(from = m, to = m_last, by = "day")

  results <- vector("list", length(days_in_month))
  used <- 0L

  for (di in seq_along(days_in_month)) {
    d <- days_in_month[di]
    d_str <- format(d, "%Y-%m-%d")
    f <- tif_map[d_str]  # named character vector lookup
    if (length(f) == 0L || is.na(f)) {
      cat("Missing", d_str, "- skipping\n")
      next
    }
    if (!file.exists(f) || file.info(f)$size == 0) {
      cat("Bad file", d_str, "- skipping\n")
      next
    }
    f <- unname(f)

    cat("Processing", d_str, ":", basename(f), "\n")

    r <- terra::rast(f)
    v_band <- pick_valid_band(r)
    l_band <- pick_lit_band(r)
    area_r <- if (terra::compareGeom(r, cell_area_r, stopOnError = FALSE)) {
      cell_area_r
    } else {
      terra::resample(cell_area_r, r, method = "near")
    }

    # Weighted (exact overlap)
    ex_valid_w <- terra::extract(v_band, sett_v, fun = sum, na.rm = TRUE, exact = TRUE)
    ex_lit_w   <- terra::extract(l_band, sett_v, fun = sum, na.rm = TRUE, exact = TRUE)

    # Unweighted (pixel-center inclusion)
    ex_valid_c <- terra::extract(v_band, sett_v, fun = sum, na.rm = TRUE, exact = FALSE)
    ex_lit_c   <- terra::extract(l_band, sett_v, fun = sum, na.rm = TRUE, exact = FALSE)

    # Any-overlap (cell touches polygon)
    ex_valid_t <- terra::extract(v_band > 0, sett_v, fun = sum, na.rm = TRUE, exact = FALSE, touches = TRUE)
    ex_total_t <- terra::extract(
      v_band,
      sett_v,
      fun = function(x, ...) length(x),
      exact = FALSE,
      touches = TRUE
    )
    ex_valid_area_w <- terra::extract(area_r * v_band, sett_v, fun = sum, na.rm = TRUE, exact = TRUE)
    if (length(ex_valid_area_w[[2]]) != nrow(sett)) {
      stop("valid_area_m2 extraction failed for ", d_str)
    }
  
    df_day <- tibble(
      settlement_id = sett$settlement_id,
      date = d,
      n_valid = ex_valid_w[[2]],
      n_lit   = ex_lit_w[[2]],
      n_valid_count = ex_valid_c[[2]],
      n_lit_count   = ex_lit_c[[2]],
      n_valid_overlap = ex_valid_t[[2]],
      n_total_overlap = ex_total_t[[2]],
      valid_area_m2 = ex_valid_area_w[[2]]
    ) %>%
      mutate(
        p_lit_sett = ifelse(n_valid > 0, n_lit / n_valid, NA_real_),
        p_lit_count = ifelse(n_valid_count > 0, n_lit_count / n_valid_count, NA_real_)
      )

    used <- used + 1L
    results[[used]] <- df_day
  }

  if (used == 0L) {
    cat("No available rasters for", m_str, "- skipping month outputs\n")
    next
  }

  sett_day <- bind_rows(results[seq_len(used)])

  # -----------------------------
  # 6) COVERAGE FILTER
  # -----------------------------
  # Safety: ensure area_m2 / n_max exists
  if (!exists("sett_area_tbl") || !"area_m2" %in% names(sett_area_tbl) || !"n_max" %in% names(sett_area_tbl)) {
    sett_area_m2 <- as.numeric(st_area(st_transform(sett, AREA_CRS)))
    ones_r <- terra::init(r0[[1]], 1)
    ex_nmax <- terra::extract(
      ones_r,
      sett_v,
      fun = function(x, ...) length(x),
      exact = FALSE,
      touches = TRUE
    )
    sett_area_tbl <- tibble(
      settlement_id = sett$settlement_id,
      area_m2 = sett_area_m2,
      n_max = ex_nmax[[2]]
    )
  }

  sett_day <- sett_day %>%
    left_join(sett_area_tbl, by = "settlement_id") %>%
    mutate(
      coverage = ifelse(!is.na(valid_area_m2) & area_m2 > 0, pmin(1, valid_area_m2 / area_m2), NA_real_),
      coverage_count = ifelse(n_total_overlap > 0, n_valid_overlap / n_total_overlap, NA_real_)
    )

  if (APPLY_COVERAGE_FILTER) {
    sett_day <- sett_day %>%
      filter(coverage >= MIN_COVERAGE)
    cat("Applied coverage filter (>", MIN_COVERAGE, "); rows:", nrow(sett_day), "\n")
  } else {
    cat("Skipping coverage filter (APPLY_COVERAGE_FILTER=FALSE); rows:", nrow(sett_day), "\n")
  }

  # -----------------------------
  # 7) SAVE DAILY PANEL
  # -----------------------------
  out_parq <- file.path(OUT_DIR, paste0("settlement_day_blackmarbler_nocov_", m_str, ".parquet"))
  arrow::write_parquet(sett_day, out_parq)
  cat("Wrote:", out_parq, "rows:", nrow(sett_day), "\n")

  # -----------------------------
  # 8) MONTHLY AGG + GEOMETRY (OPTIONAL)
  # -----------------------------
  sett_month <- sett_day %>%
    group_by(settlement_id) %>%
    summarise(
      mean_p_lit = mean(p_lit_sett, na.rm = TRUE),
      mean_p_lit_count = mean(p_lit_count, na.rm = TRUE),
      sd_p_lit   = ifelse(sum(!is.na(p_lit_sett)) >= 2, sd(p_lit_sett, na.rm = TRUE), NA_real_),
      drop_frac  = mean(p_lit_sett < 0.2, na.rm = TRUE),
      n_days_obs = sum(!is.na(p_lit_sett)),
      mean_cov   = mean(coverage, na.rm = TRUE),
      mean_cov_count = mean(coverage_count, na.rm = TRUE),
      mean_n_valid = mean(n_valid, na.rm = TRUE),
      mean_n_valid_count = mean(n_valid_count, na.rm = TRUE),
      .groups = "drop"
    )

  sett_month_sf <- sett %>%
    select(settlement_id) %>%
    left_join(sett_month, by = "settlement_id")

  out_gpkg <- file.path(OUT_DIR, paste0("settlement_month_blackmarbler_nocov_", m_str, ".gpkg"))
  st_write(
    sett_month_sf,
    out_gpkg,
    layer = OUT_LAYER,
    delete_layer = TRUE,
    quiet = TRUE
  )

  cat("Wrote monthly mapping layer:", out_gpkg, "layer =", OUT_LAYER, "\n")
}

message("Done.")
