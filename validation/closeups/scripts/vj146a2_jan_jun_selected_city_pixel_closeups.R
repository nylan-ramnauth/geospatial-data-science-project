rm(list = ls())

# ============================================================
# VJ146A2 Jan-Jun selected-city pixel close-ups
# ============================================================
#
# Purpose: Render raw-pixel close-ups and satellite context tiles
#          for five Jan-Jun 2023 VJ146A2 large-settlement dark events.
#          This mirrors the October close-up notebook, but uses only
#          Jan-Jun candidate events.
# Output:  PNG panels plus event-window, Jan-Jun benchmark, and location CSVs.
# Run:     Rscript validation/closeups/scripts/vj146a2_jan_jun_selected_city_pixel_closeups.R
# ============================================================

suppressPackageStartupMessages({
  library(sf)
  library(terra)
  library(arrow)
  library(dplyr)
})

sf::sf_use_s2(FALSE)

script_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
if (length(script_arg) > 0) {
  SCRIPT_PATH <- normalizePath(sub("^--file=", "", script_arg[[1]]))
} else {
  SCRIPT_PATH <- normalizePath("validation/closeups/scripts/vj146a2_jan_jun_selected_city_pixel_closeups.R")
}

REPO_ROOT <- normalizePath(file.path(dirname(SCRIPT_PATH), "..", "..", ".."), mustWork = TRUE)
source(file.path(REPO_ROOT, "validation", "scripts", "validation_paths.R"))
paths <- validation_paths(REPO_ROOT, "closeups")
RA_ROOT <- paths$repo_root

RAST_DIR <- file.path(RA_ROOT, "blackmarbler", "out_vj146a2_sa_daily")

SETT_GPKG <- file.path(
  RA_ROOT,
  "Map Data",
  "Settlements",
  "GPKG",
  "south_africa_dre_atlas_settlements_full_col.gpkg"
)

PANEL_DIR <- file.path(RA_ROOT, "Map Data", "settlement_day_outputs_vj146a2")

SETT_PANEL_FILES <- file.path(
  PANEL_DIR,
  sprintf("settlement_day_vj146a2_cov_yearlykeep_2023-%02d.parquet", 1:6)
)

ESKOM_PANEL <- file.path(
  PANEL_DIR,
  "mlr_validation_2023-01_to_2023-06",
  "vj146a2_2023_mlr_validation_daily_panel.csv"
)

OUT_DIR <- file.path(
  paths$figures_dir,
  "generated",
  "vj146a2_jan_jun_selected_city_pixel_closeups"
)

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

OUT_METRICS <- file.path(OUT_DIR, "vj146a2_jan_jun_selected_city_event_window_metrics.csv")
OUT_ANALYSIS <- file.path(OUT_DIR, "vj146a2_jan_jun_selected_city_analysis_metrics.csv")
OUT_LOCATIONS <- file.path(OUT_DIR, "vj146a2_jan_jun_selected_city_locations.csv")

EVENTS <- tibble::tribble(
  ~settlement_id, ~event_date,   ~label,                                  ~event_class,   ~selection_reason,
  "30250",        "2023-03-10",  "Maluti-a-Phofung Local Municipality",   "strict dark",  "Largest Jan-Jun strict-dark candidate above 100k population; high MLR and acceptable coverage.",
  "76354",        "2023-05-25",  "Bushbuckridge",                         "strict dark",  "Strict-dark candidate above 100k with full coverage and low national shed share; useful artifact/local-outage check.",
  "73644",        "2023-05-19",  "Polokwane Local Municipality",          "strict dark",  "Strict-dark candidate above 100k with full coverage and a large drop from a high Jan-Jun median.",
  "69888",        "2023-04-17",  "Nkomazi",                               "mostly dark",  "Very large mostly-dark candidate with full coverage, high baseline p_lit, and high Eskom shed share.",
  "61860",        "2023-01-23",  "Thembisile Hani Local Municipality",    "mostly dark",  "Largest Thembisile Hani Jan-Jun candidate; full coverage and large drop from a high Jan-Jun median."
) %>%
  mutate(event_date = as.Date(event_date))

