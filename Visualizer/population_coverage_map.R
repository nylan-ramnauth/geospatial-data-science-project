# population_coverage_map.R
# Stage 7 — Population Coverage Mapping
# Maps showing share of total settled population covered by the reliability
# analysis, for local and supply areas.
#
# Denominator: sum of population from the DRE Atlas settlement GPKG per area.
# Numerator:   yearly-keep population from the cov0 reliability panel.
# Areas where share < 50% are flagged with a dashed border and a * label.
#
# Outputs (in figures/):
#   coverage_map_local.pdf/.png
#   coverage_map_supply.pdf/.png
# ============================================================

rm(list = ls())

suppressPackageStartupMessages({
  library(here)
  library(sf)
  library(dplyr)
  library(arrow)
  library(ggplot2)
  library(ggrepel)
  library(scales)
})

sf::sf_use_s2(FALSE)

# ── Paths ──────────────────────────────────────────────────────────────────────
BASE_PATH  <- here::here()
OUT_DIR    <- file.path(BASE_PATH, "Map Data", "reliability_outputs_blackmarbler")
FIG_DIR    <- file.path(OUT_DIR, "figures")

SETT_GPKG  <- file.path(BASE_PATH, "Map Data", "Settlements", "GPKG",
  "south_africa_dre_atlas_settlements_simplified_full_col.gpkg")
LOCAL_SHP  <- file.path(BASE_PATH, "Map Data", "Local Area",
  "LOCAL_AREA_GCCA2025.shp")
SUPPLY_SHP <- file.path(BASE_PATH, "Map Data", "Supply Area",
  "SUPPLY_AREA_GCCA2025.shp")

THRESHOLD <- 0.5
FIG_W     <- 8
FIG_H     <- 7.2
FIG_DPI   <- 320

# ── 1) Settlement population by area (from GPKG) ───────────────────────────────
cat("Reading settlements...\n")
sett <- st_read(SETT_GPKG, quiet = TRUE) %>%
  st_make_valid() %>%
  mutate(population = coalesce(as.numeric(population), 0))

local_areas  <- st_read(LOCAL_SHP,  quiet = TRUE) %>% st_make_valid()
supply_areas <- st_read(SUPPLY_SHP, quiet = TRUE) %>% st_make_valid()

sett_pts <- sett %>%
  st_transform(st_crs(local_areas)) %>%
  st_point_on_surface() %>%
  select(settlement_id, population)

local_pop_gpkg <- st_join(sett_pts, local_areas["LocalArea"], left = TRUE) %>%
  st_drop_geometry() %>%
  filter(!is.na(LocalArea)) %>%
  group_by(area_name = LocalArea) %>%
  summarise(pop_total_gpkg = sum(population, na.rm = TRUE), .groups = "drop")

supply_pop_gpkg <- st_join(
  st_transform(sett_pts, st_crs(supply_areas)),
  supply_areas["SupplyArea"],
  left = TRUE
) %>%
  st_drop_geometry() %>%
  filter(!is.na(SupplyArea)) %>%
  group_by(area_name = SupplyArea) %>%
  summarise(pop_total_gpkg = sum(population, na.rm = TRUE), .groups = "drop")

# ── 2) Yearly-keep population (cov0 = no additional coverage filter) ───────────
local_keep <- read_parquet(file.path(OUT_DIR,
  "localarea_reliability_yearly_strict_yearlykeep_postdoe.parquet")) %>%
  select(area_name, pop_yearlykeep = area_population)

supply_keep <- read_parquet(file.path(OUT_DIR,
  "supplyarea_reliability_yearly_strict_yearlykeep_postdoe.parquet")) %>%
  select(area_name, pop_yearlykeep = area_population)

# ── 3) Build map sf objects ────────────────────────────────────────────────────
make_map_sf <- function(area_sf, area_col, pop_gpkg, pop_keep) {
  area_sf %>%
    rename(area_name = all_of(area_col)) %>%
    left_join(pop_gpkg, by = "area_name") %>%
    left_join(pop_keep,  by = "area_name") %>%
    mutate(
      pop_yearlykeep = coalesce(pop_yearlykeep, 0),
      share   = if_else(
        !is.na(pop_total_gpkg) & pop_total_gpkg > 0,
        pop_yearlykeep / pop_total_gpkg,
        NA_real_
      ),
      flagged = !is.na(share) & share < THRESHOLD,
      label   = if_else(flagged, paste0(area_name, "*"), area_name)
    )
}

