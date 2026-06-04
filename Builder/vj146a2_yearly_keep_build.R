rm(list = ls())

# ============================================================
# Build VJ146A2 Yearly Settlement Keep/Stats File
# VJ Pre-Stage 2 - Annual composite keep-list
# ============================================================
#
# Purpose:  Builds the VJ pipeline yearly settlement stats Parquet from
#           an annual Black Marble composite. Preferred annual source is
#           VJ146A4. If VJ146A4 cannot be downloaded/read, this script
#           explicitly falls back to VNP46A4 and records that fallback in
#           output columns. It does not derive yearly keep from daily
#           VJ146A2 panels and does not read existing VNP yearly stats.
#           Run this before VJ Stage 2 so the daily extraction can
#           restrict settlement polygons to the annual keep list.
# Inputs:   - Map Data/Settlements/GPKG/south_africa_dre_atlas_settlements_full_col.gpkg
#           - Black Marble annual VJ146A4 or VNP46A4 tiles downloaded at runtime
# Outputs:  - Map Data/reliability_outputs_vj146a2/yearly_settlement_stats_YYYY.parquet
#           - Map Data/reliability_outputs_vj146a2/vj146a2_yearly_keep_YYYY.parquet
#           - Map Data/reliability_outputs_vj146a2/vj146a2_yearly_keep_calibration_YYYY.csv
# Run:      Rscript Builder/vj146a2_yearly_keep_build.R
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(sf)
  library(terra)
  library(blackmarbler)
  library(exactextractr)
  library(dplyr)
  library(data.table)
})

sf::sf_use_s2(FALSE)

# ------------------------------------------------------------
# CONFIG
# ------------------------------------------------------------
BASE_PATH <- here::here()

SETT_GPKG <- file.path(
  BASE_PATH,
  "Map Data",
  "Settlements",
  "GPKG",
  "south_africa_dre_atlas_settlements_full_col.gpkg"
)

OUT_DIR <- file.path(BASE_PATH, "Map Data", "reliability_outputs_vj146a2")
YEAR_LABEL <- Sys.getenv("VJ146A2_YEAR", "2023")

TARGET_POP_SHARE <- as.numeric(Sys.getenv("VJ146A2_TARGET_POP_SHARE", "0.877"))
PIXEL_LIT_THRESHOLD <- as.numeric(Sys.getenv("VJ146A2_PIXEL_LIT_THRESHOLD", "1.0"))
SETTLEMENT_LIT_THRESHOLDS <- seq(0.05, 0.95, by = 0.01)
MIN_COVERAGE_SHARE <- as.numeric(Sys.getenv("VJ146A2_ANNUAL_MIN_COVERAGE", "0.50"))
POP_FIELD <- "population"

ANNUAL_PRODUCT_PRIORITY <- c("VJ146A4", "VNP46A4")
ANNUAL_VARIABLE <- "NearNadir_Composite_Snow_Free"
ANNUAL_QUALITY_FLAG_RM <- c(1L, 2L) # keep quality flag 0, matching VNP Stage 4
ANNUAL_H5_CACHE_DIRS <- c(
  VJ146A4 = file.path(BASE_PATH, "blackmarbler", "out_vj146a2_sa_daily", "h5_cache_annual"),
  VNP46A4 = file.path(BASE_PATH, "blackmarbler", "out_vnp46a2_sa_daily", "h5_cache_annual")
)
CHECK_ALL_TILES_EXIST <- Sys.getenv("VJ146A2_ANNUAL_CHECK_ALL_TILES", "1") != "0"