PIXEL_LIT_THRESHOLD <- 1.0
PLOT_MARGIN_DEG <- 0.035
INVALID_PIXEL_COL <- "#8f8f8f"
SATELLITE_ZOOM_DEFAULT <- as.integer(Sys.getenv("VJ_CLOSEUP_SATELLITE_ZOOM", "14"))
SATELLITE_MAX_TILES <- as.integer(Sys.getenv("VJ_CLOSEUP_SATELLITE_MAX_TILES", "64"))
SATELLITE_MARGIN_DEG <- 0.004
SATELLITE_MARGIN_FRACTION <- 0.06
SATELLITE_TILE_URL <- "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/%d/%d/%d"
SATELLITE_TILE_CACHE <- file.path(OUT_DIR, "satellite_tile_cache")

stopifnot(file.exists(RAST_DIR), file.exists(SETT_GPKG), all(file.exists(SETT_PANEL_FILES)), file.exists(ESKOM_PANEL))
stopifnot(requireNamespace("curl", quietly = TRUE), requireNamespace("jpeg", quietly = TRUE))
dir.create(SATELLITE_TILE_CACHE, recursive = TRUE, showWarnings = FALSE)

sett <- sf::st_read(SETT_GPKG, quiet = TRUE) %>%
  mutate(settlement_id = as.character(settlement_id)) %>%
  filter(.data$settlement_id %in% EVENTS$settlement_id) %>%
  st_make_valid()

if (nrow(sett) != length(unique(EVENTS$settlement_id))) {
  stop("Could not load all selected settlement polygons from ", SETT_GPKG)
}

sett_panel <- bind_rows(lapply(SETT_PANEL_FILES, arrow::read_parquet)) %>%
  mutate(
    settlement_id = as.character(.data$settlement_id),
    date = as.Date(.data$date)
  ) %>%
  filter(.data$settlement_id %in% EVENTS$settlement_id)

eskom_panel <- read.csv(ESKOM_PANEL) %>%
  mutate(date = as.Date(.data$vj_product_date)) %>%
  select(
    date,
    local_overpass_date,
    mlr_mean_1_2am_primary,
    shed_share_1_2am_primary,
    mlr_mean_0_1am,
    shed_share_0_1am,
    mlr_mean_2_3am,
    shed_share_2_3am
  )

raster_for_date <- function(date) {
  date <- as.Date(date, origin = "1970-01-01")
  f <- file.path(RAST_DIR, paste0("vj146a2_sa_500m_daily_", format(date, "%Y-%m-%d"), ".tif"))
  if (!file.exists(f)) stop("Raster missing for date ", date, ": ", f)
  f
}

extend_bbox <- function(poly, margin = PLOT_MARGIN_DEG, fraction = 0.25) {
  bb <- st_bbox(poly)
  width <- as.numeric(bb["xmax"] - bb["xmin"])
  height <- as.numeric(bb["ymax"] - bb["ymin"])
  pad_x <- max(margin, width * fraction)
  pad_y <- max(margin, height * fraction)
  terra::ext(
    as.numeric(bb["xmin"] - pad_x),
    as.numeric(bb["xmax"] + pad_x),
    as.numeric(bb["ymin"] - pad_y),
    as.numeric(bb["ymax"] + pad_y)
  )
}

get_metrics <- function(settlement_id, date) {
  date <- as.Date(date, origin = "1970-01-01")
  row <- sett_panel %>%
    filter(.data$settlement_id == !!settlement_id, .data$date == !!date) %>%
    select(
      settlement_id,
      date,
      p_lit_sett,
      coverage,
      mean_rad_sett,
      median_rad_sett,
      n_valid,
      n_lit,
      n_total_overlap
    ) %>%
    left_join(eskom_panel, by = "date")

  if (nrow(row) == 0) {
    return(tibble(
      settlement_id = settlement_id,
      date = date,
      p_lit_sett = NA_real_,
      coverage = NA_real_,
      mean_rad_sett = NA_real_,
      median_rad_sett = NA_real_,
      n_valid = NA_real_,
      n_lit = NA_real_,
      n_total_overlap = NA_real_,
      local_overpass_date = NA,
      mlr_mean_1_2am_primary = NA_real_,
      shed_share_1_2am_primary = NA_real_,
      mlr_mean_0_1am = NA_real_,
      shed_share_0_1am = NA_real_,
      mlr_mean_2_3am = NA_real_,
      shed_share_2_3am = NA_real_
    ))
  }

  row
}

