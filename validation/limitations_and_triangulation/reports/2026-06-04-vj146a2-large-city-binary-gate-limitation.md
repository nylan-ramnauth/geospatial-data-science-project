# VJ146A2 Large-City Binary-Gate Limitation Check

Date: 2026-06-04
Actor: Codex
Workstream: reliability-assessment / VJ-Eskom validation / PyPSA uptime proxy
Related main report: [[validation/eskom_mlr/reports/2026-06-03-recommended-vj-eskom-validation-specification.pdf]]

## Objective

This note records a follow-up diagnostic on whether the validated binary `p_lit` gate metrics miss load-shedding-related dimming in very large, bright urban settlements.

The main validation report uses daily national demand-weighted shares of settlements below a `p_lit` threshold:

- `p_lit < 0.05`: strict dark
- `p_lit < 0.20`: mostly dark
- `p_lit < 0.40`: broad not-up / relaxed dark

The concern tested here is whether large cities can remain far above these gates even during load shedding, because they have high baseline brightness, mixed lighting, private generation, and partial service continuity. If so, the binary metric can still validate nationally while being weak for large-city partial dimming.

## Data And Specification Used

The diagnostic used the same cleaned validation calendar as the main report:

- standard sample: 267 dates
- no-MLR baseline dates: 74 dates
- positive-MLR dates: 193 dates
- MLR regressor: corrected Eskom MLR share for 01:00-02:00 SAST, `MLR / RSA Contracted Demand`
- excess-lit dates removed using the annual-IQR rule used in the recommended report

For city-level checks, settlements were grouped by the `admin_cgaz_2` municipality field:

- `City of Cape Town`
- `City of Johannesburg`

For the one-settlement check, only settlement `191` was used:

```text
settlement_id: 191
village_name: Nooitgedacht
municipality: City of Cape Town
population: 3,911,466
demand weight: 598,819
```

## Alternative Continuous Metric

The robustness check compared the binary gates to settlement-specific baseline-relative dimming.

For each settlement:

```text
baseline_i = mean(p_lit_i,t on no-MLR validation dates)

mean-baseline relative dimming_i,t =
  max(0, baseline_i - p_lit_i,t) / baseline_i
```

This metric does not use a binary gate. It allows a bright settlement to contribute when it dims without crossing `p_lit < 0.40`. For example, a settlement moving from `p_lit = 1.00` to `p_lit = 0.98` contributes a 2 percent relative dimming signal, while the binary gates still record zero.

## City-Level Demand-Weighted Results

City-level aggregation should be interpreted carefully. These are not city-wide binary events. They are demand-weighted shares of settlement polygons within the municipality crossing each gate on a given day.

Support was uneven across the two cities:

| City | Observed dates | Dates with city demand support >= 0.40 | Mean support | P10 support | Settlement count |
|---|---:|---:|---:|---:|---:|
| City of Cape Town | 247 | 179 | 0.708 | 0.010 | 138 |
| City of Johannesburg | 261 | 245 | 0.933 | 0.917 | 24 |

Using only city-days with observed demand support `>= 0.40`, the comparison is:

| City | Metric | Mean outcome | Effect per +10pp MLR | r | R2 |
|---|---|---:|---:|---:|---:|
| Cape Town | `p_lit < 0.05` | 0.027% | +0.04 pp | 0.275 | 0.076 |
| Cape Town | `p_lit < 0.20` | 0.032% | +0.04 pp | 0.269 | 0.072 |
| Cape Town | `p_lit < 0.40` | 0.071% | +0.13 pp | 0.344 | 0.119 |
| Cape Town | mean-baseline relative dimming | 0.247% | +0.43 pp | 0.426 | 0.182 |
| Cape Town | median-baseline relative dimming | 0.270% | +0.44 pp | 0.427 | 0.182 |
| Johannesburg | `p_lit < 0.05` | 0.010% | +0.02 pp | 0.267 | 0.071 |
| Johannesburg | `p_lit < 0.20` | 0.015% | +0.02 pp | 0.221 | 0.049 |
| Johannesburg | `p_lit < 0.40` | 0.029% | +0.05 pp | 0.344 | 0.118 |
| Johannesburg | mean-baseline relative dimming | 1.507% | +1.22 pp | 0.214 | 0.046 |
| Johannesburg | median-baseline relative dimming | 1.966% | +1.30 pp | 0.204 | 0.042 |

The binary city outcomes are extremely small. For Johannesburg, the `p_lit < 0.40` mean is only 0.029 percent of demand-weighted settlement mass. This does not mean Johannesburg as a whole is sometimes dark. It means small settlement fragments inside the municipality occasionally cross the threshold.

Nonzero-day counts confirm this:

| City | Gate | Nonzero days | Mean | Max |
|---|---:|---:|---:|---:|
| Cape Town | `<0.05` | 87 / 179 | 0.027% | 0.836% |
| Cape Town | `<0.20` | 95 / 179 | 0.032% | 0.875% |
| Cape Town | `<0.40` | 120 / 179 | 0.071% | 1.471% |
| Johannesburg | `<0.05` | 60 / 245 | 0.010% | 0.346% |
| Johannesburg | `<0.20` | 66 / 245 | 0.015% | 0.346% |
| Johannesburg | `<0.40` | 80 / 245 | 0.029% | 0.346% |

