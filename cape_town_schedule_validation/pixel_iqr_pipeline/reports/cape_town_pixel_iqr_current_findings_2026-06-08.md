# Cape Town Pixel-IQR Schedule Validation Findings

Date: 2026-06-08  
Codebase: Reliability-Assessment  
Pipeline: `cape_town_schedule_validation/pixel_iqr_pipeline`  
Primary geometry: Cape Town schedule blocks from `data/aoi/cape_town_city_schedule_blocks.geojson`

## Executive Summary

The Cape Town pixel-IQR validation supports the intuition that a pixel-relative darkness signal can recover scheduled load shedding in a bright city, but only when the schedule exposure is aligned to the inferred local VJ146A2 overpass date.

The main correction is:

```text
vj_product_date = date
local_overpass_date = date + 1
```

After applying this `VJ+1` correction, block-level overpass schedule exposure explains much more of the pixel-IQR dark signal than the same-date join did.

Primary result:

```text
p_dark_iqr_block ~ overpass_sched_minutes + block FE + local date FE

Effect: +4.052 pp per fully scheduled 01:00-02:00 overpass hour
SE:     0.137 pp
p:      4.40e-171
R2:     0.370
Adj R2: 0.309
```

This is substantially stronger than the same-date placebo:

```text
Same-date effect: +1.429 pp per fully scheduled overpass hour
Same-date R2:     0.224
```

## Current Data Products

The current primary panel is:

```text
reports/cape_town_pixel_iqr_block_schedule_validation_panel.csv
```

It was built from the coverage-filtered block-day pixel-IQR parquet files:

```text
data/stage3_block_iqr_cov/block_day_vj146a2_pixel_iqr_cov_YYYY-MM.parquet
```

Current panel dimensions:

| Quantity | Value |
|---|---:|
| Rows | 3,606 |
| Blocks | 16 |
| VJ product dates | 305 |
| Local overpass dates | 305 |
| Mean pixel-IQR coverage | 0.872 |
| Mean `p_dark_iqr_block` | 0.794% |
| Median `p_dark_iqr_block` | 0.000% |
| Maximum `p_dark_iqr_block` | 34.162% |
| Share of nonzero block-days | 16.1% |

The signal is sparse but not zero. Most block-days have no detected dark pixels, but scheduled overpass block-days are much more likely to have a nonzero dark share.

## Methodological Finding: VJ+1 Date Alignment Is Essential

The earlier Cape Town validation used the VJ raster `date` directly when joining to the Cape Town schedule. That was inconsistent with the main VJ146A2 Eskom MLR validation, where the VJ product date is interpreted as the product/acquisition date and the local Eskom exposure date should be `date + 1`.

After correcting script `06`:

- `date` remains the VJ product date.
- `vj_product_date` is written explicitly.
- `local_overpass_date = date + 1` is written explicitly.
- Cape Town schedule exposure is joined on `local_overpass_date`.
- The overpass window is built on `local_overpass_date 01:00-02:00 SAST`.
- Date, month, and day-of-week fixed effects are based on `local_overpass_date`.

The same-date version can still be reproduced as a placebo with:

```bash
CAPE_TOWN_EXPOSURE_DATE_SHIFT_DAYS=0
```

## Schedule Validation Results

Outcome in all models:

```text
p_dark_iqr_block = n_dark_iqr / n_observed_iqr
```

The strongest and most interpretable exposure is whether the block was scheduled during the VJ local overpass window, or the number of scheduled minutes overlapping that window.

### Overpass Schedule Exposure

