# ============================================================
# Clean Africa Energy Tracker (Excel) -> South Africa POWER PLANTS only (sf + parquet)
# - Fixes cross-sheet type mismatches by coercing raw columns to character before bind_rows()
# - Filters out non-power infrastructure (terminals, mines, pipelines, etc.)
# - Infers missing fuel_or_tech from sheet name (e.g., coal sheet -> "Coal")
# ============================================================

rm(list = ls())

suppressPackageStartupMessages({
  library(here)
  library(readxl)
  library(dplyr)
  library(stringr)
  library(janitor)
  library(purrr)
  library(sf)
  library(arrow)
  library(readr)
})

sf::sf_use_s2(FALSE)

# -----------------------------
# PATHS (EDIT)
# -----------------------------
BASE_PATH <- here::here()
IN_XLSX   <- file.path(BASE_PATH, "Map Data", "Generators Data", "Africa-Energy-Tracker-2025-10-21.xlsx")

OUT_DIR   <- file.path(BASE_PATH, "Map Data", "Generators Data", "generators_outputs")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

OUT_GPKG  <- file.path(OUT_DIR, "south_africa_power_plants.gpkg")
OUT_PARQ  <- file.path(OUT_DIR, "south_africa_power_plants.parquet")
OUT_GEOJ  <- file.path(OUT_DIR, "south_africa_power_plants.geojson")

# -----------------------------
# HELPERS
# -----------------------------

pick_col <- function(df, candidates) {
  nm <- names(df)
  hit <- candidates[candidates %in% nm]
  if (length(hit) == 0) NA_character_ else hit[1]
}

to_num <- function(x) {
  readr::parse_number(as.character(x), na = c("", "NA", "NaN", "NULL", "null"))
}

# Infer fuel/tech category from sheet name (only used when fuel_or_tech is missing/blank)
infer_fuel_from_sheet <- function(sheet_name) {
  s <- str_to_lower(sheet_name)
  
  # Common generation categories
  if (str_detect(s, "coal")) return("Coal")
  if (str_detect(s, "gas")) return("Gas")
  if (str_detect(s, "oil|diesel|fuel\\s*oil")) return("Oil")
  if (str_detect(s, "nuclear")) return("Nuclear")
  if (str_detect(s, "hydro|hydroelectric")) return("Hydro")
  if (str_detect(s, "wind")) return("Wind")
  if (str_detect(s, "solar|pv")) return("Solar")
  if (str_detect(s, "csp|solar\\s*thermal|thermosolar")) return("Solar Thermal")
  if (str_detect(s, "geothermal")) return("Geothermal")
  if (str_detect(s, "biomass|bioenergy|biogas|waste")) return("Bioenergy")
  
  NA_character_
}

# Classify sheet as "power generation sheet" vs "other infrastructure sheet"
is_power_sheet <- function(sheet_name) {
  s <- str_to_lower(sheet_name)
  
  # Hard-exclude common non-power infrastructure (adjust if your workbook uses different wording)
  exclude <- str_detect(s, paste(
    c("mine", "mines", "terminal", "lng", "lpg", "port", "pipeline", "pipelines",
      "storage", "refinery", "refineries", "field", "fields", "well", "wells",
      "platform", "platforms", "shipping", "tanker", "export", "import", "depot",
      "transmission", "substation", "grid", "rail", "road"),
    collapse = "|"
  ))
  if (exclude) return(FALSE)
  
  # Include sheets that look like generation / power plants
  include <- str_detect(s, paste(
    c("power", "plant", "generation", "electric", "coal", "gas", "oil",
      "nuclear", "hydro", "wind", "solar", "pv", "csp", "geothermal",
      "biomass", "bioenergy", "waste"),
    collapse = "|"
  ))
  
  include
}

# Row-level "not a power plant" filter (extra safety)
# Uses plant_name + a couple other fields if present to detect mines/terminals/etc.
row_looks_like_non_power <- function(plant_name, source_sheet, city = NA_character_, province = NA_character_) {
  txt <- paste(plant_name, source_sheet, city, province, sep = " | ") %>%
    str_to_lower() %>%
    str_squish()
  
  str_detect(txt, paste(
    c("mine", "mines", "terminal", "lng", "lpg", "pipeline", "storage", "refinery",
      "export", "import", "depot", "port", "well", "field", "platform"),
    collapse = "|"
  ))
}

