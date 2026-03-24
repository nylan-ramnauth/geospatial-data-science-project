# ============================================================
# Area Coverage Sensitivity Analysis
# ============================================================
#
# Purpose:  Shows the effect of varying AREA_COVERAGE_MIN on which
#           local-area and supply-area polygons receive a metric value
#           vs. appear grey. The area parquets were produced at
#           AREA_COVERAGE_MIN = 0.25, so all rows have
#           share_population_kept >= 0.25. Re-filtering from the same
#           files lets us compare thresholds without re-running Stage 3b.
#
# Inputs:   - Map Data/reliability_outputs_blackmarbler/
#               localarea_reliability_yearly_strict_yearlykeep_postdoe_yearlykeep.parquet
#               supplyarea_reliability_yearly_strict_yearlykeep_postdoe_yearlykeep.parquet
#           - Map Data/Local Area/LOCAL_AREA_GCCA2025.shp
#           - Map Data/Supply Area/SUPPLY_AREA_GCCA2025.shp
#
# Outputs (all to Map Data/reliability_outputs_blackmarbler/figures/):
#   cov_sensitivity_local_dark_share_cov{25,30,40,50}.png   (8 files)
#   cov_sensitivity_supply_dark_share_cov{25,30,40,50}.png
#   cov_sensitivity_local_comparison.png   (2x2 patchwork grid)
#   cov_sensitivity_supply_comparison.png
#   cov_sensitivity_dropout_summary.csv
#
# Run:      Rscript Builder/area_coverage_sensitivity.R
# ============================================================

rm(list = ls())

suppressPackageStartupMessages({
  library(here)
  library(sf)
  library(dplyr)
  library(tidyr)
  library(arrow)
  library(ggplot2)
  library(scales)
  library(patchwork)
})

sf::sf_use_s2(FALSE)

# ------------------------------------------------------------------
# CONFIG
# ------------------------------------------------------------------
BASE_PATH <- here::here()
OUT_DIR   <- file.path(BASE_PATH, "Map Data", "reliability_outputs_blackmarbler")
FIG_DIR   <- file.path(OUT_DIR, "figures")
dir.create(FIG_DIR, recursive = TRUE, showWarnings = FALSE)

LOCAL_PARQUET  <- file.path(OUT_DIR,
  "localarea_reliability_yearly_strict_yearlykeep_postdoe_yearlykeep.parquet")
SUPPLY_PARQUET <- file.path(OUT_DIR,
  "supplyarea_reliability_yearly_strict_yearlykeep_postdoe_yearlykeep.parquet")

LOCAL_SHP  <- file.path(BASE_PATH, "Map Data", "Local Area",  "LOCAL_AREA_GCCA2025.shp")
SUPPLY_SHP <- file.path(BASE_PATH, "Map Data", "Supply Area", "SUPPLY_AREA_GCCA2025.shp")

THRESHOLDS   <- c(0.25, 0.30, 0.40, 0.50)
METRIC_COL   <- "dark_share_popw"
METRIC_LABEL <- "Dark share (pop-weighted)"

FIG_W   <- 8
FIG_H   <- 7.2
FIG_DPI <- 320

# ------------------------------------------------------------------
# MAP THEME (copied from reliability_choropleth_maps.R lines 98-113)
# ------------------------------------------------------------------
map_theme <- theme_void(base_size = 11) +
  theme(
    plot.background  = element_rect(fill = "white", color = NA),
    panel.background = element_rect(fill = "white", color = NA),
    legend.position    = "bottom",
    legend.direction   = "horizontal",
    legend.justification = "center",
    legend.title  = element_text(size = 9, face = "bold"),
    legend.text   = element_text(size = 8),
    legend.key.width  = grid::unit(7,   "mm"),
    legend.key.height = grid::unit(3.8, "mm"),
    plot.title    = element_text(size = 13, face = "bold", hjust = 0),
    plot.subtitle = element_text(size = 9,  color = "grey25", hjust = 0),
    plot.caption  = element_text(size = 7.5, color = "grey35", hjust = 0),
    plot.margin   = margin(8, 10, 8, 8)
  )

# ------------------------------------------------------------------
# LOAD DATA
# ------------------------------------------------------------------
message("Loading parquets ...")
local_df  <- arrow::read_parquet(LOCAL_PARQUET)
supply_df <- arrow::read_parquet(SUPPLY_PARQUET)

message("Loading shapefiles ...")
local_shp  <- sf::st_read(LOCAL_SHP,  quiet = TRUE)
supply_shp <- sf::st_read(SUPPLY_SHP, quiet = TRUE)

# ------------------------------------------------------------------
# DROPOUT SUMMARY CSV
# ------------------------------------------------------------------
# Collect all area names from shapefiles (ground truth of universe)
local_areas  <- local_shp  %>% sf::st_drop_geometry() %>%
  select(area_name = LocalArea)
supply_areas <- supply_shp %>% sf::st_drop_geometry() %>%
  select(area_name = SupplyArea)

make_dropout <- function(shp_areas, df, area_type_label) {
  # One row per area; share_population_kept = NA if not in parquet
  base <- shp_areas %>%
    left_join(
      df %>% select(area_name, share_population_kept),
      by = "area_name"
    ) %>%
    mutate(area_type = area_type_label)

  for (thr in THRESHOLDS) {
    col <- paste0("kept_cov", as.integer(thr * 100))
    base[[col]] <- !is.na(base$share_population_kept) &
                   base$share_population_kept >= thr
  }
  base
}

