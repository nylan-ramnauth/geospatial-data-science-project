rm(list = ls())

# ============================================================
# Moretele binary-lit close-up + South Africa locator GIF frames
# Diagnostic/trial path only. Does not touch production VNP files.
# ============================================================
#
# Purpose: Render one PNG per October 2023 observed day for Moretele settlement
#          70001. Each frame has:
#          - left: binary lit close-up around the settlement contour;
#          - right: full South Africa binary lit view with a red square showing
#            the close-up location.
# Output:  PNG frames plus frame metrics/manifest CSVs. GIF assembly is done by
#          Python/Pillow after this script renders frames.
# Run:     Rscript Builder/Others/vj146a2_moretele_binary_lit_sa_gif.R
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(sf)
  library(terra)
  library(arrow)
  library(dplyr)
})

sf::sf_use_s2(FALSE)

BASE_PATH <- here::here()
SETTLEMENT_ID <- "70001"
SETTLEMENT_LABEL <- "Moretele Local Municipality"
PIXEL_LIT_THRESHOLD <- 1.0
SQUARE_MARGIN_DEG <- 0.035

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
  "moretele_binary_lit_month"
)

FRAME_DIR <- file.path(OUT_DIR, "frames")
dir.create(FRAME_DIR, recursive = TRUE, showWarnings = FALSE)

OUT_METRICS <- file.path(OUT_DIR, "moretele_70001_binary_lit_frame_metrics.csv")
OUT_MANIFEST <- file.path(OUT_DIR, "moretele_70001_binary_lit_frame_manifest.csv")

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
  select("date", "p_lit_sett", "coverage", "mean_rad_sett", "median_rad_sett")

if (nrow(panel) == 0) stop("No panel rows for settlement ", SETTLEMENT_ID)

raster_for_date <- function(date) {
  f <- file.path(RAST_DIR, paste0("vj146a2_sa_500m_daily_", format(date, "%Y-%m-%d"), ".tif"))
  if (!file.exists(f)) stop("Raster missing for date ", date, ": ", f)
  f
}

square_extent <- function(poly, margin = SQUARE_MARGIN_DEG) {
  bb <- sf::st_bbox(poly)
  cx <- mean(as.numeric(c(bb["xmin"], bb["xmax"])))
  cy <- mean(as.numeric(c(bb["ymin"], bb["ymax"])))
  width <- as.numeric(bb["xmax"] - bb["xmin"])
  height <- as.numeric(bb["ymax"] - bb["ymin"])
  side <- max(width, height) + 2 * margin
  terra::ext(cx - side / 2, cx + side / 2, cy - side / 2, cy + side / 2)
}

LOCATOR_EXT <- square_extent(sett)

classify_binary_lit <- function(r) {
  if (!all(c("rad", "valid") %in% names(r))) {
    stop("Raster missing rad/valid bands")
  }
  rad <- r[["rad"]]
  valid <- r[["valid"]]
  lit_class <- terra::ifel(valid == 1 & !is.na(rad) & rad > PIXEL_LIT_THRESHOLD, 2, NA)
  lit_class <- terra::ifel(valid == 1 & !is.na(rad) & rad <= PIXEL_LIT_THRESHOLD, 1, lit_class)
  names(lit_class) <- "binary_lit"
  lit_class
}

fmt <- function(x, digits = 3) {
  ifelse(is.na(x), "NA", format(round(x, digits), nsmall = digits))
}

plot_binary <- function(layer, title, axes = TRUE) {
  terra::plot(
    layer,
    col = c("#24103f", "#ffd84d"),
    breaks = c(0.5, 1.5, 2.5),
    colNA = "#8f8f8f",
    main = title,
    axes = axes,
    legend = FALSE
  )
}

