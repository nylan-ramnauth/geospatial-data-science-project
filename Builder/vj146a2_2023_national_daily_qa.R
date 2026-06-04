rm(list = ls())

# ============================================================
# 2023 VJ146A2 National Daily QA
# ============================================================
#
# Purpose:  Build whole-country daily VJ146A2 GIFs and candidate suspect-day
#           tables by comparing daily VJ146A2 radiance to the 2023 VJ146A4
#           annual composite. Diagnostic only; does not mutate MLR calibration
#           outputs or production reliability panels.
#
# Inputs:
#   - blackmarbler/out_vj146a2_sa_daily/vj146a2_sa_500m_daily_YYYY-MM-DD.tif
#   - blackmarbler/out_vj146a2_sa_daily/h5_cache_annual/VJ146A4.A2023001.*.h5
#   - optional ../pypsa-earth/data/za_validation/eskom_2023_hourly_clean.csv
#
# Outputs:
#   - Map Data/settlement_day_outputs_vj146a2/national_daily_qa_2023/
#       frames/
#       contact_sheets/
#       vj146a2_sa_daily_binary_2023.gif
#       vj146a2_sa_daily_binary_YYYY-MM.gif
#       vj146a2_2023_daily_composite_deviation.csv
#       vj146a2_2023_suspect_day_candidates.csv
#       vj146a2_2023_retained_day_counts_by_tier.csv
#       vj146a2_2023_missing_raster_dates.csv
#
# Run:
#   Rscript Builder/vj146a2_2023_national_daily_qa.R
#
# Smoke:
#   VJ146A2_QA_MAX_DATES=3 Rscript Builder/vj146a2_2023_national_daily_qa.R
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(sf)
  library(terra)
  library(data.table)
  library(gifski)
})

sf::sf_use_s2(FALSE)

env_or_default <- function(name, default) {
  value <- Sys.getenv(name)
  if (nzchar(value)) value else default
}

BASE_PATH <- here::here()
VAULT_PATH <- normalizePath(file.path(BASE_PATH, "..", "..", ".."), mustWork = TRUE)

YEAR_LABEL <- env_or_default("VJ146A2_QA_YEAR", "2023")
LIT_THRESHOLD <- as.numeric(env_or_default("VJ146A2_QA_LIT_THRESHOLD", "1.0"))
GIF_FPS <- as.numeric(env_or_default("VJ146A2_QA_GIF_FPS", "2"))
WRITE_FRAMES <- env_or_default("VJ146A2_QA_WRITE_FRAMES", "1") != "0"
REUSE_METRICS <- env_or_default("VJ146A2_QA_REUSE_METRICS", "1") != "0"
REUSE_FRAMES <- env_or_default("VJ146A2_QA_REUSE_FRAMES", "1") != "0"
MAX_DATES <- as.integer(env_or_default("VJ146A2_QA_MAX_DATES", "0"))
TARGET_CELLS <- as.numeric(env_or_default("VJ146A2_QA_TARGET_CELLS", "650000"))

if (!grepl("^\\d{4}$", YEAR_LABEL)) stop("VJ146A2_QA_YEAR must be YYYY.")
if (!is.finite(LIT_THRESHOLD)) stop("VJ146A2_QA_LIT_THRESHOLD must be numeric.")
if (!is.finite(GIF_FPS) || GIF_FPS <= 0) stop("VJ146A2_QA_GIF_FPS must be positive.")
if (!is.finite(TARGET_CELLS) || TARGET_CELLS <= 0) stop("VJ146A2_QA_TARGET_CELLS must be positive.")

RAST_DIR <- file.path(BASE_PATH, "blackmarbler", "out_vj146a2_sa_daily")
ANNUAL_H5_DIR <- file.path(RAST_DIR, "h5_cache_annual")
ANNUAL_VARIABLE <- "NearNadir_Composite_Snow_Free"
ANNUAL_QUALITY_VARIABLE <- paste0(ANNUAL_VARIABLE, "_Quality")
QUALITY_FLAGS_DROP <- c(1, 2)

