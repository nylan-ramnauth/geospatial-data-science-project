rm(list = ls())

# ============================================================
# Moretele raw-radiance month diagnostic GIF frames
# Diagnostic/trial path only. Does not touch production VNP files.
# ============================================================
#
# Purpose:  Render one raw VJ146A2 radiance close-up PNG per October 2023
#           day retained in the settlement-day panel for Moretele settlement
#           70001, using one fixed radiance color scale.
# Output:   PNG frames plus a frame metrics CSV. GIF assembly is done by
#           Python/Pillow after this script renders frames.
# Run:      Rscript Builder/Others/vj146a2_moretele_raw_radiance_month_gif.R
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(sf)
  library(terra)
  library(arrow)
  library(dplyr)
  library(viridisLite)
})

sf::sf_use_s2(FALSE)

BASE_PATH <- here::here()
SETTLEMENT_ID <- "70001"
SETTLEMENT_LABEL <- "Moretele Local Municipality"
MONTH_LABEL <- "2023-10"
PLOT_MARGIN_DEG <- 0.035
RADIANCE_CAP_QUANTILE <- 0.99

RAST_DIR <- file.path(
  BASE_PATH,
  "blackmarbler",
  "out_vnp46a2_sa_daily",
  "qa_straylight_validation",
  "vj146a2_month_2023-10",
  "rasters"
)

SETT_GPKG <- file.path(
  BASE_PATH,
  "Map Data",
  "Settlements",
  "GPKG",
  "south_africa_dre_atlas_settlements_full_col.gpkg"
)

SETT_PANEL <- file.path(
  BASE_PATH,
  "Map Data",
  "settlement_day_outputs_vj146a2",
  "settlement_day_vj146a2_cov_yearlykeep_2023-10.parquet"
)

OUT_DIR <- file.path(
  BASE_PATH,
  "Map Data",
  "settlement_day_outputs_vj146a2",
  "pixel_closeups",
  "moretele_raw_radiance_month"
)

FRAME_DIR <- file.path(OUT_DIR, "frames")
dir.create(FRAME_DIR, recursive = TRUE, showWarnings = FALSE)

OUT_METRICS <- file.path(OUT_DIR, "moretele_70001_raw_radiance_frame_metrics.csv")
OUT_MANIFEST <- file.path(OUT_DIR, "moretele_70001_raw_radiance_frame_manifest.csv")

stopifnot(file.exists(RAST_DIR), file.exists(SETT_GPKG), file.exists(SETT_PANEL))

sett <- sf::st_read(SETT_GPKG, quiet = TRUE) %>%
  mutate(settlement_id = as.character(settlement_id)) %>%
  filter(.data$settlement_id == SETTLEMENT_ID) %>%
  st_make_valid()

if (nrow(sett) != 1) stop("Expected one settlement polygon for ", SETTLEMENT_ID)

panel <- arrow::read_parquet(SETT_PANEL) %>%
  mutate(
    settlement_id = as.character(.data$settlement_id),
    date = as.Date(.data$date)
  ) %>%
  filter(.data$settlement_id == SETTLEMENT_ID) %>%
  arrange(.data$date) %>%
  select(
    .data$date,
    .data$p_lit_sett,
    .data$coverage,
    .data$mean_rad_sett,
    .data$median_rad_sett
  )

if (nrow(panel) == 0) stop("No panel rows for settlement ", SETTLEMENT_ID)

raster_for_date <- function(date) {
  f <- file.path(RAST_DIR, paste0("vj146a2_sa_500m_daily_", format(date, "%Y-%m-%d"), ".tif"))
  if (!file.exists(f)) stop("Raster missing for date ", date, ": ", f)
  f
}

extend_bbox <- function(poly, margin = PLOT_MARGIN_DEG) {
  bb <- sf::st_bbox(poly)
  width <- as.numeric(bb["xmax"] - bb["xmin"])
  height <- as.numeric(bb["ymax"] - bb["ymin"])
  pad_x <- max(margin, width * 0.25)
  pad_y <- max(margin, height * 0.25)
  terra::ext(
    as.numeric(bb["xmin"] - pad_x),
    as.numeric(bb["xmax"] + pad_x),
    as.numeric(bb["ymin"] - pad_y),
    as.numeric(bb["ymax"] + pad_y)
  )
}

