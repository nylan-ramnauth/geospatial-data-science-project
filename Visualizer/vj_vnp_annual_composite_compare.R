rm(list = ls())

# ============================================================
# VJ146A4 vs VNP46A4 Annual Composite Comparison
# ============================================================
#
# Purpose:  Compare the 2023 VJ146A4 and VNP46A4 annual composites and
#           their calibrated settlement keep lists.
# Inputs:   - cached annual H5 tiles under blackmarbler/*/h5_cache_annual
#           - VJ and VNP yearly_settlement_stats_2023.parquet
#           - settlement GPKG for coordinates and context fields
# Outputs:  - side-by-side annual composite radiance panel
#           - side-by-side yearly-keep settlement panel
#           - settlement p_lit comparison scatter
#           - summary and disagreement CSVs
# Run:      Rscript Visualizer/vj_vnp_annual_composite_compare.R
# ============================================================

suppressPackageStartupMessages({
  library(here)
  library(sf)
  library(terra)
  library(arrow)
  library(data.table)
  library(ggplot2)
  library(patchwork)
  library(scales)
})

sf::sf_use_s2(FALSE)

BASE_PATH <- here::here()
YEAR_LABEL <- Sys.getenv("VJ146A2_YEAR", "2023")
ANNUAL_VARIABLE <- "NearNadir_Composite_Snow_Free"
ANNUAL_QUALITY_VARIABLE <- paste0(ANNUAL_VARIABLE, "_Quality")
QUALITY_FLAGS_DROP <- c(1, 2)

SETT_GPKG <- file.path(
  BASE_PATH,
  "Map Data",
  "Settlements",
  "GPKG",
  "south_africa_dre_atlas_settlements_full_col.gpkg"
)

VJ_STATS_PATH <- file.path(
  BASE_PATH,
  "Map Data",
  "reliability_outputs_vj146a2",
  paste0("yearly_settlement_stats_", YEAR_LABEL, ".parquet")
)
VNP_STATS_PATH <- file.path(
  BASE_PATH,
  "Map Data",
  "reliability_outputs_blackmarbler",
  paste0("yearly_settlement_stats_", YEAR_LABEL, ".parquet")
)

VJ_CALIB_PATH <- file.path(
  BASE_PATH,
  "Map Data",
  "reliability_outputs_vj146a2",
  paste0("vj146a2_yearly_keep_calibration_", YEAR_LABEL, ".csv")
)
VNP_CALIB_PATH <- file.path(
  BASE_PATH,
  "Map Data",
  "reliability_outputs_blackmarbler",
  paste0("yearly_composite_calibration_", YEAR_LABEL, ".csv")
)

VJ_H5_DIR <- file.path(BASE_PATH, "blackmarbler", "out_vj146a2_sa_daily", "h5_cache_annual")
VNP_H5_DIR <- file.path(BASE_PATH, "blackmarbler", "out_vnp46a2_sa_daily", "h5_cache_annual")

