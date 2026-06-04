# ============================================================
# Download Daily VJ146A2 Night-Light Rasters (NASA LAADS)
# Stage 1-style isolated VJ acquisition
# ============================================================
#
# Purpose:  Downloads VJ146A2 BRDF-corrected daily radiance for
#           South Africa-minus-Lesotho directly from NASA LAADS H5 files;
#           applies VJ quality filters and writes one 3-band GeoTIFF
#           (rad, lit, valid) per available day.
# Inputs:   - NASA Earthdata credentials in ~/.Renviron
#             (EARTHDATA_USER / EARTHDATA_PASS)
#           - blackmarbler/blackmarbletiles.geojson
# Outputs:  - blackmarbler/out_vj146a2_sa_daily/
#               vj146a2_sa_500m_daily_YYYY-MM-DD.tif
#           - blackmarbler/out_vj146a2_sa_daily/
#               vj146a2_daily_download_summary_<YEAR>.csv
# Run:      Rscript nightlight_downloader/vj146a2_daily_download.R
#
# IMPORTANT: Isolated VJ path. Does not overwrite production VNP46A2
# rasters, settlement panels, or reliability outputs.
# ============================================================

rm(list = ls())

suppressPackageStartupMessages({
  library(sf)
  library(terra)
  library(blackmarbler)
  library(geodata)
  library(httr2)
})

sf::sf_use_s2(FALSE)

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
script_path <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
if (is.na(script_path) || !nzchar(script_path)) {
  script_dir <- normalizePath(getwd(), winslash = "/", mustWork = TRUE)
} else {
  script_dir <- dirname(normalizePath(script_path, winslash = "/", mustWork = TRUE))
}

BASE_PATH <- normalizePath(file.path(script_dir, ".."), winslash = "/", mustWork = TRUE)
if (!file.exists(file.path(BASE_PATH, "README.md")) ||
    !dir.exists(file.path(BASE_PATH, "blackmarbler"))) {
  cwd <- normalizePath(getwd(), winslash = "/", mustWork = TRUE)
  if (file.exists(file.path(cwd, "README.md")) &&
      dir.exists(file.path(cwd, "blackmarbler"))) {
    BASE_PATH <- cwd
  }
}

YEAR <- as.integer(Sys.getenv("BM_VJ_YEAR", unset = "2023"))
if (is.na(YEAR) || YEAR < 2012L) stop("Invalid BM_VJ_YEAR: ", Sys.getenv("BM_VJ_YEAR"))

START_DATE <- as.Date(Sys.getenv("BM_VJ_START_DATE", unset = sprintf("%d-01-01", YEAR)))
END_DATE <- as.Date(Sys.getenv("BM_VJ_END_DATE", unset = sprintf("%d-01-01", YEAR + 1L)))
if (is.na(START_DATE) || is.na(END_DATE) || END_DATE <= START_DATE) {
  stop("Invalid BM_VJ_START_DATE / BM_VJ_END_DATE. End date is exclusive.")
}
TARGET_DATES <- seq.Date(START_DATE, END_DATE - 1L, by = "day")

OUT_DIR <- file.path(BASE_PATH, "blackmarbler", "out_vj146a2_sa_daily")
H5_CACHE <- file.path(OUT_DIR, "h5_cache")
GADM_DIR <- file.path(OUT_DIR, "gadm")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(H5_CACHE, recursive = TRUE, showWarnings = FALSE)
dir.create(GADM_DIR, recursive = TRUE, showWarnings = FALSE)

TILES_PATH <- file.path(BASE_PATH, "blackmarbler", "blackmarbletiles.geojson")
if (!file.exists(TILES_PATH)) stop("Missing local blackmarbler tile file: ", TILES_PATH)

LIT_THRESHOLD <- as.numeric(Sys.getenv("BM_VJ_LIT_THRESHOLD", unset = "1.0"))
ALLOW_CLOUD_CONF_MAX <- as.integer(Sys.getenv("BM_VJ_ALLOW_CLOUD_CONF_MAX", unset = "1"))
MANDATORY_QF_MAX <- as.integer(Sys.getenv("BM_VJ_MANDATORY_QF_MAX", unset = "0"))
DOWNLOAD_RETRIES <- as.integer(Sys.getenv("BM_VJ_DOWNLOAD_RETRIES", unset = "3"))
OVERWRITE <- toupper(Sys.getenv("BM_VJ_OVERWRITE", unset = "FALSE")) %in% c("1", "TRUE", "YES")
STOP_ON_ERROR <- toupper(Sys.getenv("BM_VJ_STOP_ON_ERROR", unset = "TRUE")) %in% c("1", "TRUE", "YES")
DRY_RUN <- toupper(Sys.getenv("BM_VJ_DRY_RUN", unset = "FALSE")) %in% c("1", "TRUE", "YES")
KEEP_H5_CACHE <- toupper(Sys.getenv("BM_VJ_KEEP_H5_CACHE", unset = "TRUE")) %in% c("1", "TRUE", "YES")

