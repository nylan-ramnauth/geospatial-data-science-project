# ============================================================
# QA Quality Flag Removal Comparison
# Stage 0b — Diagnostic / Optional
# ============================================================
#
# Purpose:  Downloads a single test-date scene from blackmarbler under
#           different quality_flag_rm scenarios and compares coverage
#           and lit share to help choose optimal QF settings.
# Inputs:   - blackmarbler/out_vnp46a2_sa_daily/*.tif  (from Stage 0)
#           - blackmarbler/out_vnp46a2_sa_daily/animations/sa_blackmarble_2023_visually_obvious_contamination_days.txt
# Outputs:  - blackmarbler/out_vnp46a2_sa_daily/qa_rm_compare/
# Run:      Rscript nightlight_downloader/qa_quality_flag_comparison.R
# NOTE:     Run from the project root directory — uses normalizePath(".") for BASE_PATH.
# ============================================================

rm(list = ls())

suppressPackageStartupMessages({
  library(sf)
  library(terra)
  library(blackmarbler)
})

sf::sf_use_s2(FALSE)

# ------------------------------------------------------------
# CONFIG
# ------------------------------------------------------------
BASE_PATH <- normalizePath(".", winslash = "/", mustWork = TRUE)
CURRENT_TIF_DIR <- file.path(BASE_PATH, "blackmarbler", "out_vnp46a2_sa_daily")
OBVIOUS_DAYS_FILE <- file.path(
  CURRENT_TIF_DIR, "animations", "sa_blackmarble_2023_visually_obvious_contamination_days.txt"
)
OUT_DIR <- file.path(CURRENT_TIF_DIR, "qa_rm_compare")
H5_CACHE <- file.path(CURRENT_TIF_DIR, "h5_cache")
LIT_THRESHOLD <- 1.0

# Optional manual override via env var, e.g. BM_TEST_DATE=2023-10-20
TEST_DATE_OVERRIDE <- Sys.getenv("BM_TEST_DATE", unset = "")
if (!nzchar(TEST_DATE_OVERRIDE)) TEST_DATE_OVERRIDE <- NA_character_

# Local tiles file used by your downloader patching approach
TILES_URL <- "https://raw.githubusercontent.com/worldbank/blackmarbler/main/data/blackmarbletiles.geojson"
TILES_PATH <- file.path(BASE_PATH, "blackmarbler", "blackmarbletiles.geojson")

# Keep only highest-quality daily pixels (QF == 0) on lunar-corrected DNB.
# For VNP46A2 this is done by removing QF 1:5.
QUALITY_SCENARIOS <- list(
  qf0_only = c(1L, 2L, 3L, 4L, 5L)
)

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(H5_CACHE, recursive = TRUE, showWarnings = FALSE)

if (!dir.exists(CURRENT_TIF_DIR)) {
  stop("Could not find current TIFF directory at: ", CURRENT_TIF_DIR,
       "\nRun this script from the project root.")
}

log_step <- function(...) {
  cat(format(Sys.time(), "%H:%M:%S"), "-", ..., "\n")
  flush.console()
}

pick_test_date <- function(override_date, obvious_file, current_dir) {
  if (!is.na(override_date) && nzchar(override_date)) return(as.Date(override_date))
  if (!file.exists(obvious_file)) stop("Obvious-days file not found: ", obvious_file)
  days <- trimws(readLines(obvious_file, warn = FALSE))
  days <- days[nzchar(days)]
  days <- as.Date(days)
  days <- days[!is.na(days)]
  if (length(days) == 0) stop("No valid dates found in obvious-days list.")

  for (i in seq_along(days)) {
    d <- days[i]
    tif_path <- file.path(current_dir, sprintf("sa_viirs_500m_daily_%s.tif", format(d, "%Y-%m-%d")))
    if (file.exists(tif_path)) return(d)
  }
  stop("No obvious-day TIFF found in current directory.")
}

