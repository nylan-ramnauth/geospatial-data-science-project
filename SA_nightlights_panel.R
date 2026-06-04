# Housekeeping
rm(list = ls())


#Imports

library(sf)
library(dplyr)
library(terra)
library(arrow)
library(tidyverse)
library(leaflet)
library(geodata)
library(readxl)
library(janitor)
#library(purr)
library(stringr)
library(viridisLite)
library(htmlwidgets)
library(htmltools)
library(ggplot2)
library(data.table)

# open data

setwd("C:/Users/Ravi/Documents/BGSE/QSM 2/")

# Settlements full parquet
settlement_day <- arrow::read_parquet(
  "settlements_simplified_with_panel_nogap_HQ_daily.parquet"
)

# Hourly Eskom Data

eskom_jan <- read_csv("eskom_data.csv")

eskom <- eskom_jan %>%
  rename(datetime = `...1`) %>%
  select(-`0`)

eskom <- eskom %>%
  mutate(
    datetime = ymd_hm(datetime),
    date     = as.Date(datetime),
    hour     = hour(datetime)
  )

eskom_overpass <- eskom %>%
  filter(hour %in% c(1, 2))

###### NATIONAL OVERPASS COMPARISON

# blackouts and demand, ESKOM
eskom_daily <- eskom_overpass %>%
  group_by(date) %>%
  summarise(
    mlr_mean_1_2am = mean(`Manual Load_Reduction(MLR)`, na.rm = TRUE),
    mlr_max_1_2am  = max(`Manual Load_Reduction(MLR)`,  na.rm = TRUE),
    contracted_demand = mean(`RSA Contracted Demand`, na.rm = TRUE),
    .groups = "drop"
  )

settlement_day <- settlement_day %>%
  mutate(
    dark = p_lit_sett < 0.05
  )

national_nightlights <- settlement_day %>%
  filter(!is.na(population)) %>%
  group_by(date) %>%
  summarise(
    # Main national nightlights proxy
    nat_mean_p_lit = weighted.mean(p_lit_sett, population, na.rm = TRUE),
    
    # Alternative: population exposed to darkness
    nat_share_dark = weighted.mean(dark, population, na.rm = TRUE),
    
    total_population = sum(population, na.rm = TRUE),
    .groups = "drop"
  )

# combine them

national_panel <- national_nightlights %>%
  left_join(eskom_daily, by = "date")

# normalize for graph
max_mlr <- max(national_panel$mlr_max_1_2am, na.rm = TRUE)

national_panel <- national_panel %>%
  mutate(
    nat_mean_p_lit_scaled  = nat_mean_p_lit  * max_mlr,
    nat_share_dark_scaled  = nat_share_dark  * max_mlr
  )

# graph with all 4 variables to test
ggplot(national_panel, aes(x = date)) +
  
  # --- Load shedding bars ---
  geom_col(
    aes(y = mlr_mean_1_2am, fill = "Mean MLR (1–2am)"),
    alpha = 0.6,
    width = 0.8
  ) +
  
  geom_col(
    aes(y = mlr_max_1_2am, fill = "Max MLR (1–2am)"),
    alpha = 0.35,
    width = 0.8
  ) +
  
  # --- Nightlights lines ---
  geom_line(
    aes(y = nat_mean_p_lit_scaled, color = "Population-weighted mean light"),
    linewidth = 1.1
  ) +
  
  geom_line(
    aes(y = nat_share_dark_scaled, color = "Population share dark"),
    linewidth = 1.1,
    linetype = "dashed"
  ) +
  
  # --- Scales & labels ---
  scale_fill_manual(
    name = "Eskom load shedding",
    values = c(
      "Mean MLR (1–2am)" = "firebrick",
      "Max MLR (1–2am)"  = "darkred"
    )
  ) +
  
  scale_color_manual(
    name = "National nightlights (scaled)",
    values = c(
      "Population-weighted mean light" = "black",
      "Population share dark"          = "steelblue"
    )
  ) +
  
  labs(
    title = "National load shedding and nighttime illumination",
    subtitle = "Bars: Eskom manual load reduction (MW, 01:00–02:00)\nLines: Population-weighted nightlights (scaled for visualization)",
    x = "Date",
    y = "MW (bars) / Scaled nightlights (lines)"
  ) +
  
  theme_minimal() +
  theme(
    legend.position = "bottom",
    legend.box = "vertical"
  )


# scatterplot