crop_ext <- extend_bbox(sett)

crop_raw_rad <- function(date) {
  r <- terra::rast(raster_for_date(date))
  if (!"rad" %in% names(r)) stop("Raster missing rad band: ", raster_for_date(date))
  rad <- terra::crop(r[["rad"]], crop_ext)
  names(rad) <- "raw_radiance"
  rad
}

rad_layers <- lapply(panel$date, crop_raw_rad)
names(rad_layers) <- format(panel$date, "%Y-%m-%d")

all_values <- unlist(lapply(rad_layers, function(r) terra::values(r, mat = FALSE)), use.names = FALSE)
all_values <- all_values[is.finite(all_values)]
if (length(all_values) == 0) stop("No finite raw-radiance pixels in Moretele crops")

rad_cap <- as.numeric(stats::quantile(all_values, probs = RADIANCE_CAP_QUANTILE, na.rm = TRUE))
rad_cap <- max(rad_cap, 1)
rad_breaks <- seq(0, rad_cap, length.out = 101)
rad_cols <- viridisLite::inferno(length(rad_breaks) - 1)

fmt <- function(x, digits = 3) {
  ifelse(is.na(x), "NA", format(round(x, digits), nsmall = digits))
}

render_frame <- function(i) {
  d <- panel$date[i]
  rad <- rad_layers[[i]]
  m <- panel[i, ]
  out_png <- file.path(
    FRAME_DIR,
    sprintf("moretele_70001_raw_radiance_%s.png", format(d, "%Y-%m-%d"))
  )

  png(out_png, width = 1500, height = 1100, res = 150)
  old_par <- par(no.readonly = TRUE)
  on.exit({
    par(old_par)
    dev.off()
  }, add = TRUE)

  par(mar = c(3.2, 3.2, 6.4, 1.4))
  terra::plot(
    rad,
    col = rad_cols,
    breaks = rad_breaks,
    colNA = "#8f8f8f",
    main = paste0(
      SETTLEMENT_LABEL,
      " raw radiance - ",
      format(d, "%Y-%m-%d"),
      "\np_lit=", fmt(m$p_lit_sett, 3),
      " cov=", fmt(m$coverage, 3),
      " mean=", fmt(m$mean_rad_sett, 2),
      " median=", fmt(m$median_rad_sett, 2),
      " | fixed p99 cap=", fmt(rad_cap, 2)
    ),
    axes = TRUE,
    legend = FALSE,
    cex.main = 0.95
  )
  plot(sf::st_geometry(sett), add = TRUE, border = "#33d1ff", lwd = 2.8)
  mtext(
    "Raw radiance color scale is fixed across frames; grey = missing/invalid raw radiance.",
    side = 1,
    line = 2.2,
    cex = 0.78
  )

  out_png
}

frames <- vapply(seq_len(nrow(panel)), render_frame, character(1))

frame_metrics <- panel %>%
  mutate(
    settlement_id = SETTLEMENT_ID,
    settlement_label = SETTLEMENT_LABEL,
    raw_radiance_cap_p99 = rad_cap,
    frame_png = frames
  ) %>%
  select(
    .data$settlement_id,
    .data$settlement_label,
    .data$date,
    .data$p_lit_sett,
    .data$coverage,
    .data$mean_rad_sett,
    .data$median_rad_sett,
    .data$raw_radiance_cap_p99,
    .data$frame_png
  )

if (requireNamespace("readr", quietly = TRUE)) {
  readr::write_csv(frame_metrics, OUT_METRICS)
  readr::write_csv(tibble::tibble(frame_png = frames), OUT_MANIFEST)
} else {
  write.csv(frame_metrics, OUT_METRICS, row.names = FALSE)
  write.csv(data.frame(frame_png = frames), OUT_MANIFEST, row.names = FALSE)
}

message("Wrote ", length(frames), " Moretele raw-radiance frames to: ", FRAME_DIR)
message("Wrote metrics: ", OUT_METRICS)
message("Wrote manifest: ", OUT_MANIFEST)
message("Radiance fixed p99 cap: ", round(rad_cap, 3))