TILES_URL <- "https://raw.githubusercontent.com/worldbank/blackmarbler/main/data/blackmarbletiles.geojson"
TILES_PATH <- file.path(BASE_PATH, "blackmarbler", "blackmarbletiles.geojson")

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
for (cache_dir in ANNUAL_H5_CACHE_DIRS) dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(SETT_GPKG)) stop("Settlements file not found: ", SETT_GPKG)
if (!grepl("^\\d{4}$", YEAR_LABEL)) stop("Invalid VJ146A2_YEAR; expected YYYY.")
if (!is.finite(TARGET_POP_SHARE) || TARGET_POP_SHARE <= 0 || TARGET_POP_SHARE >= 1) {
  stop("Invalid VJ146A2_TARGET_POP_SHARE; expected a value between 0 and 1.")
}
if (!is.finite(PIXEL_LIT_THRESHOLD)) {
  stop("Invalid VJ146A2_PIXEL_LIT_THRESHOLD; expected a finite numeric value.")
}
if (!is.finite(MIN_COVERAGE_SHARE) || MIN_COVERAGE_SHARE < 0 || MIN_COVERAGE_SHARE > 1) {
  stop("Invalid VJ146A2_ANNUAL_MIN_COVERAGE; expected a value between 0 and 1.")
}

# ------------------------------------------------------------
# BLACKMARBLER PATCHES
# ------------------------------------------------------------
patch_namespace_function <- function(ns, nm, f) {
  if (!exists(nm, envir = ns, inherits = FALSE)) {
    stop("blackmarbler namespace function not found: ", nm)
  }
  environment(f) <- ns
  unlockBinding(nm, ns)
  assign(nm, f, envir = ns)
  lockBinding(nm, ns)
  invisible(TRUE)
}

patch_blackmarbler_tiles <- function(tiles_url, tiles_path) {
  if (!file.exists(tiles_path)) return(invisible(FALSE))
  ns <- asNamespace("blackmarbler")
  objs <- ls(envir = ns, all.names = TRUE)
  hit_fns <- Filter(function(nm) {
    obj <- tryCatch(get(nm, envir = ns), error = function(e) NULL)
    if (!is.function(obj)) return(FALSE)
    txt <- paste(deparse(body(obj)), collapse = "\n")
    grepl(tiles_url, txt, fixed = TRUE)
  }, objs)
  if (length(hit_fns) == 0) return(invisible(FALSE))
  for (nm in hit_fns) {
    f <- get(nm, envir = ns)
    f_txt <- paste(deparse(body(f)), collapse = "\n")
    f_txt2 <- gsub(tiles_url, tiles_path, f_txt, fixed = TRUE)
    f2 <- f
    body(f2) <- parse(text = f_txt2)
    environment(f2) <- ns
    unlockBinding(nm, ns)
    assign(nm, f2, envir = ns)
    lockBinding(nm, ns)
  }
  invisible(TRUE)
}