if (!is.finite(LIT_THRESHOLD)) stop("Invalid BM_VJ_LIT_THRESHOLD.")
if (is.na(ALLOW_CLOUD_CONF_MAX)) stop("Invalid BM_VJ_ALLOW_CLOUD_CONF_MAX.")
if (is.na(MANDATORY_QF_MAX)) stop("Invalid BM_VJ_MANDATORY_QF_MAX.")
if (is.na(DOWNLOAD_RETRIES) || DOWNLOAD_RETRIES < 1L) DOWNLOAD_RETRIES <- 1L

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
log_step <- function(...) {
  cat(format(Sys.time(), "%H:%M:%S"), "-", ..., "\n")
  flush.console()
}

get_nasa_bearer <- function() {
  token <- blackmarbler::get_nasa_token(
    username = Sys.getenv("EARTHDATA_USER"),
    password = Sys.getenv("EARTHDATA_PASS")
  )
  if (!nzchar(token)) stop("Could not retrieve NASA bearer token.")
  token
}

build_sa_roi <- function() {
  sa <- geodata::gadm(country = "ZAF", level = 0, path = GADM_DIR) |>
    sf::st_as_sf() |>
    sf::st_transform(4326)
  lso <- geodata::gadm(country = "LSO", level = 0, path = GADM_DIR) |>
    sf::st_as_sf() |>
    sf::st_transform(4326)

  sa_g <- sf::st_make_valid(sf::st_geometry(sa))
  lso_g <- sf::st_make_valid(sf::st_geometry(lso))
  sa_clip_g <- sf::st_difference(sf::st_union(sa_g), sf::st_union(lso_g))
  sa <- sf::st_set_geometry(sa, sa_clip_g)
  sf::st_cast(sf::st_make_valid(sa), "MULTIPOLYGON")
}

tile_ids_for_roi <- function(roi_sf, tiles_path) {
  tiles <- sf::st_read(tiles_path, quiet = TRUE)
  hits <- sf::st_intersects(sf::st_transform(roi_sf, sf::st_crs(tiles)), tiles, sparse = FALSE)[1, ]
  list(tile_ids = sort(tiles$TileID[hits]), tiles = tiles)
}

extract_tile_id <- function(x) {
  hit <- regexpr("h[0-9]{2}v[0-9]{2}", x)
  out <- rep(NA_character_, length(x))
  ok <- hit > 0L
  out[ok] <- regmatches(x, hit)
  out
}

download_manifest <- function(product_id, target_date, bearer) {
  year <- format(target_date, "%Y")
  doy <- format(target_date, "%j")
  url <- sprintf(
    "https://ladsweb.modaps.eosdis.nasa.gov/archive/allData/5200/%s/%s/%s.csv",
    product_id, year, doy
  )

  last_error <- NULL
  for (attempt in seq_len(DOWNLOAD_RETRIES)) {
    resp <- tryCatch(
      httr2::request(url) |>
        httr2::req_headers(Authorization = paste("Bearer", bearer)) |>
        httr2::req_timeout(60) |>
        httr2::req_perform(),
      error = function(e) {
        last_error <<- conditionMessage(e)
        NULL
      }
    )

    if (!is.null(resp) && httr2::resp_status(resp) == 200L) {
      txt <- httr2::resp_body_string(resp)
      return(utils::read.csv(text = txt, stringsAsFactors = FALSE, check.names = FALSE))
    }

    if (attempt < DOWNLOAD_RETRIES) {
      log_step("Retrying manifest", product_id, format(target_date), sprintf("(attempt %d/%d failed)", attempt, DOWNLOAD_RETRIES))
      Sys.sleep(min(60, 8 * attempt))
      bearer <- get_nasa_bearer()
    }
  }

  stop("Manifest download failed for ", product_id, " ", format(target_date), ". Last error: ", last_error)
}