ggplot(national_panel, aes(x = mlr_mean_1_2am, y = nat_share_dark)) +
  geom_point(alpha = 0.6) +
  geom_smooth(method = "lm", se = TRUE, color = "black") +
  labs(
    x = "Mean MLR (MW, 01–02)",
    y = "Population share dark",
    title = "Load shedding and probability of darkness"
  ) +
  theme_minimal()

# bin it

national_panel_bin <- national_panel %>%
  mutate(
    mlr_bin = cut(
      mlr_mean_1_2am,
      breaks = quantile(mlr_mean_1_2am, probs = seq(0, 1, 0.25), na.rm = TRUE),
      include.lowest = TRUE
    )
  )

national_panel_bin %>%
  group_by(mlr_bin) %>%
  summarise(
    mean_dark = mean(nat_share_dark, na.rm = TRUE)
  ) %>%
  ggplot(aes(x = mlr_bin, y = mean_dark)) +
  geom_col(fill = "steelblue") +
  labs(
    x = "Load shedding intensity (quartiles)",
    y = "Mean population share dark",
    title = "Settlement darkness increases with load shedding intensity"
  ) +
  theme_minimal()


# binned regression

national_panel_bin2 <- national_panel %>%
  mutate(high_ls = mlr_mean_1_2am > median(mlr_mean_1_2am, na.rm = TRUE))

summary(lm(nat_share_dark ~ high_ls, data = national_panel_bin2))

# extreme bins

national_panel_extreme <- national_panel %>%
  mutate(
    q = ntile(mlr_mean_1_2am, 4),
    extreme = case_when(
      q == 1 ~ "Low",
      q == 4 ~ "High",
      TRUE   ~ NA_character_
    )
  ) %>%
  filter(!is.na(extreme))

summary(lm(nat_share_dark ~ extreme, data = national_panel_extreme))

# CONTROL WITH CONTRACTED DEMAND

# ---------------------------------------------------------
# Option A: Supply-normalized load shedding (ADD-ON ONLY)
# ---------------------------------------------------------

national_panel_shed <- national_panel %>%
  mutate(
    shed_share_mean = ifelse(
      (mlr_mean_1_2am + contracted_demand) > 0,
      mlr_mean_1_2am / (mlr_mean_1_2am + contracted_demand),
      NA_real_
    ),
    shed_share_max = ifelse(
      (mlr_max_1_2am + contracted_demand) > 0,
      mlr_max_1_2am / (mlr_max_1_2am + contracted_demand),
      NA_real_
    )
  )

summary(
  lm(
    nat_share_dark ~ shed_share_mean,
    data = national_panel_shed
  )
)

# plotted

max_mlr <- max(national_panel_shed$mlr_mean_1_2am, na.rm = TRUE)

ggplot(national_panel_shed, aes(x = date)) +
  geom_col(
    aes(y = mlr_mean_1_2am),
    fill = "firebrick",
    alpha = 0.6
  ) +
  geom_line(
    aes(y = shed_share_mean * max_mlr),
    color = "black",
    linewidth = 1.1
  ) +
  labs(
    title = "Load shedding and supply-normalized system stress",
    subtitle = "Bars: MLR (MW, 01–02). Line: shed_share = MLR / (MLR + served load)",
    x = "Date",
    y = "MW / Scaled shed share"
  ) +
  theme_minimal()


# ---------------------------------------------------------
# Identify sufficiently electrified settlements FILTER OUT NASA MINIMUM
# ---------------------------------------------------------

settlement_electrification <- settlement_day %>%
  group_by(settlement_id) %>%
  summarise(
    n_obs = sum(!is.na(p_lit_sett)),
    share_lit_days = mean(p_lit_sett > 0.05, na.rm = TRUE),
    .groups = "drop"
  )

electrified_settlements <- settlement_electrification %>%
  filter(share_lit_days >= 0.20) %>%
  select(settlement_id)

settlement_day_electrified <- settlement_day %>%
  semi_join(electrified_settlements, by = "settlement_id")



# ---------------------------------------------------------
# National nightlights (electrified settlements only)
# ---------------------------------------------------------

national_nightlights_elec <- settlement_day_electrified %>%
  mutate(
    dark = p_lit_sett < 0.05
  ) %>%
  filter(
    !is.na(population),
    population > 100
  ) %>%
  group_by(date) %>%
  summarise(
    nat_mean_p_lit = weighted.mean(p_lit_sett, population, na.rm = TRUE),
    nat_share_dark = weighted.mean(dark, population, na.rm = TRUE),
    total_population = sum(population, na.rm = TRUE),
    .groups = "drop"
  )

national_panel_elec <- national_nightlights_elec %>%
  left_join(eskom_daily, by = "date")

stopifnot(
  nrow(national_panel_elec) == length(unique(national_panel_elec$date))
)