OUT_DIR <- file.path(BASE_PATH, "Map Data", "reliability_outputs_vj146a2")
FIG_DIR <- file.path(OUT_DIR, "figures")
DIAG_DIR <- file.path(OUT_DIR, "diagnostics")
dir.create(FIG_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(DIAG_DIR, recursive = TRUE, showWarnings = FALSE)

required_files <- c(SETT_GPKG, VJ_STATS_PATH, VNP_STATS_PATH, VJ_CALIB_PATH, VNP_CALIB_PATH)
missing_required <- required_files[!file.exists(required_files)]
if (length(missing_required) > 0) {
  stop("Missing required comparison inputs:\n", paste(missing_required, collapse = "\n"))
}

read_best_calib <- function(path) {
  calib <- data.table::fread(path)
  share_col <- "share_population_electrified"
  if (!(share_col %in% names(calib))) stop("Missing ", share_col, " in ", path)
  calib[which.min(abs(get(share_col) - target_population_share))]
}

read_stats <- function(path, suffix) {
  stats <- as.data.table(arrow::read_parquet(path, as_data_frame = TRUE))
  keep <- c(
    "settlement_id", "population", "mean_rad", "coverage_share",
    "p_lit_sett_year", "support_ok", "electrified_best",
    "settlement_lit_threshold_best", "annual_source_product",
    "annual_source_variable", "annual_fallback_used",
    "annual_fallback_reason", "yearly_method"
  )
  keep <- intersect(keep, names(stats))
  stats <- stats[, ..keep]
  stats[, settlement_id := as.character(settlement_id)]
  data.table::setnames(
    stats,
    setdiff(names(stats), c("settlement_id", "population")),
    paste0(setdiff(names(stats), c("settlement_id", "population")), "_", suffix)
  )
  stats
}

annual_h5_files <- function(product_id, h5_dir) {
  pattern <- paste0("^", product_id, "\\.A", YEAR_LABEL, "001\\..*\\.h5$")
  files <- list.files(h5_dir, pattern = pattern, full.names = TRUE)
  if (length(files) == 0) stop("No cached ", product_id, " annual H5 tiles found in ", h5_dir)
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
  names(rad) <- "rad"
  rad
}

read_annual_mosaic <- function(product_id, h5_dir, crop_extent) {
  files <- annual_h5_files(product_id, h5_dir)
  cat("Reading", length(files), product_id, "annual tiles from", h5_dir, "\n")
  tiles <- lapply(files, read_annual_tile)
  mosaic <- if (length(tiles) == 1) tiles[[1]] else do.call(terra::merge, tiles)
  terra::crop(mosaic, crop_extent)
}

raster_plot_data <- function(r, product_label, target_cells = 650000) {
  fact <- max(1L, ceiling(sqrt(terra::ncell(r) / target_cells)))
  if (fact > 1L) {
    r <- terra::aggregate(r, fact = fact, fun = "mean", na.rm = TRUE)
  }
  d <- as.data.table(as.data.frame(r, xy = TRUE, na.rm = FALSE))
  d <- d[is.finite(rad)]
  d[, product := product_label]
  d
}

write_radiance_panel <- function(vj_r, vnp_r, zaf_outline) {
  vj_d <- raster_plot_data(vj_r, "VJ146A4")
  vnp_d <- raster_plot_data(vnp_r, "VNP46A4")
  d <- rbindlist(list(vj_d, vnp_d), use.names = TRUE)
  d[, rad_display := pmax(rad, 0.01)]
  cap <- quantile(d[rad > 0, rad], probs = 0.995, na.rm = TRUE)
  if (!is.finite(cap) || cap <= 0.01) cap <- max(d$rad_display, na.rm = TRUE)

  p <- ggplot(d, aes(x = x, y = y, fill = rad_display)) +
    geom_raster() +
    geom_sf(data = zaf_outline, inherit.aes = FALSE, fill = NA, color = "grey20", linewidth = 0.25) +
    facet_wrap(~ product, nrow = 1) +
    coord_sf(expand = FALSE) +
    scale_fill_viridis_c(
      option = "magma",
      trans = "log10",
      limits = c(0.01, cap),
      oob = scales::squish,
      name = "Radiance\n(log scale)"
    ) +
    labs(
      title = paste0("Annual Black Marble composite, ", YEAR_LABEL),
      subtitle = paste0(ANNUAL_VARIABLE, "; quality flags 1/2 masked; color scale capped at 99.5th percentile"),
      x = NULL,
      y = NULL
    ) +
    theme_minimal(base_size = 11) +
    theme(
      panel.grid = element_blank(),
      legend.position = "right",
      strip.text = element_text(face = "bold"),
      plot.title = element_text(face = "bold")
    )

  out <- file.path(FIG_DIR, paste0("vj_vnp_annual_composite_radiance_panel_", YEAR_LABEL, ".png"))
  ggsave(out, p, width = 13, height = 7.2, dpi = 220)
  cat("Wrote:", out, "\n")
  out
}

write_settlement_panel <- function(sett_xy, stats_cmp, zaf_outline) {
  status <- rbindlist(list(
    stats_cmp[, .(
      settlement_id,
      product = "VJ146A4 keep",
      electrified_best = electrified_best_vj,
      p_lit_sett_year = p_lit_sett_year_vj
    )],
    stats_cmp[, .(
      settlement_id,
      product = "VNP46A4 keep",
      electrified_best = electrified_best_vnp,
      p_lit_sett_year = p_lit_sett_year_vnp
    )]
  ), use.names = TRUE)
  d <- merge(sett_xy, status, by = "settlement_id", all.x = FALSE, all.y = TRUE)
  d[, kept := fifelse(electrified_best == 1, "kept", "not kept")]

  p <- ggplot() +
    geom_sf(data = zaf_outline, fill = "grey96", color = "grey65", linewidth = 0.25) +
    geom_point(
      data = d[kept == "not kept"],
      aes(x = lon, y = lat),
      color = "grey78",
      size = 0.18,
      alpha = 0.35
    ) +
    geom_point(
      data = d[kept == "kept"],
      aes(x = lon, y = lat, color = p_lit_sett_year),
      size = 0.35,
      alpha = 0.9
    ) +
    facet_wrap(~ product, nrow = 1) +
    coord_sf(expand = FALSE) +
    scale_color_viridis_c(option = "plasma", limits = c(0, 1), name = "Settlement\nlit share") +
    labs(
      title = paste0("Calibrated annual settlement keep lists, ", YEAR_LABEL),
      subtitle = "Grey settlements are outside each product's calibrated annual keep list",
      x = NULL,
      y = NULL
    ) +
    theme_minimal(base_size = 11) +
    theme(
      panel.grid = element_blank(),
      legend.position = "right",
      strip.text = element_text(face = "bold"),
      plot.title = element_text(face = "bold")
    )

  out <- file.path(FIG_DIR, paste0("vj_vnp_yearlykeep_settlement_panel_", YEAR_LABEL, ".png"))
  ggsave(out, p, width = 13, height = 7.2, dpi = 220)
  cat("Wrote:", out, "\n")
  out
}

write_scatter <- function(stats_cmp) {
  d <- copy(stats_cmp)
  d[, status := fifelse(
    electrified_best_vnp == 1 & electrified_best_vj == 1, "both kept",
    fifelse(
      electrified_best_vnp == 1 & electrified_best_vj == 0, "VNP only",
      fifelse(electrified_best_vnp == 0 & electrified_best_vj == 1, "VJ only", "neither")
    )
  )]
  status_cols <- c(
    "both kept" = "#1b9e77",
    "VNP only" = "#d95f02",
    "VJ only" = "#7570b3",
    "neither" = "grey78"
  )
  th_vj <- unique(na.omit(d$settlement_lit_threshold_best_vj))[1]
  th_vnp <- unique(na.omit(d$settlement_lit_threshold_best_vnp))[1]

  p <- ggplot(d, aes(x = p_lit_sett_year_vnp, y = p_lit_sett_year_vj, color = status)) +
    geom_abline(slope = 1, intercept = 0, color = "grey45", linewidth = 0.3) +
    geom_vline(xintercept = th_vnp, linetype = "dashed", color = "#d95f02", linewidth = 0.45) +
    geom_hline(yintercept = th_vj, linetype = "dashed", color = "#7570b3", linewidth = 0.45) +
    geom_point(alpha = 0.45, size = 0.45) +
    scale_color_manual(values = status_cols, name = NULL) +
    scale_x_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.25)) +
    scale_y_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.25)) +
    labs(
      title = paste0("Settlement annual lit-share comparison, ", YEAR_LABEL),
      subtitle = paste0("Dashed lines show calibrated thresholds: VNP=", th_vnp, ", VJ=", th_vj),
      x = "VNP46A4 p_lit_sett_year",
      y = "VJ146A4 p_lit_sett_year"
    ) +
    theme_minimal(base_size = 11) +
    theme(
      legend.position = "bottom",
      plot.title = element_text(face = "bold")
    )

  out <- file.path(FIG_DIR, paste0("vj_vnp_yearly_p_lit_scatter_", YEAR_LABEL, ".png"))
  ggsave(out, p, width = 8.5, height = 7.5, dpi = 220)
  cat("Wrote:", out, "\n")
  out
}

