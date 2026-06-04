# ============================================================
# One-Day VNP46A1 QF_DNB + VJ146A2 Fallback Diagnostic
# ============================================================
#
# Purpose:  Test same-day pixel salvage for one contaminated VNP46A2 day:
#           (1) use VNP46A1 QF_DNB stray-light/bad-DNB bits as companion masks;
#           (2) download NOAA-20/JPSS1 VJ146A2 directly from LAADS;
#           (3) blend VNP46A2 with VJ146A2 where VNP is rejected.
#
# Outputs:  blackmarbler/out_vnp46a2_sa_daily/qa_straylight_validation/one_day_a1_vj/
# Run:      Rscript nightlight_downloader/Others/stray_light_one_day_a1_vj_diagnostic.R
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

DATE_STR <- Sys.getenv("BM_ONE_DAY_DATE", unset = "2023-10-20")
TARGET_DATE <- as.Date(DATE_STR)
if (is.na(TARGET_DATE)) stop("Invalid BM_ONE_DAY_DATE: ", DATE_STR)
YEAR_STR <- format(TARGET_DATE, "%Y")
DOY_STR <- format(TARGET_DATE, "%j")

CURRENT_TIF_DIR <- file.path(BASE_PATH, "blackmarbler", "out_vnp46a2_sa_daily")
CURRENT_TIF <- file.path(CURRENT_TIF_DIR, sprintf("sa_viirs_500m_daily_%s.tif", DATE_STR))
if (!file.exists(CURRENT_TIF)) stop("Current production TIFF not found: ", CURRENT_TIF)

