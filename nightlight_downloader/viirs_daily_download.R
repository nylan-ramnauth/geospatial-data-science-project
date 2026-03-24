# ============================================================
# Download Daily VIIRS Night-Light Rasters (NASA LAADS / blackmarbler)
# Stage 0 — Data Acquisition
# ============================================================
#
# Purpose:  Downloads VNP46A2 BRDF-corrected, no-gap-fill daily radiance
#           for South Africa via the blackmarbler R package; applies
#           quality filters (cloud mask, Mandatory QF, snow flag) and
#           writes one 3-band GeoTIFF (rad, lit, valid) per day.
# Inputs:   - NASA Earthdata credentials in ~/.Renviron (EARTHDATA_USER / EARTHDATA_PASS)
#           - blackmarbler/blackmarbletiles.geojson  (local tiles cache)
# Outputs:  - blackmarbler/out_vnp46a2_sa_daily/sa_viirs_500m_daily_YYYY-MM-DD.tif
# Run:      Rscript nightlight_downloader/viirs_daily_download.R
# ============================================================

rm(list = ls())

# ---- CONFIG (edit for your machine) ----
BASE_PATH <- here::here()

library(here)
library(sf)
library(terra)
library(blackmarbler)
library(geodata)

# ---- Patch blackmarbler to read tiles GeoJSON from local file (no sf patching) ----

tiles_url  <- "https://raw.githubusercontent.com/worldbank/blackmarbler/main/data/blackmarbletiles.geojson"
tiles_path <- file.path(BASE_PATH, "blackmarbler", "blackmarbletiles.geojson")
stopifnot(file.exists(tiles_path))

ns <- asNamespace("blackmarbler")
objs <- ls(envir = ns, all.names = TRUE)

# Find all functions in blackmarbler that mention the tiles URL
hit_fns <- Filter(function(nm) {
  obj <- tryCatch(get(nm, envir = ns), error = function(e) NULL)
  if (!is.function(obj)) return(FALSE)
  txt <- paste(deparse(body(obj)), collapse = "\n")
  grepl(tiles_url, txt, fixed = TRUE)
}, objs)

if (length(hit_fns) == 0) {
  stop("Could not find tiles URL inside blackmarbler namespace. ",
       "Either the URL changed or it's constructed indirectly. ",
       "Next step: grep the installed package files on disk.")
}

message("[PATCH] Found tiles URL in: ", paste(hit_fns, collapse = ", "))

# Patch each hit function *inside the namespace*
for (nm in hit_fns) {
  f <- get(nm, envir = ns)
  f_txt <- paste(deparse(body(f)), collapse = "\n")
  f_txt2 <- gsub(tiles_url, tiles_path, f_txt, fixed = TRUE)
  
  f2 <- f
  body(f2) <- parse(text = f_txt2)
  
  unlockBinding(nm, ns)
  assign(nm, f2, envir = ns)
  lockBinding(nm, ns)
}

# Quick sanity check: confirm patched function bodies now contain local path
for (nm in hit_fns) {
  f <- get(nm, envir = ns)
  f_txt <- paste(deparse(body(f)), collapse = "\n")
  message("[PATCH-CHECK] ", nm, " has local path? ",
          grepl(tiles_path, f_txt, fixed = TRUE))
}
# ---------------------------------------------------------------------------

# ----------------------------
# AUTH (Earthdata)
# ----------------------------
# Recommended: set EARTHDATA_USER and EARTHDATA_PASS in ~/.Renviron
# and restart R, then:
# Sys.getenv("EARTHDATA_USER"); Sys.getenv("EARTHDATA_PASS")

bearer <- blackmarbler::get_nasa_token(
  username = Sys.getenv("EARTHDATA_USER"),
  password = Sys.getenv("EARTHDATA_PASS")
)

stopifnot(nzchar(bearer))

# ----------------------------
# User inputs
# ----------------------------
start_date <- as.Date("2023-07-26")
end_date   <- as.Date("2024-01-01") # exclusive

LIT_THRESHOLD <- 1.0
ALLOW_CLOUD_CONF_MAX <- 1L  # 0 strict, 1 probably clear, 2 lenient
MANDATORY_QF_MAX <- 0L      # 0 (strict) or 1 (less strict)

# Prefer non-gap-filled like your GEE script; if you see too many NAs, set TRUE.
USE_GAP_FILLED <- FALSE

out_dir  <- file.path(BASE_PATH, "blackmarbler", "out_vnp46a2_sa_daily")
h5_cache <- file.path(out_dir, "h5_cache")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(h5_cache, recursive = TRUE, showWarnings = FALSE)
stopifnot(dir.exists(h5_cache))
stopifnot(file.access(h5_cache, 2) == 0)

# ----------------------------
# ROI: South Africa polygon (EPSG:4326)
# ----------------------------
sa <- geodata::gadm(country = "ZAF", level = 0, path = file.path(out_dir, "gadm")) |>
  st_as_sf() |>
  st_transform(4326)


lso <- geodata::gadm(country="LSO", level=0, path=file.path(out_dir,"gadm")) |>
  st_as_sf() |>
  st_transform(4326)

# Make sure both are valid geometries
sa_g  <- st_make_valid(st_geometry(sa))
lso_g <- st_make_valid(st_geometry(lso))