national_panel_elec_shed <- national_panel_elec %>%
  mutate(
    shed_share_mean = ifelse(
      (mlr_mean_1_2am + contracted_demand) > 0,
      mlr_mean_1_2am / (mlr_mean_1_2am + contracted_demand),
      NA_real_
    )
  )

summary(
  lm(
    nat_share_dark ~ shed_share_mean,
    data = national_panel_elec_shed
  )
)

# final graphs

plot_data <- national_panel_elec_shed %>%
  mutate(
    shed_bin = ntile(shed_share_mean, 4)
  )

binned_means <- plot_data %>%
  group_by(shed_bin) %>%
  summarise(
    shed_share_mean = mean(shed_share_mean, na.rm = TRUE),
    nat_share_dark  = mean(nat_share_dark,  na.rm = TRUE),
    .groups = "drop"
  )

ggplot(plot_data, aes(x = shed_share_mean, y = nat_share_dark)) +
  # Raw daily points
  geom_point(alpha = 0.4) +
  
  # Linear fit
  geom_smooth(method = "lm", se = TRUE, linewidth = 1) +
  
  # Binned means
  geom_point(
    data = binned_means,
    aes(x = shed_share_mean, y = nat_share_dark),
    size = 3
  ) +
  
  labs(
    title = "Supply-normalized load shedding and nighttime darkness",
    subtitle = "Daily national population-weighted measures, January 2023",
    x = "Fraction of potential electricity demand curtailed",
    y = "Share of population living in dark settlements (01:00–02:00)"
  ) +
  theme_minimal()


# FINAL DUAL BINS

plot_extremes <- national_panel_elec_shed %>%
  mutate(
    q = ntile(shed_share_mean, 4),
    group = case_when(
      q == 1 ~ "Low load-shedding (bottom 25%)",
      q == 4 ~ "High load-shedding (top 25%)",
      TRUE   ~ NA_character_
    )
  ) %>%
  filter(!is.na(group))

# Make sure group is a factor with low LS as baseline
plot_extremes <- plot_extremes %>%
  mutate(
    group = factor(
      group,
      levels = c(
        "Low load-shedding (bottom 25%)",
        "High load-shedding (top 25%)"
      )
    )
  )

summary(
  lm(
    nat_share_dark ~ group,
    data = plot_extremes
  )
)

set.seed(123)

plot_extremes_sum <- plot_extremes %>%
  group_by(group) %>%
  summarise(
    mean_dark = mean(nat_share_dark, na.rm = TRUE),
    boot = list(
      replicate(
        1000,
        mean(sample(nat_share_dark, replace = TRUE), na.rm = TRUE)
      )
    ),
    .groups = "drop"
  ) %>%
  mutate(
    ci_low  = purrr::map_dbl(boot, ~ quantile(.x, 0.025)),
    ci_high = purrr::map_dbl(boot, ~ quantile(.x, 0.975))
  )

plot_extremes_sum <- plot_extremes_sum %>%
  mutate(
    group = factor(
      group,
      levels = c(
        "Low load-shedding (bottom 25%)",
        "High load-shedding (top 25%)"
      )
    )
  )

ggplot(plot_extremes_sum, aes(x = group, y = mean_dark)) +
  geom_col(fill = "#142247", alpha = 0.9, width = 0.6) +
  geom_errorbar(
    aes(ymin = ci_low, ymax = ci_high),
    width = 0.15
  ) +
  scale_y_continuous(labels = scales::percent_format(accuracy = 1)) +
  labs(
    title = "Nighttime darkness is almost double on high load-shedding days (Entire Republic of South Africa)",
    subtitle = "Comparison of bottom and top quartiles of supply-normalized load shedding (Jan 2023)",
    x = "",
    y = "Population share living in dark settlements (01:00–02:00)"
  ) +
  theme_minimal(base_size = 13)+ 
  theme(
  axis.text = element_text(
    color = "black",
    size  = 11,
    family = ""
  ),
  axis.title = element_text(
    color = "black",
    size  = 13,
    family = ""
  ),
  axis.title.y = element_text(
    margin = margin(r = 12)
  )
)



# OLD:

##############################################################################
# A. Share of nights fully lit
monthly_patterns <- settlement_day%>%
  group_by(settlement_id) %>%
  summarise(
    mean_p_lit = mean(p_lit_sett, na.rm = TRUE),
    share_full = mean(p_lit_sett > 0.9, na.rm = TRUE),
    share_zero = mean(p_lit_sett < 0.05, na.rm = TRUE),
    days_obs   = sum(!is.na(p_lit_sett))
  )