standardise_sheet <- function(sheet_name) {
  
  # Skip obviously irrelevant sheets early
  if (!is_power_sheet(sheet_name)) return(NULL)
  
  # Read sheet + standardize column names
  df0 <- readxl::read_excel(IN_XLSX, sheet = sheet_name, .name_repair = "unique_quiet") |>
    janitor::clean_names()
  
  if (nrow(df0) == 0) return(NULL)
  
  # Prevent bind_rows() failures: coerce all raw columns to character
  df <- df0 |> mutate(across(everything(), ~ as.character(.x)))
  
  # Candidate column names (post-clean_names)
  col_country <- pick_col(df, c("country", "country_area", "country_or_area", "area", "country_region"))
  col_name    <- pick_col(df, c("plant_name", "project_name", "facility_name", "name"))
  col_status  <- pick_col(df, c("status", "project_status", "plant_status"))
  col_cap     <- pick_col(df, c("capacity_mw", "capacity", "capacity_mw_net", "capacity_mw_gross", "mw"))
  col_lat     <- pick_col(df, c("latitude", "lat", "y"))
  col_lon     <- pick_col(df, c("longitude", "lon", "lng", "long", "x"))
  col_city    <- pick_col(df, c("city", "town", "locality"))
  col_prov    <- pick_col(df, c("province", "state", "admin_1", "admin1", "region"))
  col_fuel    <- pick_col(df, c("fuel", "fuel_type", "technology", "tech", "primary_fuel", "type", "fuel_or_tech"))
  
  # Optional IDs / references
  col_gem_loc <- pick_col(df, c("gem_location_id", "location_id", "gem_id", "project_id"))
  col_gem_unit<- pick_col(df, c("gem_unit_id", "unit_id"))
  col_wiki    <- pick_col(df, c("wiki_url", "url", "source_url"))
  
  out <- df |>
    mutate(
      source_sheet = sheet_name,
      
      country_area = if (!is.na(col_country)) df[[col_country]] else NA_character_,
      plant_name   = if (!is.na(col_name))    df[[col_name]]    else NA_character_,
      status       = if (!is.na(col_status))  df[[col_status]]  else NA_character_,
      
      capacity_mw  = if (!is.na(col_cap)) to_num(df[[col_cap]]) else NA_real_,
      latitude     = if (!is.na(col_lat)) to_num(df[[col_lat]]) else NA_real_,
      longitude    = if (!is.na(col_lon)) to_num(df[[col_lon]]) else NA_real_,
      
      city         = if (!is.na(col_city)) df[[col_city]] else NA_character_,
      province     = if (!is.na(col_prov)) df[[col_prov]] else NA_character_,
      
      fuel_or_tech_raw = if (!is.na(col_fuel)) df[[col_fuel]] else NA_character_,
      fuel_or_tech = {
        inferred <- infer_fuel_from_sheet(sheet_name)
        x <- fuel_or_tech_raw
        x <- ifelse(is.na(x) | str_squish(x) == "", inferred, x)
        x
      },
      
      gem_location_id = if (!is.na(col_gem_loc)) df[[col_gem_loc]] else NA_character_,
      gem_unit_id     = if (!is.na(col_gem_unit)) df[[col_gem_unit]] else NA_character_,
      wiki_url        = if (!is.na(col_wiki)) df[[col_wiki]] else NA_character_
    ) |>
    select(
      source_sheet, country_area, plant_name, status, capacity_mw,
      latitude, longitude, city, province, fuel_or_tech,
      gem_location_id, gem_unit_id, wiki_url,
      everything()
    )
  
  out
}

# -----------------------------
# 1) READ + STACK ALL *POWER-LIKE* SHEETS
# -----------------------------
sheets <- readxl::excel_sheets(IN_XLSX)

raw_all <- purrr::map(sheets, standardise_sheet) |>
  purrr::compact() |>
  bind_rows()

stopifnot(nrow(raw_all) > 0)

# -----------------------------
# 2) FILTER TO SOUTH AFRICA
# -----------------------------
sa <- raw_all |>
  mutate(country_area_norm = str_squish(str_to_lower(country_area))) |>
  filter(country_area_norm %in% c("south africa", "republic of south africa")) |>
  select(-country_area_norm)

# -----------------------------
# 3) DROP NON-POWER ROWS (EXTRA SAFETY)
# -----------------------------
sa <- sa |>
  filter(!row_looks_like_non_power(plant_name, source_sheet, city, province))

# -----------------------------
# 4) CLEAN COORDS + BASIC VALIDATION
# -----------------------------
sa <- sa |>
  filter(!is.na(longitude), !is.na(latitude)) |>
  filter(longitude >= -180, longitude <= 180, latitude >= -90, latitude <= 90)

# -----------------------------
# 5) MAKE sf (POINTS)
# -----------------------------
sa_sf <- st_as_sf(sa, coords = c("longitude", "latitude"), crs = 4326, remove = FALSE)

# -----------------------------
# 6) WRITE OUTPUTS
# -----------------------------
st_write(sa_sf, OUT_GPKG, layer = "generators_sa", delete_layer = TRUE, quiet = TRUE)
arrow::write_parquet(st_drop_geometry(sa_sf), OUT_PARQ)
st_write(sa_sf, OUT_GEOJ, delete_dsn = TRUE, quiet = TRUE)

cat("Wrote:\n")
cat(" -", OUT_GPKG, "\n")
cat(" -", OUT_PARQ, "\n")
cat(" -", OUT_GEOJ, "\n")

# -----------------------------
# 7) QUICK AUDIT
# -----------------------------
kept <- names(st_drop_geometry(sa_sf))
core <- c("plant_name", "capacity_mw", "status", "latitude", "longitude", "city", "province", "fuel_or_tech", "source_sheet")
cat("\nCore fields present:\n")
print(setNames(core %in% kept, core))

cat("\nFuel_or_tech missing after inference:\n")
cat(sum(is.na(sa_sf$fuel_or_tech) | str_squish(sa_sf$fuel_or_tech) == ""), "rows\n")

cat("\nTop fuel_or_tech values:\n")
print(sa_sf |>
        st_drop_geometry() |>
        count(fuel_or_tech, sort = TRUE) |>
        head(20))
