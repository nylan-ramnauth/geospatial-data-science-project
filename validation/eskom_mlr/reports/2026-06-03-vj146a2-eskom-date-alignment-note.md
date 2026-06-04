# VJ146A2 Eskom Date Alignment Note

**Date:** 2026-06-03
**Status:** Work note; canonical source is [[3-wiki/reliability-assessment/vj146a2-eskom-date-alignment]]
**Workstream:** reliability-assessment

## Finding

The October 2023 VJ146A2 settlement-day `date` should be interpreted as the VJ product/acquisition date. For Eskom MLR validation in the selected `01:00-02:00 SAST` overpass window, the local Eskom exposure date should be:

```text
local_overpass_date = vj_product_date + 1
```

This explains why the earlier "next-day" diagnostic was stronger than the same-calendar-date match: under the product-date interpretation, product date + 1 is the local overpass date, not a placebo.

## Documentation Quotes

NASA Black Marble User Guide, Collection 2.0:

> "Julian Date of Acquisition (A-YYYYDDD)"

LAADS VJ146A2 V2.0 file specification:

> "VJ146A2 V2.0.4 daily L3"

> "GranuleDayNightFlag STRING 1 PGE Night"

NOAA STAR VIIRS timing reference:

> "at 01:30 local solar time in the southbound direction"

## Local Metadata Check

Inspected cached H5:

```text
VJ146A2.A2023289.h20v12.002.2025142164411.h5
```

Observed metadata:

| Field | Value |
|---|---|
| `StartTime` | `2023-10-16 00:00:00.000` |
| `EndTime` | `2023-10-16 23:59:59.000` |
| `RangeBeginningDate` | `2023-10-16` |
| `RangeBeginningTime` | `00:00:00.000` |
| `RangeEndingDate` | `2023-10-16` |
| `RangeEndingTime` | `23:59:59.000` |
| `DayNightFlag` | `Night` |

## Validation Result

Filtered `>=10k` events, `coverage >= 0.8`, monthly median `p_lit >= 0.7`, Eskom `hour == 1`:

| Eskom date used | Strict vs shed share | Mostly-dark vs shed share |
|---|---:|---:|
| `product_date - 1` | cor `-0.075`, R2 `0.006` | cor `-0.052`, R2 `0.003` |
| `product_date` | cor `0.350`, R2 `0.122` | cor `0.335`, R2 `0.112` |
| `product_date + 1` | cor `0.458`, R2 `0.210` | cor `0.468`, R2 `0.219` |

## Example

| VJ product date | Strict events | Mostly-dark events | Same-date Eskom MLR / share | Product-date + 1 Eskom MLR / share |
|---|---:|---:|---:|---:|
| `2023-10-16` | 9 | 16 | `0 MW` / `0.000000` | `889.891 MW` / `0.040083` |
| `2023-10-17` | 12 | 24 | `889.891 MW` / `0.040083` | `959.320 MW` / `0.042496` |

## Caveat

The documentation and H5 metadata support the workflow-level date alignment. They do not prove exact per-pixel overpass timestamps, because the inspected daily VJ146A2 H5 fields do not include per-pixel acquisition times.

This note should be used only for date handling and validation diagnostics, not causal outage attribution.

## References

- NASA Black Marble User Guide, Collection 2.0: https://landweb.modaps.eosdis.nasa.gov/data/userguide/BlackMarbleUserGuide_Collection2.0_20241203.pdf
- LAADS VJ146A2 V2.0 file specification: https://ladsweb.modaps.eosdis.nasa.gov/filespec/VIIRS/2/VJ146A2_v2.0.fs
- NOAA STAR GBBEPx V5 ATBD: https://www.star.nesdis.noaa.gov/pub/smcd/akhuff/ACC_Product_Documentation/GBBEPx_V5_ATBD_2024.pdf