# Interpretation
# Pattern	Likely reality
# high share_full, high share_zero	grid on/off (blackouts)
# low share_zero, low share_full	spatial inequality
# high share_full, low share_zero	reliable grid


# NEW
# ---------------------------------------------------------
# I1. Observation counts (all days valid in this dataset)
# ---------------------------------------------------------
obs_quality <- settlement_day %>%
  group_by(settlement_id) %>%
  summarise(
    n_obs_days = n(),        # total days in panel
    mean_p_lit = mean(p_lit_sett)
  )


# =========================================================
# I2. Simple Nighttime Illumination (Level Indicators)
# =========================================================
# These variables summarize the overall level of detected
# nighttime illumination within each settlement, without
# making claims about reliability or stability.

illumination_level <- settlement_day %>%
  group_by(settlement_id) %>%
  summarise(
    # Mean daily share of illuminated pixels across the year
    # Captures overall illumination intensity
    mean_p_lit = mean(p_lit_sett),
    
    # Share of days with near-complete illumination
    # Interpreted as consistently illuminated settlements
    share_full = mean(p_lit_sett > 0.9),
    
    # Share of days with near-zero illumination
    # Interpreted as non-electrified or frequently dark settlements
    share_zero = mean(p_lit_sett < 0.05)
  )


# =========================================================
# I3. Illumination Variability (Reliability Indicators)
# =========================================================
# These variables capture day-to-day fluctuations in detected
# illumination, which serve as proxies for electricity reliability.

illumination_variability <- settlement_day %>%
  group_by(settlement_id) %>%
  summarise(
    # Mean daily illumination (used for normalization)
    mean_p_lit = mean(p_lit_sett),
    
    # Absolute variability in illumination
    # Sensitive to scale and baseline brightness
    sd_p_lit = sd(p_lit_sett),
    
    # Relative variability (scale-invariant)
    # Enables comparison across settlements with different baselines
    cv_p_lit = sd_p_lit / mean_p_lit
  )


# =========================================================
# I4. Maximum Consecutive Unilluminated Days (Outage Severity)
# =========================================================
# This block measures the persistence of darkness by identifying
# the longest uninterrupted sequence of days with no detectable
# illumination. This captures the duration of potential outages,
# not just their frequency.

illumination_runs <- settlement_day %>%
  # Ensure correct temporal ordering
  arrange(settlement_id, date) %>%
  group_by(settlement_id) %>%
  mutate(
    # Indicator for an unilluminated day
    # Threshold chosen to reflect near-zero detected radiance
    unlit_day = p_lit_sett < 0.05,
    
    # Identify consecutive runs of unlit vs lit days
    run_id = rleid(unlit_day)
  ) %>%
  group_by(settlement_id, run_id) %>%
  summarise(
    # Length of each run of unilluminated days
    run_length = sum(unlit_day),
    .groups = "drop"
  ) %>%
  group_by(settlement_id) %>%
  summarise(
    # Maximum uninterrupted unilluminated spell
    max_unlit_run = max(run_length)
  )


# =========================================================
# Combine all engineered settlement-level variables
# =========================================================
# This produces a single table with illumination levels,
# variability, and outage persistence for each settlement.

settlement_metrics <- obs_quality %>%
  left_join(illumination_level,      by = "settlement_id") %>%
  left_join(illumination_variability, by = "settlement_id") %>%
  left_join(illumination_runs,        by = "settlement_id")

settlement_metrics <- settlement_metrics %>%
  mutate(
    # Normalize longest unilluminated run by panel length
    unlit_run_share = max_unlit_run / n_obs_days
  )

# ---------------------------------------------------------
# Sanity checks (panel-length aware)
# ---------------------------------------------------------

# Relative variability
summary(settlement_metrics$cv_p_lit)

# Share of longest unilluminated spell
summary(settlement_metrics$unlit_run_share)

# Settlements with persistent darkness
settlement_metrics %>%
  filter(unlit_run_share >= 0.8) %>%
  arrange(desc(unlit_run_share))

# if CV is NA, settlement is never illuminated, if 0 its always illuminated, otherwise it has SD
settlement_metrics <- settlement_metrics %>%
  mutate(
    illum_regime = case_when(
      mean_p_lit == 0            ~ "Never illuminated",
      sd_p_lit == 0              ~ "Consistently illuminated",
      TRUE                       ~ "Intermittently illuminated"
    )
  )

# only keep CV variable for intermittent nightlights ??? double check
settlement_metrics %>%
  filter(illum_regime == "Intermittently illuminated") %>%
  summary(cv_p_lit)

