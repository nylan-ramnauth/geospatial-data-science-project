# ============================================================
# VJ146A2 Monthly GIF Diagnostic
# ============================================================
#
# Purpose:  Download one full month of VJ146A2 only, build daily
#           South Africa-minus-Lesotho 500 m diagnostic rasters, and
#           render a discrete lit-threshold GIF.
#
# Default:  BM_VJ_MONTH=2023-10, because 2023-10-20 is a known bad
#           VNP46A2 stray-light day.
#
# Outputs:  blackmarbler/out_vnp46a2_sa_daily/qa_straylight_validation/
#             vj146a2_month_<YYYY-MM>/
#
# Run:      Rscript nightlight_downloader/Others/vj146a2_month_gif_diagnostic.R
#
# IMPORTANT: Diagnostic-only. Does not modify production daily TIFFs,
# viirs_daily_download.R, or settlement-panel outputs.
# ============================================================

rm(list = ls())

suppressPackageStartupMessages({
  library(sf)
  library(terra)
  library(blackmarbler)
  library(geodata)
  library(httr2)
  library(readr)
  library(gifski)
  library(stringr)
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

BASE_PATH <- normalizePath(file.path(script_dir, "..", ".."), winslash = "/", mustWork = TRUE)
if (!file.exists(file.path(BASE_PATH, "STRAY_LIGHT_FIX_PLAN.md"))) {
  cwd <- normalizePath(getwd(), winslash = "/", mustWork = TRUE)
  if (file.exists(file.path(cwd, "STRAY_LIGHT_FIX_PLAN.md"))) BASE_PATH <- cwd
}

MONTH_STR <- Sys.getenv("BM_VJ_MONTH", unset = "2023-10")
MONTH_START <- as.Date(paste0(MONTH_STR, "-01"))
if (is.na(MONTH_START)) stop("Invalid BM_VJ_MONTH; expected YYYY-MM, got: ", MONTH_STR)
MONTH_END <- seq(MONTH_START, length = 2L, by = "1 month")[2] - 1L
TARGET_DATES <- seq(MONTH_START, MONTH_END, by = "1 day")

CURRENT_TIF_DIR <- file.path(BASE_PATH, "blackmarbler", "out_vnp46a2_sa_daily")
OUT_DIR <- file.path(
  CURRENT_TIF_DIR,
  "qa_straylight_validation",
  sprintf("vj146a2_month_%s", MONTH_STR)
)
H5_CACHE <- file.path(OUT_DIR, "h5_cache")
RASTER_DIR <- file.path(OUT_DIR, "rasters")
FRAME_DIR <- file.path(OUT_DIR, "frames")
dir.create(H5_CACHE, recursive = TRUE, showWarnings = FALSE)
dir.create(RASTER_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(FRAME_DIR, recursive = TRUE, showWarnings = FALSE)

TILES_PATH <- file.path(BASE_PATH, "blackmarbler", "blackmarbletiles.geojson")
if (!file.exists(TILES_PATH)) stop("Missing local blackmarbler tile file: ", TILES_PATH)

LIT_THRESHOLD <- as.numeric(Sys.getenv("BM_VJ_LIT_THRESHOLD", unset = "1.0"))
ALLOW_CLOUD_CONF_MAX <- as.integer(Sys.getenv("BM_VJ_ALLOW_CLOUD_CONF_MAX", unset = "1"))
MANDATORY_QF_MAX <- as.integer(Sys.getenv("BM_VJ_MANDATORY_QF_MAX", unset = "0"))
DOWNLOAD_RETRIES <- as.integer(Sys.getenv("BM_VJ_DOWNLOAD_RETRIES", unset = "3"))
GIF_FPS <- as.numeric(Sys.getenv("BM_VJ_GIF_FPS", unset = "2"))

CLASS_COLS <- c("#32104b", "#ffd31a")
NA_COL <- "#d9d9d9"

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

build_sa_roi <- function(current_tif_dir) {
  gadm_dir <- file.path(current_tif_dir, "gadm")
  dir.create(gadm_dir, recursive = TRUE, showWarnings = FALSE)

  sa <- geodata::gadm(country = "ZAF", level = 0, path = gadm_dir) |>
    sf::st_as_sf() |>
    sf::st_transform(4326)
  lso <- geodata::gadm(country = "LSO", level = 0, path = gadm_dir) |>
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
  sort(tiles$TileID[hits])
}

download_manifest <- function(product_id, target_date, bearer) {
  year <- format(target_date, "%Y")
  doy <- format(target_date, "%j")
  url <- sprintf(
    "https://ladsweb.modaps.eosdis.nasa.gov/archive/allData/5200/%s/%s/%s.csv",
    product_id, year, doy
  )
  last_error <- NULL
  for (attempt in seq_len(max(1L, DOWNLOAD_RETRIES))) {
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
      return(readr::read_csv(I(httr2::resp_body_string(resp)), show_col_types = FALSE))
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
  for (attempt in seq_len(max(1L, DOWNLOAD_RETRIES))) {
    resp <- tryCatch(
      httr2::request(url) |>
        httr2::req_headers(Authorization = paste("Bearer", bearer)) |>
        httr2::req_timeout(120) |>
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
    stop("Variable ", variable, " not found in ", basename(h5_file), ". Available: ", paste(names(h5_data), collapse = ", "))
  }

  tile_i <- stringr::str_extract(basename(h5_file), "h\\d{2}v\\d{2}")
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

download_vj146a2_variable <- function(variable, target_date, tile_ids, bearer, h5_cache, tiles_sf, roi_sf, manifest = NULL) {
  product_id <- "VJ146A2"
  if (is.null(manifest)) manifest <- download_manifest(product_id, target_date, bearer)
  manifest$tile_id <- stringr::str_extract(manifest$name, "h\\d{2}v\\d{2}")
  wanted <- manifest[manifest$tile_id %in% tile_ids & grepl("\\.h5$", manifest$name), , drop = FALSE]
  if (nrow(wanted) == 0L) stop("No VJ146A2 H5 files found for target tiles on ", format(target_date))

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

qf_bits_fun <- function(x, shift, mask) {
  x <- as.integer(round(x))
  bitwAnd(bitwShiftR(x, shift), mask)
}

extract_cloud_bits <- function(cloud) {
  list(
    cloud_conf = terra::app(cloud, function(x) qf_bits_fun(x, 6L, 3L)),
    day_night = terra::app(cloud, function(x) qf_bits_fun(x, 0L, 1L)),
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

build_vj_candidate <- function(rad, qf, cloud, snow) {
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
  lit_ge1 <- terra::ifel(is.na(rad_masked), NA, terra::ifel(rad_masked >= LIT_THRESHOLD, 1, 0))
  names(lit_ge1) <- "lit_ge1"
  list(rad = rad_masked, lit_ge1 = lit_ge1, valid = valid)
}

count_condition <- function(condition_raster) {
  x <- terra::ifel(condition_raster, 1, 0)
  x <- terra::ifel(is.na(condition_raster), 0, x)
  as.numeric(terra::global(x, "sum", na.rm = TRUE)[1, 1])
}

summarize_scene <- function(date_str, rasters) {
  n_total <- terra::ncell(rasters$valid)
  n_valid <- count_condition(rasters$valid == 1)
  n_lit <- count_condition(rasters$lit_ge1 == 1)
  data.frame(
    date = date_str,
    n_total_pixels = n_total,
    n_valid_pixels = n_valid,
    n_lit_pixels_ge1 = n_lit,
    valid_share = ifelse(n_total > 0, n_valid / n_total, NA_real_),
    p_lit_ge1 = ifelse(n_valid > 0, n_lit / n_valid, NA_real_),
    lit_share_all_ge1 = ifelse(n_total > 0, n_lit / n_total, NA_real_),
    mean_rad_valid = as.numeric(terra::global(rasters$rad, "mean", na.rm = TRUE)[1, 1]),
    status = "ok",
    stringsAsFactors = FALSE
  )
}

missing_summary_row <- function(date_str, reason) {
  data.frame(
    date = date_str,
    n_total_pixels = NA_real_,
    n_valid_pixels = NA_real_,
    n_lit_pixels_ge1 = NA_real_,
    valid_share = NA_real_,
    p_lit_ge1 = NA_real_,
    lit_share_all_ge1 = NA_real_,
    mean_rad_valid = NA_real_,
    status = reason,
    stringsAsFactors = FALSE
  )
}

write_daily_tif <- function(date_str, rasters) {
  out_file <- file.path(RASTER_DIR, sprintf("vj146a2_sa_500m_daily_%s.tif", date_str))
  terra::writeRaster(
    c(rasters$rad, rasters$lit_ge1, rasters$valid),
    out_file,
    overwrite = TRUE,
    wopt = list(gdal = c("COMPRESS=LZW"))
  )
  out_file
}

plot_discrete_legend <- function() {
  plot(NA, xlim = c(0, 1), ylim = c(0, 1), xaxs = "i", yaxs = "i", axes = FALSE, xlab = "", ylab = "")
  mtext("threshold class", side = 3, line = 0.5, cex = 1.0, font = 2)
  rect(0.14, 0.58, 0.34, 0.78, col = CLASS_COLS[1], border = "black")
  text(0.42, 0.68, "0: rad < 1\nunlit", adj = 0, cex = 0.82)
  rect(0.14, 0.31, 0.34, 0.51, col = CLASS_COLS[2], border = "black")
  text(0.42, 0.41, "1: rad >= 1\nlit", adj = 0, cex = 0.82)
  rect(0.14, 0.10, 0.34, 0.22, col = NA_COL, border = "black")
  text(0.42, 0.16, "invalid\nmissing", adj = 0, cex = 0.82)
  box()
}

plot_lit_map <- function(lit_ge1, main) {
  e <- ext(lit_ge1)
  mat <- as.matrix(lit_ge1, wide = TRUE)
  xs <- seq(e$xmin, e$xmax, length.out = ncol(mat))
  ys <- seq(e$ymin, e$ymax, length.out = nrow(mat))
  z <- t(mat[nrow(mat):1, , drop = FALSE])

  plot(
    NA,
    xlim = c(e$xmin, e$xmax),
    ylim = c(e$ymin, e$ymax),
    xaxs = "i",
    yaxs = "i",
    asp = 1,
    xlab = "",
    ylab = "",
    main = main,
    cex.main = 1.15,
    axes = TRUE
  )
  rect(e$xmin, e$ymin, e$xmax, e$ymax, col = NA_COL, border = NA)
  image(xs, ys, z, col = CLASS_COLS, breaks = c(-0.5, 0.5, 1.5), add = TRUE, useRaster = TRUE)
  box()
}

write_frame <- function(date_str, rasters, summary_row) {
  frame_file <- file.path(FRAME_DIR, sprintf("vj146a2_lit_ge1_%s.png", date_str))
  png(frame_file, width = 1400, height = 1000, res = 150)
  layout(matrix(c(1, 2), nrow = 1), widths = c(5.5, 1.15))
  par(mar = c(3.5, 3.5, 3.2, 0.8))
  plot_lit_map(
    rasters$lit_ge1,
    sprintf("VJ146A2 500m lit threshold - %s", date_str)
  )
  mtext(
    sprintf("valid share %.3f | p_lit_ge1 %.3f", summary_row$valid_share, summary_row$p_lit_ge1),
    side = 1,
    line = 2.2,
    cex = 0.85
  )
  par(mar = c(4.0, 0.4, 3.0, 0.4))
  plot_discrete_legend()
  dev.off()
  frame_file
}

write_missing_frame <- function(date_str, roi_sf, reason) {
  frame_file <- file.path(FRAME_DIR, sprintf("vj146a2_lit_ge1_%s.png", date_str))
  png(frame_file, width = 1400, height = 1000, res = 150)
  layout(matrix(c(1, 2), nrow = 1), widths = c(5.5, 1.15))
  par(mar = c(3.5, 3.5, 3.2, 0.8))
  plot(
    terra::vect(roi_sf),
    col = NA_COL,
    border = "#777777",
    main = sprintf("VJ146A2 500m lit threshold - %s", date_str),
    axes = TRUE
  )
  text(
    x = mean(sf::st_bbox(roi_sf)[c("xmin", "xmax")]),
    y = mean(sf::st_bbox(roi_sf)[c("ymin", "ymax")]),
    labels = reason,
    cex = 1.2,
    font = 2
  )
  par(mar = c(4.0, 0.4, 3.0, 0.4))
  plot_discrete_legend()
  dev.off()
  frame_file
}

# ------------------------------------------------------------
# Run
# ------------------------------------------------------------
log_step("Repository root:", BASE_PATH)
log_step("Month:", MONTH_STR, sprintf("(%s to %s)", format(MONTH_START), format(MONTH_END)))
log_step("Output:", OUT_DIR)

bearer <- get_nasa_bearer()
roi_sf <- build_sa_roi(CURRENT_TIF_DIR)
tiles_sf <- sf::st_read(TILES_PATH, quiet = TRUE)
tile_ids <- tile_ids_for_roi(roi_sf, TILES_PATH)
log_step("Target tiles:", paste(tile_ids, collapse = ", "))

summary_rows <- list()
frame_files <- character(0)

for (target_date in TARGET_DATES) {
  target_date <- as.Date(target_date, origin = "1970-01-01")
  date_str <- format(target_date, "%Y-%m-%d")
  log_step("Processing VJ146A2", date_str)

  manifest <- download_manifest("VJ146A2", target_date, bearer)
  manifest$tile_id <- stringr::str_extract(manifest$name, "h\\d{2}v\\d{2}")
  available_tiles <- intersect(sort(unique(stats::na.omit(manifest$tile_id))), tile_ids)
  if (length(available_tiles) == 0L) {
    reason <- "no South Africa VJ146A2 tiles in LAADS manifest"
    log_step("Skipping", date_str, "-", reason)
    summary_rows[[date_str]] <- missing_summary_row(date_str, reason)
    frame_files <- c(frame_files, write_missing_frame(date_str, roi_sf, "No VJ146A2 SA tile available"))
    next
  }

  rad <- download_vj146a2_variable("DNB_BRDF-Corrected_NTL", target_date, tile_ids, bearer, H5_CACHE, tiles_sf, roi_sf, manifest)
  qf <- download_vj146a2_variable("Mandatory_Quality_Flag", target_date, tile_ids, bearer, H5_CACHE, tiles_sf, roi_sf, manifest)
  cloud <- download_vj146a2_variable("QF_Cloud_Mask", target_date, tile_ids, bearer, H5_CACHE, tiles_sf, roi_sf, manifest)
  snow <- download_vj146a2_variable("Snow_Flag", target_date, tile_ids, bearer, H5_CACHE, tiles_sf, roi_sf, manifest)
  names(rad) <- "rad"
  names(qf) <- "mandatory_qf"
  names(cloud) <- "qf_cloud_mask"
  names(snow) <- "snow_flag"

  rasters <- build_vj_candidate(rad, qf, cloud, snow)
  out_tif <- write_daily_tif(date_str, rasters)
  summary_row <- summarize_scene(date_str, rasters)
  frame_file <- write_frame(date_str, rasters, summary_row)

  summary_rows[[date_str]] <- summary_row
  frame_files <- c(frame_files, frame_file)
  log_step("Wrote:", out_tif)
}

summary_tbl <- do.call(rbind, summary_rows)
summary_csv <- file.path(OUT_DIR, sprintf("vj146a2_month_%s_summary.csv", MONTH_STR))
utils::write.csv(summary_tbl, summary_csv, row.names = FALSE)

gif_file <- file.path(OUT_DIR, sprintf("vj146a2_lit_ge1_%s.gif", MONTH_STR))
gifski::gifski(
  png_files = frame_files,
  gif_file = gif_file,
  width = 1400,
  height = 1000,
  delay = 1 / GIF_FPS,
  progress = TRUE
)

log_step("Wrote summary:", summary_csv)
log_step("Wrote GIF:", gif_file)
log_step("Done.")