OUT_DIR <- file.path(
  BASE_PATH,
  "Map Data",
  "settlement_day_outputs_vj146a2",
  paste0("national_daily_qa_", YEAR_LABEL)
)
FRAME_DIR <- file.path(OUT_DIR, "frames")
CONTACT_DIR <- file.path(OUT_DIR, "contact_sheets")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(FRAME_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(CONTACT_DIR, recursive = TRUE, showWarnings = FALSE)

ESKOM_HOURLY <- file.path(
  VAULT_PATH,
  "6-codebases",
  "repos",
  "pypsa-earth",
  "data",
  "za_validation",
  "eskom_2023_hourly_clean.csv"
)

OUT_DAILY <- file.path(OUT_DIR, paste0("vj146a2_", YEAR_LABEL, "_daily_composite_deviation.csv"))
OUT_SUSPECT <- file.path(OUT_DIR, paste0("vj146a2_", YEAR_LABEL, "_suspect_day_candidates.csv"))
OUT_RETAINED <- file.path(OUT_DIR, paste0("vj146a2_", YEAR_LABEL, "_retained_day_counts_by_tier.csv"))
OUT_MISSING <- file.path(OUT_DIR, paste0("vj146a2_", YEAR_LABEL, "_missing_raster_dates.csv"))
OUT_FRAME_MANIFEST <- file.path(OUT_DIR, paste0("vj146a2_", YEAR_LABEL, "_frame_manifest.csv"))
OUT_FULL_GIF <- file.path(OUT_DIR, paste0("vj146a2_sa_daily_binary_", YEAR_LABEL, ".gif"))

log_step <- function(...) {
  cat(format(Sys.time(), "%H:%M:%S"), "-", ..., "\n")
  flush.console()
}

safe_div <- function(num, den) {
  ifelse(is.finite(den) & den > 0, num / den, NA_real_)
}

raster_files <- list.files(
  RAST_DIR,
  pattern = paste0("^vj146a2_sa_500m_daily_", YEAR_LABEL, "-\\d{2}-\\d{2}\\.tif$"),
  full.names = TRUE
)
if (length(raster_files) == 0) stop("No VJ146A2 daily rasters found in: ", RAST_DIR)

date_from_path <- function(path) {
  as.Date(sub(".*_(\\d{4}-\\d{2}-\\d{2})\\.tif$", "\\1", basename(path)))
}

all_file_tbl <- data.table(
  date = as.Date(vapply(raster_files, date_from_path, as.Date("1970-01-01")), origin = "1970-01-01"),
  raster_file = raster_files
)
setorder(all_file_tbl, date)
file_tbl <- copy(all_file_tbl)
setorder(file_tbl, date)
if (MAX_DATES > 0) file_tbl <- file_tbl[seq_len(min(.N, MAX_DATES))]

expected_dates <- seq.Date(as.Date(paste0(YEAR_LABEL, "-01-01")), as.Date(paste0(YEAR_LABEL, "-12-31")), by = "day")
missing_dates <- as.Date(setdiff(expected_dates, all_file_tbl$date), origin = "1970-01-01")
fwrite(data.table(date = missing_dates), OUT_MISSING)

annual_h5_files <- function() {
  pattern <- paste0("^VJ146A4\\.A", YEAR_LABEL, "001\\..*\\.h5$")
  files <- list.files(ANNUAL_H5_DIR, pattern = pattern, full.names = TRUE)
  if (length(files) == 0) stop("No cached VJ146A4 annual H5 tiles found in: ", ANNUAL_H5_DIR)
  files
}

read_annual_tile <- function(path) {
  r <- terra::rast(path)
  nms <- names(r)
  if (!(ANNUAL_VARIABLE %in% nms)) stop("Missing ", ANNUAL_VARIABLE, " in ", path)
  if (!(ANNUAL_QUALITY_VARIABLE %in% nms)) stop("Missing ", ANNUAL_QUALITY_VARIABLE, " in ", path)
  rad <- r[[ANNUAL_VARIABLE]]
  qf <- r[[ANNUAL_QUALITY_VARIABLE]]
  rad <- terra::ifel(qf == QUALITY_FLAGS_DROP[1] | qf == QUALITY_FLAGS_DROP[2], NA, rad)
  names(rad) <- "annual_rad"
  rad
}

align_annual_reference <- function(template) {
  files <- annual_h5_files()
  log_step("Reading", length(files), "cached VJ146A4 annual tiles.")
  tiles <- lapply(files, read_annual_tile)
  annual <- if (length(tiles) == 1L) tiles[[1L]] else do.call(terra::merge, tiles)
  annual <- terra::crop(annual, terra::ext(template))

  if (!terra::compareGeom(template[[1]], annual, stopOnError = FALSE)) {
    log_step("Resampling annual composite to daily raster grid.")
    annual <- terra::resample(annual, template[[1]], method = "bilinear")
  }
  names(annual) <- "annual_rad"
  annual
}

zaf_outline <- function() {
  outline_path <- file.path(RAST_DIR, "gadm", "gadm", "gadm41_ZAF_0_pk.rds")
  if (file.exists(outline_path)) {
    x <- sf::st_as_sf(readRDS(outline_path))
    sf::st_transform(x, 4326)
  } else {
    NULL
  }
}

downsample <- function(r, target_cells = TARGET_CELLS, fun = "mean") {
  fact <- max(1L, ceiling(sqrt(terra::ncell(r) / target_cells)))
  if (fact <= 1L) return(r)
  terra::aggregate(r, fact = fact, fun = fun, na.rm = TRUE)
}

count_condition <- function(x) {
  y <- terra::ifel(x, 1, 0)
  y <- terra::ifel(is.na(y), 0, y)
  as.numeric(terra::global(y, "sum", na.rm = TRUE)[1, 1])
}

mean_raster <- function(x) {
  as.numeric(terra::global(x, "mean", na.rm = TRUE)[1, 1])
}

metric_quantiles <- function(x) {
  vals <- terra::values(x, mat = FALSE, na.rm = TRUE)
  vals <- vals[is.finite(vals)]
  if (length(vals) == 0L) {
    return(c(p05 = NA_real_, median = NA_real_, p90 = NA_real_, p95 = NA_real_))
  }
  as.numeric(stats::quantile(vals, probs = c(0.05, 0.50, 0.90, 0.95), na.rm = TRUE, names = FALSE)) |>
    stats::setNames(c("p05", "median", "p90", "p95"))
}

class_cols <- c("#24103f", "#ffd84d")
resid_cols <- colorRampPalette(c("#08306b", "#f7fbff", "#7f0000"))(101)

has_finite_cells <- function(r) {
  vals <- terra::values(r, mat = FALSE, na.rm = TRUE)
  any(is.finite(vals))
}

plot_empty_raster <- function(r, main, message, outline = NULL) {
  e <- terra::ext(r)
  plot(
    NA,
    xlim = c(terra::xmin(e), terra::xmax(e)),
    ylim = c(terra::ymin(e), terra::ymax(e)),
    xaxs = "i",
    yaxs = "i",
    asp = 1,
    xlab = "",
    ylab = "",
    main = main,
    axes = TRUE
  )
  rect(terra::xmin(e), terra::ymin(e), terra::xmax(e), terra::ymax(e), col = "#8f8f8f", border = NA)
  text(mean(c(terra::xmin(e), terra::xmax(e))), mean(c(terra::ymin(e), terra::ymax(e))), message, cex = 1.05, font = 2)
  if (!is.null(outline)) plot(sf::st_geometry(outline), add = TRUE, border = "grey20", lwd = 0.5)
  box()
}

plot_lit_fraction <- function(r, main, outline = NULL) {
  if (!has_finite_cells(r)) {
    plot_empty_raster(r, main, "No plottable lit pixels", outline)
    return(invisible(NULL))
  }
  terra::plot(
    r,
    col = class_cols,
    breaks = c(0, 0.5, 1),
    colNA = "#8f8f8f",
    main = main,
    axes = TRUE,
    legend = FALSE
  )
  if (!is.null(outline)) plot(sf::st_geometry(outline), add = TRUE, border = "grey20", lwd = 0.5)
}

plot_residual <- function(r, main, outline = NULL) {
  if (!has_finite_cells(r)) {
    plot_empty_raster(r, main, "No plottable radiance residuals", outline)
    return(invisible(NULL))
  }
  terra::plot(
    r,
    col = resid_cols,
    range = c(-1.5, 1.5),
    colNA = "#8f8f8f",
    main = main,
    axes = TRUE,
    legend = FALSE
  )
  if (!is.null(outline)) plot(sf::st_geometry(outline), add = TRUE, border = "grey20", lwd = 0.5)
}

render_frame <- function(daily, annual, date, metrics, outline = NULL) {
  date_str <- format(date, "%Y-%m-%d")
  frame_file <- file.path(FRAME_DIR, paste0("vj146a2_sa_daily_binary_", date_str, ".png"))

  valid <- daily[["valid"]] == 1
  daily_lit <- terra::ifel(valid & daily[["rad"]] > LIT_THRESHOLD, 1, NA)
  daily_lit <- terra::ifel(valid & daily[["rad"]] <= LIT_THRESHOLD, 0, daily_lit)
  annual_lit <- terra::ifel(!is.na(annual) & annual > LIT_THRESHOLD, 1, NA)
  annual_lit <- terra::ifel(!is.na(annual) & annual <= LIT_THRESHOLD, 0, annual_lit)
  resid <- log1p(daily[["rad"]]) - log1p(annual)
  resid <- terra::mask(resid, valid, maskvalues = 0, updatevalue = NA)

  daily_plot <- downsample(daily_lit)
  annual_plot <- downsample(annual_lit)
  resid_plot <- downsample(resid)

  png(frame_file, width = 2100, height = 1180, res = 150)
  old_par <- par(no.readonly = TRUE)
  on.exit({
    par(old_par)
    dev.off()
  }, add = TRUE)

  layout(matrix(c(1, 2, 3), nrow = 1), widths = c(1, 1, 1))
  par(oma = c(1.3, 0.4, 5.5, 0.4), mar = c(3.0, 2.6, 2.7, 0.8))
  plot_lit_fraction(daily_plot, "Daily VJ146A2 lit", outline)
  plot_lit_fraction(annual_plot, "VJ146A4 annual lit", outline)
  plot_residual(resid_plot, "log1p daily - annual radiance", outline)

  title(
    main = paste0(
      "VJ146A2 national daily QA - ", date_str,
      " | tier: ", metrics$review_tier
    ),
    outer = TRUE,
    line = 3.1,
    cex.main = 1.05
  )
  mtext(
    paste0(
      "valid=", sprintf("%.3f", metrics$valid_share),
      " | lit=", sprintf("%.3f", metrics$daily_lit_share),
      " | excess-lit=", sprintf("%.3f", metrics$excess_lit_share),
      " | excess-dark=", sprintf("%.3f", metrics$excess_dark_share),
      " | p95 log residual=", sprintf("%.3f", metrics$residual_log_p95),
      " | score=", sprintf("%.2f", metrics$composite_score)
    ),
    outer = TRUE,
    side = 3,
    line = 2.0,
    cex = 0.82
  )
  mtext(
    "Purple = unlit, yellow = lit, grey = invalid/missing. Residual panel flags direct radiance anomalies relative to annual composite.",
    outer = TRUE,
    side = 1,
    line = 0.1,
    cex = 0.78
  )

  frame_file
}

frame_path_for_date <- function(date) {
  file.path(FRAME_DIR, paste0("vj146a2_sa_daily_binary_", format(date, "%Y-%m-%d"), ".png"))
}

compute_daily_metrics <- function(path, date, annual) {
  daily <- terra::rast(path)
  required <- c("rad", "lit", "valid")
  if (!all(required %in% names(daily))) {
    stop("Daily raster missing required bands in ", path, ": ", paste(setdiff(required, names(daily)), collapse = ", "))
  }

  valid <- daily[["valid"]] == 1
  common <- valid & !is.na(daily[["rad"]]) & !is.na(annual)
  daily_lit <- valid & daily[["rad"]] > LIT_THRESHOLD
  annual_lit_common <- common & annual > LIT_THRESHOLD
  daily_lit_common <- common & daily[["rad"]] > LIT_THRESHOLD
  daily_dark_common <- common & daily[["rad"]] <= LIT_THRESHOLD
  annual_dark_common <- common & annual <= LIT_THRESHOLD
  residual <- log1p(daily[["rad"]]) - log1p(annual)
  residual <- terra::mask(residual, common, maskvalues = 0, updatevalue = NA)

  n_total <- terra::ncell(daily)
  n_valid <- count_condition(valid)
  n_common <- count_condition(common)
  n_lit <- count_condition(daily_lit)
  n_excess_lit <- count_condition(daily_lit_common & annual_dark_common)
  n_excess_dark <- count_condition(daily_dark_common & annual_lit_common)
  q <- metric_quantiles(residual)
  mean_diff <- mean_raster(residual)
  rmse <- sqrt(mean_raster(residual^2))
  mae <- mean_raster(abs(residual))
  positive_share <- safe_div(count_condition(residual > 0), n_common)
  negative_share <- safe_div(count_condition(residual < 0), n_common)
  high_pos_share <- safe_div(count_condition(residual > 1), n_common)
  high_neg_share <- safe_div(count_condition(residual < -1), n_common)

  data.table(
    date = as.Date(date),
    raster_file = path,
    n_total_pixels = n_total,
    n_valid_pixels = n_valid,
    n_common_pixels = n_common,
    n_lit_pixels = n_lit,
    valid_share = safe_div(n_valid, n_total),
    annual_comparison_share = safe_div(n_common, n_total),
    daily_lit_share = safe_div(n_lit, n_valid),
    excess_lit_share = safe_div(n_excess_lit, n_common),
    excess_dark_share = safe_div(n_excess_dark, n_common),
    residual_log_mean = mean_diff,
    residual_log_median = q[["median"]],
    residual_log_p05 = q[["p05"]],
    residual_log_p90 = q[["p90"]],
    residual_log_p95 = q[["p95"]],
    residual_log_rmse = rmse,
    residual_log_mae = mae,
    residual_positive_share = positive_share,
    residual_negative_share = negative_share,
    residual_gt_1_share = high_pos_share,
    residual_lt_minus_1_share = high_neg_share
  )
}

robust_z <- function(x) {
  ok <- is.finite(x)
  out <- rep(NA_real_, length(x))
  if (sum(ok) < 3L) return(out)
  med <- stats::median(x[ok], na.rm = TRUE)
  scale <- stats::mad(x[ok], constant = 1.4826, na.rm = TRUE)
  if (!is.finite(scale) || scale <= 0) scale <- stats::sd(x[ok], na.rm = TRUE)
  if (!is.finite(scale) || scale <= 0) return(out)
  out[ok] <- (x[ok] - med) / scale
  out
}

add_review_tiers <- function(metrics) {
  metrics[, month := format(date, "%Y-%m")]
  z_cols <- c(
    "excess_lit_share",
    "excess_dark_share",
    "residual_log_p95",
    "residual_log_rmse",
    "residual_gt_1_share",
    "residual_lt_minus_1_share"
  )
  for (col in z_cols) {
    metrics[, paste0(col, "_monthly_z") := robust_z(get(col)), by = month]
  }
  metrics[, low_valid_share_monthly_z := robust_z(-valid_share), by = month]

  score_cols <- c(paste0(z_cols, "_monthly_z"), "low_valid_share_monthly_z")
  metrics[, composite_score := do.call(pmax, c(.SD, list(na.rm = TRUE))), .SDcols = score_cols]
  metrics[!is.finite(composite_score), composite_score := NA_real_]
  q90 <- stats::quantile(metrics$composite_score, 0.90, na.rm = TRUE)
  q95 <- stats::quantile(metrics$composite_score, 0.95, na.rm = TRUE)
  if (!is.finite(q90)) q90 <- Inf
  if (!is.finite(q95)) q95 <- Inf

  metrics[, review_tier := fifelse(
    composite_score >= q95 |
      excess_lit_share_monthly_z >= 3 |
      excess_dark_share_monthly_z >= 3 |
      residual_log_p95_monthly_z >= 3 |
      residual_log_rmse_monthly_z >= 3 |
      low_valid_share_monthly_z >= 3,
    "high_review",
    fifelse(
      composite_score >= q90 |
        excess_lit_share_monthly_z >= 2 |
        excess_dark_share_monthly_z >= 2 |
        residual_log_p95_monthly_z >= 2 |
        residual_log_rmse_monthly_z >= 2 |
        low_valid_share_monthly_z >= 2,
      "medium_review",
      "normal_review"
    )
  )]

  metrics[, reason_flags := paste(
    c(
      if (isTRUE(excess_lit_share_monthly_z >= 2)) "excess_lit" else NA_character_,
      if (isTRUE(excess_dark_share_monthly_z >= 2)) "excess_dark" else NA_character_,
      if (isTRUE(residual_log_p95_monthly_z >= 2) || isTRUE(residual_gt_1_share_monthly_z >= 2)) "radiance_positive_outlier" else NA_character_,
      if (isTRUE(residual_lt_minus_1_share_monthly_z >= 2)) "radiance_negative_outlier" else NA_character_,
      if (isTRUE(low_valid_share_monthly_z >= 2)) "low_valid_share" else NA_character_
    )[!is.na(c(
      if (isTRUE(excess_lit_share_monthly_z >= 2)) "excess_lit" else NA_character_,
      if (isTRUE(excess_dark_share_monthly_z >= 2)) "excess_dark" else NA_character_,
      if (isTRUE(residual_log_p95_monthly_z >= 2) || isTRUE(residual_gt_1_share_monthly_z >= 2)) "radiance_positive_outlier" else NA_character_,
      if (isTRUE(residual_lt_minus_1_share_monthly_z >= 2)) "radiance_negative_outlier" else NA_character_,
      if (isTRUE(low_valid_share_monthly_z >= 2)) "low_valid_share" else NA_character_
    ))],
    collapse = ";"
  ), by = seq_len(nrow(metrics))]
  metrics[reason_flags == "", reason_flags := "none"]
  metrics[]
}

write_contact_sheet <- function(label, frame_files, dates, out_file, ncol = 3L) {
  if (length(frame_files) == 0L) return(NA_character_)
  if (!requireNamespace("png", quietly = TRUE)) {
    warning("Package png is unavailable; skipping contact sheet: ", label)
    return(NA_character_)
  }
  keep <- file.exists(frame_files)
  frame_files <- frame_files[keep]
  dates <- dates[keep]
  if (length(frame_files) == 0L) return(NA_character_)

  imgs <- lapply(frame_files, png::readPNG)
  n <- length(imgs)
  ncol <- min(ncol, n)
  nrow <- ceiling(n / ncol)
  tile_w <- 560
  tile_h <- 315
  png(out_file, width = ncol * tile_w, height = nrow * tile_h + 70, res = 110)
  old_par <- par(no.readonly = TRUE)
  on.exit({
    par(old_par)
    dev.off()
  }, add = TRUE)
  par(mar = c(0, 0, 0, 0), oma = c(0, 0, 0, 0))
  plot.new()
  plot.window(xlim = c(0, ncol * tile_w), ylim = c(0, nrow * tile_h + 70), xaxs = "i", yaxs = "i")
  title_y <- nrow * tile_h + 48
  text(18, title_y, label, adj = 0, font = 2, cex = 1.25)
  for (i in seq_len(n)) {
    col_i <- (i - 1L) %% ncol
    row_i <- (i - 1L) %/% ncol
    x0 <- col_i * tile_w
    x1 <- x0 + tile_w
    y1 <- nrow * tile_h - row_i * tile_h
    y0 <- y1 - tile_h + 6
    rasterImage(imgs[[i]], x0, y0, x1, y1)
    rect(x0, y0, x1, y1, border = "grey20", lwd = 1)
    text(x0 + 8, y1 - 18, format(dates[i], "%Y-%m-%d"), adj = 0, col = "white", font = 2, cex = 0.9)
  }
  out_file
}

read_eskom_joinable_dates <- function() {
  if (!file.exists(ESKOM_HOURLY)) return(as.Date(character()))
  eskom <- fread(ESKOM_HOURLY)
  ts_col <- "Date Time Hour Beginning"
  if (!(ts_col %in% names(eskom))) return(as.Date(character()))
  eskom[, date := as.Date(substr(as.character(get(ts_col)), 1, 10))]
  eskom[, hour := as.integer(substr(as.character(get(ts_col)), 12, 13))]
  sort(unique(eskom[hour == 1L, date]))
}

retained_summary <- function(metrics) {
  joinable_dates <- read_eskom_joinable_dates()
  scenarios <- list(
    all_observed = metrics$date,
    exclude_high_review = metrics[review_tier != "high_review", date],
    exclude_medium_or_high_review = metrics[review_tier == "normal_review", date]
  )
  rows <- rbindlist(lapply(names(scenarios), function(scenario) {
    dates <- sort(unique(scenarios[[scenario]]))
    local_overpass <- dates + 1L
    by_month <- data.table(date = dates)[, .N, by = .(month = format(date, "%Y-%m"))]
    min_monthly <- if (nrow(by_month) == 0L) NA_integer_ else min(by_month$N)
    data.table(
      scenario = scenario,
      n_vj_product_dates_retained = length(dates),
      n_eskom_1_2am_joinable_retained = sum(local_overpass %in% joinable_dates),
      min_monthly_retained_dates = min_monthly,
      warn_below_300_year = length(dates) < 300,
      warn_below_15_any_month = is.finite(min_monthly) && min_monthly < 15
    )
  }), use.names = TRUE)
  rows
}

log_step("Repository root:", BASE_PATH)
log_step("Daily rasters:", nrow(file_tbl), "| missing expected dates:", length(missing_dates))
log_step("Output:", OUT_DIR)

template <- terra::rast(file_tbl$raster_file[1])
annual <- align_annual_reference(template)
outline <- zaf_outline()

metrics <- NULL
if (REUSE_METRICS && file.exists(OUT_DAILY)) {
  candidate <- fread(OUT_DAILY)
  candidate[, date := as.Date(date)]
  candidate_dates <- sort(format(candidate$date, "%Y-%m-%d"))
  raster_dates <- sort(format(as.Date(file_tbl$date), "%Y-%m-%d"))
  if (nrow(candidate) == nrow(file_tbl) && identical(candidate_dates, raster_dates)) {
    log_step("Reusing existing full metrics:", OUT_DAILY)
    metrics <- candidate
  } else {
    log_step(
      "Existing metrics do not match current date set; recomputing.",
      sprintf("rows %d/%d; date set match: %s", nrow(candidate), nrow(file_tbl), identical(candidate_dates, raster_dates))
    )
  }
}

if (is.null(metrics)) {
  metric_rows <- vector("list", nrow(file_tbl))
  for (i in seq_len(nrow(file_tbl))) {
    d <- file_tbl$date[i]
    log_step("Scoring", format(d, "%Y-%m-%d"), sprintf("(%d/%d)", i, nrow(file_tbl)))
    metric_rows[[i]] <- compute_daily_metrics(file_tbl$raster_file[i], d, annual)
  }

  metrics <- rbindlist(metric_rows, use.names = TRUE, fill = TRUE)
  metrics <- add_review_tiers(metrics)
}
if (!("review_tier" %in% names(metrics))) metrics <- add_review_tiers(metrics)
setorder(metrics, date)
fwrite(metrics, OUT_DAILY)
log_step("Wrote daily metrics:", OUT_DAILY)

suspects <- copy(metrics)
setorder(suspects, -composite_score, date)
fwrite(suspects, OUT_SUSPECT)
log_step("Wrote suspect-day ranking:", OUT_SUSPECT)

retained <- retained_summary(metrics)
fwrite(retained, OUT_RETAINED)
log_step("Wrote retained-day counts:", OUT_RETAINED)

frame_manifest <- metrics[, .(date, frame_png = NA_character_)]
if (WRITE_FRAMES) {
  frames <- character(nrow(metrics))
  for (i in seq_len(nrow(metrics))) {
    d <- metrics$date[i]
    expected_frame <- frame_path_for_date(d)
    if (REUSE_FRAMES && file.exists(expected_frame)) {
      log_step("Reusing frame", format(d, "%Y-%m-%d"), sprintf("(%d/%d)", i, nrow(metrics)))
      frames[i] <- expected_frame
      next
    }
    log_step("Rendering frame", format(d, "%Y-%m-%d"), sprintf("(%d/%d)", i, nrow(metrics)))
    daily <- terra::rast(metrics$raster_file[i])
    frames[i] <- render_frame(daily, annual, d, metrics[i], outline)
  }
  frame_manifest[, frame_png := frames]
  fwrite(frame_manifest, OUT_FRAME_MANIFEST)
  log_step("Wrote frame manifest:", OUT_FRAME_MANIFEST)

  if (length(frames) > 0L) {
    gifski::gifski(
      png_files = frames,
      gif_file = OUT_FULL_GIF,
      width = 2100,
      height = 1180,
      delay = 1 / GIF_FPS,
      loop = 0,
      progress = TRUE
    )
    log_step("Wrote full-year GIF:", OUT_FULL_GIF)

    frame_manifest[, month := format(date, "%Y-%m")]
    for (m in sort(unique(frame_manifest$month))) {
      sub <- frame_manifest[month == m & file.exists(frame_png)]
      if (nrow(sub) == 0L) next
      month_gif <- file.path(OUT_DIR, paste0("vj146a2_sa_daily_binary_", m, ".gif"))
      gifski::gifski(
        png_files = sub$frame_png,
        gif_file = month_gif,
        width = 2100,
        height = 1180,
        delay = 1 / GIF_FPS,
        loop = 0,
        progress = FALSE
      )
      log_step("Wrote monthly GIF:", month_gif)
    }

    contact_specs <- list(
      top_composite_score = head(metrics[order(-composite_score)], 12L),
      top_excess_lit = head(metrics[order(-excess_lit_share)], 12L),
      top_excess_dark = head(metrics[order(-excess_dark_share)], 12L),
      top_radiance_positive = head(metrics[order(-residual_log_p95)], 12L),
      lowest_valid_share = head(metrics[order(valid_share)], 12L)
    )
    for (nm in names(contact_specs)) {
      sub <- merge(
        contact_specs[[nm]][, .(date)],
        frame_manifest[, .(date, frame_png)],
        by = "date",
        all.x = TRUE,
        sort = FALSE
      )
      out <- file.path(CONTACT_DIR, paste0("vj146a2_", YEAR_LABEL, "_", nm, "_contact_sheet.png"))
      write_contact_sheet(nm, sub$frame_png, sub$date, out)
      log_step("Wrote contact sheet:", out)
    }
  }
} else {
  fwrite(frame_manifest, OUT_FRAME_MANIFEST)
}

log_step("Done.")