dropout_local  <- make_dropout(local_areas,  local_df,  "local")
dropout_supply <- make_dropout(supply_areas, supply_df, "supply")
dropout_all    <- bind_rows(dropout_local, dropout_supply)

write.csv(
  dropout_all,
  file.path(FIG_DIR, "cov_sensitivity_dropout_summary.csv"),
  row.names = FALSE
)
message("Saved: cov_sensitivity_dropout_summary.csv")

# Print summary table to console
cat("\n--- Dropout summary: areas shown at each threshold ---\n")
for (thr in THRESHOLDS) {
  col <- paste0("kept_cov", as.integer(thr * 100))
  n_local  <- sum(dropout_local[[col]],  na.rm = TRUE)
  n_supply <- sum(dropout_supply[[col]], na.rm = TRUE)
  cat(sprintf("  cov >= %.2f  |  local: %d/%d shown  |  supply: %d/%d shown\n",
              thr,
              n_local,  nrow(local_shp),
              n_supply, nrow(supply_shp)))
}
cat("\n")

# ------------------------------------------------------------------
# MAP-BUILDER FUNCTION
# ------------------------------------------------------------------
make_map <- function(shp, df, shp_join_col, threshold, metric_col,
                     metric_label, title_prefix) {
  filtered <- df %>% filter(share_population_kept >= threshold)

  map_sf <- shp %>%
    left_join(filtered, by = setNames("area_name", shp_join_col)) %>%
    sf::st_transform(4326)

  n_shown <- sum(!is.na(map_sf[[metric_col]]))
  n_total <- nrow(map_sf)

  ggplot(map_sf) +
    geom_sf(
      aes(fill = .data[[metric_col]]),
      color = "white", linewidth = 0.22
    ) +
    coord_sf(datum = NA, expand = FALSE) +
    scale_fill_viridis_c(
      option    = "cividis",
      direction = -1,
      na.value  = "grey90",
      name      = metric_label,
      labels    = scales::label_percent(accuracy = 1)
    ) +
    guides(
      fill = guide_colorbar(
        title.position = "top",
        title.hjust    = 0.5,
        barwidth       = grid::unit(68, "mm"),
        barheight      = grid::unit(4,  "mm")
      )
    ) +
    labs(
      title    = paste0(title_prefix, " \u2014 Coverage \u2265 ",
                        scales::percent(threshold, accuracy = 1)),
      subtitle = paste0(n_shown, " of ", n_total, " areas shown"),
      caption  = "Grey indicates areas below the coverage threshold or with no data."
    ) +
    map_theme
}

# ------------------------------------------------------------------
# LOOP: individual PNGs + collect plots for patchwork grids
# ------------------------------------------------------------------
run_area <- function(shp, df, shp_join_col, area_slug, title_prefix) {
  plots <- list()

  for (thr in THRESHOLDS) {
    thr_tag <- paste0("cov", as.integer(thr * 100))

    p <- make_map(
      shp         = shp,
      df          = df,
      shp_join_col = shp_join_col,
      threshold   = thr,
      metric_col  = METRIC_COL,
      metric_label = METRIC_LABEL,
      title_prefix = title_prefix
    )

    plots[[thr_tag]] <- p

    png_name <- file.path(
      FIG_DIR,
      paste0("cov_sensitivity_", area_slug, "_dark_share_", thr_tag, ".png")
    )
    ggsave(png_name, plot = p, width = FIG_W, height = FIG_H, dpi = FIG_DPI)
    message("Saved: ", basename(png_name))
  }

  # 2x2 patchwork comparison grid
  grid_plot <- patchwork::wrap_plots(plots, ncol = 2) +
    patchwork::plot_annotation(
      title   = paste0(title_prefix, " \u2014 Coverage Threshold Sensitivity"),
      subtitle = paste0(
        "METRIC: ", METRIC_LABEL,
        "  |  Grey = area below threshold"
      ),
      theme = theme(
        plot.title    = element_text(size = 15, face = "bold"),
        plot.subtitle = element_text(size = 10, color = "grey30")
      )
    )

  grid_name <- file.path(
    FIG_DIR,
    paste0("cov_sensitivity_", area_slug, "_comparison.png")
  )
  ggsave(grid_name, plot = grid_plot,
         width = FIG_W * 2, height = FIG_H * 2, dpi = FIG_DPI)
  message("Saved: ", basename(grid_name))
}

message("Building local-area maps ...")
run_area(
  shp          = local_shp,
  df           = local_df,
  shp_join_col = "LocalArea",
  area_slug    = "local",
  title_prefix = "Local Area"
)

message("Building supply-area maps ...")
run_area(
  shp          = supply_shp,
  df           = supply_df,
  shp_join_col = "SupplyArea",
  area_slug    = "supply",
  title_prefix = "Supply Area"
)

message("\nDone. Outputs in: ", FIG_DIR)
message("  8 individual PNGs (4 thresholds x 2 area types)")
message("  2 comparison grids")
message("  1 dropout summary CSV")
