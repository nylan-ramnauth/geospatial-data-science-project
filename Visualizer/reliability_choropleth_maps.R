# ============================================================
# Reliability Choropleth Maps (Static)
# Stage 5 — Output Visualisation
# ============================================================
#
# Purpose:  Reads local-area and supply-area reliability Parquets from
#           Stage 3; produces ggplot2 choropleth PDFs/PNGs for metrics
#           such as dark_share_popw and switch_rate_popw.
# Inputs:   - Map Data/reliability_outputs_blackmarbler/localarea_reliability_*.parquet
#           - Map Data/reliability_outputs_blackmarbler/supplyarea_reliability_*.parquet
#           - Map Data/Local Area/LOCAL_AREA_GCCA2025.shp
#           - Map Data/Supply Area/SUPPLY_AREA_GCCA2025.shp
# Outputs:  - Map Data/reliability_outputs_blackmarbler/choropleth_*.pdf / *.png
# Run:      Rscript Visualizer/reliability_choropleth_maps.R
# ============================================================

rm(list = ls())

suppressPackageStartupMessages({
  library(here)
  library(sf)
  library(dplyr)
  library(arrow)
  library(ggplot2)
  library(lubridate)
  library(viridisLite)
  library(scales)
})

sf::sf_use_s2(FALSE)

# -----------------------------
# CONFIG
# -----------------------------
BASE_PATH <- here::here()
OUT_DIR <- file.path(BASE_PATH, "Map Data", "reliability_outputs_blackmarbler")
FIG_DIR <- file.path(OUT_DIR, "figures")
dir.create(FIG_DIR, recursive = TRUE, showWarnings = FALSE)

LOCAL_AREAS_SHP <- file.path(BASE_PATH, "Map Data", "Local Area","LOCAL_AREA_GCCA2025.shp")
SUPPLY_AREAS_SHP <- file.path(BASE_PATH, "Map Data", "Supply Area","SUPPLY_AREA_GCCA2025.shp")

# Visualization switches
PERIOD <- "yearly"        # monthly | quarterly | yearly
MODE <- "yearlykeep"       # standard | yearlykeep

# File naming profile (must match panel script outputs)
# OUTPUT_SUFFIX = "" matches reliability_panel_build_yearlykeep.R default (no suffix)
if (MODE == "yearlykeep") {
  STATE <- "strict_yearlykeep_postdoe"
  OUTPUT_SUFFIX <- ""
} else {
  STATE <- "strict"        # strict | hysteresis
  OUTPUT_SUFFIX <- ""      # "" | "_moonfilter_obvious" | "_moonfilter_maybe"
}
if (nzchar(Sys.getenv("RUN_OUTPUT_SUFFIX"))) OUTPUT_SUFFIX <- Sys.getenv("RUN_OUTPUT_SUFFIX")
FIG_TAG <- Sys.getenv("RUN_FIG_TAG", unset = "")  # e.g. "_cov25" appended to figure names

# Metrics to map
# Map 1 (level):     uptime_popw       — mean reliability; yellow = reliable
# Map 2 (inequality): sd_uptime_popw   — cross-sectional SD; yellow = equal
# Map 3 (volatility): cv_p_lit_popw    — temporal fluctuation; yellow = stable
METRIC_MAIN <- "uptime_popw"
METRIC_SD   <- "sd_uptime_popw"
METRIC_VAR  <- "cv_p_lit_popw"

# Output style
FIG_WIDTH_IN <- 8
FIG_HEIGHT_IN <- 7.2
FIG_DPI <- 320

LOCAL_OVERLAY_LABEL <- "Local Area boundaries (LOCAL_AREA_GCCA2025)"
SUPPLY_OVERLAY_LABEL <- "Supply Area boundaries (SUPPLY_AREA_GCCA2025)"

# RStudio preview controls
FAST_PREVIEW <- interactive() && identical(Sys.getenv("RSTUDIO"), "1")
PREVIEW_MAP <- "local_main" # local_main | local_var | supply_main | supply_var | all
SIMPLIFY_TOLERANCE_DEG <- 0.004
DRAW_COUNTRY_OUTLINE <- !FAST_PREVIEW

# -----------------------------
# HELPERS
# -----------------------------
load_area_metrics <- function(area_prefix, period, state) {
  path <- file.path(
    OUT_DIR,
    paste0(area_prefix, "_reliability_", period, "_", state, OUTPUT_SUFFIX, ".parquet")
  )
  if (!file.exists(path)) stop("Missing metrics file: ", path)

  df <- arrow::read_parquet(path)

  period_col <- switch(
    period,
    monthly = "month",
    quarterly = "quarter",
    yearly = "year",
    stop("Invalid PERIOD value")
  )

  df <- df %>% mutate(period_start = as.Date(.data[[period_col]]))
  list(data = df, period_col = period_col)
}

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

period_label <- function(period, period_date) {
  switch(
    period,
    monthly = format(period_date, "%B %Y"),
    quarterly = paste0("Q", lubridate::quarter(period_date), " ", lubridate::year(period_date)),
    yearly = format(period_date, "%Y"),
    as.character(period_date)
  )
}