| Exposure | Specification | N | R2 | Adj R2 | Effect | SE | p |
|---|---|---:|---:|---:|---:|---:|---:|
| Any overpass schedule | No FE | 3,606 | 0.209 | 0.209 | +4.111 pp | 0.133 pp | 5.05e-186 |
| Any overpass schedule | Block FE | 3,606 | 0.245 | 0.242 | +4.157 pp | 0.131 pp | 3.90e-196 |
| Any overpass schedule | Block + month + DOW FE | 3,606 | 0.254 | 0.247 | +4.047 pp | 0.134 pp | 3.24e-179 |
| Any overpass schedule | Block + date FE | 3,606 | 0.365 | 0.303 | +3.956 pp | 0.136 pp | 3.50e-165 |
| Overpass minutes | No FE | 3,606 | 0.216 | 0.216 | +4.204 pp per 60 min | 0.133 pp | 8.44e-193 |
| Overpass minutes | Block FE | 3,606 | 0.251 | 0.248 | +4.245 pp per 60 min | 0.131 pp | 7.55e-203 |
| Overpass minutes | Block + month + DOW FE | 3,606 | 0.261 | 0.254 | +4.141 pp per 60 min | 0.134 pp | 7.87e-186 |
| Overpass minutes | Block + date FE | 3,606 | 0.370 | 0.309 | +4.052 pp per 60 min | 0.137 pp | 4.40e-171 |

The overpass effect is very stable across fixed-effect choices, staying close to `+4 pp`.

### Full-Day Schedule Exposure

| Exposure | Specification | N | R2 | Adj R2 | Effect | SE | p |
|---|---|---:|---:|---:|---:|---:|---:|
| Any full-day schedule | No FE | 3,606 | 0.017 | 0.017 | +0.930 pp | 0.118 pp | 4.34e-15 |
| Any full-day schedule | Block FE | 3,606 | 0.049 | 0.045 | +0.940 pp | 0.116 pp | 9.01e-16 |
| Any full-day schedule | Block + month + DOW FE | 3,606 | 0.068 | 0.060 | +0.618 pp | 0.140 pp | 1.10e-05 |
| Any full-day schedule | Block + date FE | 3,606 | 0.203 | 0.125 | +0.256 pp | 0.187 pp | 0.171 |
| Full-day minutes | No FE | 3,606 | 0.042 | 0.041 | +3.603 pp per 1,000 min | 0.288 pp | 3.61e-35 |
| Full-day minutes | Block FE | 3,606 | 0.074 | 0.070 | +3.656 pp per 1,000 min | 0.284 pp | 3.90e-37 |
| Full-day minutes | Block + month + DOW FE | 3,606 | 0.084 | 0.075 | +3.292 pp per 1,000 min | 0.371 pp | 1.09e-18 |
| Full-day minutes | Block + date FE | 3,606 | 0.207 | 0.130 | +3.332 pp per 1,000 min | 0.730 pp | 5.15e-06 |

Full-day exposure is weaker and less robust than overpass exposure. This supports the interpretation that the pixel-IQR signal is detecting darkness near satellite overpass timing, not just generic high-load-shedding days.

## Scheduled vs Not Scheduled Means

| Exposure | Status | N | Mean dark share | Median dark share | Share nonzero |
|---|---|---:|---:|---:|---:|
| Overpass schedule | Not scheduled | 3,084 | 0.199% | 0.000% | 8.1% |
| Overpass schedule | Scheduled | 522 | 4.310% | 0.651% | 62.8% |
| Full-day schedule | Not scheduled | 963 | 0.112% | 0.000% | 4.7% |
| Full-day schedule | Scheduled | 2,643 | 1.042% | 0.000% | 20.2% |

The mean contrast is much larger for the overpass window than for the full-day schedule indicator.

## Eskom MLR / Contracted Demand Checks

The MLR exposure follows the main MLR validation idea:

```text
shed_share = Manual Load_Reduction(MLR) / RSA Contracted Demand
```

For this Cape Town check, Eskom `hour == 1` was joined on `local_overpass_date`.

### Correlations

| Pair | N | Correlation | R2 | p |
|---|---:|---:|---:|---:|
| `p_dark_iqr_block` vs `shed_share` | 3,584 | 0.162 | 0.026 | 1.42e-22 |
| `p_dark_iqr_block` vs `overpass_sched_minutes` | 3,584 | 0.465 | 0.216 | 2.34e-191 |
| `shed_share` vs `overpass_sched_minutes` | 3,584 | 0.248 | 0.062 | 2.01e-51 |

MLR share is positively correlated with the dark signal, but much less strongly than the Cape Town block-specific overpass schedule. MLR share and overpass schedule are not strongly collinear.

### MLR-Only and MLR-Plus-Schedule Specifications

