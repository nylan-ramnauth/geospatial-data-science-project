# ============================================================
# VNP46A2 Stray-Light / Residual Artifact Redownload Diagnostic
# Stage 1b - Diagnostic only
# ============================================================
#
# Purpose:  Redownload a small set of known contaminated/control VNP46A2
#           days through blackmarbler into an isolated cache, compare the
#           current production TIFFs with fresh Mandatory-QF-only output
#           and a candidate Collection 2 QA-bit mask, and write notebook-
#           ready rasters, PNG panels, and CSV summaries.
# Inputs:   - NASA Earthdata credentials in EARTHDATA_USER / EARTHDATA_PASS
#           - blackmarbler/blackmarbletiles.geojson
#           - blackmarbler/out_vnp46a2_sa_daily/sa_viirs_500m_daily_*.tif
# Outputs:  - blackmarbler/out_vnp46a2_sa_daily/qa_straylight_validation/
# Run:      Rscript nightlight_downloader/Others/stray_light_blackmarbler_redownload_diagnostic.R
#
# IMPORTANT: This script is diagnostic-only. It must not overwrite the
# production daily TIFFs or modify the full-year downloader/panel pipeline.
# ============================================================

rm(list = ls())

suppressPackageStartupMessages({
  library(sf)
  library(terra)
  library(blackmarbler)
  library(geodata)
})

sf::sf_use_s2(FALSE)

# ------------------------------------------------------------
# Paths and configuration
# ------------------------------------------------------------
script_path <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
if (is.na(script_path) || !nzchar(script_path)) {
  script_dir <- normalizePath(getwd(), winslash = "/", mustWork = TRUE)
} else {
  script_dir <- dirname(normalizePath(script_path, winslash = "/", mustWork = TRUE))
}

BASE_PATH <- normalizePath(file.path(script_dir, "..", ".."), winslash = "/", mustWork = TRUE)
if (!file.exists(file.path(BASE_PATH, "STRAY_LIGHT_FIX_PLAN.md"))) {
  # Fallback for interactive execution from the repository root.
  cwd <- normalizePath(getwd(), winslash = "/", mustWork = TRUE)
  if (file.exists(file.path(cwd, "STRAY_LIGHT_FIX_PLAN.md"))) BASE_PATH <- cwd
}

CURRENT_TIF_DIR <- file.path(BASE_PATH, "blackmarbler", "out_vnp46a2_sa_daily")
OUT_DIR <- file.path(CURRENT_TIF_DIR, "qa_straylight_validation")
H5_CACHE <- file.path(OUT_DIR, "h5_cache_redownload")
RASTER_DIR <- file.path(OUT_DIR, "rasters")
PNG_DIR <- file.path(OUT_DIR, "png")

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(H5_CACHE, recursive = TRUE, showWarnings = FALSE)
dir.create(RASTER_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(PNG_DIR, recursive = TRUE, showWarnings = FALSE)

if (!dir.exists(CURRENT_TIF_DIR)) {
  stop("Production TIFF directory not found: ", CURRENT_TIF_DIR)
}

TILES_URL <- "https://raw.githubusercontent.com/worldbank/blackmarbler/main/data/blackmarbletiles.geojson"
TILES_PATH <- file.path(BASE_PATH, "blackmarbler", "blackmarbletiles.geojson")

LIT_THRESHOLD <- as.numeric(Sys.getenv("BM_DIAG_LIT_THRESHOLD", unset = "1.0"))
ALLOW_CLOUD_CONF_MAX <- as.integer(Sys.getenv("BM_DIAG_ALLOW_CLOUD_CONF_MAX", unset = "1"))
MANDATORY_QF_MAX <- as.integer(Sys.getenv("BM_DIAG_MANDATORY_QF_MAX", unset = "0"))
FORCE_REDOWNLOAD <- tolower(Sys.getenv("BM_DIAG_FORCE_REDOWNLOAD", unset = "true")) %in%
  c("1", "true", "yes", "y")
PLOT_MAXCELL <- as.integer(Sys.getenv("BM_DIAG_PLOT_MAXCELL", unset = "650000"))
DOWNLOAD_RETRIES <- as.integer(Sys.getenv("BM_DIAG_DOWNLOAD_RETRIES", unset = "3"))

DEFAULT_DATES <- data.frame(
  date = as.Date(c(
    "2023-10-20",
    "2023-02-28",
    "2023-04-28",
    "2023-11-06",
    "2023-01-27",
    "2023-01-29",
    "2023-10-22"
  )),
  role = c(
    "worst_single_day",
    "visually_obvious_primary",
    "visually_obvious_primary",
    "visually_obvious_late_season",
    "maybe_contaminated_user_example",
    "nearby_clean_control",
    "nearby_clean_control"
  ),
  stringsAsFactors = FALSE
)

dates_override <- Sys.getenv("BM_DIAG_DATES", unset = "")
if (nzchar(dates_override)) {
  date_values <- trimws(strsplit(dates_override, ",", fixed = TRUE)[[1]])
  date_values <- date_values[nzchar(date_values)]
  TARGET_DATES <- data.frame(
    date = as.Date(date_values),
    role = "manual_override",
    stringsAsFactors = FALSE
  )
  if (any(is.na(TARGET_DATES$date))) stop("Invalid BM_DIAG_DATES value: ", dates_override)
} else {
  TARGET_DATES <- DEFAULT_DATES
}

SENTINEL_BBOX <- c(
  xmin = 19.0,
  xmax = 22.5,
  ymin = -31.5,
  ymax = -28.0
)
SENTINEL_LABEL <- "rural_northern_cape_bbox"

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
  if (!nzchar(token)) {
    stop("Could not retrieve NASA bearer token from EARTHDATA_USER/EARTHDATA_PASS.")
  }
  token
}