download_laads_file <- function(url, out_path, bearer) {
  if (file.exists(out_path) && file.info(out_path)$size > 10000) return(out_path)

  last_error <- NULL
  for (attempt in seq_len(DOWNLOAD_RETRIES)) {
    resp <- tryCatch(
      httr2::request(url) |>
        httr2::req_headers(Authorization = paste("Bearer", bearer)) |>
        httr2::req_timeout(180) |>
        httr2::req_perform(),
      error = function(e) {
        last_error <<- conditionMessage(e)
        NULL
      }
    )

    if (!is.null(resp) && httr2::resp_status(resp) == 200L) {
      writeBin(httr2::resp_body_raw(resp), out_path)
      return(out_path)
    }

    if (attempt < DOWNLOAD_RETRIES) {
      log_step("Retrying file", basename(out_path), sprintf("(attempt %d/%d failed)", attempt, DOWNLOAD_RETRIES))
      Sys.sleep(min(60, 8 * attempt))
      bearer <- get_nasa_bearer()
    }
  }

  stop("File download failed: ", url, ". Last error: ", last_error)
}

read_h5_var_like_blackmarbler <- function(h5_file, variable, tiles_sf) {
  h5_data <- terra::rast(h5_file)
  if (!(variable %in% names(h5_data))) {
    stop("Variable ", variable, " not found in ", basename(h5_file),
         ". Available: ", paste(names(h5_data), collapse = ", "))
  }

  tile_i <- extract_tile_id(basename(h5_file))
  grid_i <- tiles_sf[tiles_sf$TileID == tile_i, ]
  if (nrow(grid_i) != 1L) stop("Could not locate tile geometry for ", tile_i)
  bb <- sf::st_bbox(grid_i)

  out <- h5_data[[variable]]
  terra::crs(out) <- "EPSG:4326"
  terra::ext(out) <- c(round(bb$xmin), round(bb$xmax), round(bb$ymin), round(bb$ymax))

  remove_fill_value <- getFromNamespace("remove_fill_value", "blackmarbler")
  apply_scaling_factor <- getFromNamespace("apply_scaling_factor", "blackmarbler")
  out <- remove_fill_value(out, variable)
  apply_scaling_factor(out, variable)
}

download_vj146a2_variable <- function(variable, target_date, tile_ids, bearer, h5_cache, tiles_sf, roi_sf, manifest) {
  manifest$tile_id <- extract_tile_id(manifest$name)
  wanted <- manifest[manifest$tile_id %in% tile_ids & grepl("\\.h5$", manifest$name), , drop = FALSE]
  if (nrow(wanted) == 0L) stop("No VJ146A2 H5 files found for target tiles on ", format(target_date))
  if (!all(c("name", "downloadsLink") %in% names(wanted))) {
    stop("Unexpected LAADS manifest columns. Found: ", paste(names(wanted), collapse = ", "))
  }

  rasters <- vector("list", nrow(wanted))
  for (i in seq_len(nrow(wanted))) {
    out_path <- file.path(h5_cache, wanted$name[i])
    download_laads_file(wanted$downloadsLink[i], out_path, bearer)
    rasters[[i]] <- read_h5_var_like_blackmarbler(out_path, variable, tiles_sf)
  }

  merged <- do.call(terra::merge, rasters)
  merged <- terra::crop(merged, terra::vect(roi_sf))
  terra::mask(merged, terra::vect(roi_sf))
}

daily_h5_paths <- function(manifest, tile_ids, h5_cache) {
  manifest$tile_id <- extract_tile_id(manifest$name)
  wanted <- manifest[manifest$tile_id %in% tile_ids & grepl("\\.h5$", manifest$name), , drop = FALSE]
  file.path(h5_cache, wanted$name)
}

align_to_template <- function(r, template, method = "near") {
  same_grid <- isTRUE(all.equal(terra::res(r), terra::res(template))) &&
    isTRUE(all.equal(terra::ext(r), terra::ext(template))) &&
    isTRUE(all.equal(terra::crs(r), terra::crs(template)))
  if (same_grid) return(r)
  terra::resample(r, template, method = method)
}

qf_bits_fun <- function(x, shift, mask) {
  x <- as.integer(round(x))
  bitwAnd(bitwShiftR(x, shift), mask)
}