| Specification | N | R2 | Adj R2 | Effect |
|---|---:|---:|---:|---|
| `shed_share` only | 3,584 | 0.026 | 0.026 | MLR: +1.088 pp per 10pp, p 1.42e-22 |
| `shed_share + block FE` | 3,584 | 0.059 | 0.054 | MLR: +1.098 pp per 10pp, p 1.38e-23 |
| `shed_share + block + month + DOW FE` | 3,584 | 0.071 | 0.063 | MLR: +0.921 pp per 10pp, p 2.43e-08 |
| `shed_share + block + month + date FE` | 3,584 | 0.202 | 0.125 | MLR not interpretable because date FE absorb date-level MLR variation |
| `overpass minutes + shed_share` | 3,584 | 0.218 | 0.218 | Overpass: +4.090 pp; MLR: +0.336 pp |
| `overpass minutes + shed_share + block FE` | 3,584 | 0.254 | 0.250 | Overpass: +4.130 pp; MLR: +0.341 pp |
| `overpass minutes + shed_share + block + month + DOW FE` | 3,584 | 0.261 | 0.254 | Overpass: +4.107 pp; MLR: +0.253 pp, p 0.088 |
| `overpass minutes + shed_share + block + month + date FE` | 3,584 | 0.370 | 0.309 | Overpass: +4.052 pp; MLR not interpretable |

The block-specific overpass schedule remains the dominant predictor after adding national MLR share. MLR alone carries a weak but significant national reliability signal; it does not replace the local schedule validation.

Do not interpret MLR coefficients in date-FE models. MLR share varies only by date, so local date fixed effects absorb the identifying variation.

## Interaction Check

A centered interaction specification was also tested:

```text
p_dark_iqr_block ~ any_overpass_sched * centered_shed_share
                 + block FE + month FE + DOW FE
```

Results:

| Quantity | Value |
|---|---:|
| N | 3,584 |
| R2 | 0.265 |
| Adjusted R2 | 0.257 |
| Overpass effect at mean MLR share | +3.436 pp |
| Interaction | +23.005 pp per unit MLR share |
| Interaction p-value | 1.27e-11 |

Interpreted at a 10 percentage point increase in MLR share, the interaction is about `+2.30 pp`. This suggests scheduled overpass blocks become especially dark on nationally high-MLR nights.

## Block Heterogeneity

The overpass effect is not spatially uniform. Some schedule blocks have very strong darkening, while others show little darkening.

Top overpass differences:

| Block | Circuit | Mean coverage | Mean dark share | Overpass scheduled rows | Scheduled mean | Not scheduled mean | Difference |
|---:|---|---:|---:|---:|---:|---:|---:|
| 4 | Area 4 | 0.863 | 1.943% | 29 | 12.130% | 0.354% | +11.776 pp |
| 5 | Area 5 | 0.846 | 2.005% | 35 | 9.407% | 0.558% | +8.849 pp |
| 13 | Area 13 | 0.906 | 1.087% | 31 | 6.528% | 0.284% | +6.244 pp |
| 6 | Area 6 | 0.881 | 1.128% | 33 | 6.276% | 0.323% | +5.953 pp |
| 10 | Area 10 | 0.889 | 0.993% | 31 | 6.045% | 0.251% | +5.794 pp |

Lowest overpass differences:

| Block | Circuit | Mean coverage | Mean dark share | Overpass scheduled rows | Scheduled mean | Not scheduled mean | Difference |
|---:|---|---:|---:|---:|---:|---:|---:|
| 14 | Area 14 | 0.852 | 0.033% | 46 | 0.174% | 0.001% | +0.173 pp |
| 8 | Area 8 | 0.828 | 0.069% | 34 | 0.355% | 0.014% | +0.341 pp |
| 7 | Area 7 | 0.817 | 0.181% | 32 | 0.557% | 0.102% | +0.455 pp |
| 1 | Area 1 | 0.907 | 0.221% | 41 | 0.613% | 0.146% | +0.467 pp |
| 11 | Area 11 | 0.833 | 0.479% | 30 | 2.381% | 0.147% | +2.234 pp |

This heterogeneity could reflect real differences in brightness, outage compliance, schedule accuracy, cloud/quality filtering, land-use composition, or block geometry.

