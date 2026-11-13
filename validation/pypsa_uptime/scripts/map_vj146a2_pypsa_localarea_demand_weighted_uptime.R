#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(sf)
  library(dplyr)
  library(ggplot2)
  library(scales)
  library(viridisLite)
})

sf::sf_use_s2(FALSE)

script_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
script_path <- if (length(script_arg) > 0) {
  normalizePath(sub("^--file=", "", script_arg[[1]]), mustWork = TRUE)
} else {
  normalizePath("validation/pypsa_uptime/scripts/map_vj146a2_pypsa_localarea_demand_weighted_uptime.R", mustWork = TRUE)
}
repo_dir <- normalizePath(file.path(dirname(script_path), "..", "..", ".."), mustWork = TRUE)
source(file.path(repo_dir, "validation", "scripts", "validation_paths.R"))
paths <- validation_paths(repo_dir, "pypsa_uptime")

codebase_dir <- paths$repo_root
local_area_shp <- file.path(codebase_dir, "Map Data", "Local Area", "LOCAL_AREA_GCCA2025.shp")
metric_csv <- file.path(paths$data_dir, "vj146a2_2023_pypsa_localarea_demand_weighted_uptime.csv")
fig_dir <- file.path(paths$figures_dir, "vj146a2-pypsa-demand-weighted-uptime")
pypsa_gpkg <- file.path(paths$data_dir, "vj146a2_2023_pypsa_localarea_reliability_regions.gpkg")
pypsa_gpkg_layer <- "vj146a2_2023_localarea_reliability"
pypsa_gpkg_audit <- file.path(paths$data_dir, "vj146a2_2023_pypsa_localarea_reliability_regions_audit.csv")
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(local_area_shp)) stop("Missing LocalArea shapefile: ", local_area_shp)
if (!file.exists(metric_csv)) stop("Missing metric CSV. Run build_vj146a2_pypsa_localarea_demand_weighted_uptime.R first: ", metric_csv)

fig_width_in <- 8
fig_height_in <- 7.2
fig_dpi <- 320

map_theme <- theme_void(base_size = 11) +
  theme(
    plot.background = element_rect(fill = "white", color = NA),
    panel.background = element_rect(fill = "white", color = NA),
    legend.position = "bottom",
    legend.direction = "horizontal",
    legend.justification = "center",
    legend.title = element_text(size = 9, face = "bold"),
    legend.text = element_text(size = 8),
    legend.key.width = grid::unit(7, "mm"),
    legend.key.height = grid::unit(3.8, "mm"),
    plot.title = element_text(size = 13, face = "bold", hjust = 0),
    plot.subtitle = element_text(size = 9, color = "grey25", hjust = 0),
    plot.caption = element_text(size = 7.5, color = "grey35", hjust = 0),
    plot.margin = margin(8, 10, 8, 8)
  )

safe_pretty_breaks <- function(x, n = 5) {
  x <- x[is.finite(x)]
  if (length(x) == 0) return(NULL)
  b <- pretty(x, n = n)
  b <- b[b >= min(x) & b <= max(x)]
  b <- unique(b)
  if (length(b) <= 1) return(NULL)
  b
}

local_areas <- st_read(local_area_shp, quiet = TRUE)
metric <- read.csv(metric_csv, stringsAsFactors = FALSE)

required_metric_columns <- c(
  "area_name",
  "year",
  "not_up_040_share_demandw",
  "availability_040_demandw",
  "area_demand",
  "share_demand_kept",
  "n_dates_daily_first",
  "mean_observed_demand_share_daily_first",
  "demand_gate_threshold",
  "excess_lit_screen"
)
missing_metric_columns <- setdiff(required_metric_columns, names(metric))
if (length(missing_metric_columns) > 0) {
  stop("Metric CSV is missing required PyPSA export column(s): ", paste(missing_metric_columns, collapse = ", "))
}
if (anyDuplicated(metric$area_name) > 0) {
  duplicated_areas <- unique(metric$area_name[duplicated(metric$area_name)])
  stop("Metric CSV contains duplicate area_name values: ", paste(duplicated_areas, collapse = ", "))
}
if (anyDuplicated(local_areas$LocalArea) > 0) {
  duplicated_areas <- unique(local_areas$LocalArea[duplicated(local_areas$LocalArea)])
  stop("LocalArea boundary file contains duplicate LocalArea values: ", paste(duplicated_areas, collapse = ", "))
}

service_deficit <- metric$not_up_040_share_demandw
availability <- metric$availability_040_demandw
bad_metric_values <- !is.finite(service_deficit) |
  service_deficit < 0 |
  service_deficit > 1 |
  !is.finite(availability) |
  availability < 0 |
  availability > 1
if (any(bad_metric_values)) {
  stop(
    "Metric CSV contains invalid not-up or availability shares for: ",
    paste(metric$area_name[bad_metric_values], collapse = ", ")
  )
}

local_map <- local_areas %>%
  left_join(metric, by = c("LocalArea" = "area_name")) %>%
  mutate(
    area_name = LocalArea,
    value_unit = "share",
    service_deficit_column = "not_up_040_share_demandw",
    availability_column = "availability_040_demandw",
    geometry_source = "LOCAL_AREA_GCCA2025.shp",
    metric_source = basename(metric_csv),
    pypsa_export_status = if_else(
      is.finite(not_up_040_share_demandw) &
        not_up_040_share_demandw >= 0 &
        not_up_040_share_demandw <= 1 &
        is.finite(availability_040_demandw) &
        availability_040_demandw >= 0 &
        availability_040_demandw <= 1,
      "ready",
      "missing_or_invalid_metric"
    )
  )