patch_blackmarbler_tiles <- function(tiles_url, tiles_path) {
  if (!file.exists(tiles_path)) {
    log_step("Local blackmarbler tile file not found; package patch skipped:", tiles_path)
    return(invisible(FALSE))
  }

  ns <- asNamespace("blackmarbler")
  objs <- ls(envir = ns, all.names = TRUE)

  hit_fns <- Filter(function(nm) {
    obj <- tryCatch(get(nm, envir = ns), error = function(e) NULL)
    if (!is.function(obj)) return(FALSE)
    txt <- paste(deparse(body(obj)), collapse = "\n")
    grepl(tiles_url, txt, fixed = TRUE)
  }, objs)

  if (length(hit_fns) == 0L) {
    log_step("No blackmarbler function referenced the remote tile URL; patch skipped.")
    return(invisible(FALSE))
  }

  for (nm in hit_fns) {
    f <- get(nm, envir = ns)
    f_txt <- paste(deparse(body(f)), collapse = "\n")
    f_txt2 <- gsub(tiles_url, tiles_path, f_txt, fixed = TRUE)
    f2 <- f
    body(f2) <- parse(text = f_txt2)
    unlockBinding(nm, ns)
    assign(nm, f2, envir = ns)
    lockBinding(nm, ns)
  }

  log_step("Patched blackmarbler tile URL in", length(hit_fns), "function(s).")
  invisible(TRUE)
}

build_sa_roi <- function(base_path, current_tif_dir) {
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
  sa <- sf::st_make_valid(sa)
  sf::st_cast(sa, "MULTIPOLYGON")
}

align_to_template <- function(r, template, method = "near") {
  if (isTRUE(all.equal(terra::res(r), terra::res(template))) &&
      isTRUE(all.equal(terra::ext(r), terra::ext(template))) &&
      isTRUE(all.equal(terra::crs(r), terra::crs(template)))) {
    return(r)
  }
  terra::resample(r, template, method = method)
}

qf_bits_fun <- function(x, shift, mask) {
  x <- as.integer(round(x))
  bitwAnd(bitwShiftR(x, shift), mask)
}

make_valid_01 <- function(valid_logical) {
  valid <- terra::ifel(valid_logical, 1, 0)
  terra::ifel(is.na(valid_logical), 0, valid)
}

derive_lit_valid_from_rad <- function(rad, lit_threshold) {
  valid <- terra::ifel(is.na(rad), 0, 1)
  names(valid) <- "valid"
  lit <- terra::ifel(is.na(rad), NA, terra::ifel(rad > lit_threshold, 1, 0))
  names(lit) <- "lit"
  list(lit = lit, valid = valid)
}