patch_blackmarbler_vj_annual_support <- function() {
  ns <- asNamespace("blackmarbler")

  patch_namespace_function(ns, "define_variable", function(variable, product_id) {
    if (is.null(variable)) {
      if (product_id %in% c("VNP46A1", "VJ146A1")) variable <- "DNB_At_Sensor_Radiance_500m"
      if (product_id %in% c("VNP46A2", "VJ146A2")) variable <- "Gap_Filled_DNB_BRDF-Corrected_NTL"
      if (product_id %in% c("VNP46A3", "VNP46A4", "VJ146A3", "VJ146A4")) {
        variable <- "NearNadir_Composite_Snow_Free"
      }
    }
    variable
  })

  patch_namespace_function(ns, "define_date_name", function(date_i, product_id) {
    if (product_id %in% c("VNP46A1", "VNP46A2", "VJ146A1", "VJ146A2")) {
      return(paste0("t", stringr::str_replace_all(date_i, "-", "_")))
    }
    if (product_id %in% c("VNP46A3", "VJ146A3")) {
      return(paste0("t", stringr::str_replace_all(date_i, "-", "_") %>% substring(1, 7)))
    }
    if (product_id %in% c("VNP46A4", "VJ146A4")) {
      return(paste0("t", stringr::str_replace_all(date_i, "-", "_") %>% substring(1, 4)))
    }
    stop("Unsupported Black Marble product_id: ", product_id)
  })

  patch_namespace_function(ns, "create_dataset_name_df", function(product_id, all = FALSE,
                                                                  years = NULL, months = NULL,
                                                                  days = NULL) {
    daily_products <- c("VNP46A1", "VNP46A2", "VJ146A1", "VJ146A2")
    monthly_products <- c("VNP46A3", "VJ146A3")
    annual_products <- c("VNP46A4", "VJ146A4")
    supported_products <- c(daily_products, monthly_products, annual_products)
    if (!(product_id %in% supported_products)) {
      stop("Unsupported Black Marble product_id: ", product_id)
    }

    if (product_id %in% daily_products) months <- NULL
    if (product_id %in% monthly_products) days <- NULL
    if (product_id %in% annual_products) {
      days <- NULL
      months <- NULL
    }

    year_end <- as.numeric(substring(Sys.Date(), 1, 4))
    if (product_id %in% daily_products) {
      param_df <- tidyr::expand_grid(year = 2012:year_end, day = pad3(1:366))
    }
    if (product_id %in% monthly_products) {
      param_df <- tidyr::expand_grid(
        year = 2012:year_end,
        day = c(
          "001", "032", "061", "092", "122", "153", "183", "214", "245", "275", "306", "336",
          "060", "091", "121", "152", "182", "213", "244", "274", "305", "335"
        )
      )
    }
    if (product_id %in% annual_products) {
      param_df <- tidyr::expand_grid(year = 2012:year_end, day = "001")
    }

    if (product_id %in% c(daily_products, monthly_products)) {
      param_df <- param_df %>%
        dplyr::mutate(month = month_start_day_to_month(day) %>% as.numeric())
    }
    if (!is.null(years)) param_df <- param_df[param_df$year %in% years, ]
    if (product_id %in% c(daily_products, monthly_products)) {
      if (!is.null(months)) param_df <- param_df[as.numeric(param_df$month) %in% as.numeric(months), ]
      if (!is.null(days)) param_df <- param_df[as.numeric(param_df$day) %in% as.numeric(days), ]
    }

    purrr::map2(param_df$year, param_df$day, read_bm_csv, product_id) %>%
      dplyr::bind_rows()
  })

  patch_namespace_function(ns, "bm_raster_i", function(roi_sf, product_id, date, bearer, variable,
                                                       quality_flag_rm, check_all_tiles_exist,
                                                       h5_dir, download_method, quiet, temp_dir) {
    tiles_path <- file.path(here::here(), "blackmarbler", "blackmarbletiles.geojson")
    tiles_source <- if (file.exists(tiles_path)) {
      tiles_path
    } else {
      "https://raw.githubusercontent.com/worldbank/blackmarbler/main/data/blackmarbletiles.geojson"
    }
    bm_tiles_sf <- sf::read_sf(tiles_source)
    if (product_id %in% c("VNP46A3", "VJ146A3") && nchar(date) %in% 7) date <- paste0(date, "-01")
    if (product_id %in% c("VNP46A4", "VJ146A4") && nchar(date) %in% 4) date <- paste0(date, "-01-01")

    year <- lubridate::year(date)
    month <- lubridate::month(date)
    day <- lubridate::yday(date)
    bm_files_df <- create_dataset_name_df(product_id = product_id, all = TRUE, years = year, months = month, days = day)
    if (nrow(bm_files_df) == 0) {
      warning(paste0("No satellite imagery exists for ", date, "; skipping"))
      return(NULL)
    }

    bm_tiles_sf <- bm_tiles_sf[!(stringr::str_detect(bm_tiles_sf$TileID, "h00")), ]
    bm_tiles_sf <- bm_tiles_sf[!(stringr::str_detect(bm_tiles_sf$TileID, "v00")), ]
    inter <- tryCatch({
      sf::st_intersects(bm_tiles_sf, roi_sf, sparse = FALSE) %>% apply(1, sum)
    }, error = function(e1) {
      tryCatch({
        warning("Issue with `roi_sf` intersecting with blackmarble tiles; trying bounding box intersection.")
        roi_bbox_sf <- roi_sf %>%
          sf::st_bbox() %>%
          sf::st_as_sfc() %>%
          sf::st_as_sf()
        sf::st_intersects(bm_tiles_sf, roi_bbox_sf, sparse = FALSE) %>% apply(1, sum)
      }, error = function(e2) {
        stop("Issue with `roi_sf` intersecting with blackmarble tiles; try buffering by width 0: ", e2$message)
      })
    })

    grid_use_sf <- bm_tiles_sf[inter > 0, ]
    tile_ids_rx <- paste(grid_use_sf$TileID, collapse = "|")
    if (nrow(grid_use_sf) > 0) {
      bm_files_df <- bm_files_df[stringr::str_detect(bm_files_df$name, tile_ids_rx), ]
    } else {
      bm_files_df <- data.frame(NULL)
    }

    if (nrow(bm_files_df) == 0) {
      warning(paste0("No satellite imagery exists for ", date, "; skipping"))
      return(NULL)
    }
    if ((nrow(bm_files_df) < nrow(grid_use_sf)) && check_all_tiles_exist) {
      warning("Not all satellite imagery tiles for this location exist, so skipping. To ignore, set check_all_tiles_exist = FALSE.")
    }

    unlink(file.path(temp_dir, product_id), recursive = TRUE)
    if (!quiet) message(paste0("Processing ", nrow(bm_files_df), " nighttime light tiles"))
    r_list <- lapply(bm_files_df$name, function(name_i) {
      download_raster(name_i, temp_dir, variable, bearer, quality_flag_rm, h5_dir, download_method, quiet)
    })
    r_list <- r_list[!vapply(r_list, is.null, logical(1))]
    if (length(r_list) == 0) return(NULL)
    if (length(r_list) == 1) {
      r <- r_list[[1]]
    } else {
      r <- do.call(terra::mosaic, c(r_list, fun = "max"))
    }
    r <- terra::crop(r, roi_sf)
    unlink(file.path(temp_dir, product_id), recursive = TRUE)
    r
  })

  invisible(TRUE)
}