## City-Level Analysis

The block-level analysis asks whether the dark signal appears in the specific schedule block that is supposed to be off. At that level, the Cape Town schedule should dominate because the City of Cape Town determines the local distribution of outages across blocks.

The city-level analysis asks a different question: after collapsing all blocks into one Cape Town observation per night, does national Eskom MLR / contracted demand explain aggregate Cape Town darkness?

For this analysis, the unit is one row per `local_overpass_date`. The citywide outcome is pixel-weighted:

```text
city_p_dark_iqr = sum(n_dark_iqr across blocks) / sum(n_observed_iqr across blocks)
```

Cape Town schedule exposure is also pixel-weighted across blocks:

```text
city_overpass_sched_share =
  sum(n_observed_iqr * overpass_sched_minutes / 60) / sum(n_observed_iqr)
```

Eskom MLR share is joined on `local_overpass_date` using `hour == 1`.

### City Panel Summary

| Quantity | Value |
|---|---:|
| Dates | 303 |
| Mean city dark share | 0.526% |
| Median city dark share | 0.081% |
| Maximum city dark share | 4.665% |
| Mean city overpass scheduled share | 16.7% |
| Mean Eskom MLR shed share | 6.26% |

### City-Level Correlations

| Pair | N | Correlation | R2 | p |
|---|---:|---:|---:|---:|
| City dark share vs MLR shed share | 303 | 0.362 | 0.131 | 8.64e-11 |
| City dark share vs city overpass scheduled share | 303 | 0.334 | 0.112 | 2.39e-09 |
| City dark share vs full-day schedule intensity | 303 | 0.389 | 0.151 | 2.22e-12 |
| MLR shed share vs city overpass scheduled share | 303 | 0.402 | 0.161 | 3.62e-13 |
| MLR shed share vs full-day schedule intensity | 303 | 0.785 | 0.616 | 1.69e-64 |

At city level, national MLR share is meaningfully correlated with citywide darkness. It is also very strongly correlated with full-day Cape Town schedule intensity. This is expected: once the spatial allocation across blocks is collapsed, national system stress becomes a proxy for how much load shedding Cape Town had to schedule overall.

### City-Level Regression Results

Effects are in percentage points of `city_p_dark_iqr`.

| Specification | N | R2 | Adj R2 | Effect |
|---|---:|---:|---:|---|
| `MLR only` | 303 | 0.131 | 0.128 | MLR: +0.689 pp per 10pp MLR share, p 8.64e-11 |
| `MLR + month FE` | 303 | 0.156 | 0.121 | MLR: +0.516 pp per 10pp, p 8.41e-04 |
| `MLR + DOW FE` | 303 | 0.163 | 0.144 | MLR: +0.723 pp per 10pp, p 1.42e-11 |
| `MLR + month + DOW FE` | 303 | 0.185 | 0.134 | MLR: +0.564 pp per 10pp, p 3.88e-04 |
| `Cape Town overpass schedule only` | 303 | 0.112 | 0.109 | Overpass share: +1.362 pp for 0% to 100% scheduled, p 2.39e-09 |
| `Cape Town overpass schedule + month FE` | 303 | 0.185 | 0.151 | Overpass share: +1.105 pp, p 4.07e-06 |
| `Cape Town overpass schedule + DOW FE` | 303 | 0.128 | 0.108 | Overpass share: +1.330 pp, p 7.07e-09 |
| `Cape Town overpass schedule + month + DOW FE` | 303 | 0.202 | 0.152 | Overpass share: +1.044 pp, p 1.62e-05 |
| `Overpass schedule + MLR` | 303 | 0.173 | 0.168 | Overpass: +0.919 pp, p 1.03e-04; MLR: +0.516 pp per 10pp, p 3.48e-06 |
| `Overpass schedule + MLR + month FE` | 303 | 0.198 | 0.162 | Overpass: +0.953 pp, p 1.13e-04; MLR: +0.344 pp per 10pp, p 0.0276 |
| `Overpass schedule + MLR + DOW FE` | 303 | 0.199 | 0.177 | Overpass: +0.844 pp, p 3.72e-04; MLR: +0.562 pp per 10pp, p 6.53e-07 |
| `Overpass schedule + MLR + month + DOW FE` | 303 | 0.220 | 0.167 | Overpass: +0.869 pp, p 4.78e-04; MLR: +0.403 pp per 10pp, p 0.0126 |
| `Full-day schedule intensity only` | 303 | 0.151 | 0.148 | +0.126 pp per pixel-weighted scheduled hour/day, p 2.22e-12 |
| `Full-day schedule intensity + MLR` | 303 | 0.160 | 0.154 | Full-day schedule: +0.089 pp/hour, p 0.00150; MLR: +0.280 pp per 10pp, p 0.0867 |
| `Full-day schedule intensity + MLR + month + DOW FE` | 303 | 0.205 | 0.151 | Full-day schedule: +0.089 pp/hour, p 0.00929; MLR: +0.147 pp per 10pp, p 0.508 |

