# ============================================================
# DOE Parameter Sweep — Stage 3b Sensitivity Analysis
# ============================================================
# Purpose: Read pre-computed settlement_day_states parquet and sweep
#   ROLLING_LIT_MIN × ROLLING_OBS_MIN × LIT_THRESHOLD to find the
#   parameter combination that maximises DOE confirmation rate for
#   Stage 2c-qualified (yearly-keep) settlements.
# Inputs:  Map Data/reliability_outputs_blackmarbler/
#            settlement_day_states_strict_yearlykeep.parquet
# Outputs: Map Data/reliability_outputs_blackmarbler/
#            doe_parameter_sweep_results.csv
# Run:     Rscript Builder/doe_parameter_sweep.R
# ============================================================

rm(list = ls())
suppressPackageStartupMessages({
  library(here)
  library(arrow)
  library(data.table)
})

BASE_PATH <- here::here()
STATES_FILE <- file.path(
  BASE_PATH, "Map Data", "reliability_outputs_blackmarbler",
  "settlement_day_states_strict_yearlykeep_yearlykeep.parquet"
)
OUT_CSV <- file.path(
  BASE_PATH, "Map Data", "reliability_outputs_blackmarbler",
  "doe_parameter_sweep_results.csv"
)

if (!file.exists(STATES_FILE)) stop("States parquet not found: ", STATES_FILE)

cat("Reading states parquet...\n")
states <- as.data.table(read_parquet(STATES_FILE))
states[, date := as.Date(date)]
data.table::setorder(states, settlement_id, date)

n_sett <- uniqueN(states$settlement_id)
cat("Settlements:", n_sett, "\n")

# ----- Helper: compute DOE confirmation count from pre-computed n_lit30/n_obs30 -----
count_doe <- function(dt, rol_lit, rol_obs) {
  dt2 <- copy(dt)
  dt2[, elec_30d := data.table::fifelse(
    !is.na(n_obs30) & n_obs30 >= rol_obs,
    data.table::fifelse(n_lit30 >= rol_lit, 1L, 0L),
    NA_integer_
  )]
  doe_tbl <- dt2[, .(
    doe_new = {
      idx <- which(elec_30d == 1L)
      if (length(idx) > 0) date[idx[1L]] else as.Date(NA)
    }
  ), by = settlement_id]
  sum(!is.na(doe_tbl$doe_new))
}

# ----- Helper: recompute n_lit30 from p_lit_sett for a new LIT_THRESHOLD -----
recompute_nlit30 <- function(dt, lit_thr) {
  dt2 <- copy(dt)
  dt2[, lit_one := {
    lo <- as.integer(p_lit_sett >= lit_thr)
    lo[is.na(lo)] <- 0L
    lo
  }]
  dt2[, n_lit30_new := rev(
    data.table::frollsum(rev(lit_one), n = 30L, align = "right")
  ), by = settlement_id]
  dt2
}

# ----- Build grid -----
grid_fast <- CJ(           # use existing n_lit30 (LIT_THRESHOLD = 0.4)
  rol_lit = c(6L, 8L, 10L, 12L, 14L, 17L),
  rol_obs = c(8L, 10L, 12L, 15L, 20L)
)
grid_fast <- grid_fast[rol_lit <= rol_obs]  # lit can't exceed obs

lit_thresholds_extra <- c(0.20, 0.30)  # 0.40 already covered by grid_fast

cat("Running fast sweep (", nrow(grid_fast), "combos)...\n")
results_fast <- rbindlist(lapply(seq_len(nrow(grid_fast)), function(i) {
  rl <- grid_fast$rol_lit[i]; ro <- grid_fast$rol_obs[i]
  n_doe <- count_doe(states, rl, ro)
  data.table(lit_thr = 0.40, rol_lit = rl, rol_obs = ro,
             n_confirmed = n_doe, n_total = n_sett,
             share_confirmed = round(n_doe / n_sett, 4))
}))

cat("Running LIT_THRESHOLD sweep...\n")
results_lit <- rbindlist(lapply(lit_thresholds_extra, function(thr) {
  cat("  LIT_THRESHOLD =", thr, "\n")
  dt_new <- recompute_nlit30(states, thr)
  # Use a representative grid for this threshold
  sub_grid <- CJ(rol_lit = c(6L, 8L, 10L, 12L), rol_obs = c(8L, 10L, 12L, 15L))
  sub_grid <- sub_grid[rol_lit <= rol_obs]
  rbindlist(lapply(seq_len(nrow(sub_grid)), function(i) {
    rl <- sub_grid$rol_lit[i]; ro <- sub_grid$rol_obs[i]
    # use n_lit30_new instead of n_lit30
    dt_tmp <- copy(dt_new)
    dt_tmp[, n_lit30 := n_lit30_new]
    n_doe <- count_doe(dt_tmp, rl, ro)
    data.table(lit_thr = thr, rol_lit = rl, rol_obs = ro,
               n_confirmed = n_doe, n_total = n_sett,
               share_confirmed = round(n_doe / n_sett, 4))
  }))
}))

results <- rbind(results_fast, results_lit)
setorder(results, -share_confirmed)

utils::write.csv(results, OUT_CSV, row.names = FALSE)
cat("\nTop 10 parameter combos:\n")
print(head(results, 10))
cat("\nBaseline (current settings: lit_thr=0.4, rol_lit=17, rol_obs=20):\n")
print(results[lit_thr == 0.40 & rol_lit == 17L & rol_obs == 20L])
cat("\nWrote:", OUT_CSV, "\n")