safe_pretty_breaks <- function(x, n = 5) {
  x <- x[is.finite(x)]
  if (length(x) == 0) return(NULL)
  b <- pretty(x, n = n)
  b <- b[b >= min(x) & b <= max(x)]
  b <- unique(b)
  if (length(b) <= 1) return(NULL)
  b
}

metric_definition <- function(metric_col) {
  switch(
    metric_col,
    uptime_popw     = "Population-weighted mean uptime: share of observed post-DOE days classified as lit",
    sd_uptime_popw  = "Population-weighted SD of settlement uptime within each area (cross-sectional inequality)",
    cv_p_lit_popw   = "Population-weighted mean CV of daily radiance (temporal volatility of the supply signal)",
    dark_share_popw = "Population-weighted share of observed post-DOE days classified as dark",
    switch_rate_popw = "Population-weighted share of consecutive observed post-DOE day pairs with a lit/dark state change",
    paste("Population-weighted metric:", metric_col)
  )
}

build_subtitle <- function(metric_col, overlay_label, period_label, state_label) {
  paste0(
    metric_definition(metric_col),
    "\nOverlay: ", overlay_label,
    " | Period: ", period_label,
    " | State: ", state_label
  )
}

plot_metric_map <- function(sf_obj, metric_col, palette_option, legend_name, map_title, map_subtitle, breaks = NULL, percent = FALSE, direction = 1) {
  scale_fun <- if (percent) label_percent(accuracy = 1) else label_number(accuracy = 0.01)
  chosen_breaks <- if (is.null(breaks)) safe_pretty_breaks(sf_obj[[metric_col]], n = 5) else breaks

  p <- ggplot(sf_obj) +
    geom_sf(aes(fill = .data[[metric_col]]), color = "white", linewidth = 0.22, show.legend = TRUE) +
    coord_sf(datum = NA, expand = FALSE) +
    labs(
      title = map_title,
      subtitle = map_subtitle,
      caption = "Gray indicates missing values in the selected metric."
    ) +
    map_theme

  if (DRAW_COUNTRY_OUTLINE) {
    country_outline <- suppressMessages(suppressWarnings(sf::st_union(sf_obj)))
    p <- p + geom_sf(
      data = country_outline,
      fill = NA,
      color = "grey20",
      linewidth = 0.35,
      inherit.aes = FALSE,
      show.legend = FALSE
    )
  }

  if (is.null(breaks)) {
    p +
      scale_fill_viridis_c(
        option = palette_option,
        direction = direction,
        na.value = "grey90",
        name = legend_name,
        breaks = chosen_breaks,
        labels = scale_fun
      ) +
      guides(
        fill = guide_colorbar(
          title.position = "top",
          title.hjust = 0.5,
          barwidth = grid::unit(68, "mm"),
          barheight = grid::unit(4, "mm")
        )
      )
  } else {
    p +
      scale_fill_viridis_c(
        option = palette_option,
        direction = direction,
        breaks = breaks,
        na.value = "grey90",
        name = legend_name,
        labels = scale_fun
      ) +
      guides(
        fill = guide_colorbar(
          title.position = "top",
          title.hjust = 0.5,
          barwidth = grid::unit(68, "mm"),
          barheight = grid::unit(4, "mm")
        )
      )
  }
}

# -----------------------------
# LOAD SHAPEFILES
# -----------------------------
local_areas <- st_read(LOCAL_AREAS_SHP, quiet = TRUE)
supply_areas <- st_read(SUPPLY_AREAS_SHP, quiet = TRUE)

# -----------------------------
# LOAD METRICS
# -----------------------------
local_loaded <- load_area_metrics("localarea", PERIOD, STATE)
supply_loaded <- load_area_metrics("supplyarea", PERIOD, STATE)

local_df <- local_loaded$data
supply_df <- supply_loaded$data

latest_local_period <- max(local_df$period_start, na.rm = TRUE)
latest_supply_period <- max(supply_df$period_start, na.rm = TRUE)
local_period_label <- period_label(PERIOD, latest_local_period)
supply_period_label <- period_label(PERIOD, latest_supply_period)

local_map <- local_areas %>%
  left_join(
    local_df %>% filter(period_start == latest_local_period),
    by = c("LocalArea" = "area_name")
  )

supply_map <- supply_areas %>%
  left_join(
    supply_df %>% filter(period_start == latest_supply_period),
    by = c("SupplyArea" = "area_name")
  )

if (FAST_PREVIEW) {
  local_map <- suppressWarnings(sf::st_simplify(local_map, dTolerance = SIMPLIFY_TOLERANCE_DEG, preserveTopology = TRUE))
  supply_map <- suppressWarnings(sf::st_simplify(supply_map, dTolerance = SIMPLIFY_TOLERANCE_DEG, preserveTopology = TRUE))
}