### City-Level Interaction Check

The interaction specification tests whether Cape Town scheduled exposure is more visible in the NTL signal on nationally high-MLR nights:

```text
city_p_dark_iqr ~ centered_city_overpass_sched_share * centered_shed_share
```

Without month or DOW FE:

| Quantity | Value |
|---|---:|
| N | 303 |
| R2 | 0.185 |
| Adjusted R2 | 0.177 |
| Centered city overpass scheduled share | +0.747 pp |
| Centered MLR shed share | +5.736 pp per unit share |
| Interaction | +12.438 pp |
| Interaction p-value | 0.036 |

With month and DOW FE:

| Quantity | Value |
|---|---:|
| N | 303 |
| R2 | 0.233 |
| Adjusted R2 | 0.178 |
| Centered city overpass scheduled share | +0.675 pp |
| Centered MLR shed share | +4.196 pp per unit share |
| Interaction | +13.777 pp |
| Interaction p-value | 0.030 |

Interpreted at a 10 percentage point increase in MLR share, the interaction is about `+1.38 pp` for a full 0% to 100% increase in the city overpass scheduled share. This suggests that citywide scheduled exposure is more visibly dark on nationally high-MLR nights.

### City-Level Interpretation

At city level, the result differs from the block-level finding. National MLR share matters once all Cape Town blocks are collapsed into one citywide observation. This is because national system stress is closely related to how much load shedding Cape Town schedules overall, especially over the full day.

However, the Cape Town schedule still matters after controlling for MLR. In the combined city-level overpass model with month and DOW FE, both `city_overpass_sched_share` and MLR share remain statistically significant.

The interpretation is therefore:

- At block level, Cape Town schedule exposure dominates because it identifies where the outage should occur.
- At city level, Eskom MLR share becomes informative because it proxies the overall intensity of load shedding pressure facing Cape Town.
- The citywide dark signal appears to combine both national stress and local schedule implementation.

## Extreme-Quartile Checks

The earlier MLR validation used a bottom-versus-top quartile comparison as an interpretable robustness check. The same style was applied here using the corrected `VJ+1` panel:

```text
Bottom quartile = observations at or below the 25th percentile of exposure
Top quartile    = observations at or above the 75th percentile of exposure
```

Then the outcome is regressed on a `top_quartile` indicator. Because many low-load-shedding observations are exactly zero, the bottom quartile is often a zero-exposure group.

### City-Level Extreme Quartiles

Outcome:

```text
city_p_dark_iqr
```

| Sorting variable | Specification | N | Bottom mean dark | Top mean dark | Top-bottom effect | R2 | p |
|---|---|---:|---:|---:|---:|---:|---:|
| `shed_share` | No FE | 159 | 0.157% | 0.910% | +0.753 pp | 0.192 | 7.56e-09 |
| `shed_share` | Month + DOW FE | 159 | 0.157% | 0.910% | +0.823 pp | 0.368 | 0.00110 |
| `city_overpass_sched_share` | No FE | 195 | 0.127% | 1.107% | +0.980 pp | 0.248 | 1.25e-13 |
| `city_overpass_sched_share` | Month + DOW FE | 195 | 0.127% | 1.107% | +0.862 pp | 0.360 | 1.65e-08 |
| `city_day_sched_minutes_pw` | No FE | 152 | 0.136% | 0.956% | +0.820 pp | 0.188 | 2.41e-08 |
| `city_day_sched_minutes_pw` | Month + DOW FE | 152 | 0.136% | 0.956% | +0.620 pp | 0.367 | 0.00944 |