local_sf  <- make_map_sf(local_areas,  "LocalArea",  local_pop_gpkg,  local_keep)
supply_sf <- make_map_sf(supply_areas, "SupplyArea", supply_pop_gpkg, supply_keep)

cat("Flagged local areas (<50%):\n")
local_sf %>% st_drop_geometry() %>%
  filter(flagged) %>%
  select(area_name, pop_total_gpkg, pop_yearlykeep, share) %>%
  mutate(share = round(share, 3)) %>%
  print()

cat("\nFlagged supply areas (<50%):\n")
supply_sf %>% st_drop_geometry() %>%
  filter(flagged) %>%
  select(area_name, pop_total_gpkg, pop_yearlykeep, share) %>%
  mutate(share = round(share, 3)) %>%
  print()

# ── 4) Map function ────────────────────────────────────────────────────────────
FOOTNOTE <- paste0(
  "* Fewer than 50% of the total settled population in this area is included ",
  "in the reliability analysis.\n",
  "Population totals derived from the DRE Atlas settlement layer (NA treated as 0)."
)

make_coverage_map <- function(map_sf, title, label_flagged_only = TRUE) {

  # Centroids for repel labels
  centroids <- map_sf %>%
    st_centroid() %>%
    mutate(
      lon = st_coordinates(.)[, 1],
      lat = st_coordinates(.)[, 2]
    ) %>%
    st_drop_geometry()

  label_data <- if (label_flagged_only) {
    filter(centroids, flagged)
  } else {
    centroids
  }

  ggplot() +
    geom_sf(
      data        = map_sf,
      aes(fill    = share),
      colour      = "white",
      linewidth   = 0.35
    ) +
    geom_sf(
      data      = filter(map_sf, flagged),
      fill      = NA,
      colour    = "#333333",
      linewidth = 0.55,
      linetype  = "dashed"
    ) +
    scale_fill_gradient2(
      low      = "#b2182b",
      mid      = "#f5f0e8",
      high     = "#2166ac",
      midpoint = THRESHOLD,
      limits   = c(0, 1),
      na.value = "#cccccc",
      name     = "Share of settled\npopulation covered",
      labels   = percent_format(accuracy = 1),
      guide    = guide_colorbar(
        barwidth     = unit(0.5, "cm"),
        barheight    = unit(6.5, "cm"),
        ticks.colour = "grey40",
        frame.colour = "grey60"
      )
    ) +
    ggrepel::geom_label_repel(
      data          = label_data,
      aes(x         = lon,
          y         = lat,
          label     = label,
          fontface  = if_else(flagged, "bold", "plain")),
      size          = 2.5,
      fill          = alpha("white", 0.75),
      colour        = "grey15",
      label.size    = 0,
      label.padding = unit(0.15, "lines"),
      box.padding   = unit(0.35, "lines"),
      max.overlaps  = Inf,
      seed          = 42
    ) +
    labs(title = title, caption = FOOTNOTE) +
    theme_void(base_size = 11) +
    theme(
      plot.title    = element_text(face = "bold", size = 11.5,
                                   margin = margin(b = 6)),
      plot.caption  = element_text(size = 6.8, colour = "#555555",
                                   hjust = 0, margin = margin(t = 8)),
      legend.position = "right",
      legend.title  = element_text(size = 8.5),
      legend.text   = element_text(size = 8),
      plot.margin   = margin(10, 10, 10, 10)
    )
}

# ── 5) Build plots ─────────────────────────────────────────────────────────────
cat("\nBuilding maps...\n")

local_plot <- make_coverage_map(
  local_sf,
  "Share of settled population covered by reliability analysis - Local areas",
  label_flagged_only = TRUE
)

supply_plot <- make_coverage_map(
  supply_sf,
  "Share of settled population covered by reliability analysis - Supply areas",
  label_flagged_only = FALSE
)

# ── 6) Save ────────────────────────────────────────────────────────────────────
for (nm in c("local", "supply")) {
  p    <- get(paste0(nm, "_plot"))
  base <- file.path(FIG_DIR, paste0("coverage_map_", nm))
  ggsave(paste0(base, ".pdf"), plot = p, width = FIG_W, height = FIG_H)
  ggsave(paste0(base, ".png"), plot = p, width = FIG_W, height = FIG_H,
         dpi = FIG_DPI)
  cat("Saved coverage_map_", nm, ".pdf/.png\n", sep = "")
}