mask_rad_to_valid <- function(rad, valid, lit_threshold) {
  rad_masked <- terra::mask(rad, valid, maskvalues = 0, updatevalue = NA)
  names(rad_masked) <- "rad"
  lit <- terra::ifel(is.na(rad_masked), NA, terra::ifel(rad_masked > lit_threshold, 1, 0))
  names(lit) <- "lit"
  names(valid) <- "valid"
  list(rad = rad_masked, lit = lit, valid = valid)
}

current_tif_path <- function(date_str) {
  file.path(CURRENT_TIF_DIR, sprintf("sa_viirs_500m_daily_%s.tif", date_str))
}

delete_diagnostic_h5_for_date <- function(h5_cache, date_str) {
  token <- paste0("A", format(as.Date(date_str), "%Y%j"))
  files <- list.files(
    h5_cache,
    pattern = paste0("^VNP46A2\\.", token, "\\..*\\.h5$"),
    full.names = TRUE
  )
  if (length(files) == 0L) return(invisible(0L))
  unlink(files)
  length(files)
}

get_bm <- function(var, date_str, roi_sf, bearer, h5_cache, quality_flag_rm = NULL) {
  args <- list(
    roi_sf = roi_sf,
    product_id = "VNP46A2",
    date = date_str,
    bearer = bearer,
    variable = var,
    output_location_type = "memory",
    h5_dir = h5_cache,
    quiet = TRUE
  )
  if (!is.null(quality_flag_rm)) args$quality_flag_rm <- quality_flag_rm

  last_error <- NULL
  for (attempt in seq_len(max(1L, DOWNLOAD_RETRIES))) {
    args$bearer <- bearer
    r <- tryCatch(
      do.call(blackmarbler::bm_raster, args),
      error = function(e) {
        last_error <<- conditionMessage(e)
        NULL
      }
    )
    if (inherits(r, "SpatRaster")) return(r)

    if (attempt < max(1L, DOWNLOAD_RETRIES)) {
      log_step(
        "Retrying", var, "for", date_str,
        sprintf("(attempt %d/%d failed)", attempt, DOWNLOAD_RETRIES)
      )
      Sys.sleep(min(60, 8 * attempt))
      bearer <- get_nasa_bearer()
    }
  }

  detail <- if (is.null(last_error)) "" else paste0(" Last error: ", last_error)
  stop("blackmarbler download failed for ", var, " on ", date_str, detail)
}

count_condition <- function(condition_raster) {
  x <- terra::ifel(condition_raster, 1, 0)
  x <- terra::ifel(is.na(condition_raster), 0, x)
  as.numeric(terra::global(x, "sum", na.rm = TRUE)[1, 1])
}

count_non_na <- function(r) {
  x <- terra::ifel(is.na(r), 0, 1)
  as.numeric(terra::global(x, "sum", na.rm = TRUE)[1, 1])
}

summarize_scene <- function(date_str, role, scenario, scope, rad, lit, valid, source_path) {
  n_total <- terra::ncell(valid)
  n_valid <- count_condition(valid == 1)
  n_lit <- count_condition(lit == 1)
  mean_rad_valid <- as.numeric(terra::global(rad, "mean", na.rm = TRUE)[1, 1])

  data.frame(
    date = date_str,
    role = role,
    scenario = scenario,
    scope = scope,
    n_total_pixels = n_total,
    n_valid_pixels = n_valid,
    n_lit_pixels = n_lit,
    valid_share = ifelse(n_total > 0, n_valid / n_total, NA_real_),
    p_lit = ifelse(n_valid > 0, n_lit / n_valid, NA_real_),
    lit_share_all = ifelse(n_total > 0, n_lit / n_total, NA_real_),
    mean_rad_valid = mean_rad_valid,
    source_path = source_path,
    stringsAsFactors = FALSE
  )
}

crop_to_sentinel <- function(r) {
  terra::crop(
    r,
    terra::ext(
      SENTINEL_BBOX[["xmin"]],
      SENTINEL_BBOX[["xmax"]],
      SENTINEL_BBOX[["ymin"]],
      SENTINEL_BBOX[["ymax"]]
    )
  )
}