At city level, the top-exposure quartile is clearly darker than the bottom-exposure quartile for MLR share, city overpass schedule share, and full-day schedule intensity. The largest raw contrast is the city overpass schedule split: `+0.980 pp`, with `R2 = 0.248`.

### Block-Level Extreme Quartiles

Outcome:

```text
p_dark_iqr_block
```

| Sorting variable | Specification | N | Bottom mean dark | Top mean dark | Top-bottom effect | R2 | p |
|---|---|---:|---:|---:|---:|---:|---:|
| `shed_share` | No FE | 1,910 | 0.245% | 1.528% | +1.283 pp | 0.038 | 1.13e-17 |
| `shed_share` | Block FE | 1,910 | 0.245% | 1.528% | +1.300 pp | 0.075 | 1.40e-18 |
| `shed_share` | Block + month + DOW FE | 1,910 | 0.245% | 1.528% | +1.700 pp | 0.114 | 3.34e-08 |
| `overpass_sched_minutes` | No FE | 3,584 | 0.200% | 4.310% | +4.110 pp | 0.209 | 1.27e-184 |
| `overpass_sched_minutes` | Block FE | 3,584 | 0.200% | 4.310% | +4.156 pp | 0.245 | 9.81e-195 |
| `overpass_sched_minutes` | Block + month + DOW FE | 3,584 | 0.200% | 4.310% | +4.048 pp | 0.254 | 3.16e-178 |
| `day_sched_minutes` | No FE | 1,869 | 0.115% | 1.813% | +1.698 pp | 0.056 | 5.11e-25 |
| `day_sched_minutes` | Block FE | 1,869 | 0.115% | 1.813% | +1.734 pp | 0.100 | 6.96e-27 |
| `day_sched_minutes` | Block + month + DOW FE | 1,869 | 0.115% | 1.813% | +1.347 pp | 0.120 | 2.52e-07 |

At block level, the extreme-quartile comparison confirms the continuous-regression result. The overpass schedule split is the strongest validation check: top overpass-scheduled rows are about `+4.05 pp` darker than bottom overpass-scheduled rows after block, month, and day-of-week fixed effects.

For `overpass_sched_minutes`, the quartile split is effectively an unscheduled-versus-scheduled comparison because the distribution contains many zero-minute rows. This is why the quartile result closely reproduces the binary overpass schedule model.

### Quartile Interpretation

The quartile results reinforce the main scale-specific interpretation:

- at city level, high national MLR nights and high Cape Town schedule-intensity nights are both visibly darker;
- at block level, Cape Town overpass schedule remains the strongest validation because it matches both geography and overpass timing;
- MLR quartiles are significant at block level, but they are weaker than local overpass schedule quartiles.

## Interpretation

Current findings support three claims.

First, the pixel-IQR method is detecting a real Cape Town schedule signal. The raw signal is sparse, but scheduled overpass block-days are much darker and much more likely to be nonzero.

Second, the timing alignment matters. The `VJ+1` correction substantially increases both effect size and explanatory power. This is consistent with the main VJ146A2 Eskom alignment note and suggests that same-date schedule joins understate the validation signal.

Third, the role of Eskom MLR depends on aggregation. At block level, local Cape Town schedule exposure is more informative than national MLR share because it identifies which block should be dark. At city level, MLR share is more meaningful because it captures national system stress and is strongly correlated with Cape Town's overall full-day schedule intensity.

## Full Conclusion

The Cape Town validation supports the pixel-IQR approach, but it also clarifies what each validation scale is measuring.

At the block level, the nighttime-lights signal lines up strongly with the Cape Town load-shedding schedule once the correct `VJ+1` date alignment is used. The preferred block-level overpass specification gives an effect of about `+4 pp` dark share and `R2 = 0.370` with block and local-date fixed effects. This is the strongest evidence in the exercise: when a Cape Town schedule block is supposed to be off during the satellite overpass window, pixels in that block become measurably darker.

