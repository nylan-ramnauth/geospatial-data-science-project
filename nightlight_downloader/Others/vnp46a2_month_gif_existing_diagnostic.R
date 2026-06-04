# ============================================================
# Existing VNP46A2 Monthly GIF Diagnostic
# ============================================================
#
# Purpose:  Build a 500 m monthly discrete lit-threshold GIF from
#           existing production VNP46A2 daily TIFFs only. This script
#           does not download data and does not modify production TIFFs.
#
# Default:  BM_VNP_MONTH=2023-10, matching the VJ146A2 monthly GIF.
#
# Outputs:  blackmarbler/out_vnp46a2_sa_daily/qa_straylight_validation/
#             vnp46a2_month_<YYYY-MM>/
#
# Run:      Rscript nightlight_downloader/Others/vnp46a2_month_gif_existing_diagnostic.R
#
# IMPORTANT: Diagnostic-only. Does not modify production daily TIFFs,
# viirs_daily_download.R, or settlement-panel outputs.
# ============================================================

rm(list = ls())

suppressPackageStartupMessages({
  library(terra)
  library(gifski)
})

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

MONTH_STR <- Sys.getenv("BM_VNP_MONTH", unset = "2023-10")
MONTH_START <- as.Date(paste0(MONTH_STR, "-01"))
if (is.na(MONTH_START)) stop("Invalid BM_VNP_MONTH; expected YYYY-MM, got: ", MONTH_STR)
MONTH_END <- seq(MONTH_START, length = 2L, by = "1 month")[2] - 1L
TARGET_DATES <- seq(MONTH_START, MONTH_END, by = "1 day")

CURRENT_TIF_DIR <- file.path(BASE_PATH, "blackmarbler", "out_vnp46a2_sa_daily")
OUT_DIR <- file.path(
  CURRENT_TIF_DIR,
  "qa_straylight_validation",
  sprintf("vnp46a2_month_%s", MONTH_STR)
)
FRAME_DIR <- file.path(OUT_DIR, "frames")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(FRAME_DIR, recursive = TRUE, showWarnings = FALSE)

LIT_THRESHOLD <- as.numeric(Sys.getenv("BM_VNP_LIT_THRESHOLD", unset = "1.0"))
GIF_FPS <- as.numeric(Sys.getenv("BM_VNP_GIF_FPS", unset = "2"))

CLASS_COLS <- c("#32104b", "#ffd31a")
NA_COL <- "#d9d9d9"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
log_step <- function(...) {
  cat(format(Sys.time(), "%H:%M:%S"), "-", ..., "\n")
  flush.console()
}

tif_for_date <- function(date_str) {
  file.path(CURRENT_TIF_DIR, sprintf("sa_viirs_500m_daily_%s.tif", date_str))
}

make_lit_ge1 <- function(r) {
  if (!all(c("rad", "valid") %in% names(r))) {
    stop("VNP46A2 TIFF must contain bands named rad and valid.")
  }
  rad <- r[["rad"]]
  valid <- r[["valid"]]
  lit_ge1 <- terra::ifel(valid == 1, terra::ifel(rad >= LIT_THRESHOLD, 1, 0), NA)
  names(lit_ge1) <- "lit_ge1"
  lit_ge1
}

count_condition <- function(condition_raster) {
  x <- terra::ifel(condition_raster, 1, 0)
  x <- terra::ifel(is.na(condition_raster), 0, x)
  as.numeric(terra::global(x, "sum", na.rm = TRUE)[1, 1])
}

