# VJ146A2 Full-Year Additional Plot/GIF Candidates

**Date:** 2026-06-03
**Status:** Working candidate screen
**Input events:** `6-codebases/repos/Reliability-Assessment/Map Data/settlement_day_outputs_vj146a2/mlr_validation_2023/vj146a2_2023_mlr_validation_large_events.csv`
**Underlying panel:** `6-codebases/repos/Reliability-Assessment/Map Data/settlement_day_outputs_vj146a2/settlement_day_vj146a2_cov_yearlykeep_2023-MM.parquet`
**Screened event table:** `validation/closeups/data/vj146a2_full_year_plot_gif_candidate_screen.csv`
**Recommended candidates:** `validation/closeups/data/vj146a2_full_year_additional_plot_gif_candidates.csv`
**Executed notebook:** `validation/closeups/notebooks/vj146a2_full_year_selected_settlement_pixel_closeups.ipynb`
**Rendered outputs:** `validation/closeups/figures/generated/vj146a2_full_year_selected_settlement_pixel_closeups/`
**Related reports:** [[validation/data_manifest.md#legacy-closeup-artifacts]], [[validation/eskom_mlr/reports/2026-06-03-vj-full-year-mlr-validation-calibration]]

## Method

This screen starts from the full-year large-event table and joins each event to the same settlement's previous-day and next-day rows in the VJ yearlykeep coverage-filtered monthly panels. This is stricter than ranking event days alone: a candidate is useful for a notebook or GIF only if the surrounding days actually exist in the panel and have enough valid coverage.

- Minimum coverage on each of previous/event/next day: `0.8`.
- Minimum full-year retained observations for the settlement: `180`.
- `notebook_sharp_three_day_dip`: event `p_lit_sett < 0.20`, both neighboring days `p_lit_sett >= 0.45`, and average neighbor-to-event drop at least `0.40`.
- `gif_sustained_high_coverage_episode`: event `p_lit_sett < 0.20`, previous/event/next rows all available with enough coverage, but neighboring days are also dark on average. These are less ideal for a before/after contrast panel but useful for an animated sequence.
- Settlement IDs already present in the 15 priority candidates from the full-year brief are excluded here so this list surfaces additional settlements.

## Screen Summary
|Large-event rows screened |Rows with prev+next data |Rows passing 3-day coverage screen |Rows passing observation+coverage screen |Sharp three-day dips |Sustained high-coverage episodes |Large sharp dips >=50k |Large sustained episodes >=50k |
|:-------------------------|:------------------------|:----------------------------------|:----------------------------------------|:--------------------|:--------------------------------|:----------------------|:------------------------------|
|8,065                     |4,043                    |3,356                              |2,883                                    |822                  |560                              |46                     |23                             |

## Additional Large Settlements For Notebook Panels

These are new `population >= 50,000` candidates with clean previous/event/next observations and a visible one-day drop.

|Date       |Local overpass |Settlement ID |Settlement                          |Province     |District            |Population |Class                     |Prev p_lit |Event p_lit |Next p_lit |Min 3-day coverage |Obs days |Neighbor drop |Shed share |
|:----------|:--------------|:-------------|:-----------------------------------|:------------|:-------------------|:----------|:-------------------------|:----------|:-----------|:----------|:------------------|:--------|:-------------|:----------|
|2023-04-24 |2023-04-25     |46678         |Ga-Segonyana Local Municipality     |Nothern Cape |John Taolo Gaetsewe |92,690     |mostly_dark_p_lit_lt_0.20 |0.7936     |0.1635      |0.9016     |1.0000             |272      |0.6841        |0.1076     |
|2023-09-13 |2023-09-14     |48939         |Matjhabeng Local Municipality       |Free State   |Lejweleputswa       |70,099     |strict_dark_p_lit_lt_0.05 |0.9003     |0.0276      |0.9091     |1.0000             |240      |0.8771        |0.1065     |
|2023-05-22 |2023-05-23     |49044         |Moqhaka Local Municipality          |Free State   |Fezile Dabi         |80,800     |mostly_dark_p_lit_lt_0.20 |1.0000     |0.0853      |1.0000     |1.0000             |235      |0.9147        |0.0748     |
|2023-07-12 |2023-07-13     |51558         |Merafong City Local Municipality    |Gauteng      |West Rand           |54,228     |mostly_dark_p_lit_lt_0.20 |0.9349     |0.1300      |0.9414     |1.0000             |238      |0.8081        |0.1142     |
|2023-01-22 |2023-01-23     |52564         |Westonaria Local Municipality       |Gauteng      |West Rand           |51,908     |strict_dark_p_lit_lt_0.05 |0.5944     |0.0385      |0.5999     |1.0000             |243      |0.5587        |0.0581     |
|2023-04-17 |2023-04-18     |55160         |Moses Kotane Local Municipality     |North West   |Bojanala            |56,179     |strict_dark_p_lit_lt_0.05 |0.7430     |0.0366      |0.8153     |1.0000             |245      |0.7425        |0.1078     |
|2023-04-21 |2023-04-22     |61851         |Thembisile Hani Local Municipality  |Mpumalanga   |Nkangala            |56,096     |strict_dark_p_lit_lt_0.05 |0.9891     |0.0000      |0.8920     |0.9689             |244      |0.9405        |0.1153     |
|2023-07-12 |2023-07-13     |61930         |Emalahleni Local Municipality       |Mpumalanga   |Nkangala            |54,794     |mostly_dark_p_lit_lt_0.20 |0.7113     |0.0902      |0.8746     |0.8730             |242      |0.7028        |0.1142     |
|2023-10-06 |2023-10-07     |63077         |Albert Luthuli Local Municipality   |Mpumalanga   |Gert Sibande        |57,739     |mostly_dark_p_lit_lt_0.20 |0.9704     |0.1420      |0.9988     |0.8867             |183      |0.8426        |0.0373     |
|2023-01-22 |2023-01-23     |70237         |Bela Bela Local Municipality        |Limpopo      |Waterberg           |59,264     |mostly_dark_p_lit_lt_0.20 |0.9686     |0.1979      |0.4895     |1.0000             |254      |0.5311        |0.0581     |
|2023-01-18 |2023-01-19     |70495         |Dr JS Moroka Local Municipality     |Mpumalanga   |Nkangala            |88,664     |mostly_dark_p_lit_lt_0.20 |0.9288     |0.0923      |0.9985     |0.9909             |239      |0.8713        |0.0901     |
|2023-07-12 |2023-07-13     |70733         |Elias Motsoaledi Local Municipality |Limpopo      |Sekhukhune          |52,367     |strict_dark_p_lit_lt_0.05 |0.8685     |0.0143      |0.9036     |1.0000             |252      |0.8718        |0.1142     |

## Additional Large Settlements For GIFs

These are new `population >= 50,000` candidates with strong coverage but a sustained dark spell rather than a clean one-day dip.

|Date       |Local overpass |Settlement ID |Settlement                          |Province     |District            |Population |Class                     |Prev p_lit |Event p_lit |Next p_lit |Min 3-day coverage |Obs days |Neighbor drop |Shed share |
|:----------|:--------------|:-------------|:-----------------------------------|:------------|:-------------------|:----------|:-------------------------|:----------|:-----------|:----------|:------------------|:--------|:-------------|:----------|
|2023-03-06 |2023-03-07     |46678         |Ga-Segonyana Local Municipality     |Nothern Cape |John Taolo Gaetsewe |92,690     |mostly_dark_p_lit_lt_0.20 |0.4923     |0.0877      |0.0741     |0.8790             |272      |0.1955        |0.1123     |
|2023-09-14 |2023-09-15     |48709         |Klerksdorp                          |North West   |Dr Kenneth Kaunda   |92,082     |mostly_dark_p_lit_lt_0.20 |0.0768     |0.1106      |0.4095     |1.0000             |252      |0.1325        |0.1102     |
|2023-04-26 |2023-04-27     |48939         |Matjhabeng Local Municipality       |Free State   |Lejweleputswa       |70,099     |mostly_dark_p_lit_lt_0.20 |0.1804     |0.1071      |0.0951     |0.8179             |240      |0.0307        |0.0616     |
|2023-02-22 |2023-02-23     |51558         |Merafong City Local Municipality    |Gauteng      |West Rand           |54,228     |strict_dark_p_lit_lt_0.05 |0.0294     |0.0459      |0.0069     |1.0000             |238      |-0.0277       |0.1301     |
|2023-02-22 |2023-02-23     |52564         |Westonaria Local Municipality       |Gauteng      |West Rand           |51,908     |mostly_dark_p_lit_lt_0.20 |0.3857     |0.1072      |0.2095     |1.0000             |243      |0.1904        |0.1301     |
|2023-04-18 |2023-04-19     |61851         |Thembisile Hani Local Municipality  |Mpumalanga   |Nkangala            |56,096     |strict_dark_p_lit_lt_0.05 |0.0334     |0.0010      |0.1079     |1.0000             |244      |0.0697        |0.1133     |
|2023-12-02 |2023-12-03     |63077         |Albert Luthuli Local Municipality   |Mpumalanga   |Gert Sibande        |57,739     |mostly_dark_p_lit_lt_0.20 |0.1567     |0.1579      |0.1297     |0.8784             |183      |-0.0147       |0.0681     |
|2023-01-26 |2023-01-27     |70495         |Dr JS Moroka Local Municipality     |Mpumalanga   |Nkangala            |88,664     |mostly_dark_p_lit_lt_0.20 |0.2063     |0.1398      |0.0530     |1.0000             |239      |-0.0102       |0.1054     |
|2023-04-21 |2023-04-22     |70733         |Elias Motsoaledi Local Municipality |Limpopo      |Sekhukhune          |52,367     |mostly_dark_p_lit_lt_0.20 |0.1708     |0.1069      |0.0783     |0.9964             |252      |0.0177        |0.1153     |

## Secondary 10k-50k Candidates

These are smaller settlements with very clean support. They are useful if the notebook needs a broader size gradient.

|Date       |Local overpass |Settlement ID |Settlement                     |Province     |District            |Population |Class                     |Prev p_lit |Event p_lit |Next p_lit |Min 3-day coverage |Obs days |Neighbor drop |Shed share |
|:----------|:--------------|:-------------|:------------------------------|:------------|:-------------------|:----------|:-------------------------|:----------|:-----------|:----------|:------------------|:--------|:-------------|:----------|
|2023-11-16 |2023-11-17     |11374         |Emthanjeni Local Municipality  |Nothern Cape |Pixley ka Seme      |11,006     |strict_dark_p_lit_lt_0.05 |0.9418     |0.0003      |0.9418     |1.0000             |248      |0.9415        |0.0594     |
|2023-09-12 |2023-09-13     |11401         |Umsobomvu Local Municipality   |Nothern Cape |Pixley ka Seme      |11,358     |mostly_dark_p_lit_lt_0.20 |1.0000     |0.1257      |0.9625     |1.0000             |235      |0.8556        |0.0993     |
|2023-10-17 |2023-10-18     |11530         |Siyancuma Local Municipality   |Nothern Cape |Pixley ka Seme      |10,646     |strict_dark_p_lit_lt_0.05 |0.9609     |0.0000      |0.9724     |1.0000             |243      |0.9666        |0.0425     |
|2023-07-14 |2023-07-15     |11668         |Letsemeng Local Municipality   |Free State   |Xhariep             |10,819     |strict_dark_p_lit_lt_0.05 |0.9982     |0.0000      |0.9710     |1.0000             |236      |0.9846        |0.1043     |
|2023-10-13 |2023-10-14     |11771         |Dikgatlong Local Municipality  |Nothern Cape |Frances Baard       |12,749     |strict_dark_p_lit_lt_0.05 |0.9938     |0.0000      |0.9970     |1.0000             |247      |0.9954        |0.0415     |
|2023-05-15 |2023-05-16     |11887         |Magareng Local Municipality    |Nothern Cape |Frances Baard       |20,547     |mostly_dark_p_lit_lt_0.20 |0.8601     |0.1773      |0.9630     |1.0000             |260      |0.7343        |0.0985     |
|2023-04-16 |2023-04-17     |12930         |Tswelopele Local Municipality  |Free State   |Lejweleputswa       |22,532     |mostly_dark_p_lit_lt_0.20 |0.9632     |0.1845      |0.9339     |0.9563             |233      |0.7641        |0.1149     |
|2023-08-11 |2023-08-12     |13087         |Selosesha 7                    |Free State   |Mangaung            |17,354     |strict_dark_p_lit_lt_0.05 |1.0000     |0.0000      |1.0000     |1.0000             |223      |1.0000        |0.0687     |
|2023-04-15 |2023-04-16     |13088         |Selosesha 5                    |Free State   |Mangaung            |14,171     |strict_dark_p_lit_lt_0.05 |1.0000     |0.0000      |0.9997     |1.0000             |227      |0.9998        |0.1275     |
|2023-09-13 |2023-09-14     |13241         |Masilonyana Local Municipality |Free State   |Lejweleputswa       |10,693     |strict_dark_p_lit_lt_0.05 |0.8864     |0.0000      |0.9600     |1.0000             |240      |0.9232        |0.1065     |
|2023-04-15 |2023-04-16     |13256         |Setsoto Local Municipality     |Free State   |Thabo Mofutsanyane  |14,345     |strict_dark_p_lit_lt_0.05 |0.8309     |0.0000      |0.7536     |1.0000             |236      |0.7922        |0.1275     |
|2023-08-15 |2023-08-16     |13435         |Setsoto Local Municipality     |Free State   |Thabo Mofutsanyane  |25,566     |strict_dark_p_lit_lt_0.05 |1.0000     |0.0000      |0.9269     |1.0000             |230      |0.9635        |0.0647     |
|2023-12-11 |2023-12-12     |3922          |Matzikama Local Municipality   |Western Cape |West Coast          |15,756     |mostly_dark_p_lit_lt_0.20 |0.9895     |0.1206      |0.9876     |1.0000             |267      |0.8680        |0.0620     |
|2023-04-25 |2023-04-26     |46462         |Gamagara Local Municipality    |Nothern Cape |John Taolo Gaetsewe |11,585     |strict_dark_p_lit_lt_0.05 |0.9476     |0.0000      |0.9340     |1.0000             |265      |0.9408        |0.0900     |
|2023-12-13 |2023-12-14     |46548         |Gamagara Local Municipality    |Nothern Cape |John Taolo Gaetsewe |10,951     |strict_dark_p_lit_lt_0.05 |0.8346     |0.0000      |0.9572     |1.0000             |264      |0.8959        |0.0355     |

## Interpretation

The notebook list is better for side-by-side before/event/after panels because both neighboring days are visibly brighter. The GIF list is better for multi-day sequences because the dark state often persists into neighboring days. Neither list confirms blackouts by itself; both lists only identify high-support candidates for raw-pixel inspection.
