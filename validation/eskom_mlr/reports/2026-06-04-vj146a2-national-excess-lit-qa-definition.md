---
type: work-report
date: '2026-06-04'
workstream: reliability-assessment
status: working-note
codebase: reliability-assessment
---

# VJ146A2 National Excess-Lit QA Definition

## Purpose

This note documents how the national daily VJ146A2 excess-lit diagnostic is calculated, so later visual checks and day-removal sensitivities use the same definition.

Related artifacts:

- Script: [[6-codebases/repos/Reliability-Assessment/Builder/vj146a2_2023_national_daily_qa.R]]
- QA outputs: [[6-codebases/repos/Reliability-Assessment/Map Data/settlement_day_outputs_vj146a2/national_daily_qa_2023]]
- Monthly Tukey excess-lit date list: [[validation/eskom_mlr/data/vj146a2_2023_excess_lit_monthly_tukey_dates_for_gif_check.csv]]
- Tukey/IQR summary: [[validation/eskom_mlr/data/vj146a2_2023_tukey_iqr_summary.csv]]

## Inputs Compared

For each VJ product date, the diagnostic compares:

- Daily VJ146A2 South Africa raster:
  - `rad`
  - `lit`
  - `valid`
- Annual VJ146A4 composite:
  - `NearNadir_Composite_Snow_Free`
  - annual quality mask applied before comparison

The annual composite is aligned to the daily raster grid before pixel-level comparison.

## Comparable Pixel Denominator

The denominator is not all South Africa pixels. It is only pixels valid in both the daily raster and annual composite for that specific date:

```text
comparable_pixels_d =
  daily_valid_d == TRUE
  AND annual_composite_valid == TRUE
```

If a daily raster has 50 percent invalid pixels, those invalid pixels are excluded from the comparison entirely, even when the annual composite has valid values there.

Daily-invalid pixels do not count as:

- excess lit
- excess dark
- annual lit
- annual dark
- denominator pixels

This is why `valid_share` is tracked separately in the QA table.

## Excess-Lit Share

Within the comparable pixel set, the diagnostic applies the lit threshold:

```text
daily_lit_d = daily_rad_d > 1.0
annual_lit = annual_rad > 1.0
annual_dark = annual_rad <= 1.0
```

The excess-lit count is:

```text
excess_lit_pixels_d =
  count(daily_lit_d == TRUE AND annual_dark == TRUE)
```

The national excess-lit share is:

```text
excess_lit_share_d =
  excess_lit_pixels_d
  /
  count(comparable_pixels_d)
```

Plain-language definition:

> `excess_lit_share` is the share of mutually valid daily-plus-annual pixels that are lit in the daily VJ146A2 image but dark in the annual VJ146A4 composite.

It is not:

```text
excess_lit_pixels / all South Africa pixels
```

## Black-Marble-Style Day Flag

The fast day-level analogue to the Black Marble composite outlier screen uses Tukey/IQR upper fences on the daily national `excess_lit_share` series.

For a monthly Tukey excess-lit flag:

```text
flag_d = excess_lit_share_d > Q3_month + 1.5 * IQR_month
```

where:

```text
IQR_month = Q3_month - Q1_month
```

This is an upper-tail-only rule because the suspected artifact is false brightness / stray light. Low-side darkness outliers are not automatically removed because they may be real blackout or dimming signal.

## Current Monthly Tukey Excess-Lit Dates

Using the monthly Tukey upper fence on `excess_lit_share`, the flagged VJ product dates are:

```text
2023-02-11
2023-02-15
2023-02-26
2023-03-14
2023-03-19
2023-03-30
2023-04-14
2023-04-20
2023-04-30
2023-05-12
2023-06-12
2023-06-27
2023-07-09
2023-07-25
2023-08-25
2023-09-16
2023-10-07
2023-10-08
2023-10-18
2023-10-23
2023-11-20
2023-12-05
```

Count:

- `22` observed VJ dates
- `17` of the `280` demand-gated validation pass nights used in the recommended Rmd validation specification

## Interpretation

This whole-day screen is not identical to the Black Marble composite method. Black Marble applies Tukey/IQR filtering at the pixel-observation level before forming monthly or annual composites.

The day-level `excess_lit_share` Tukey screen is a fast approximation:

- useful for identifying dates to inspect in the GIF
- useful for quick removal sensitivity
- not a replacement for full pixel-level outlier masking

The more faithful but slower version would mask anomalous pixel-day observations before recomputing settlement-day metrics.