summarize_scene <- function(date_str, r, lit_ge1, status) {
  n_total <- terra::ncell(lit_ge1)
  if (status != "ok") {
    return(data.frame(
      date = date_str,
      n_total_pixels = NA_real_,
      n_valid_pixels = NA_real_,
      n_lit_pixels_ge1 = NA_real_,
      valid_share = NA_real_,
      p_lit_ge1 = NA_real_,
      lit_share_all_ge1 = NA_real_,
      mean_rad_valid = NA_real_,
      status = status,
      stringsAsFactors = FALSE
    ))
  }

  valid <- r[["valid"]]
  rad_valid <- terra::mask(r[["rad"]], valid, maskvalues = 0, updatevalue = NA)
  n_valid <- count_condition(valid == 1)
  n_lit <- count_condition(lit_ge1 == 1)
  data.frame(
    date = date_str,
    n_total_pixels = n_total,
    n_valid_pixels = n_valid,
    n_lit_pixels_ge1 = n_lit,
    valid_share = ifelse(n_total > 0, n_valid / n_total, NA_real_),
    p_lit_ge1 = ifelse(n_valid > 0, n_lit / n_valid, NA_real_),
    lit_share_all_ge1 = ifelse(n_total > 0, n_lit / n_total, NA_real_),
    mean_rad_valid = as.numeric(terra::global(rad_valid, "mean", na.rm = TRUE)[1, 1]),
    status = status,
    stringsAsFactors = FALSE
  )
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

write_missing_frame <- function(date_str, template, reason) {
  frame_file <- file.path(FRAME_DIR, sprintf("vnp46a2_lit_ge1_%s.png", date_str))
  png(frame_file, width = 1400, height = 1000, res = 150)
  layout(matrix(c(1, 2), nrow = 1), widths = c(5.5, 1.15))
  par(mar = c(3.5, 3.5, 3.2, 0.8))
  e <- ext(template)
  plot(NA, xlim = c(e$xmin, e$xmax), ylim = c(e$ymin, e$ymax), asp = 1, axes = TRUE, xlab = "", ylab = "",
       main = sprintf("VNP46A2 500m lit threshold - %s", date_str))
  rect(e$xmin, e$ymin, e$xmax, e$ymax, col = NA_COL, border = "#777777")
  text(mean(c(e$xmin, e$xmax)), mean(c(e$ymin, e$ymax)), labels = reason, cex = 1.2, font = 2)
  par(mar = c(4.0, 0.4, 3.0, 0.4))
  plot_discrete_legend()
  dev.off()
  frame_file
}

write_frame <- function(date_str, lit_ge1, summary_row) {
  frame_file <- file.path(FRAME_DIR, sprintf("vnp46a2_lit_ge1_%s.png", date_str))
  png(frame_file, width = 1400, height = 1000, res = 150)
  layout(matrix(c(1, 2), nrow = 1), widths = c(5.5, 1.15))
  par(mar = c(3.5, 3.5, 3.2, 0.8))
  plot_lit_map(lit_ge1, sprintf("VNP46A2 500m lit threshold - %s", date_str))
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

# ------------------------------------------------------------
# Run
# ------------------------------------------------------------
log_step("Repository root:", BASE_PATH)
log_step("Month:", MONTH_STR, sprintf("(%s to %s)", format(MONTH_START), format(MONTH_END)))
log_step("Output:", OUT_DIR)
log_step("Using existing VNP46A2 TIFFs only; no download step.")

template_file <- tif_for_date(format(TARGET_DATES[1], "%Y-%m-%d"))
if (!file.exists(template_file)) {
  any_existing <- list.files(CURRENT_TIF_DIR, pattern = "^sa_viirs_500m_daily_.*\\.tif$", full.names = TRUE)
  if (length(any_existing) == 0L) stop("No existing production TIFFs found in: ", CURRENT_TIF_DIR)
  template_file <- any_existing[1]
}
template <- terra::rast(template_file)[["rad"]]

summary_rows <- list()
frame_files <- character(0)

for (target_date in TARGET_DATES) {
  target_date <- as.Date(target_date, origin = "1970-01-01")
  date_str <- format(target_date, "%Y-%m-%d")
  tif_path <- tif_for_date(date_str)

  if (!file.exists(tif_path)) {
    reason <- "missing existing VNP46A2 production TIFF"
    log_step("Skipping", date_str, "-", reason)
    summary_rows[[date_str]] <- summarize_scene(date_str, NULL, template, reason)
    frame_files <- c(frame_files, write_missing_frame(date_str, template, "Missing VNP46A2 TIFF"))
    next
  }

  log_step("Rendering VNP46A2", date_str)
  r <- terra::rast(tif_path)
  lit_ge1 <- make_lit_ge1(r)
  summary_row <- summarize_scene(date_str, r, lit_ge1, "ok")
  frame_file <- write_frame(date_str, lit_ge1, summary_row)

  summary_rows[[date_str]] <- summary_row
  frame_files <- c(frame_files, frame_file)
}

summary_tbl <- do.call(rbind, summary_rows)
summary_csv <- file.path(OUT_DIR, sprintf("vnp46a2_month_%s_summary.csv", MONTH_STR))
utils::write.csv(summary_tbl, summary_csv, row.names = FALSE)

gif_file <- file.path(OUT_DIR, sprintf("vnp46a2_lit_ge1_%s.gif", MONTH_STR))
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