render_frame <- function(i) {
  d <- panel$date[i]
  m <- panel[i, ]
  r <- terra::rast(raster_for_date(d))
  full_class <- classify_binary_lit(r)
  close_class <- terra::crop(full_class, LOCATOR_EXT)

  out_png <- file.path(
    FRAME_DIR,
    sprintf("moretele_70001_binary_lit_sa_%s.png", format(d, "%Y-%m-%d"))
  )

  png(out_png, width = 2100, height = 1050, res = 150)
  old_par <- par(no.readonly = TRUE)
  on.exit({
    par(old_par)
    dev.off()
  }, add = TRUE)

  layout(matrix(c(1, 2), nrow = 1), widths = c(1.08, 1))
  par(oma = c(0.4, 0.4, 4.8, 0.4))

  par(mar = c(3.2, 3.2, 4.0, 1.2))
  plot_binary(
    close_class,
    title = paste0(
      "Close-up binary lit\n",
      "p_lit=", fmt(m$p_lit_sett, 3),
      " cov=", fmt(m$coverage, 3),
      " mean=", fmt(m$mean_rad_sett, 2),
      " median=", fmt(m$median_rad_sett, 2)
    )
  )
  plot(sf::st_geometry(sett), add = TRUE, border = "#33d1ff", lwd = 2.8)

  par(mar = c(3.2, 3.2, 4.0, 1.2))
  plot_binary(full_class, title = "South Africa binary lit")
  rect(
    terra::xmin(LOCATOR_EXT),
    terra::ymin(LOCATOR_EXT),
    terra::xmax(LOCATOR_EXT),
    terra::ymax(LOCATOR_EXT),
    border = "#ff2b2b",
    lwd = 3.2
  )
  points(
    mean(c(terra::xmin(LOCATOR_EXT), terra::xmax(LOCATOR_EXT))),
    mean(c(terra::ymin(LOCATOR_EXT), terra::ymax(LOCATOR_EXT))),
    pch = 3,
    col = "#ff2b2b",
    lwd = 2.4,
    cex = 1.1
  )

  title(
    main = paste0(
      SETTLEMENT_LABEL,
      " binary lit stability - ",
      format(d, "%Y-%m-%d"),
      " | threshold rad > ",
      PIXEL_LIT_THRESHOLD
    ),
    outer = TRUE,
    line = 2.6,
    cex.main = 1.15
  )
  mtext(
    "Purple = unlit (rad <= 1), yellow = lit (rad > 1), grey = invalid/missing; red square locates the close-up on the national map.",
    outer = TRUE,
    side = 1,
    line = -0.2,
    cex = 0.82
  )

  out_png
}

frames <- vapply(seq_len(nrow(panel)), render_frame, character(1))

frame_metrics <- panel %>%
  mutate(
    settlement_id = SETTLEMENT_ID,
    settlement_label = SETTLEMENT_LABEL,
    pixel_lit_threshold = PIXEL_LIT_THRESHOLD,
    locator_xmin = terra::xmin(LOCATOR_EXT),
    locator_xmax = terra::xmax(LOCATOR_EXT),
    locator_ymin = terra::ymin(LOCATOR_EXT),
    locator_ymax = terra::ymax(LOCATOR_EXT),
    frame_png = frames
  ) %>%
  select(
    "settlement_id",
    "settlement_label",
    "date",
    "p_lit_sett",
    "coverage",
    "mean_rad_sett",
    "median_rad_sett",
    "pixel_lit_threshold",
    "locator_xmin",
    "locator_xmax",
    "locator_ymin",
    "locator_ymax",
    "frame_png"
  )

if (requireNamespace("readr", quietly = TRUE)) {
  readr::write_csv(frame_metrics, OUT_METRICS)
  readr::write_csv(tibble::tibble(frame_png = frames), OUT_MANIFEST)
} else {
  write.csv(frame_metrics, OUT_METRICS, row.names = FALSE)
  write.csv(data.frame(frame_png = frames), OUT_MANIFEST, row.names = FALSE)
}

message("Wrote ", length(frames), " Moretele binary-lit side-by-side frames to: ", FRAME_DIR)
message("Wrote metrics: ", OUT_METRICS)
message("Wrote manifest: ", OUT_MANIFEST)
