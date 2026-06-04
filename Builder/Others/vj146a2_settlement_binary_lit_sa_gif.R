rm(list = ls())

# ============================================================
# VJ146A2 binary-lit close-up + South Africa locator GIF frames
# Diagnostic/trial path only. Does not touch production VNP files.
# ============================================================
#
# Purpose: Render one PNG per observed day for one settlement and optionally
#          assemble those frames into a GIF.
#          Each frame has:
#          - left: binary lit close-up around the settlement contour;
#          - right: full South Africa binary lit view with a red square showing
#            the close-up location.
#
# Required environment variables for non-default runs:
#   SETTLEMENT_ID     e.g. 69888
#   SETTLEMENT_LABEL  e.g. Nkomazi
#   SETTLEMENT_SLUG   e.g. nkomazi
#
# Optional environment variables:
#   YEAR_MONTH       e.g. 2023-10
#   SQUARE_MARGIN_DEG e.g. 0.035
#   LIT_THRESHOLD    e.g. 1
#   CREATE_GIF       TRUE/FALSE
#   GIF_DELAY        seconds per frame, e.g. 0.9
#   RAST_DIR         override raster directory
#   SETT_PANEL       override settlement-day parquet
#   ESKOM_HOURLY     override Eskom hourly CSV
#   OUT_ROOT         override output root
#
# Example:
#   YEAR_MONTH=2023-10 SETTLEMENT_ID=69888 SETTLEMENT_LABEL=Nkomazi SETTLEMENT_SLUG=nkomazi \
#     Rscript Builder/Others/vj146a2_settlement_binary_lit_sa_gif.R
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(sf)
  library(terra)
  library(arrow)
  library(dplyr)
})

sf::sf_use_s2(FALSE)

env_or_default <- function(name, default) {
  value <- Sys.getenv(name)
  if (nzchar(value)) value else default
}

BASE_PATH <- here::here()
VAULT_PATH <- normalizePath(file.path(BASE_PATH, "..", "..", ".."), mustWork = TRUE)
YEAR_MONTH <- env_or_default("YEAR_MONTH", "2023-10")
SETTLEMENT_ID <- env_or_default("SETTLEMENT_ID", "70001")
SETTLEMENT_LABEL <- env_or_default("SETTLEMENT_LABEL", "Moretele Local Municipality")
SETTLEMENT_SLUG <- env_or_default("SETTLEMENT_SLUG", "moretele")
PIXEL_LIT_THRESHOLD <- as.numeric(env_or_default("LIT_THRESHOLD", "1"))
SQUARE_MARGIN_DEG <- as.numeric(env_or_default("SQUARE_MARGIN_DEG", "0.035"))
CREATE_GIF <- toupper(env_or_default("CREATE_GIF", "TRUE")) %in% c("1", "TRUE", "YES", "Y")
GIF_DELAY <- as.numeric(env_or_default("GIF_DELAY", "0.9"))

month_start <- as.Date(paste0(YEAR_MONTH, "-01"))
if (is.na(month_start)) stop("YEAR_MONTH must be YYYY-MM, got: ", YEAR_MONTH)
month_end <- seq(month_start, length = 2, by = "month")[2] - 1

DEFAULT_RAST_DIR <- file.path(
  BASE_PATH,
  "blackmarbler",
  "out_vnp46a2_sa_daily",
  "qa_straylight_validation",
  paste0("vj146a2_month_", YEAR_MONTH),
  "rasters"
)
RAST_DIR <- env_or_default("RAST_DIR", DEFAULT_RAST_DIR)

SETT_GPKG <- file.path(
  BASE_PATH,
  "Map Data",
  "Settlements",
  "GPKG",
  "south_africa_dre_atlas_settlements_full_col.gpkg"
)

DEFAULT_SETT_PANEL <- file.path(
  BASE_PATH,
  "Map Data",
  "settlement_day_outputs_vj146a2",
  paste0("settlement_day_vj146a2_cov_yearlykeep_", YEAR_MONTH, ".parquet")
)
SETT_PANEL <- env_or_default("SETT_PANEL", DEFAULT_SETT_PANEL)

DEFAULT_ESKOM_HOURLY <- file.path(
  VAULT_PATH,
  "6-codebases",
  "repos",
  "pypsa-earth",
  "data",
  "za_validation",
  "eskom_2023_hourly_clean.csv"
)
ESKOM_HOURLY <- env_or_default("ESKOM_HOURLY", DEFAULT_ESKOM_HOURLY)

DEFAULT_OUT_ROOT <- file.path(
  BASE_PATH,
  "Map Data",
  "settlement_day_outputs_vj146a2",
  "pixel_closeups",
  "binary_lit_sa_locator"
)
OUT_ROOT <- env_or_default("OUT_ROOT", DEFAULT_OUT_ROOT)
OUT_DIR <- file.path(OUT_ROOT, YEAR_MONTH, paste0(SETTLEMENT_SLUG, "_", SETTLEMENT_ID))

FRAME_DIR <- file.path(OUT_DIR, "frames")
dir.create(FRAME_DIR, recursive = TRUE, showWarnings = FALSE)