extract_cloud_bits <- function(cloud) {
  list(
    day_night = terra::app(cloud, function(x) qf_bits_fun(x, 0L, 1L)),
    cloud_conf = terra::app(cloud, function(x) qf_bits_fun(x, 6L, 3L)),
    shadow = terra::app(cloud, function(x) qf_bits_fun(x, 8L, 1L)),
    cirrus = terra::app(cloud, function(x) qf_bits_fun(x, 9L, 1L)),
    snow_ice_cloud = terra::app(cloud, function(x) qf_bits_fun(x, 10L, 1L)),
    aurora = terra::app(cloud, function(x) qf_bits_fun(x, 12L, 1L)),
    lunar_eclipse = terra::app(cloud, function(x) qf_bits_fun(x, 13L, 1L))
  )
}

make_valid_01 <- function(valid_logical) {
  valid <- terra::ifel(valid_logical, 1, 0)
  terra::ifel(is.na(valid_logical), 0, valid)
}

build_vj_daily_raster <- function(rad, qf, cloud, snow) {
  bits <- extract_cloud_bits(cloud)
  valid_logical <- (bits$day_night == 0) &
    (bits$cloud_conf <= ALLOW_CLOUD_CONF_MAX) &
    (qf <= MANDATORY_QF_MAX) &
    (snow == 0) &
    (bits$snow_ice_cloud == 0) &
    (bits$shadow == 0) &
    (bits$cirrus == 0) &
    (bits$aurora == 0) &
    (bits$lunar_eclipse == 0) &
    !is.na(rad) &
    !is.na(qf) &
    !is.na(cloud) &
    !is.na(snow)

  valid <- make_valid_01(valid_logical)
  names(valid) <- "valid"

  rad_masked <- terra::mask(rad, valid, maskvalues = 0, updatevalue = NA)
  names(rad_masked) <- "rad"

  lit <- terra::ifel(is.na(rad_masked), NA, terra::ifel(rad_masked > LIT_THRESHOLD, 1, 0))
  names(lit) <- "lit"

  c(rad_masked, lit, valid)
}

count_condition <- function(condition_raster) {
  x <- terra::ifel(condition_raster, 1, 0)
  x <- terra::ifel(is.na(condition_raster), 0, x)
  as.numeric(terra::global(x, "sum", na.rm = TRUE)[1, 1])
}

summarize_output <- function(date_str, out, status = "ok") {
  valid <- out[["valid"]]
  lit <- out[["lit"]]
  rad <- out[["rad"]]
  n_total <- terra::ncell(valid)
  n_valid <- count_condition(valid == 1)
  n_lit <- count_condition(lit == 1)
  data.frame(
    date = date_str,
    n_total_pixels = n_total,
    n_valid_pixels = n_valid,
    n_lit_pixels = n_lit,
    valid_share = ifelse(n_total > 0, n_valid / n_total, NA_real_),
    p_lit = ifelse(n_valid > 0, n_lit / n_valid, NA_real_),
    lit_share_all = ifelse(n_total > 0, n_lit / n_total, NA_real_),
    mean_rad_valid = as.numeric(terra::global(rad, "mean", na.rm = TRUE)[1, 1]),
    status = status,
    stringsAsFactors = FALSE
  )
}

summary_row <- function(date_str, status, reason = NA_character_) {
  data.frame(
    date = date_str,
    n_total_pixels = NA_real_,
    n_valid_pixels = NA_real_,
    n_lit_pixels = NA_real_,
    valid_share = NA_real_,
    p_lit = NA_real_,
    lit_share_all = NA_real_,
    mean_rad_valid = NA_real_,
    status = status,
    reason = reason,
    stringsAsFactors = FALSE
  )
}

with_reason <- function(row, reason = NA_character_) {
  row$reason <- reason
  row
}

write_daily_tif <- function(date_str, out) {
  out_file <- file.path(OUT_DIR, sprintf("vj146a2_sa_500m_daily_%s.tif", date_str))
  terra::writeRaster(
    out,
    out_file,
    overwrite = TRUE,
    wopt = list(gdal = c("COMPRESS=LZW"))
  )
  out_file
}