OUT_DIR <- file.path(CURRENT_TIF_DIR, "qa_straylight_validation", "one_day_a1_vj")
H5_CACHE <- file.path(OUT_DIR, "h5_cache")
RASTER_DIR <- file.path(OUT_DIR, "rasters")
PNG_DIR <- file.path(OUT_DIR, "png")
dir.create(H5_CACHE, recursive = TRUE, showWarnings = FALSE)
dir.create(RASTER_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(PNG_DIR, recursive = TRUE, showWarnings = FALSE)

TILES_URL <- "https://raw.githubusercontent.com/worldbank/blackmarbler/main/data/blackmarbletiles.geojson"
TILES_PATH <- file.path(BASE_PATH, "blackmarbler", "blackmarbletiles.geojson")

LIT_THRESHOLD <- as.numeric(Sys.getenv("BM_ONE_DAY_LIT_THRESHOLD", unset = "1.0"))
ALLOW_CLOUD_CONF_MAX <- as.integer(Sys.getenv("BM_ONE_DAY_ALLOW_CLOUD_CONF_MAX", unset = "1"))
MANDATORY_QF_MAX <- as.integer(Sys.getenv("BM_ONE_DAY_MANDATORY_QF_MAX", unset = "0"))
DOWNLOAD_RETRIES <- as.integer(Sys.getenv("BM_ONE_DAY_DOWNLOAD_RETRIES", unset = "3"))
PLOT_MAXCELL <- as.integer(Sys.getenv("BM_ONE_DAY_PLOT_MAXCELL", unset = "650000"))

# VNP46A1 QF_DNB masks. The narrow mask tests only the documented stray-light
# value 16. The strict mask removes the other high-risk DNB QA bits too.
A1_STRAY_BIT_VALUE <- 16L
A1_STRICT_BAD_VALUES <- c(2L, 4L, 8L, 16L, 256L, 512L, 1024L, 2048L)

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

patch_blackmarbler_tiles <- function(tiles_url, tiles_path) {
  if (!file.exists(tiles_path)) {
    log_step("Local tiles file missing; blackmarbler tile patch skipped:", tiles_path)
    return(invisible(FALSE))
  }

  ns <- asNamespace("blackmarbler")
  objs <- ls(envir = ns, all.names = TRUE)
  hit_fns <- Filter(function(nm) {
    obj <- tryCatch(get(nm, envir = ns), error = function(e) NULL)
    if (!is.function(obj)) return(FALSE)
    grepl(tiles_url, paste(deparse(body(obj)), collapse = "\n"), fixed = TRUE)
  }, objs)

  for (nm in hit_fns) {
    f <- get(nm, envir = ns)
    f_txt <- paste(deparse(body(f)), collapse = "\n")
    f2 <- f
    body(f2) <- parse(text = gsub(tiles_url, tiles_path, f_txt, fixed = TRUE))
    unlockBinding(nm, ns)
    assign(nm, f2, envir = ns)
    lockBinding(nm, ns)
  }
  log_step("Patched blackmarbler tile URL in", length(hit_fns), "function(s).")
  invisible(TRUE)
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

mask_rad_to_valid <- function(rad, valid) {
  rad_masked <- terra::mask(rad, valid, maskvalues = 0, updatevalue = NA)
  names(rad_masked) <- "rad"
  lit <- terra::ifel(is.na(rad_masked), NA, terra::ifel(rad_masked > LIT_THRESHOLD, 1, 0))
  names(lit) <- "lit"
  names(valid) <- "valid"
  list(rad = rad_masked, lit = lit, valid = valid)
}

current_from_tif <- function(path) {
  r <- terra::rast(path)
  if (!all(c("rad", "lit", "valid") %in% names(r))) {
    stop("Current TIFF must have bands named rad, lit, valid.")
  }
  list(rad = r[["rad"]], lit = r[["lit"]], valid = r[["valid"]])
}

download_bm <- function(product_id, variable, roi_sf, bearer, h5_cache, quality_flag_rm = NULL) {
  args <- list(
    roi_sf = roi_sf,
    product_id = product_id,
    date = DATE_STR,
    bearer = bearer,
    variable = variable,
    output_location_type = "memory",
    h5_dir = h5_cache,
    quiet = TRUE
  )
  if (!is.null(quality_flag_rm)) args$quality_flag_rm <- quality_flag_rm

  last_error <- NULL
  for (attempt in seq_len(max(1L, DOWNLOAD_RETRIES))) {
    r <- tryCatch(
      do.call(blackmarbler::bm_raster, args),
      error = function(e) {
        last_error <<- conditionMessage(e)
        NULL
      }
    )
    if (inherits(r, "SpatRaster")) return(r)
    if (attempt < DOWNLOAD_RETRIES) {
      log_step("Retrying", product_id, variable, sprintf("(attempt %d/%d failed)", attempt, DOWNLOAD_RETRIES))
      Sys.sleep(min(60, 8 * attempt))
      args$bearer <- get_nasa_bearer()
    }
  }
  stop("Download failed for ", product_id, " ", variable, ". Last error: ", last_error)
}

tile_ids_for_roi <- function(roi_sf, tiles_path) {
  tiles <- sf::st_read(tiles_path, quiet = TRUE)
  hits <- sf::st_intersects(sf::st_transform(roi_sf, sf::st_crs(tiles)), tiles, sparse = FALSE)[1, ]
  sort(tiles$TileID[hits])
}

download_manifest <- function(product_id, year, doy, bearer) {
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
      log_step("Retrying manifest", product_id, sprintf("(attempt %d/%d failed)", attempt, DOWNLOAD_RETRIES))
      Sys.sleep(min(60, 8 * attempt))
      bearer <- get_nasa_bearer()
    }
  }
  stop("Manifest download failed for ", product_id, " ", year, "/", doy, ". Last error: ", last_error)
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
  out <- apply_scaling_factor(out, variable)
  out
}

download_vj146a2_variable <- function(variable, tile_ids, bearer, h5_cache, tiles_sf, roi_sf, template) {
  product_id <- "VJ146A2"
  manifest <- download_manifest(product_id, YEAR_STR, DOY_STR, bearer)
  manifest$tile_id <- stringr::str_extract(manifest$name, "h\\d{2}v\\d{2}")
  wanted <- manifest[manifest$tile_id %in% tile_ids & grepl("\\.h5$", manifest$name), , drop = FALSE]
  if (nrow(wanted) == 0L) stop("No VJ146A2 H5 files found for target tiles.")

  rasters <- vector("list", nrow(wanted))
  for (i in seq_len(nrow(wanted))) {
    out_path <- file.path(h5_cache, wanted$name[i])
    download_laads_file(wanted$downloadsLink[i], out_path, bearer)
    rasters[[i]] <- read_h5_var_like_blackmarbler(out_path, variable, tiles_sf)
  }

  merged <- do.call(terra::merge, rasters)
  merged <- terra::crop(merged, terra::vect(roi_sf))
  merged <- terra::mask(merged, terra::vect(roi_sf))
  align_to_template(merged, template, method = "near")
}

build_a2_candidate <- function(rad, qf, cloud, snow) {
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
  mask_rad_to_valid(rad, make_valid_01(valid_logical))
}

bitmask_flagged <- function(qf_dnb, values) {
  out <- terra::ifel(qf_dnb >= 0, 0, NA)
  for (value in values) {
    out <- out | (terra::app(qf_dnb, function(x) bitwAnd(as.integer(round(x)), value)) != 0)
  }
  out
}

