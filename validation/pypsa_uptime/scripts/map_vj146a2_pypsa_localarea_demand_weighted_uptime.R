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

local_map <- local_areas %>%
  left_join(metric, by = c("LocalArea" = "area_name"))

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