The continuous dimming metric captures more large-city variation in levels, especially for Cape Town. However, it does not uniformly improve validation fit. In Johannesburg, the binary `p_lit < 0.40` metric has higher R2 than baseline-relative dimming.

## Settlement 191 Check

Settlement `191` is the cleanest example because it is a single very large Cape Town settlement rather than a municipality-level aggregation.

The no-MLR baseline is almost fully lit:

```text
observed validation days: 179
no-MLR baseline days: 51
mean baseline p_lit: 0.999896
median baseline p_lit: 1.000000
baseline SD: 0.000249
```

For this settlement, the binary gates never turn on:

| Metric | Nonzero days | Mean | Result |
|---|---:|---:|---|
| `p_lit < 0.05` | 0 / 179 | 0 | not estimable |
| `p_lit < 0.20` | 0 / 179 | 0 | not estimable |
| `p_lit < 0.40` | 0 / 179 | 0 | not estimable |

The continuous dimming outcomes do show a statistically significant association with Eskom MLR:

| Outcome | Mean | Max | Effect per +10pp MLR | r | R2 | Newey-West p |
|---|---:|---:|---:|---:|---:|---:|
| Mean-baseline relative dimming | 0.052% | 2.009% | +0.132 pp | 0.303 | 0.092 | 0.00835 |
| Median-baseline relative dimming | 0.057% | 2.019% | +0.135 pp | 0.308 | 0.095 | 0.00713 |
| Raw `p_lit` | 0.99943 | 1.000 | -0.135 pp | -0.308 | 0.095 | 0.00713 |

By MLR group:

| MLR group | n | Mean `p_lit` | Median `p_lit` | Minimum `p_lit` | Mean-baseline relative dimming |
|---|---:|---:|---:|---:|---:|
| No MLR | 51 | 0.999896 | 1.000000 | 0.998769 | 0.007% |
| Other positive MLR | 82 | 0.999630 | 0.999941 | 0.990215 | 0.032% |
| High MLR | 46 | 0.998555 | 0.999812 | 0.979811 | 0.138% |

Lowest observed `p_lit` day:

```text
date: 2023-02-21
p_lit: 0.979811
MLR share, 01:00-02:00: 17.6%
binary gates: all zero
mean-baseline relative dimming: 2.01%
```

This settlement confirms the limitation: a very large, bright urban settlement can dim in a way that is statistically associated with Eskom MLR, while never approaching `p_lit < 0.40`.

## Interpretation

The large-city diagnostic supports three conclusions.

First, the binary metric should not be interpreted as a complete measure of partial large-city dimming. It is a threshold-crossing measure. For very bright cities, load shedding can reduce `p_lit` without causing the settlement to cross even the relaxed `0.40` gate.

Second, this limitation does not invalidate the main report. Nationally, the binary gates still validate more strongly against Eskom MLR than the continuous baseline-relative metrics tested so far. The current report is therefore still the cleanest basis for the PyPSA-facing reliability proxy.

Third, the continuous dimming check is useful as a robustness result. It shows that the VJ signal is not only an artifact of hard darkness thresholds. At least in settlement `191`, load-shedding exposure is associated with statistically significant dimming even when all binary gates are zero.

## Alternatives Considered

### Replace Binary Gates With Continuous Dimming

Not recommended as the main metric. Continuous dimming captures partial urban dimming, but national validation fit is weaker than the binary gates:

```text
Demand-weighted simple R2:
p_lit < 0.05: 0.618
p_lit < 0.20: 0.608
p_lit < 0.40: 0.600
mean-baseline relative dimming: 0.512
```

### Use A Hybrid Metric For Large Cities

Technically feasible:

```text
large settlements:
  max(0, baseline_i - p_lit_i,t) / baseline_i

other settlements:
  1[p_lit_i,t < gate]
```

But this changes the estimand. It mixes binary outage shares with fractional dimming shares. That may be useful later, but it would need a separate validation and a clear interpretation.

### Remove Large Cities

Useful only as a diagnostic. Excluding settlements above a population threshold, such as 1 million, could make the binary outage signal clearer in non-megacity settlements. But it would no longer be a national ENS proxy. It would become a non-megacity outage proxy.

## Recommendation

Keep the main report's binary-gate framework as the validation basis.

The next decision should be the preferred `p_lit` gate for the PyPSA-facing uptime / ENS proxy:

- `p_lit < 0.05`: strict blackout-like sensitivity
- `p_lit < 0.20`: mostly-dark sensitivity
- `p_lit < 0.40`: preferred broad not-up / degraded-service proxy

The large-city robustness check should be retained as a limitation and interpretation note:

```text
The binary not-up metric is validated nationally and remains the preferred PyPSA proxy,
but it is conservative for very bright large cities because it does not capture small
relative dimming unless a settlement crosses the chosen p_lit gate.
```

If revisited later, the most useful additions would be:

- rerun the national validation excluding settlements above 1 million population
- rerun it with a hybrid large-settlement dimming metric
- compare resulting LocalArea annual uptime rankings against the current `p_lit < 0.40` construction