count_condition <- function(condition_raster) {
  x <- terra::ifel(condition_raster, 1, 0)
  x <- terra::ifel(is.na(condition_raster), 0, x)
  as.numeric(terra::global(x, "sum", na.rm = TRUE)[1, 1])
}

summarize_scene <- function(scenario, rasters) {
  n_total <- terra::ncell(rasters$valid)
  n_valid <- count_condition(rasters$valid == 1)
  n_lit <- count_condition(rasters$lit == 1)
  data.frame(
    date = DATE_STR,
    scenario = scenario,
    n_total_pixels = n_total,
    n_valid_pixels = n_valid,
    n_lit_pixels = n_lit,
    valid_share = ifelse(n_total > 0, n_valid / n_total, NA_real_),
    p_lit = ifelse(n_valid > 0, n_lit / n_valid, NA_real_),
    lit_share_all = ifelse(n_total > 0, n_lit / n_total, NA_real_),
    mean_rad_valid = as.numeric(terra::global(rasters$rad, "mean", na.rm = TRUE)[1, 1]),
    stringsAsFactors = FALSE
  )
}

summarize_mask <- function(mask_name, mask_raster) {
  n_total <- terra::ncell(mask_raster)
  n_flagged <- count_condition(mask_raster == 1)
  data.frame(
    date = DATE_STR,
    mask = mask_name,
    n_total_pixels = n_total,
    n_flagged_pixels = n_flagged,
    share_flagged = ifelse(n_total > 0, n_flagged / n_total, NA_real_),
    stringsAsFactors = FALSE
  )
}