collect_event_metrics <- function(event) {
  dates <- seq.Date(event$event_date - 1, event$event_date + 1, by = "day")
  bind_rows(lapply(dates, function(d) get_metrics(event$settlement_id, d))) %>%
    mutate(
      event_date = event$event_date,
      event_label = event$label,
      event_class = event$event_class,
      selection_reason = event$selection_reason,
      relative_day = case_when(
        .data$date < event$event_date ~ "before",
        .data$date == event$event_date ~ "event",
        TRUE ~ "after"
      )
    )
}

mean_or_na <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) == 0) return(NA_real_)
  mean(x)
}

median_or_na <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) == 0) return(NA_real_)
  stats::median(x)
}

collect_analysis_metrics <- function() {
  analysis <- sett_panel %>%
    group_by(.data$settlement_id) %>%
    summarise(
      first_panel_date = min(.data$date, na.rm = TRUE),
      last_panel_date = max(.data$date, na.rm = TRUE),
      n_days = n(),
      n_days_with_p_lit = sum(!is.na(.data$p_lit_sett)),
      analysis_p_lit_mean = mean_or_na(.data$p_lit_sett),
      analysis_p_lit_median = median_or_na(.data$p_lit_sett),
      analysis_p_lit_min = min(.data$p_lit_sett, na.rm = TRUE),
      analysis_coverage_mean = mean_or_na(.data$coverage),
      analysis_coverage_median = median_or_na(.data$coverage),
      analysis_daily_mean_rad_mean = mean_or_na(.data$mean_rad_sett),
      analysis_daily_mean_rad_median = median_or_na(.data$mean_rad_sett),
      analysis_daily_median_rad_mean = mean_or_na(.data$median_rad_sett),
      analysis_daily_median_rad_median = median_or_na(.data$median_rad_sett),
      analysis_strict_dark_count = sum(.data$p_lit_sett < 0.05, na.rm = TRUE),
      analysis_mostly_dark_count = sum(.data$p_lit_sett < 0.20, na.rm = TRUE),
      .groups = "drop"
    )

  EVENTS %>%
    left_join(analysis, by = "settlement_id") %>%
    rename(event_label = label) %>%
    select(
      event_label,
      event_class,
      selection_reason,
      settlement_id,
      event_date,
      first_panel_date,
      last_panel_date,
      n_days,
      n_days_with_p_lit,
      analysis_p_lit_mean,
      analysis_p_lit_median,
      analysis_p_lit_min,
      analysis_coverage_mean,
      analysis_coverage_median,
      analysis_daily_mean_rad_mean,
      analysis_daily_mean_rad_median,
      analysis_daily_median_rad_mean,
      analysis_daily_median_rad_median,
      analysis_strict_dark_count,
      analysis_mostly_dark_count
    )
}

collect_location_metadata <- function() {
  points <- sett %>%
    st_transform(3857) %>%
    st_point_on_surface() %>%
    st_transform(4326)
  coords <- sf::st_coordinates(points)

  settlement_locations <- sett %>%
    st_drop_geometry() %>%
    transmute(
      settlement_id = .data$settlement_id,
      village_name = .data$village_name,
      admin_cgaz_1 = .data$admin_cgaz_1,
      admin_cgaz_2 = .data$admin_cgaz_2,
      population = .data$population,
      source_lat = .data$lat,
      source_lon = .data$lon,
      representative_lon = coords[, "X"],
      representative_lat = coords[, "Y"],
      google_earth_search = paste0(
        format(round(coords[, "Y"], 6), nsmall = 6),
        ", ",
        format(round(coords[, "X"], 6), nsmall = 6)
      )
    )

  EVENTS %>%
    left_join(settlement_locations, by = "settlement_id") %>%
    rename(event_label = label) %>%
    select(
      event_label,
      event_class,
      selection_reason,
      settlement_id,
      event_date,
      village_name,
      admin_cgaz_1,
      admin_cgaz_2,
      population,
      representative_lat,
      representative_lon,
      google_earth_search,
      source_lat,
      source_lon
    )
}