process_date <- function(target_date, bearer, tile_ids, tiles_sf, roi_sf, template) {
  date_str <- format(target_date, "%Y-%m-%d")
  out_file <- file.path(OUT_DIR, sprintf("vj146a2_sa_500m_daily_%s.tif", date_str))

  if (file.exists(out_file) && !OVERWRITE) {
    existing <- terra::rast(out_file)
    names(existing) <- c("rad", "lit", "valid")
    return(list(template = template, row = with_reason(summarize_output(date_str, existing, "existing"), "existing output reused")))
  }

  manifest <- download_manifest("VJ146A2", target_date, bearer)
  manifest$tile_id <- extract_tile_id(manifest$name)
  available_tiles <- intersect(sort(unique(stats::na.omit(manifest$tile_id))), tile_ids)
  if (length(available_tiles) == 0L) {
    return(list(template = template, row = summary_row(date_str, "missing", "no South Africa VJ146A2 tiles in LAADS manifest")))
  }
  date_h5_files <- daily_h5_paths(manifest, tile_ids, H5_CACHE)

  rad <- download_vj146a2_variable("DNB_BRDF-Corrected_NTL", target_date, tile_ids, bearer, H5_CACHE, tiles_sf, roi_sf, manifest)
  qf <- download_vj146a2_variable("Mandatory_Quality_Flag", target_date, tile_ids, bearer, H5_CACHE, tiles_sf, roi_sf, manifest)
  cloud <- download_vj146a2_variable("QF_Cloud_Mask", target_date, tile_ids, bearer, H5_CACHE, tiles_sf, roi_sf, manifest)
  snow <- download_vj146a2_variable("Snow_Flag", target_date, tile_ids, bearer, H5_CACHE, tiles_sf, roi_sf, manifest)
  names(rad) <- "rad"
  names(qf) <- "mandatory_qf"
  names(cloud) <- "qf_cloud_mask"
  names(snow) <- "snow_flag"

  if (is.null(template)) template <- rad
  rad <- align_to_template(rad, template, method = "near")
  qf <- align_to_template(qf, template, method = "near")
  cloud <- align_to_template(cloud, template, method = "near")
  snow <- align_to_template(snow, template, method = "near")

  out <- build_vj_daily_raster(rad, qf, cloud, snow)
  out_file <- write_daily_tif(date_str, out)
  if (!KEEP_H5_CACHE) {
    unlink(date_h5_files[file.exists(date_h5_files)])
  }
  row <- with_reason(summarize_output(date_str, out, "ok"), out_file)
  list(template = template, row = row)
}

# ------------------------------------------------------------
# Run
# ------------------------------------------------------------
log_step("Repository root:", BASE_PATH)
log_step("Date range:", format(START_DATE), "to", format(END_DATE - 1L), "(end date exclusive:", format(END_DATE), ")")
log_step("Output:", OUT_DIR)
log_step("Filter:", sprintf("lit rad > %.3f; cloud_conf <= %d; mandatory_qf <= %d", LIT_THRESHOLD, ALLOW_CLOUD_CONF_MAX, MANDATORY_QF_MAX))
log_step("Overwrite existing daily TIFFs:", OVERWRITE)
log_step("Keep raw H5 cache:", KEEP_H5_CACHE)

if (DRY_RUN) {
  log_step("Dry run requested; exiting before NASA auth/download.")
  quit(save = "no", status = 0)
}

bearer <- get_nasa_bearer()
roi_sf <- build_sa_roi()
tile_info <- tile_ids_for_roi(roi_sf, TILES_PATH)
tile_ids <- tile_info$tile_ids
tiles_sf <- tile_info$tiles
log_step("Target tiles:", paste(tile_ids, collapse = ", "))

summary_rows <- list()
template <- NULL

for (target_date in TARGET_DATES) {
  target_date <- as.Date(target_date, origin = "1970-01-01")
  date_str <- format(target_date, "%Y-%m-%d")
  log_step("Processing VJ146A2", date_str)

  result <- tryCatch(
    process_date(target_date, bearer, tile_ids, tiles_sf, roi_sf, template),
    error = function(e) {
      if (STOP_ON_ERROR) stop(e)
      log_step("FAILED", date_str, "-", conditionMessage(e))
      list(template = template, row = summary_row(date_str, "failed", conditionMessage(e)))
    }
  )

  template <- result$template
  summary_rows[[date_str]] <- result$row
  log_step("Status:", result$row$status[1], "-", result$row$reason[1])
}

summary_csv <- file.path(OUT_DIR, sprintf("vj146a2_daily_download_summary_%d.csv", YEAR))
summary_tbl <- do.call(rbind, summary_rows)
if (file.exists(summary_csv)) {
  existing_summary <- utils::read.csv(summary_csv, stringsAsFactors = FALSE)
  existing_summary <- existing_summary[!(existing_summary$date %in% summary_tbl$date), , drop = FALSE]
  summary_tbl <- rbind(existing_summary, summary_tbl)
  summary_tbl <- summary_tbl[order(summary_tbl$date), , drop = FALSE]
}
utils::write.csv(summary_tbl, summary_csv, row.names = FALSE)

log_step("Wrote summary:", summary_csv)
log_step("Done.")