OUT_STEM <- paste0(SETTLEMENT_SLUG, "_", SETTLEMENT_ID, "_binary_lit")
OUT_METRICS <- file.path(OUT_DIR, paste0(OUT_STEM, "_frame_metrics.csv"))
OUT_MANIFEST <- file.path(OUT_DIR, paste0(OUT_STEM, "_frame_manifest.csv"))
OUT_GIF <- file.path(OUT_DIR, paste0(OUT_STEM, "_closeup_sa_", YEAR_MONTH, ".gif"))

stopifnot(file.exists(RAST_DIR), file.exists(SETT_GPKG), file.exists(SETT_PANEL), file.exists(ESKOM_HOURLY))

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

eskom <- read.csv(ESKOM_HOURLY, check.names = FALSE)
eskom$datetime_text <- as.character(eskom[["Date Time Hour Beginning"]])
if (any(!grepl("^\\d{4}-\\d{2}-\\d{2} \\d{2}:", eskom$datetime_text))) {
  stop("Unexpected Eskom timestamp format in: ", ESKOM_HOURLY)
}

eskom_hourly_month <- eskom %>%
  mutate(
    # The Eskom file is hour-beginning in SAST. Parse date/hour from text to
    # avoid POSIX timezone conversion shifting midnight rows to the prior date.
    date = as.Date(substr(.data$datetime_text, 1, 10)),
    hour = as.integer(substr(.data$datetime_text, 12, 13))
  ) %>%
  filter(.data$date >= month_start, .data$date <= month_end, .data$hour %in% c(0, 1)) %>%
  select(
    "date",
    "hour",
    "Manual Load_Reduction(MLR)",
    "RSA Contracted Demand",
    "Residual Demand"
  )

eskom_daily <- eskom_hourly_month %>%
  group_by(.data$date) %>%
  summarise(
    n_eskom_hours_00_02 = n(),
    mlr_00_01_mw = {
      x <- `Manual Load_Reduction(MLR)`[hour == 0]
      if (length(x) == 0) NA_real_ else x[1]
    },
    mlr_01_02_mw = {
      x <- `Manual Load_Reduction(MLR)`[hour == 1]
      if (length(x) == 0) NA_real_ else x[1]
    },
    contracted_demand_00_01_mw = {
      x <- `RSA Contracted Demand`[hour == 0]
      if (length(x) == 0) NA_real_ else x[1]
    },
    contracted_demand_01_02_mw = {
      x <- `RSA Contracted Demand`[hour == 1]
      if (length(x) == 0) NA_real_ else x[1]
    },
    residual_demand_00_01_mw = {
      x <- `Residual Demand`[hour == 0]
      if (length(x) == 0) NA_real_ else x[1]
    },
    residual_demand_01_02_mw = {
      x <- `Residual Demand`[hour == 1]
      if (length(x) == 0) NA_real_ else x[1]
    },
    .groups = "drop"
  )

panel <- panel %>%
  left_join(eskom_daily, by = "date")

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
    sprintf("%s_sa_%s.png", OUT_STEM, format(d, "%Y-%m-%d"))
  )

  png(out_png, width = 2100, height = 1180, res = 150)
  old_par <- par(no.readonly = TRUE)
  on.exit({
    par(old_par)
    dev.off()
  }, add = TRUE)

  layout(matrix(c(1, 2), nrow = 1), widths = c(1.08, 1))
  par(oma = c(1.3, 0.4, 5.8, 0.4))

  par(mar = c(3.2, 3.2, 2.8, 1.2))
  plot_binary(
    close_class,
    title = paste0(
      "Close-up | p_lit=", fmt(m$p_lit_sett, 3),
      " cov=", fmt(m$coverage, 3),
      " mean=", fmt(m$mean_rad_sett, 2),
      " median=", fmt(m$median_rad_sett, 2)
    )
  )
  plot(sf::st_geometry(sett), add = TRUE, border = "#33d1ff", lwd = 2.8)

  par(mar = c(3.2, 3.2, 2.8, 1.2))
  plot_binary(full_class, title = "South Africa locator")
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
    line = 3.2,
    cex.main = 1.08
  )
  mtext(
    paste0(
      "Eskom MLR: 00-01=",
      fmt(m$mlr_00_01_mw[1], 1),
      " MW | 01-02=",
      fmt(m$mlr_01_02_mw[1], 1),
      " MW"
    ),
    outer = TRUE,
    side = 3,
    line = 2.05,
    cex = 0.9
  )
  mtext(
    "Purple = unlit (rad <= 1), yellow = lit (rad > 1), grey = invalid/missing; red square locates the close-up on the national map.",
    outer = TRUE,
    side = 1,
    line = 0.2,
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
    "mlr_00_01_mw",
    "mlr_01_02_mw",
    "contracted_demand_00_01_mw",
    "contracted_demand_01_02_mw",
    "residual_demand_00_01_mw",
    "residual_demand_01_02_mw",
    "n_eskom_hours_00_02",
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

message("Wrote ", length(frames), " binary-lit side-by-side frames to: ", FRAME_DIR)
message("Wrote metrics: ", OUT_METRICS)
message("Wrote manifest: ", OUT_MANIFEST)

if (CREATE_GIF) {
  if (!requireNamespace("gifski", quietly = TRUE)) {
    stop("CREATE_GIF=TRUE requires the R package gifski.")
  }
  gifski::gifski(
    png_files = frames,
    gif_file = OUT_GIF,
    width = 2100,
    height = 1180,
    delay = GIF_DELAY,
    loop = 0
  )
  message("Wrote GIF: ", OUT_GIF)
}