write_summary_tables <- function(stats_cmp, vj_best, vnp_best, sett_meta) {
  stats_cmp[, status := fifelse(
    electrified_best_vnp == 1 & electrified_best_vj == 1, "both_kept",
    fifelse(
      electrified_best_vnp == 1 & electrified_best_vj == 0, "vnp_only",
      fifelse(electrified_best_vnp == 0 & electrified_best_vj == 1, "vj_only", "neither")
    )
  )]
  stats_cmp[, p_lit_diff_vj_minus_vnp := p_lit_sett_year_vj - p_lit_sett_year_vnp]
  stats_cmp[, mean_rad_diff_vj_minus_vnp := mean_rad_vj - mean_rad_vnp]

  summary <- rbindlist(list(
    data.table(
      product = "VJ146A4",
      annual_source_product = unique(na.omit(stats_cmp$annual_source_product_vj))[1],
      annual_fallback_used = unique(na.omit(stats_cmp$annual_fallback_used_vj))[1],
      settlement_threshold = vj_best$settlement_lit_threshold,
      settlements_total = vj_best$n_settlements_total,
      settlements_support_ok = vj_best$n_settlements_support_ok,
      settlements_electrified = vj_best$n_settlements_electrified,
      share_settlements_electrified = vj_best$share_settlements_electrified,
      population_total = vj_best$population_total,
      population_electrified = vj_best$population_electrified,
      share_population_electrified = vj_best$share_population_electrified,
      target_population_share = vj_best$target_population_share,
      abs_error = vj_best$abs_error
    ),
    data.table(
      product = "VNP46A4",
      annual_source_product = "VNP46A4",
      annual_fallback_used = FALSE,
      settlement_threshold = vnp_best$settlement_lit_threshold,
      settlements_total = vnp_best$n_settlements_total,
      settlements_support_ok = vnp_best$n_settlements_support_ok,
      settlements_electrified = vnp_best$n_settlements_electrified,
      share_settlements_electrified = vnp_best$share_settlements_electrified,
      population_total = vnp_best$population_total,
      population_electrified = vnp_best$population_electrified,
      share_population_electrified = vnp_best$share_population_electrified,
      target_population_share = vnp_best$target_population_share,
      abs_error = vnp_best$abs_error
    )
  ), use.names = TRUE, fill = TRUE)

  summary_out <- file.path(DIAG_DIR, paste0("vj_vnp_annual_keep_summary_", YEAR_LABEL, ".csv"))
  fwrite(summary, summary_out)
  cat("Wrote:", summary_out, "\n")

  disagreement <- stats_cmp[, .(
    settlements = .N,
    population = sum(population, na.rm = TRUE),
    mean_population = mean(population, na.rm = TRUE),
    median_population = median(population, na.rm = TRUE),
    mean_p_lit_vnp = mean(p_lit_sett_year_vnp, na.rm = TRUE),
    mean_p_lit_vj = mean(p_lit_sett_year_vj, na.rm = TRUE),
    median_p_lit_vnp = median(p_lit_sett_year_vnp, na.rm = TRUE),
    median_p_lit_vj = median(p_lit_sett_year_vj, na.rm = TRUE),
    mean_p_lit_diff_vj_minus_vnp = mean(p_lit_diff_vj_minus_vnp, na.rm = TRUE),
    mean_rad_vnp = mean(mean_rad_vnp, na.rm = TRUE),
    mean_rad_vj = mean(mean_rad_vj, na.rm = TRUE)
  ), by = status][order(status)]

  disagreement_out <- file.path(DIAG_DIR, paste0("vj_vnp_annual_keep_disagreement_summary_", YEAR_LABEL, ".csv"))
  fwrite(disagreement, disagreement_out)
  cat("Wrote:", disagreement_out, "\n")

  detail <- merge(
    stats_cmp[status %in% c("vnp_only", "vj_only")],
    sett_meta,
    by = "settlement_id",
    all.x = TRUE
  )
  regional <- detail[, .(
    settlements = .N,
    population = sum(population, na.rm = TRUE),
    median_population = median(population, na.rm = TRUE),
    mean_p_lit_vnp = mean(p_lit_sett_year_vnp, na.rm = TRUE),
    mean_p_lit_vj = mean(p_lit_sett_year_vj, na.rm = TRUE),
    mean_p_lit_diff_vj_minus_vnp = mean(p_lit_diff_vj_minus_vnp, na.rm = TRUE)
  ), by = .(status, admin_cgaz_1)][order(status, -settlements)]
  regional_out <- file.path(DIAG_DIR, paste0("vj_vnp_annual_keep_disagreement_by_province_", YEAR_LABEL, ".csv"))
  fwrite(regional, regional_out)
  cat("Wrote:", regional_out, "\n")

  detail <- detail[order(status, -population)]
  keep_cols <- c(
    "status", "settlement_id", "village_name", "admin_cgaz_1", "admin_cgaz_2",
    "population", "p_lit_sett_year_vnp", "p_lit_sett_year_vj",
    "p_lit_diff_vj_minus_vnp", "mean_rad_vnp", "mean_rad_vj",
    "coverage_share_vnp", "coverage_share_vj", "support_ok_vnp", "support_ok_vj"
  )
  keep_cols <- intersect(keep_cols, names(detail))
  detail_out <- file.path(DIAG_DIR, paste0("vj_vnp_annual_keep_disagreement_detail_", YEAR_LABEL, ".csv"))
  fwrite(detail[, ..keep_cols], detail_out)
  cat("Wrote:", detail_out, "\n")

  invisible(list(
    summary = summary_out,
    disagreement = disagreement_out,
    regional = regional_out,
    detail = detail_out
  ))
}