# ------------------------------------------------------------
# HELPERS
# ------------------------------------------------------------
require_cols <- function(x, required, label) {
  missing_cols <- setdiff(required, names(x))
  if (length(missing_cols) > 0) {
    stop(label, " is missing required columns: ", paste(missing_cols, collapse = ", "))
  }
}

download_annual_composite <- function(roi_sf, bearer) {
  reasons <- character()
  for (product_id in ANNUAL_PRODUCT_PRIORITY) {
    fallback_used <- product_id != ANNUAL_PRODUCT_PRIORITY[[1]]
    fallback_reason <- if (fallback_used) paste(reasons, collapse = " | ") else ""
    message("Trying annual Black Marble product: ", product_id)

    rad <- tryCatch(
      blackmarbler::bm_raster(
        roi_sf = roi_sf,
        product_id = product_id,
        date = YEAR_LABEL,
        bearer = bearer,
        variable = ANNUAL_VARIABLE,
        quality_flag_rm = ANNUAL_QUALITY_FLAG_RM,
        check_all_tiles_exist = CHECK_ALL_TILES_EXIST,
        output_location_type = "memory",
        h5_dir = ANNUAL_H5_CACHE_DIRS[[product_id]],
        quiet = TRUE
      ),
      error = function(e) e
    )

    if (inherits(rad, "SpatRaster")) {
      if (terra::nlyr(rad) > 1) {
        message("Downloaded raster has ", terra::nlyr(rad), " bands. Using first band only.")
        rad <- rad[[1]]
      }
      names(rad) <- "rad"
      if (fallback_used) {
        message("Annual fallback used: ", product_id, " because ", fallback_reason)
      }
      return(list(
        raster = rad,
        product_id = product_id,
        fallback_used = fallback_used,
        fallback_reason = fallback_reason
      ))
    }

    reason <- if (inherits(rad, "condition")) conditionMessage(rad) else "blackmarbler returned NULL/non-raster"
    reasons <- c(reasons, paste0(product_id, ": ", reason))
    message("Annual product failed: ", product_id, " | ", reason)
  }

  stop(
    "Could not download/read any annual Black Marble product.\n  - ",
    paste(reasons, collapse = "\n  - ")
  )
}

# ------------------------------------------------------------
# LOAD SETTLEMENTS
# ------------------------------------------------------------
message("Reading settlements...")
sett <- sf::st_read(SETT_GPKG, quiet = TRUE)
require_cols(sett, c("settlement_id", POP_FIELD), "Settlement GPKG")