patch_blackmarbler_tiles <- function(tiles_url, tiles_path) {
  if (!file.exists(tiles_path)) {
    log_step("Skipping package patch; local tiles file not found:", tiles_path)
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

  if (length(hit_fns) == 0) {
    log_step("No blackmarbler functions referenced tiles URL; patch skipped.")
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

build_roi_from_template <- function(template_raster) {
  xmn <- terra::xmin(template_raster)
  xmx <- terra::xmax(template_raster)
  ymn <- terra::ymin(template_raster)
  ymx <- terra::ymax(template_raster)
  ring <- matrix(
    c(
      xmn, ymn,
      xmx, ymn,
      xmx, ymx,
      xmn, ymx,
      xmn, ymn
    ),
    ncol = 2,
    byrow = TRUE
  )
  poly <- sf::st_polygon(list(ring))
  sf::st_sf(id = 1L, geometry = sf::st_sfc(poly, crs = 4326))
}

align_to_template <- function(r, template, method = "near") {
  if (isTRUE(all.equal(terra::res(r), terra::res(template))) &&
      isTRUE(all.equal(terra::ext(r), terra::ext(template))) &&
      isTRUE(all.equal(terra::crs(r), terra::crs(template)))) {
    return(r)
  }
  terra::resample(r, template, method = method)
}

derive_lit_valid <- function(rad, lit_threshold) {
  valid <- terra::ifel(is.na(rad), 0, 1)
  names(valid) <- "valid"
  lit <- terra::ifel(is.na(rad), NA, terra::ifel(rad > lit_threshold, 1, 0))
  names(lit) <- "lit"
  list(lit = lit, valid = valid)
}

summarize_scene <- function(name, rad, lit, valid) {
  n_total <- terra::ncell(valid)
  n_valid <- as.numeric(terra::global(valid == 1, "sum", na.rm = TRUE)[1, 1])
  n_lit <- as.numeric(terra::global(lit == 1, "sum", na.rm = TRUE)[1, 1])
  lit_share_valid <- ifelse(n_valid > 0, n_lit / n_valid, NA_real_)
  mean_rad_valid <- as.numeric(terra::global(rad, "mean", na.rm = TRUE)[1, 1])
  data.frame(
    scenario = name,
    n_total_pixels = n_total,
    n_valid_pixels = n_valid,
    n_lit_pixels = n_lit,
    share_valid_pixels = ifelse(n_total > 0, n_valid / n_total, NA_real_),
    lit_share_among_valid = lit_share_valid,
    mean_rad_among_valid = mean_rad_valid,
    stringsAsFactors = FALSE
  )
}

quality_label <- function(qf_value) {
  labels <- c(
    "0" = "0: High-quality",
    "1" = "1: Poor-quality (outlier/cloud/other)",
    "2" = "2: Poor-quality (high solar zenith angle)",
    "3" = "3: Poor-quality (lunar eclipse)",
    "4" = "4: Poor-quality (aurora)",
    "5" = "5: Poor-quality (glint)"
  )
  key <- as.character(qf_value)
  ifelse(key %in% names(labels), labels[key], paste0(key, ": Other/unknown"))
}

summarize_quality <- function(quality_raster) {
  freq_tbl <- terra::freq(quality_raster)
  if (is.null(freq_tbl) || nrow(freq_tbl) == 0) {
    return(data.frame(
      qf_value = integer(0),
      qf_label = character(0),
      n_pixels = numeric(0),
      share_pixels = numeric(0),
      stringsAsFactors = FALSE
    ))
  }
  freq_tbl <- as.data.frame(freq_tbl)
  freq_tbl <- freq_tbl[!is.na(freq_tbl[, 1]), , drop = FALSE]
  names(freq_tbl) <- c("qf_value", "n_pixels")
  total_pixels <- sum(freq_tbl$n_pixels)
  freq_tbl$qf_label <- quality_label(freq_tbl$qf_value)
  freq_tbl$share_pixels <- ifelse(total_pixels > 0, freq_tbl$n_pixels / total_pixels, NA_real_)
  freq_tbl[order(freq_tbl$qf_value), c("qf_value", "qf_label", "n_pixels", "share_pixels")]
}

build_quality_012 <- function(quality_raster, roi_polygon) {
  # Match the 3-class style used in the NASA example:
  # 0 = high-quality persistent, 1 = high-quality ephemeral, 2 = poor-quality
  quality_012 <- terra::ifel(
    is.na(quality_raster),
    NA,
    terra::ifel(
      quality_raster == 0, 0,
      terra::ifel(quality_raster == 1, 1, 2)
    )
  )
  quality_012 <- terra::mask(quality_012, terra::vect(roi_polygon))
  quality_012 <- terra::as.factor(quality_012)
  levels(quality_012) <- data.frame(
    id = 0:2,
    cover = c(
      "0: High-quality, persistent",
      "1: High-quality, ephemeral",
      "2: Poor-quality"
    )
  )
  quality_012
}

# ------------------------------------------------------------
# RUN
# ------------------------------------------------------------
patch_blackmarbler_tiles(TILES_URL, TILES_PATH)

test_date <- pick_test_date(TEST_DATE_OVERRIDE, OBVIOUS_DAYS_FILE, CURRENT_TIF_DIR)
date_str <- format(test_date, "%Y-%m-%d")
current_tif <- file.path(CURRENT_TIF_DIR, sprintf("sa_viirs_500m_daily_%s.tif", date_str))

if (!file.exists(current_tif)) stop("Current TIFF not found for test date: ", current_tif)

log_step("Using test date:", date_str)
log_step("Current TIFF:", current_tif)

current <- terra::rast(current_tif)
if (!all(c("rad", "lit", "valid") %in% names(current))) {
  stop("Current TIFF must contain bands named rad, lit, valid.")
}

template <- current[["rad"]]
roi_sf <- build_roi_from_template(template)

bearer <- blackmarbler::get_nasa_token(
  username = Sys.getenv("EARTHDATA_USER"),
  password = Sys.getenv("EARTHDATA_PASS")
)
if (!nzchar(bearer)) stop("Could not retrieve NASA bearer token.")

results <- list(
  current = list(
    rad = current[["rad"]],
    lit = current[["lit"]],
    valid = current[["valid"]]
  )
)

for (sc in names(QUALITY_SCENARIOS)) {
  qrm <- QUALITY_SCENARIOS[[sc]]
  log_step("Downloading blackmarbler for", date_str, "with quality_flag_rm =", paste(qrm, collapse = ","))

  rad <- blackmarbler::bm_raster(
    roi_sf = roi_sf,
    product_id = "VNP46A2",
    date = date_str,
    bearer = bearer,
    variable = "DNB_BRDF-Corrected_NTL",
    quality_flag_rm = qrm,
    output_location_type = "memory",
    h5_dir = H5_CACHE,
    quiet = TRUE
  )

  if (!inherits(rad, "SpatRaster")) stop("Download failed for scenario: ", sc)
  rad <- align_to_template(rad, template, method = "near")
  names(rad) <- "rad"

  dv <- derive_lit_valid(rad, LIT_THRESHOLD)
  results[[sc]] <- list(rad = rad, lit = dv$lit, valid = dv$valid)

  out_tif <- file.path(OUT_DIR, sprintf("bm_qfrm_%s_%s.tif", sc, date_str))
  terra::writeRaster(c(rad, dv$lit, dv$valid), out_tif, overwrite = TRUE, wopt = list(gdal = c("COMPRESS=LZW")))
  log_step("Wrote scenario TIFF:", out_tif)
}

log_step("Downloading Mandatory_Quality_Flag for", date_str)
quality_r <- blackmarbler::bm_raster(
  roi_sf = roi_sf,
  product_id = "VNP46A2",
  date = date_str,
  bearer = bearer,
  variable = "Mandatory_Quality_Flag",
  output_location_type = "memory",
  h5_dir = H5_CACHE,
  quiet = TRUE
)
if (!inherits(quality_r, "SpatRaster")) stop("Download failed for Mandatory_Quality_Flag.")
quality_r <- align_to_template(quality_r, template, method = "near")
names(quality_r) <- "mandatory_qf"

quality_tif <- file.path(OUT_DIR, sprintf("bm_mandatory_qf_%s.tif", date_str))
terra::writeRaster(quality_r, quality_tif, overwrite = TRUE, wopt = list(gdal = c("COMPRESS=LZW")))
log_step("Wrote quality TIFF:", quality_tif)

summary_tbl <- do.call(
  rbind,
  lapply(names(results), function(nm) {
    x <- results[[nm]]
    summarize_scene(nm, x$rad, x$lit, x$valid)
  })
)

summary_csv <- file.path(OUT_DIR, sprintf("quality_flag_rm_compare_%s.csv", date_str))
utils::write.csv(summary_tbl, summary_csv, row.names = FALSE)
log_step("Wrote summary CSV:", summary_csv)

quality_summary <- summarize_quality(quality_r)
quality_summary_csv <- file.path(OUT_DIR, sprintf("mandatory_quality_distribution_%s.csv", date_str))
utils::write.csv(quality_summary, quality_summary_csv, row.names = FALSE)
log_step("Wrote quality distribution CSV:", quality_summary_csv)

quality_012 <- build_quality_012(quality_r, roi_sf)
quality_012_tif <- file.path(OUT_DIR, sprintf("mandatory_quality_012_%s.tif", date_str))
terra::writeRaster(quality_012, quality_012_tif, overwrite = TRUE, wopt = list(gdal = c("COMPRESS=LZW")))
log_step("Wrote quality 0/1/2 TIFF:", quality_012_tif)

if (requireNamespace("ggplot2", quietly = TRUE) && requireNamespace("tidyterra", quietly = TRUE)) {
  quality_plot <- ggplot2::ggplot() +
    tidyterra::geom_spatraster(data = quality_012) +
    ggplot2::scale_fill_brewer(
      palette = "Spectral",
      direction = -1,
      na.value = "transparent"
    ) +
    ggplot2::labs(
      fill = "Quality",
      title = sprintf("Mandatory_Quality_Flag classes (%s)", date_str)
    ) +
    ggplot2::coord_sf() +
    ggplot2::theme_void() +
    ggplot2::theme(plot.title = ggplot2::element_text(face = "bold", hjust = 0.5))

  quality_plot_png <- file.path(OUT_DIR, sprintf("mandatory_quality_012_map_%s.png", date_str))
  ggplot2::ggsave(
    filename = quality_plot_png,
    plot = quality_plot,
    width = 10,
    height = 7,
    dpi = 300
  )
  log_step("Wrote ggplot quality map:", quality_plot_png)
} else {
  log_step("Skipped ggplot quality map (missing package ggplot2 and/or tidyterra).")
}

if (!("qf0_only" %in% names(results))) {
  stop("Expected scenario qf0_only in results.")
}

diff_qf0 <- terra::ifel(
  is.na(results$current$lit) | is.na(results$qf0_only$lit),
  NA,
  results$qf0_only$lit - results$current$lit
)

png_file <- file.path(OUT_DIR, sprintf("quality_flag_rm_compare_%s.png", date_str))
png(png_file, width = 2400, height = 1500, res = 220)
op <- par(mfrow = c(2, 3), mar = c(3, 3, 3, 5))
on.exit({
  par(op)
  dev.off()
}, add = TRUE)

lit_cols <- c("#1b1b1b", "#fdae61")
lit_breaks <- c(-0.1, 0.5, 1.1)
diff_cols <- c("#2c7bb6", "grey85", "#d7191c")
diff_breaks <- c(-1.5, -0.5, 0.5, 1.5)
valid_cols <- c("grey20", "white")
valid_breaks <- c(-0.1, 0.5, 1.1)
qf_cols <- c("#1a9850", "#66bd63", "#fdae61", "#f46d43", "#d73027", "#a50026")
qf_breaks <- c(-0.5, 0.5, 1.5, 2.5, 3.5, 4.5, 5.5)

plot(results$current$lit, col = lit_cols, breaks = lit_breaks, main = sprintf("Current lit\n%s", date_str))
plot(results$qf0_only$lit, col = lit_cols, breaks = lit_breaks, main = "bm_raster lit (highest quality: qf0 only)")
plot(results$qf0_only$valid, col = valid_cols, breaks = valid_breaks, main = "qf0-only valid mask")
plot(diff_qf0, col = diff_cols, breaks = diff_breaks, main = "Diff lit: qf0_only - current")
plot(quality_r, col = qf_cols, breaks = qf_breaks, main = "Mandatory_Quality_Flag")
plot(results$current$valid, col = valid_cols, breaks = valid_breaks, main = "Current valid mask")

mtext("Blue = dropped lit vs current | Red = added lit vs current", side = 1, outer = FALSE, line = -1, cex = 0.9)
dev.off()

log_step("Wrote comparison plot:", png_file)
log_step("Done.")