cat("Reading settlements and yearly stats...\n")
sett <- sf::st_read(SETT_GPKG, quiet = TRUE)
sett$settlement_id <- as.character(sett$settlement_id)
sett_xy <- as.data.table(sf::st_drop_geometry(sett))[, .(
  settlement_id,
  village_name,
  admin_cgaz_1,
  admin_cgaz_2,
  lon = as.numeric(lon),
  lat = as.numeric(lat)
)]
sett_meta <- copy(sett_xy)[, c("lon", "lat") := NULL]

zaf_outline_path <- file.path(BASE_PATH, "blackmarbler", "out_vj146a2_sa_daily", "gadm", "gadm", "gadm41_ZAF_0_pk.rds")
if (file.exists(zaf_outline_path)) {
  zaf_outline <- readRDS(zaf_outline_path)
  zaf_outline <- sf::st_as_sf(zaf_outline)
  zaf_outline <- sf::st_transform(zaf_outline, 4326)
} else {
  zaf_outline <- sf::st_as_sf(sf::st_as_sfc(sf::st_bbox(sett)))
}

sett_bbox <- sf::st_bbox(sf::st_transform(sett, 4326))
crop_extent <- terra::ext(
  sett_bbox[["xmin"]],
  sett_bbox[["xmax"]],
  sett_bbox[["ymin"]],
  sett_bbox[["ymax"]]
)

vj_stats <- read_stats(VJ_STATS_PATH, "vj")
vnp_stats <- read_stats(VNP_STATS_PATH, "vnp")
stats_cmp <- merge(vnp_stats, vj_stats, by = c("settlement_id", "population"), all = TRUE)

vj_best <- read_best_calib(VJ_CALIB_PATH)
vnp_best <- read_best_calib(VNP_CALIB_PATH)

write_summary_tables(stats_cmp, vj_best, vnp_best, sett_meta)

cat("Building annual composite raster panel...\n")
vj_r <- read_annual_mosaic("VJ146A4", VJ_H5_DIR, crop_extent)
vnp_r <- read_annual_mosaic("VNP46A4", VNP_H5_DIR, crop_extent)
write_radiance_panel(vj_r, vnp_r, zaf_outline)

cat("Building settlement comparison panels...\n")
write_settlement_panel(sett_xy, stats_cmp, zaf_outline)
write_scatter(stats_cmp)

cat("Done.\n")