metric_without_geometry <- setdiff(metric$area_name, local_areas$LocalArea)
geometry_without_metric <- setdiff(local_areas$LocalArea, metric$area_name)
if (length(metric_without_geometry) > 0) {
  stop("Metric area_name values without LocalArea geometry: ", paste(metric_without_geometry, collapse = ", "))
}

export_audit <- local_map %>%
  st_drop_geometry() %>%
  transmute(
    LocalArea,
    area_name,
    pypsa_export_status,
    not_up_040_share_demandw,
    availability_040_demandw,
    value_unit,
    area_demand,
    share_demand_kept,
    n_dates_daily_first,
    mean_observed_demand_share_daily_first,
    demand_gate_threshold,
    excess_lit_screen
  )
utils::write.csv(export_audit, pypsa_gpkg_audit, row.names = FALSE, na = "")
message("Wrote: ", pypsa_gpkg_audit)
if (length(geometry_without_metric) > 0) {
  warning(
    "LocalArea geometry without PyPSA uptime metric; exported with missing_or_invalid_metric status: ",
    paste(geometry_without_metric, collapse = ", "),
    call. = FALSE
  )
}
if (any(export_audit$pypsa_export_status != "ready")) {
  warning(
    "PyPSA reliability GPKG contains non-ready LocalArea rows. See audit: ",
    pypsa_gpkg_audit,
    call. = FALSE
  )
}

st_write(
  local_map,
  dsn = pypsa_gpkg,
  layer = pypsa_gpkg_layer,
  delete_dsn = TRUE,
  quiet = TRUE
)
message("Wrote: ", pypsa_gpkg)
message("GPKG layer: ", pypsa_gpkg_layer)

country_outline <- suppressMessages(suppressWarnings(sf::st_union(local_map)))

plot_metric_map <- function(metric_col, legend_name, map_title, caption, percent = FALSE, direction = 1) {
  scale_fun <- if (percent) label_percent(accuracy = 1) else label_number(accuracy = 0.01)
  breaks <- safe_pretty_breaks(local_map[[metric_col]], n = 5)

  ggplot(local_map) +
    geom_sf(aes(fill = .data[[metric_col]]), color = "white", linewidth = 0.22, show.legend = TRUE) +
    geom_sf(
      data = country_outline,
      fill = NA,
      color = "grey20",
      linewidth = 0.35,
      inherit.aes = FALSE,
      show.legend = FALSE
    ) +
    coord_sf(datum = NA, expand = FALSE) +
    scale_fill_viridis_c(
      option = "cividis",
      direction = direction,
      na.value = "grey90",
      name = legend_name,
      breaks = breaks,
      labels = scale_fun
    ) +
    guides(
      fill = guide_colorbar(
        title.position = "top",
        title.hjust = 0.5,
        barwidth = grid::unit(68, "mm"),
        barheight = grid::unit(4, "mm")
      )
    ) +
    labs(
      title = map_title,
      subtitle = paste0(
        "VJ146A2 2023, annual-IQR excess-lit days removed\n",
        "Settlement coverage >= 50%; LocalArea-day observed demand >= 40%; Overlay: Local Area Boundaries"
      ),
      caption = caption
    ) +
    map_theme
}

plot_uptime <- plot_metric_map(
  metric_col = "availability_040_demandw",
  legend_name = "Availability (daily-first, p_lit >= 0.40)",
  map_title = "South Africa: Local Area Power Reliability - Demand-Weighted Availability",
  caption = "Yellow indicates higher daily-first availability. Demand weights use the settlement GPKG demand field.",
  percent = TRUE,
  direction = 1
)

plot_sd_uptime <- plot_metric_map(
  metric_col = "sd_uptime_demandw",
  legend_name = "SD of uptime (demand-weighted)",
  map_title = "South Africa: Local Area Reliability Inequality - Demand-Weighted SD Uptime",
  caption = "Yellow indicates lower cross-settlement inequality in uptime. Demand weights use the settlement GPKG demand field.",
  percent = TRUE,
  direction = -1
)

plot_cv_radiance <- plot_metric_map(
  metric_col = "cv_p_lit_demandw",
  legend_name = "CV of daily lit share (demand-weighted)",
  map_title = "South Africa: Local Area Supply Volatility - Demand-Weighted CV Radiance",
  caption = "Yellow indicates lower temporal volatility in the night-light signal. Demand weights use the settlement GPKG demand field.",
  percent = FALSE,
  direction = -1
)

save_map <- function(plot_obj, stem) {
  base <- file.path(fig_dir, paste0(stem, "_vj146a2_2023_annual_excess_lit_iqr"))
  ggsave(paste0(base, ".pdf"), plot = plot_obj, width = fig_width_in, height = fig_height_in, units = "in")
  ggsave(paste0(base, ".png"), plot = plot_obj, width = fig_width_in, height = fig_height_in, units = "in", dpi = fig_dpi)
  message("Saved: ", paste0(base, ".pdf"))
  message("Saved: ", paste0(base, ".png"))
}

save_map(plot_uptime, "localarea_demand_weighted_uptime")
save_map(plot_sd_uptime, "localarea_demand_weighted_sd_uptime")
save_map(plot_cv_radiance, "localarea_demand_weighted_cv_radiance")