crop_layers <- function(date, crop_ext) {
  date <- as.Date(date, origin = "1970-01-01")
  r <- terra::rast(raster_for_date(date))
  if (!all(c("rad", "valid") %in% names(r))) {
    stop("Raster missing rad/valid bands: ", raster_for_date(date))
  }
  rad <- terra::crop(r[["rad"]], crop_ext)
  valid <- terra::crop(r[["valid"]], crop_ext)
  valid_rad <- terra::ifel(valid == 1 & !is.na(rad), rad, NA)

  rad_bin <- terra::classify(
    valid_rad,
    rcl = matrix(
      c(
        -Inf, PIXEL_LIT_THRESHOLD, 1,
        PIXEL_LIT_THRESHOLD, 2, 2,
        2, 4, 3,
        4, 8, 4,
        8, 12, 5,
        12, Inf, 6
      ),
      ncol = 3,
      byrow = TRUE
    ),
    include.lowest = TRUE,
    right = TRUE
  )

  lit_class <- terra::classify(
    valid_rad,
    rcl = matrix(
      c(
        -Inf, PIXEL_LIT_THRESHOLD, 1,
        PIXEL_LIT_THRESHOLD, Inf, 2
      ),
      ncol = 3,
      byrow = TRUE
    ),
    include.lowest = TRUE,
    right = TRUE
  )

  names(rad) <- "radiance"
  names(valid_rad) <- "valid_radiance"
  names(rad_bin) <- "valid_radiance_bin"
  names(lit_class) <- "lit_class"
  list(rad = rad, valid_rad = valid_rad, rad_bin = rad_bin, lit_class = lit_class)
}

fmt <- function(x, digits = 3) {
  ifelse(is.na(x), "NA", format(round(x, digits), nsmall = digits))
}

lon_to_tile_x <- function(lon, z) {
  floor((lon + 180) / 360 * 2^z)
}

lat_to_tile_y <- function(lat, z) {
  lat_rad <- lat * pi / 180
  floor((1 - log(tan(lat_rad) + 1 / cos(lat_rad)) / pi) / 2 * 2^z)
}

tile_x_to_lon <- function(x, z) {
  x / 2^z * 360 - 180
}

tile_y_to_lat <- function(y, z) {
  atan(sinh(pi * (1 - 2 * y / 2^z))) * 180 / pi
}

tile_grid_for_extent <- function(xmin, xmax, ymin, ymax, z) {
  x_range <- lon_to_tile_x(c(xmin, xmax), z)
  y_range <- lat_to_tile_y(c(ymax, ymin), z)
  list(
    z = z,
    xs = seq(min(x_range), max(x_range)),
    ys = seq(min(y_range), max(y_range))
  )
}

choose_satellite_grid <- function(xmin, xmax, ymin, ymax) {
  z <- SATELLITE_ZOOM_DEFAULT
  grid <- tile_grid_for_extent(xmin, xmax, ymin, ymax, z)
  while (length(grid$xs) * length(grid$ys) > SATELLITE_MAX_TILES && z > 10) {
    z <- z - 1L
    grid <- tile_grid_for_extent(xmin, xmax, ymin, ymax, z)
  }
  grid
}

read_satellite_tile <- function(x, y, z) {
  tile_path <- file.path(SATELLITE_TILE_CACHE, sprintf("esri_world_imagery_z%d_x%d_y%d.jpg", z, x, y))
  if (!file.exists(tile_path)) {
    url <- sprintf(SATELLITE_TILE_URL, z, y, x)
    curl::curl_download(url, tile_path, quiet = TRUE)
  }
  jpeg::readJPEG(tile_path)
}