sett$settlement_id <- as.character(sett$settlement_id)
sett[[POP_FIELD]] <- as.numeric(sett[[POP_FIELD]])
sett[[POP_FIELD]][is.na(sett[[POP_FIELD]])] <- 0
sett <- sf::st_make_valid(sett)

if (anyDuplicated(sett$settlement_id) > 0) stop("Settlement GPKG has duplicate settlement_id values.")
if (nrow(sett) == 0) stop("Settlement GPKG has zero settlement rows.")

patch_blackmarbler_tiles(TILES_URL, TILES_PATH)
patch_blackmarbler_vj_annual_support()

bearer <- blackmarbler::get_nasa_token(
  username = Sys.getenv("EARTHDATA_USER"),
  password = Sys.getenv("EARTHDATA_PASS")
)
if (!nzchar(bearer)) stop("Could not retrieve NASA bearer token.")

roi_sf <- sf::st_sf(id = 1L, geometry = sf::st_as_sfc(sf::st_bbox(sett)))
annual <- download_annual_composite(roi_sf, bearer)
rad <- annual$raster

if (is.na(sf::st_crs(sett))) stop("Settlements CRS is missing.")
if (!identical(sf::st_crs(sett)$wkt, sf::st_crs(terra::crs(rad))$wkt)) {
  message("Reprojecting settlements to annual raster CRS...")
  sett <- sf::st_transform(sett, terra::crs(rad))
}

# ------------------------------------------------------------
# SETTLEMENT-LEVEL STATS FROM YEARLY COMPOSITE
# ------------------------------------------------------------
message("Extracting settlement-level annual composite stats...")
valid <- terra::ifel(is.na(rad), 0, 1)
lit <- terra::ifel(is.na(rad), 0, terra::ifel(rad >= PIXEL_LIT_THRESHOLD, 1, 0))
allpix <- terra::setValues(terra::rast(rad), 1)

mean_rad <- exactextractr::exact_extract(rad, sett, "mean", progress = TRUE)
lit_weight <- exactextractr::exact_extract(lit, sett, "sum", progress = TRUE)
valid_weight <- exactextractr::exact_extract(valid, sett, "sum", progress = TRUE)
total_weight <- exactextractr::exact_extract(allpix, sett, "sum", progress = TRUE)

sett_stats <- data.table(
  settlement_id = sett$settlement_id,
  population = sett[[POP_FIELD]],
  mean_rad = as.numeric(mean_rad),
  lit_weight = as.numeric(lit_weight),
  valid_weight = as.numeric(valid_weight),
  total_weight = as.numeric(total_weight)
)

sett_stats[, coverage_share := fifelse(total_weight > 0, valid_weight / total_weight, NA_real_)]
sett_stats[, p_lit_sett_year := fifelse(valid_weight > 0, lit_weight / valid_weight, NA_real_)]
sett_stats[, support_ok := !is.na(p_lit_sett_year) & !is.na(coverage_share) & coverage_share >= MIN_COVERAGE_SHARE]

sett_stats[, annual_source_product := annual$product_id]
sett_stats[, annual_source_variable := ANNUAL_VARIABLE]
sett_stats[, annual_fallback_used := annual$fallback_used]
sett_stats[, annual_fallback_reason := annual$fallback_reason]
sett_stats[, yearly_method := "annual_composite"]
sett_stats[, year := YEAR_LABEL]
sett_stats[, pixel_lit_threshold := PIXEL_LIT_THRESHOLD]
sett_stats[, min_coverage_share := MIN_COVERAGE_SHARE]

pop_total <- sett_stats[, sum(population, na.rm = TRUE)]
n_total <- nrow(sett_stats)
if (!is.finite(pop_total) || pop_total <= 0) stop("Total full-universe settlement population is zero or invalid.")