# -----------------------------
# PLOTS
# Design convention: yellow = good on all maps
#   uptime    — cividis, direction= 1: yellow = high uptime   = reliable
#   sd_uptime — magma,   direction=-1: yellow = low SD        = equal
#   cv_p_lit  — viridis, direction=-1: yellow = low CV        = stable
# -----------------------------

# -- Map 1: Uptime (level) --------------------------------------------------
plot_local_main <- plot_metric_map(
  local_map,
  metric_col     = METRIC_MAIN,
  palette_option = "cividis",
  legend_name    = "Uptime (population-weighted)",
  map_title      = "South Africa: Local Area Power Reliability - Uptime",
  map_subtitle   = build_subtitle(
    METRIC_MAIN, LOCAL_OVERLAY_LABEL, local_period_label, STATE),
  percent        = TRUE,
  direction      = 1
)

plot_supply_main <- plot_metric_map(
  supply_map,
  metric_col     = METRIC_MAIN,
  palette_option = "cividis",
  legend_name    = "Uptime (population-weighted)",
  map_title      = "South Africa: Supply Area Power Reliability - Uptime",
  map_subtitle   = build_subtitle(
    METRIC_MAIN, SUPPLY_OVERLAY_LABEL, supply_period_label, STATE),
  percent        = TRUE,
  direction      = 1
)

# -- Map 2: Cross-sectional SD of uptime (inequality) -----------------------
plot_local_sd <- plot_metric_map(
  local_map,
  metric_col     = METRIC_SD,
  palette_option = "cividis",
  legend_name    = "SD of uptime (population-weighted)",
  map_title      = "South Africa: Local Area Reliability Inequality - SD Uptime",
  map_subtitle   = build_subtitle(
    METRIC_SD, LOCAL_OVERLAY_LABEL, local_period_label, STATE),
  percent        = TRUE,
  direction      = -1
)

plot_supply_sd <- plot_metric_map(
  supply_map,
  metric_col     = METRIC_SD,
  palette_option = "cividis",
  legend_name    = "SD of uptime (population-weighted)",
  map_title      = "South Africa: Supply Area Reliability Inequality - SD Uptime",
  map_subtitle   = build_subtitle(
    METRIC_SD, SUPPLY_OVERLAY_LABEL, supply_period_label, STATE),
  percent        = TRUE,
  direction      = -1
)

# -- Map 3: CV of p_lit (temporal volatility) --------------------------------
plot_local_var <- plot_metric_map(
  local_map,
  metric_col     = METRIC_VAR,
  palette_option = "cividis",
  legend_name    = "CV of daily radiance (population-weighted)",
  map_title      = "South Africa: Local Area Supply Volatility - CV Radiance",
  map_subtitle   = build_subtitle(
    METRIC_VAR, LOCAL_OVERLAY_LABEL, local_period_label, STATE),
  percent        = FALSE,
  direction      = -1
)

plot_supply_var <- plot_metric_map(
  supply_map,
  metric_col     = METRIC_VAR,
  palette_option = "cividis",
  legend_name    = "CV of daily radiance (population-weighted)",
  map_title      = "South Africa: Supply Area Supply Volatility - CV Radiance",
  map_subtitle   = build_subtitle(
    METRIC_VAR, SUPPLY_OVERLAY_LABEL, supply_period_label, STATE),
  percent        = FALSE,
  direction      = -1
)

if (PREVIEW_MAP == "all") {
  print(plot_local_main);  print(plot_local_sd);  print(plot_local_var)
  print(plot_supply_main); print(plot_supply_sd); print(plot_supply_var)
} else if (PREVIEW_MAP == "local_sd") {
  print(plot_local_sd)
} else if (PREVIEW_MAP == "local_var") {
  print(plot_local_var)
} else if (PREVIEW_MAP == "supply_main") {
  print(plot_supply_main)
} else if (PREVIEW_MAP == "supply_sd") {
  print(plot_supply_sd)
} else if (PREVIEW_MAP == "supply_var") {
  print(plot_supply_var)
} else {
  print(plot_local_main)
}

# -----------------------------
# EXPORT  (6 maps × PDF + PNG = 12 files)
# -----------------------------
tag <- paste0(PERIOD, "_", STATE, "_all", FIG_TAG)

save_map <- function(plot_obj, stem) {
  base <- file.path(FIG_DIR, paste0(stem, "_", tag))
  ggsave(paste0(base, ".pdf"), plot = plot_obj,
         width = FIG_WIDTH_IN, height = FIG_HEIGHT_IN, units = "in")
  ggsave(paste0(base, ".png"), plot = plot_obj,
         width = FIG_WIDTH_IN, height = FIG_HEIGHT_IN,
         units = "in", dpi = FIG_DPI)
  message("Saved: ", stem, "_", tag, ".pdf/png")
}

save_map(plot_local_main,  "local_main")
save_map(plot_local_sd,    "local_sd")
save_map(plot_local_var,   "local_var")
save_map(plot_supply_main, "supply_main")
save_map(plot_supply_sd,   "supply_sd")
save_map(plot_supply_var,  "supply_var")

message("Visualization complete for ", tag)