render_satellite_panel <- function(event) {
  message(
    "Rendering satellite context: ",
    event$label,
    " ",
    format(event$event_date, "%Y-%m-%d"),
    " [",
    event$settlement_id,
    "]"
  )

  poly <- sett %>% filter(.data$settlement_id == event$settlement_id)
  if (nrow(poly) != 1) stop("Expected one polygon for settlement_id ", event$settlement_id)

  crop_ext <- extend_bbox(poly, margin = SATELLITE_MARGIN_DEG, fraction = SATELLITE_MARGIN_FRACTION)
  xmin <- terra::xmin(crop_ext)
  xmax <- terra::xmax(crop_ext)
  ymin <- terra::ymin(crop_ext)
  ymax <- terra::ymax(crop_ext)
  grid <- choose_satellite_grid(xmin, xmax, ymin, ymax)

  out_png <- file.path(
    OUT_DIR,
    paste0(
      "satellite_closeup_",
      event$settlement_id,
      "_",
      format(event$event_date, "%Y-%m-%d"),
      ".png"
    )
  )

  png(out_png, width = 1800, height = 950, res = 170)
  old_par <- par(no.readonly = TRUE)
  on.exit({
    par(old_par)
    dev.off()
  }, add = TRUE)

  par(mar = c(3.5, 3.5, 4.8, 1.2))
  plot(
    NA,
    xlim = c(xmin, xmax),
    ylim = c(ymin, ymax),
    xlab = "longitude",
    ylab = "latitude",
    main = paste0(event$label, " settlement contour on satellite imagery"),
    axes = TRUE
  )

  for (x in grid$xs) {
    for (y in grid$ys) {
      img <- read_satellite_tile(x, y, grid$z)
      tile_xmin <- tile_x_to_lon(x, grid$z)
      tile_xmax <- tile_x_to_lon(x + 1, grid$z)
      tile_ymax <- tile_y_to_lat(y, grid$z)
      tile_ymin <- tile_y_to_lat(y + 1, grid$z)
      rasterImage(img, tile_xmin, tile_ymin, tile_xmax, tile_ymax)
    }
  }

  plot(st_geometry(poly), add = TRUE, border = "#33d1ff", lwd = 3.2)
  box()
  mtext(
    paste0(
      "Basemap: Esri World Imagery XYZ tiles, zoom ",
      grid$z,
      "; cyan contour: settlement polygon used for aggregation"
    ),
    side = 1,
    line = 2.4,
    cex = 0.75
  )

  out_png
}

plot_discrete_layer <- function(layer, cols, breaks, title, legend_title, legend_labels, legend_fills) {
  n_valid <- terra::global(!is.na(layer), "sum", na.rm = TRUE)[1, 1]
  if (is.na(n_valid)) n_valid <- 0

  if (n_valid == 0) {
    placeholder <- layer
    placeholder[] <- 1
    terra::plot(
      placeholder,
      col = INVALID_PIXEL_COL,
      breaks = c(0.5, 1.5),
      colNA = INVALID_PIXEL_COL,
      main = title,
      axes = TRUE,
      legend = FALSE
    )
  } else {
    terra::plot(
      layer,
      col = cols,
      breaks = breaks,
      colNA = INVALID_PIXEL_COL,
      main = title,
      axes = TRUE,
      legend = FALSE
    )
  }

  legend(
    "right",
    inset = c(-0.31, 0),
    title = legend_title,
    legend = legend_labels,
    fill = legend_fills,
    xpd = NA,
    bty = "n",
    cex = 0.70
  )
}