# ------------------------------------------------------------
# THRESHOLD SWEEP
# ------------------------------------------------------------
message("Running annual-composite threshold sweep...")
calib <- rbindlist(lapply(SETTLEMENT_LIT_THRESHOLDS, function(threshold) {
  elect <- sett_stats$support_ok & sett_stats$p_lit_sett_year >= threshold
  n_elect <- sum(elect, na.rm = TRUE)
  pop_elect <- sum(sett_stats$population[elect], na.rm = TRUE)
  share_pop <- pop_elect / pop_total

  data.table(
    year = YEAR_LABEL,
    yearly_method = "annual_composite",
    annual_source_product = annual$product_id,
    annual_source_variable = ANNUAL_VARIABLE,
    annual_fallback_used = annual$fallback_used,
    annual_fallback_reason = annual$fallback_reason,
    yearly_tif = paste(annual$product_id, YEAR_LABEL, ANNUAL_VARIABLE, "qf0", sep = "_"),
    pixel_lit_threshold = PIXEL_LIT_THRESHOLD,
    settlement_lit_threshold = threshold,
    min_coverage_share = MIN_COVERAGE_SHARE,
    n_settlements_total = n_total,
    n_settlements_support_ok = sum(sett_stats$support_ok, na.rm = TRUE),
    n_settlements_electrified = n_elect,
    share_settlements_electrified = n_elect / n_total,
    population_total = pop_total,
    population_electrified = pop_elect,
    share_population_electrified = share_pop,
    target_population_share = TARGET_POP_SHARE,
    abs_error = abs(share_pop - TARGET_POP_SHARE)
  )
}))

setorder(calib, abs_error, -share_population_electrified, settlement_lit_threshold)
best <- calib[1]

message("Best annual-composite threshold summary:")
print(best)

sett_stats[, electrified_best := as.integer(support_ok & p_lit_sett_year >= best$settlement_lit_threshold)]
sett_stats[, settlement_lit_threshold_best := best$settlement_lit_threshold]
sett_stats[, target_population_share := TARGET_POP_SHARE]

setcolorder(
  sett_stats,
  c(
    "settlement_id",
    "population",
    "electrified_best",
    "annual_source_product",
    "annual_source_variable",
    "annual_fallback_used",
    "annual_fallback_reason",
    "yearly_method",
    setdiff(
      names(sett_stats),
      c(
        "settlement_id",
        "population",
        "electrified_best",
        "annual_source_product",
        "annual_source_variable",
        "annual_fallback_used",
        "annual_fallback_reason",
        "yearly_method"
      )
    )
  )
)

keep <- sett_stats[electrified_best == 1L, .(
  settlement_id,
  population,
  electrified_best,
  annual_source_product,
  annual_source_variable,
  annual_fallback_used,
  annual_fallback_reason,
  yearly_method
)]

if (nrow(keep) == 0) stop("VJ pre-Stage 2 produced zero electrified settlements; inspect calibration before continuing.")

# ------------------------------------------------------------
# WRITE OUTPUTS
# ------------------------------------------------------------
stats_csv <- file.path(OUT_DIR, paste0("yearly_settlement_stats_", YEAR_LABEL, ".csv"))
stats_parquet <- file.path(OUT_DIR, paste0("yearly_settlement_stats_", YEAR_LABEL, ".parquet"))
calib_csv <- file.path(OUT_DIR, paste0("vj146a2_yearly_keep_calibration_", YEAR_LABEL, ".csv"))
keep_parquet <- file.path(OUT_DIR, paste0("vj146a2_yearly_keep_", YEAR_LABEL, ".parquet"))

fwrite(sett_stats, stats_csv)
arrow::write_parquet(sett_stats, stats_parquet)
fwrite(calib, calib_csv)
arrow::write_parquet(keep, keep_parquet)

message("Wrote VJ annual-composite yearly stats: ", stats_parquet)
message("Wrote VJ annual-composite yearly keep list: ", keep_parquet)
message("Wrote VJ annual-composite calibration: ", calib_csv)
message(
  "Annual source: ", annual$product_id,
  " | fallback used: ", annual$fallback_used,
  if (nzchar(annual$fallback_reason)) paste0(" | reason: ", annual$fallback_reason) else "",
  " | best threshold: ", best$settlement_lit_threshold,
  " | electrified population share: ", round(best$share_population_electrified, 4)
)