append_scene_summaries <- function(rows, date_str, role, scenario, rasters, source_path) {
  whole <- summarize_scene(
    date_str, role, scenario, "whole_scene",
    rasters$rad, rasters$lit, rasters$valid, source_path
  )
  sentinel <- summarize_scene(
    date_str, role, scenario, SENTINEL_LABEL,
    crop_to_sentinel(rasters$rad),
    crop_to_sentinel(rasters$lit),
    crop_to_sentinel(rasters$valid),
    source_path
  )
  c(rows, list(whole, sentinel))
}

make_metric_row <- function(date_str, metric, value, label, n_pixels, denom, bit_position, keep_criterion) {
  data.frame(
    date = date_str,
    metric = metric,
    value = value,
    label = label,
    n_pixels = n_pixels,
    denominator_pixels = denom,
    share_pixels = ifelse(denom > 0, n_pixels / denom, NA_real_),
    bit_position = bit_position,
    keep_criterion = keep_criterion,
    stringsAsFactors = FALSE
  )
}

summarize_bits <- function(date_str, qf, cloud, snow, bits) {
  rows <- list()

  qf_denom <- count_non_na(qf)
  for (v in c(0:5, 255)) {
    rows[[length(rows) + 1L]] <- make_metric_row(
      date_str, "mandatory_qf", v, paste0("Mandatory_Quality_Flag == ", v),
      count_condition(qf == v), qf_denom, NA_integer_, "keep <= 0"
    )
  }

  snow_denom <- count_non_na(snow)
  for (v in c(0, 1, 255)) {
    rows[[length(rows) + 1L]] <- make_metric_row(
      date_str, "snow_flag", v, paste0("Snow_Flag == ", v),
      count_condition(snow == v), snow_denom, NA_integer_, "keep == 0"
    )
  }

  cloud_denom <- count_non_na(cloud)
  for (v in 0:1) {
    rows[[length(rows) + 1L]] <- make_metric_row(
      date_str, "day_night", v, paste0("QF_Cloud_Mask bit 0 == ", v),
      count_condition(bits$day_night == v), cloud_denom, 0L, "keep 0 night"
    )
  }

  for (v in 0:3) {
    rows[[length(rows) + 1L]] <- make_metric_row(
      date_str, "cloud_confidence", v, paste0("QF_Cloud_Mask bits 6-7 == ", v),
      count_condition(bits$cloud_conf == v), cloud_denom, 6L, "keep <= 1"
    )
  }

  bit_specs <- data.frame(
    metric = c("shadow", "cirrus", "snow_ice_cloud", "aurora", "lunar_eclipse"),
    bit_position = c(8L, 9L, 10L, 12L, 13L),
    keep_criterion = c("keep 0", "keep 0", "keep 0", "keep 0", "keep 0"),
    stringsAsFactors = FALSE
  )

  for (i in seq_len(nrow(bit_specs))) {
    nm <- bit_specs$metric[i]
    rows[[length(rows) + 1L]] <- make_metric_row(
      date_str, nm, 1L,
      paste0("QF_Cloud_Mask bit ", bit_specs$bit_position[i], " flagged"),
      count_condition(bits[[nm]] == 1), cloud_denom,
      bit_specs$bit_position[i], bit_specs$keep_criterion[i]
    )
  }

  do.call(rbind, rows)
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

sample_values <- function(r, n = 200000L) {
  vals <- tryCatch(
    terra::spatSample(r, size = n, method = "regular", na.rm = TRUE, as.df = TRUE)[[1]],
    error = function(e) numeric(0)
  )
  vals <- as.numeric(vals)
  vals[is.finite(vals)]
}

plot_breaks <- function(values, lower = 0, probs = 0.99, fallback_upper = 5, n_breaks = 16L) {
  values <- values[is.finite(values)]
  if (length(values) == 0L) return(seq(lower, fallback_upper, length.out = n_breaks + 1L))
  upper <- as.numeric(stats::quantile(values, probs = probs, na.rm = TRUE))
  if (!is.finite(upper) || upper <= lower) upper <- fallback_upper
  seq(lower, upper, length.out = n_breaks + 1L)
}

plot_comparison_png <- function(date_str, role, current, qf0, candidate, out_file) {
  rad_vals <- c(
    sample_values(current$rad),
    sample_values(qf0$rad),
    sample_values(candidate$rad)
  )
  rad_breaks <- plot_breaks(rad_vals, lower = 0, probs = 0.99, fallback_upper = 5)
  rad_max <- max(rad_breaks)
  rad_cols <- hcl.colors(length(rad_breaks) - 1L, "Inferno", rev = FALSE)

  diff <- current$rad - candidate$rad
  names(diff) <- "rad_diff_current_minus_candidate"
  diff_vals <- abs(sample_values(diff))
  diff_upper <- as.numeric(stats::quantile(diff_vals[is.finite(diff_vals)], probs = 0.99, na.rm = TRUE))
  if (!is.finite(diff_upper) || diff_upper <= 0) diff_upper <- rad_max
  diff_breaks <- seq(-diff_upper, diff_upper, length.out = 17L)
  diff_cols <- hcl.colors(length(diff_breaks) - 1L, "Blue-Red 3", rev = TRUE)

  png(out_file, width = 2600, height = 1800, res = 220)
  op <- par(mfrow = c(2, 2), mar = c(2.2, 2.2, 3.4, 5.2), oma = c(0, 0, 3.0, 0))
  tryCatch({
    plot(
      terra::clamp(current$rad, lower = 0, upper = rad_max, values = TRUE),
      col = rad_cols, breaks = rad_breaks, maxcell = PLOT_MAXCELL,
      main = "Current production radiance"
    )
    plot(
      terra::clamp(qf0$rad, lower = 0, upper = rad_max, values = TRUE),
      col = rad_cols, breaks = rad_breaks, maxcell = PLOT_MAXCELL,
      main = "Fresh blackmarbler QF0-only"
    )
    plot(
      terra::clamp(candidate$rad, lower = 0, upper = rad_max, values = TRUE),
      col = rad_cols, breaks = rad_breaks, maxcell = PLOT_MAXCELL,
      main = "Fresh candidate C2 QA mask"
    )
    plot(
      terra::clamp(diff, lower = -diff_upper, upper = diff_upper, values = TRUE),
      col = diff_cols, breaks = diff_breaks, maxcell = PLOT_MAXCELL,
      main = "Radiance diff: current - candidate"
    )
    mtext(sprintf("%s (%s)", date_str, role), outer = TRUE, font = 2, cex = 1.1)
  }, finally = {
    par(op)
    dev.off()
  })

  diff
}

write_scenario_tif <- function(rasters, out_file) {
  terra::writeRaster(
    c(rasters$rad, rasters$lit, rasters$valid),
    out_file,
    overwrite = TRUE,
    wopt = list(gdal = c("COMPRESS=LZW"))
  )
}

write_progress_csvs <- function(summary_rows, bit_rows, summary_csv, bit_csv) {
  if (length(summary_rows) > 0L) {
    utils::write.csv(do.call(rbind, summary_rows), summary_csv, row.names = FALSE)
  }
  if (length(bit_rows) > 0L) {
    utils::write.csv(do.call(rbind, bit_rows), bit_csv, row.names = FALSE)
  }
}

# ------------------------------------------------------------
# Run
# ------------------------------------------------------------
log_step("Repository root:", BASE_PATH)
log_step("Diagnostic output:", OUT_DIR)
log_step("Diagnostic H5 cache:", H5_CACHE)
log_step("Force redownload from diagnostic cache:", FORCE_REDOWNLOAD)

patch_blackmarbler_tiles(TILES_URL, TILES_PATH)

bearer <- get_nasa_bearer()

roi_sf <- build_sa_roi(BASE_PATH, CURRENT_TIF_DIR)

summary_rows <- list()
bit_rows <- list()
summary_csv <- file.path(OUT_DIR, "diagnostic_summary.csv")
bit_csv <- file.path(OUT_DIR, "diagnostic_bit_shares.csv")

for (i in seq_len(nrow(TARGET_DATES))) {
  date_str <- format(TARGET_DATES$date[i], "%Y-%m-%d")
  role <- TARGET_DATES$role[i]
  log_step("Starting", date_str, "(", role, ")")

  current_path <- current_tif_path(date_str)
  if (!file.exists(current_path)) stop("Current production TIFF not found for ", date_str, ": ", current_path)

  if (FORCE_REDOWNLOAD) {
    n_deleted <- delete_diagnostic_h5_for_date(H5_CACHE, date_str)
    log_step("Deleted", n_deleted, "existing diagnostic H5 file(s) for", date_str)
  }

  current_r <- terra::rast(current_path)
  if (!all(c("rad", "lit", "valid") %in% names(current_r))) {
    stop("Current TIFF must have bands named rad, lit, valid: ", current_path)
  }
  template <- current_r[["rad"]]
  current <- list(
    rad = current_r[["rad"]],
    lit = current_r[["lit"]],
    valid = current_r[["valid"]]
  )

  rad_raw <- get_bm("DNB_BRDF-Corrected_NTL", date_str, roi_sf, bearer, H5_CACHE)
  rad_raw <- align_to_template(rad_raw, template, method = "near")
  names(rad_raw) <- "rad"

  rad_qf0 <- get_bm(
    "DNB_BRDF-Corrected_NTL", date_str, roi_sf, bearer, H5_CACHE,
    quality_flag_rm = c(1L, 2L, 3L, 4L, 5L)
  )
  rad_qf0 <- align_to_template(rad_qf0, template, method = "near")
  names(rad_qf0) <- "rad"
  qf0_dv <- derive_lit_valid_from_rad(rad_qf0, LIT_THRESHOLD)
  qf0 <- list(rad = rad_qf0, lit = qf0_dv$lit, valid = qf0_dv$valid)

  qf <- get_bm("Mandatory_Quality_Flag", date_str, roi_sf, bearer, H5_CACHE)
  cloud <- get_bm("QF_Cloud_Mask", date_str, roi_sf, bearer, H5_CACHE)
  snow <- get_bm("Snow_Flag", date_str, roi_sf, bearer, H5_CACHE)

  qf <- align_to_template(qf, template, method = "near")
  cloud <- align_to_template(cloud, template, method = "near")
  snow <- align_to_template(snow, template, method = "near")
  names(qf) <- "mandatory_qf"
  names(cloud) <- "qf_cloud_mask"
  names(snow) <- "snow_flag"

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
    !is.na(rad_raw) &
    !is.na(qf) &
    !is.na(cloud) &
    !is.na(snow)

  valid_candidate <- make_valid_01(valid_logical)
  names(valid_candidate) <- "valid"
  candidate <- mask_rad_to_valid(rad_raw, valid_candidate, LIT_THRESHOLD)

  qf0_tif <- file.path(RASTER_DIR, sprintf("diagnostic_qf0_only_%s.tif", date_str))
  candidate_tif <- file.path(RASTER_DIR, sprintf("diagnostic_candidate_c2_mask_%s.tif", date_str))
  diff_tif <- file.path(RASTER_DIR, sprintf("diagnostic_rad_diff_current_minus_candidate_%s.tif", date_str))
  png_file <- file.path(PNG_DIR, sprintf("diagnostic_comparison_%s.png", date_str))

  write_scenario_tif(qf0, qf0_tif)
  write_scenario_tif(candidate, candidate_tif)
  diff <- plot_comparison_png(date_str, role, current, qf0, candidate, png_file)
  terra::writeRaster(diff, diff_tif, overwrite = TRUE, wopt = list(gdal = c("COMPRESS=LZW")))

  summary_rows <- append_scene_summaries(summary_rows, date_str, role, "current_production", current, current_path)
  summary_rows <- append_scene_summaries(summary_rows, date_str, role, "blackmarbler_qf0_only", qf0, qf0_tif)
  summary_rows <- append_scene_summaries(summary_rows, date_str, role, "blackmarbler_candidate_c2_mask", candidate, candidate_tif)
  bit_rows[[length(bit_rows) + 1L]] <- summarize_bits(date_str, qf, cloud, snow, bits)
  write_progress_csvs(summary_rows, bit_rows, summary_csv, bit_csv)

  log_step("Wrote diagnostic outputs for", date_str)
}

summary_tbl <- do.call(rbind, summary_rows)
bit_tbl <- do.call(rbind, bit_rows)

utils::write.csv(summary_tbl, summary_csv, row.names = FALSE)
utils::write.csv(bit_tbl, bit_csv, row.names = FALSE)

log_step("Wrote summary CSV:", summary_csv)
log_step("Wrote bit-share CSV:", bit_csv)
log_step("Done.")