render_event_panel <- function(event) {
  message(
    "Rendering close-up: ",
    event$label,
    " ",
    format(event$event_date, "%Y-%m-%d"),
    " [",
    event$settlement_id,
    "]"
  )

  poly <- sett %>% filter(.data$settlement_id == event$settlement_id)
  if (nrow(poly) != 1) stop("Expected one polygon for settlement_id ", event$settlement_id)

  dates <- seq.Date(event$event_date - 1, event$event_date + 1, by = "day")
  crop_ext <- extend_bbox(poly)
  metrics <- collect_event_metrics(event)

  out_png <- file.path(
    OUT_DIR,
    paste0(
      "vj146a2_pixel_closeup_",
      event$settlement_id,
      "_",
      format(event$event_date, "%Y-%m-%d"),
      ".png"
    )
  )

  png(out_png, width = 1800, height = 1520, res = 170)
  old_par <- par(no.readonly = TRUE)
  on.exit({
    par(old_par)
    dev.off()
  }, add = TRUE)

  layout(matrix(1:6, nrow = 2, byrow = TRUE), heights = c(1, 1))
  par(mar = c(3.2, 3.2, 6.2, 5.2), oma = c(0.4, 0.4, 6.2, 0.4))

  rad_cols <- c("#24103f", "#ffd84d", "#ffb000", "#ff7a1a", "#e94b35", "#b61f65")
  rad_breaks <- seq(0.5, 6.5, by = 1)
  rad_legend <- c("invalid", "<=1", "1-2", "2-4", "4-8", "8-12", ">12")
  class_cols <- c("#24103f", "#ffd84d")
  class_breaks <- c(0.5, 1.5, 2.5)
  class_legend <- c("invalid", "0 unlit", "1 lit")

  for (d in dates) {
    d <- as.Date(d, origin = "1970-01-01")
    layers <- crop_layers(d, crop_ext)
    m <- metrics %>% filter(.data$date == !!d)
    rel <- m$relative_day[1]
    title <- paste0(
      format(d, "%Y-%m-%d"),
      " (", rel, ")",
      "\np_lit=", fmt(m$p_lit_sett[1], 3),
      " cov=", fmt(m$coverage[1], 3),
      " MLR=", fmt(m$mlr_mean_1_2am_primary[1], 1), " MW"
    )

    plot_discrete_layer(
      layers$rad_bin,
      cols = rad_cols,
      breaks = rad_breaks,
      title = title,
      legend_title = "valid rad bin",
      legend_labels = rad_legend,
      legend_fills = c(INVALID_PIXEL_COL, rad_cols)
    )
    plot(st_geometry(poly), add = TRUE, border = "#33d1ff", lwd = 2.6)
  }

  for (d in dates) {
    d <- as.Date(d, origin = "1970-01-01")
    layers <- crop_layers(d, crop_ext)
    m <- metrics %>% filter(.data$date == !!d)
    rel <- m$relative_day[1]
    title <- paste0(
      "Raw pixel class: ", format(d, "%Y-%m-%d"),
      " (", rel, ")",
      "\ninvalid grey, 0: rad <= 1, 1: rad > 1"
    )

    plot_discrete_layer(
      layers$lit_class,
      cols = class_cols,
      breaks = class_breaks,
      title = title,
      legend_title = "class",
      legend_labels = class_legend,
      legend_fills = c(INVALID_PIXEL_COL, class_cols)
    )
    plot(st_geometry(poly), add = TRUE, border = "#33d1ff", lwd = 2.6)
  }

  title(
    main = paste0(event$label, " Jan-Jun ", event$event_class, " event close-up"),
    outer = TRUE,
    cex.main = 1.35,
    line = 3.5
  )

  out_png
}

all_metrics <- bind_rows(lapply(seq_len(nrow(EVENTS)), function(i) {
  collect_event_metrics(EVENTS[i, ])
}))
analysis_metrics <- collect_analysis_metrics()
location_metadata <- collect_location_metadata()

satellite_pngs <- vapply(seq_len(nrow(EVENTS)), function(i) render_satellite_panel(EVENTS[i, ]), character(1))
pngs <- vapply(seq_len(nrow(EVENTS)), function(i) render_event_panel(EVENTS[i, ]), character(1))

if (requireNamespace("readr", quietly = TRUE)) {
  readr::write_csv(all_metrics, OUT_METRICS)
  readr::write_csv(analysis_metrics, OUT_ANALYSIS)
  readr::write_csv(location_metadata, OUT_LOCATIONS)
} else {
  write.csv(all_metrics, OUT_METRICS, row.names = FALSE)
  write.csv(analysis_metrics, OUT_ANALYSIS, row.names = FALSE)
  write.csv(location_metadata, OUT_LOCATIONS, row.names = FALSE)
}

message("Wrote metrics: ", OUT_METRICS)
message("Wrote Jan-Jun metrics: ", OUT_ANALYSIS)
message("Wrote locations: ", OUT_LOCATIONS)
message("Wrote satellite panels:")
for (p in satellite_pngs) message(" - ", p)
message("Wrote diagnostic panels:")
for (p in pngs) message(" - ", p)
message("Done.")