# Union to single parts, then subtract
sa_clip_g <- st_difference(st_union(sa_g), st_union(lso_g))

# Replace SA geometry with the result (keeps 1-row attributes)
sa <- st_set_geometry(sa, sa_clip_g)

sa <- st_make_valid(sa)
sa <- st_cast(sa, "MULTIPOLYGON")


# ----------------------------
# Variable names (may differ by release)
# If you get "invalid variable", run once:
# blackmarbler::bm_raster(sa, product_id="VNP46A2", date="2023-01-01",
#                         bearer=bearer, variable="")
# ----------------------------
VAR_RAD <- if (USE_GAP_FILLED) {
  "Gap_Filled_DNB_BRDF-Corrected_NTL"
} else {
  "DNB_BRDF-Corrected_NTL"
}

VAR_QF    <- "Mandatory_Quality_Flag"
VAR_CLOUD <- "QF_Cloud_Mask"
VAR_SNOW  <- "Snow_Flag"

# ----------------------------
# Helpers
# ----------------------------

# Extract cloud confidence bits 6-7: (x >> 6) & 3
cloud_conf_fun <- function(x) {
  x <- as.integer(round(x))
  bitwAnd(bitwShiftR(x, 6L), 3L)
}



# Download one variable as SpatRaster (mosaic + clip handled by bm_raster)
get_bm <- function(var, d_iso) {
  blackmarbler::bm_raster(
    roi_sf = sa,
    product_id = "VNP46A2",
    date = d_iso,
    bearer = bearer,
    variable = var,
    output_location_type = "memory",
    h5_dir = h5_cache,
    quiet = TRUE
  )
}

# Enforce fixed grid (template) for strict reproducibility downstream
align_to_template <- function(r, template, method = "near") {
  if (all.equal(terra::res(r), terra::res(template)) &&
      all.equal(terra::ext(r), terra::ext(template)) &&
      all.equal(terra::crs(r), terra::crs(template))) {
    return(r)
  }
  terra::resample(r, template, method = method)
}

# ----------------------------
# Main loop
# ----------------------------
dates <- seq.Date(start_date, end_date - 1, by = "day")
template <- NULL

# Ensure dates is a Date sequence


for (i in seq_along(dates)) {
  
  d <- dates[i]                       # Date object
  stopifnot(inherits(d, "Date"))
  d_iso <- format(d, "%Y-%m-%d")      # "YYYY-MM-DD"
  
  cat("\n---", d_iso, "---\n")
  
  # 1) Download radiance + QA layers (pass ISO date string)
  rad   <- get_bm(VAR_RAD,   d_iso)
  qf    <- get_bm(VAR_QF,    d_iso)
  cloud <- get_bm(VAR_CLOUD, d_iso)
  snow  <- get_bm(VAR_SNOW,  d_iso)
  
  # Basic sanity checks (fail fast)
  # Skip if any layer is missing (bm_raster can return NULL when it "skips")
  if (!inherits(rad, "SpatRaster") ||
      !inherits(qf, "SpatRaster") ||
      !inherits(cloud, "SpatRaster") ||
      !inherits(snow, "SpatRaster")) {
    
    cat("SKIP:", d_iso, " -> no imagery / missing layer(s)\n")
    next
  }
  
  # 2) Set template grid from first day radiance
  if (is.null(template)) template <- rad
  
  # 3) Align all layers to template grid
  rad   <- align_to_template(rad,   template, method = "near")
  qf    <- align_to_template(qf,    template, method = "near")
  cloud <- align_to_template(cloud, template, method = "near")
  snow  <- align_to_template(snow,  template, method = "near")
  
  # 4) Compute cloud confidence bits 6-7
  cloud_conf <- terra::app(cloud, cloud_conf_fun)
  
  # 5) Build valid mask (0/1)
  valid_logical <- (cloud_conf <= ALLOW_CLOUD_CONF_MAX) &
    (qf <= MANDATORY_QF_MAX) &
    (snow == 0)
  
  # Robust: treat NA as invalid (0), ensure valid has no NA
  valid <- terra::ifel(valid_logical, 1, 0)
  valid <- terra::ifel(is.na(valid_logical), 0, valid)
  names(valid) <- "valid"
  
  # Diagnostics: share of valid pixels (now deterministic)
  valid_rate <- terra::global(valid, "mean")[1, 1]
  cat("Valid share (all pixels):", round(100 * valid_rate, 3), "%\n")
  
  # 6) Mask radiance to valid pixels (rad = NA when valid == 0)
  rad_masked <- terra::mask(rad, valid, maskvalues = 0, updatevalue = NA)
  names(rad_masked) <- "rad"
  
  # 7) lit: 1 if rad > threshold within valid pixels (NA outside valid)
  lit <- terra::ifel(is.na(rad_masked), NA, terra::ifel(rad_masked > LIT_THRESHOLD, 1, 0))
  names(lit) <- "lit"
  
  # 8) Write a 3-band GeoTIFF per day
  out <- c(rad_masked, lit, valid)
  out_file <- file.path(out_dir, sprintf("sa_viirs_500m_daily_%s.tif", d_iso))
  
  terra::writeRaster(out, out_file, overwrite = TRUE,
                     wopt = list(gdal = c("COMPRESS=LZW")))
  cat("Wrote:", out_file, "\n")
}


cat("\nDone.\n")