The date correction is not a minor detail. Same-date alignment gave a much weaker result, around `+1.429 pp` and `R2 = 0.224`. After shifting schedule exposure to:

```text
local_overpass_date = vj_product_date + 1
```

the validation signal becomes much clearer. For VJ146A2 validation, product date and local overpass date must therefore be kept separate in every downstream schedule or MLR join.

At the block level, Eskom MLR share does not drive the result. That is expected. MLR is a national system-stress measure, while the City of Cape Town schedule determines which local block is supposed to be shed. Once the model knows the Cape Town block schedule, national MLR adds relatively little to explaining within-city spatial variation.

At the city level, the interpretation changes. When all Cape Town blocks are collapsed into one citywide dark-share series, Eskom MLR becomes informative. MLR share alone explains `R2 = 0.131` of citywide darkness, and it is strongly correlated with full-day Cape Town schedule intensity (`corr = 0.785`). This means national system stress helps explain how much load shedding Cape Town experiences overall, but not where inside Cape Town it occurs.

The clean interpretation is:

```text
Block level:
  Cape Town schedule validates spatial allocation of outages.

City level:
  Eskom MLR validates aggregate load-shedding intensity.

Pixel-IQR:
  Detects overpass-time darkness when timing and geography are aligned correctly.
```

The exercise also addresses the original bright-city concern. A single absolute radiance threshold can fail in bright urban areas because most pixels remain bright even during partial outages. The pixel-IQR method instead asks whether each pixel is unusually dark relative to its own annual distribution. That produces a sparse signal, but the signal is not noise: scheduled overpass block-days are much darker and much more likely to have nonzero dark pixels.

The methodological takeaway is to use pixel-relative dark detection for bright-city validation and to match the validation scale to the ground-truth exposure:

- use schedule blocks for Cape Town schedule validation;
- use citywide aggregation for Eskom MLR / national system-stress validation;
- use settlements or local areas for the broader national MLR validation.

The remaining caveat is that this is schedule validation, not direct outage ground truth. Scheduled outages may not always be implemented, unscheduled faults may occur, and signal strength can vary with land use, baseline brightness, quality filtering, cloud contamination, and block geometry. Even with those caveats, the Cape Town exercise gives stronger confidence that the NTL metric is detecting real load-shedding-related darkness when both timing and geography are handled correctly.

## Caveats

This is a validation exercise, not a causal outage estimate. The pixel-IQR metric identifies unusually dark pixels relative to each pixel's 2023 distribution. It does not directly prove whether a household or feeder was disconnected.

The Cape Town schedule data are treated as the schedule truth. If scheduled events were not implemented, or if there were unscheduled faults, the validation will be attenuated or spatially uneven.

Date fixed effects should not be used to interpret date-level variables such as Eskom MLR share. They are useful for isolating within-date block schedule variation, but they absorb national date-level variation.

The city-level MLR and schedule regressions above were run as diagnostics from the corrected `VJ+1` block panel. They should be moved into a formal script before being treated as final reproducible outputs.

## Generated Figures

Current figure outputs:

- `../figures/cape_town_pixel_iqr_block_schedule_validation_coefficients.png`
- `../figures/cape_town_pixel_iqr_block_schedule_validation_means.png`
- `../figures/cape_town_pixel_iqr_block_schedule_validation_bins.png`
- `../figures/cape_town_pixel_iqr_block_schedule_validation_blocks.png`
- `../figures/cape_town_pixel_iqr_citywide_schedule_signal_overlay.png`
- `../figures/cape_town_pixel_iqr_citywide_schedule_signal_scatter.png`
- `../figures/cape_town_pixel_iqr_citywide_schedule_signal_bins.png`

## Recommended Next Steps

1. Add the city-level MLR/contracted-demand regression table to a formal script so it is reproducible rather than ad hoc.
2. Rerun or replace the older citywide plotting diagnostic with a `VJ+1` version based on the corrected block panel.
3. Inspect high-effect and low-effect blocks spatially to understand whether heterogeneity comes from land use, brightness, coverage, or schedule implementation.
4. Consider using the Cape Town result as a validation appendix for the broader NTL reliability metric, while keeping the settlement/MLR validation as the national comparison.