write_scenario_tif <- function(name, rasters) {
  out_file <- file.path(RASTER_DIR, sprintf("%s_%s.tif", name, DATE_STR))
  terra::writeRaster(
    c(rasters$rad, rasters$lit, rasters$valid),
    out_file,
    overwrite = TRUE,
    wopt = list(gdal = c("COMPRESS=LZW"))
  )
  out_file
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

plot_panel <- function(scenarios, out_file) {
  rad_vals <- unlist(lapply(scenarios, function(x) sample_values(x$rad)), use.names = FALSE)
  rad_breaks <- plot_breaks(rad_vals, lower = 0, probs = 0.99, fallback_upper = 5)
  rad_max <- max(rad_breaks)
  rad_cols <- hcl.colors(length(rad_breaks) - 1L, "Inferno", rev = FALSE)

  png(out_file, width = 3000, height = 1800, res = 220)
  op <- par(mfrow = c(2, 3), mar = c(2.2, 2.2, 3.2, 4.6), oma = c(0, 0, 3.0, 0))
  tryCatch({
    for (nm in names(scenarios)) {
      plot(
        terra::clamp(scenarios[[nm]]$rad, lower = 0, upper = rad_max, values = TRUE),
        col = rad_cols,
        breaks = rad_breaks,
        maxcell = PLOT_MAXCELL,
        main = nm
      )
    }
    mtext(sprintf("One-day A1/VJ diagnostic: %s", DATE_STR), outer = TRUE, font = 2, cex = 1.1)
  }, finally = {
    par(op)
    dev.off()
  })
}

# ------------------------------------------------------------
# Run
# ------------------------------------------------------------
log_step("Repository root:", BASE_PATH)
log_step("Date:", DATE_STR)
log_step("Output:", OUT_DIR)

patch_blackmarbler_tiles(TILES_URL, TILES_PATH)
bearer <- get_nasa_bearer()
roi_sf <- build_sa_roi(CURRENT_TIF_DIR)
tiles_sf <- sf::st_read(TILES_PATH, quiet = TRUE)
tile_ids <- tile_ids_for_roi(roi_sf, TILES_PATH)
log_step("Target tiles:", paste(tile_ids, collapse = ", "))

current <- current_from_tif(CURRENT_TIF)
template <- current$rad

log_step("Downloading VNP46A1 QF_DNB companion mask")
qf_dnb <- download_bm("VNP46A1", "QF_DNB", roi_sf, bearer, H5_CACHE)
qf_dnb <- align_to_template(qf_dnb, template, method = "near")
names(qf_dnb) <- "qf_dnb"

a1_stray_flagged <- bitmask_flagged(qf_dnb, A1_STRAY_BIT_VALUE)
a1_strict_flagged <- bitmask_flagged(qf_dnb, A1_STRICT_BAD_VALUES)
names(a1_stray_flagged) <- "a1_qf_dnb_stray_flagged"
names(a1_strict_flagged) <- "a1_qf_dnb_strict_flagged"

vnp_a1_stray_masked <- mask_rad_to_valid(
  current$rad,
  make_valid_01((current$valid == 1) & !(a1_stray_flagged == 1))
)
vnp_a1_strict_masked <- mask_rad_to_valid(
  current$rad,
  make_valid_01((current$valid == 1) & !(a1_strict_flagged == 1))
)

log_step("Downloading VJ146A2 direct LAADS rasters")
vj_rad <- download_vj146a2_variable("DNB_BRDF-Corrected_NTL", tile_ids, bearer, H5_CACHE, tiles_sf, roi_sf, template)
vj_qf <- download_vj146a2_variable("Mandatory_Quality_Flag", tile_ids, bearer, H5_CACHE, tiles_sf, roi_sf, template)
vj_cloud <- download_vj146a2_variable("QF_Cloud_Mask", tile_ids, bearer, H5_CACHE, tiles_sf, roi_sf, template)
vj_snow <- download_vj146a2_variable("Snow_Flag", tile_ids, bearer, H5_CACHE, tiles_sf, roi_sf, template)
names(vj_rad) <- "rad"
names(vj_qf) <- "mandatory_qf"
names(vj_cloud) <- "qf_cloud_mask"
names(vj_snow) <- "snow_flag"

vj_candidate <- build_a2_candidate(vj_rad, vj_qf, vj_cloud, vj_snow)

blend_valid <- make_valid_01((vnp_a1_strict_masked$valid == 1) | (vj_candidate$valid == 1))
blend_rad <- terra::ifel(vnp_a1_strict_masked$valid == 1, vnp_a1_strict_masked$rad, vj_candidate$rad)
blend_rad <- terra::mask(blend_rad, blend_valid, maskvalues = 0, updatevalue = NA)
names(blend_rad) <- "rad"
blend_lit <- terra::ifel(is.na(blend_rad), NA, terra::ifel(blend_rad > LIT_THRESHOLD, 1, 0))
names(blend_lit) <- "lit"
names(blend_valid) <- "valid"
blend <- list(rad = blend_rad, lit = blend_lit, valid = blend_valid)

scenarios <- list(
  "Current VNP46A2" = current,
  "VNP46A2 + A1 stray bit" = vnp_a1_stray_masked,
  "VNP46A2 + A1 strict DNB bits" = vnp_a1_strict_masked,
  "VJ146A2 candidate C2 mask" = vj_candidate,
  "Blend: VNP strict else VJ" = blend
)

summary_tbl <- do.call(rbind, Map(summarize_scene, names(scenarios), scenarios))
mask_tbl <- rbind(
  summarize_mask("a1_qf_dnb_stray_16", a1_stray_flagged),
  summarize_mask("a1_qf_dnb_strict_bad_bits", a1_strict_flagged)
)

for (nm in names(scenarios)) {
  safe_nm <- tolower(gsub("[^a-zA-Z0-9]+", "_", nm))
  write_scenario_tif(safe_nm, scenarios[[nm]])
}
terra::writeRaster(qf_dnb, file.path(RASTER_DIR, sprintf("vnp46a1_qf_dnb_%s.tif", DATE_STR)), overwrite = TRUE)
terra::writeRaster(a1_stray_flagged, file.path(RASTER_DIR, sprintf("vnp46a1_qf_dnb_stray_flag_%s.tif", DATE_STR)), overwrite = TRUE)
terra::writeRaster(a1_strict_flagged, file.path(RASTER_DIR, sprintf("vnp46a1_qf_dnb_strict_bad_bits_%s.tif", DATE_STR)), overwrite = TRUE)

summary_csv <- file.path(OUT_DIR, sprintf("one_day_a1_vj_summary_%s.csv", DATE_STR))
mask_csv <- file.path(OUT_DIR, sprintf("one_day_a1_vj_mask_shares_%s.csv", DATE_STR))
utils::write.csv(summary_tbl, summary_csv, row.names = FALSE)
utils::write.csv(mask_tbl, mask_csv, row.names = FALSE)

panel_png <- file.path(PNG_DIR, sprintf("one_day_a1_vj_comparison_%s.png", DATE_STR))
plot_panel(scenarios, panel_png)

log_step("Wrote summary:", summary_csv)
log_step("Wrote mask shares:", mask_csv)
log_step("Wrote panel:", panel_png)
log_step("Done.")
