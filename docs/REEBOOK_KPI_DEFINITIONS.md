# Uppal Reebok — KPI & Formula Source of Truth

> **Purpose:** This document is the single source of truth for every abbreviation, KPI definition, and formula used in the Uppal Reebok sales reports.
>
> **Critical implementation rule:** All report code must refer to the definitions in this document. Do **not** duplicate formulas independently in SQL, JavaScript, HTML, Excel, or any other report layer.
>
> **Change rule:** If a formula or definition is changed here, every reference/implementation of that KPI across the reports must be updated to use the new definition.

---

## 1. Core Business Rules


| Sales Associates | Balraj Gaddam, Rambabu Dharavath, Erri Srija |
| Final amount | Taxable Amount |
| Primary sales basis | RSV — Retail Sale Value |



---

## 2. KPI Definitions

| Abbreviation | Full Form | Formula | What it means |
|---|---|---|---|
| RSV | Retail Sale Value | `SUM(Taxable Amount)` | The retail sale value used as the primary sales basis for Uppal Reebok. |
| NSV | Net Sales Value | `SUM(Taxable Amount)` | The final sales value used for achievement and KPI calculations. |
| Target | Sales Target | Daywise: `that month's target ÷ days in the month (28/29/30/31)`; the monthly target is ₹14,00,000 unless the month has its own (September 2026: ₹8,00,000). MTD: sum of the daywise targets from the 1st through the report date | The sales amount that is expected to be achieved for the relevant period. |
| ACH% | Achievement Percentage | `(NSV Achieved / Target) × 100` | How much of the target has been achieved. |
| Bills | Number of Bills | `SUM(Bills)` | Total number of bills/transactions made. |
| Qty | Quantity Sold | `SUM(Qty Sold)` | Total number of units sold. |
| ATV | Average Transaction Value | `NSV / Bills` | Average sales value generated per bill. |
| UPT | Units Per Transaction | `Qty Sold / Bills` | Average number of units bought in one bill. |
| ASP | Average Selling Price | `NSV / Qty Sold` | Average selling value per unit. |
| FUPT | Footwear Per Unit Transaction | `Footwear Qty / Bills` | Average number of footwear units sold per bill. |
| SFR | Socks to Footwear Ratio | `Socks Qty / Footwear Qty` | How many socks are bought per footwear unit. |
| AFR | Apparel to Footwear Ratio | `Apparel Qty / Footwear Qty` | How many apparel units are sold per footwear unit. |
| FW | Footwear | Product section/category = `Footwear` | Footwear products sold. |
| APP | Apparel | Product section/category = `Apparel` | Apparel products sold. |
| ACC | Accessories | Product section/category = `Accessories` | Accessories products sold. |
| YTD | Year Till Date | `From 1 July through report date` | Cumulative result from 1 July (the most recent 1 July on or before the report date), computed by the pipeline from raw sales (`ytd` row in `gold.reebok_daily_metrics`). Target = ₹14,00,000 × completed months since 1 July + current MTD target. |
| MTD | Month Till Date | `From 1st of month through report date` | The cumulative result from the beginning of the month up to the report date. |
| WTD | Week Till Date | `From start of week through report date` | Week-to-date value, if/when implemented. |
| MD % | Markdown Percentage | `(MRP - NSV) / MRP x 100`, MRP = SUM(MRP x Qty) | How far below MRP the sales were made (decided 20-Sep-2026). Note: MRP includes GST and NSV does not, so this reads higher than a GST-inclusive comparison. |
| % Mix | Percentage Mix | `Category NSV / Total relevant NSV × 100` | The proportion of a category within the relevant total (NSV basis). |
| % within Gender | Division share within a gender | `Division MTD NSV / that Gender's total MTD NSV × 100` | Division split inside Men / Women / Unisex. |

---

## 2a. Units Sold — Data Rules

Verified against the raw SAP export (Aug-2026 audit).

- **Carry Bag lines are not units sold.** Lines with Class Name = `Carry Bag` are free packaging
  (MRP ₹1, 100% discount, ₹0 taxable amount, Section `RB UNISEX`, blank Item Division). They are
  excluded from Qty, division, gender and salesperson counts. NSV and Bills are unaffected
  (a bag never creates a bill). Do not confuse with Class Name `Bag`, which is real Accessories merchandise.
- **Blank Item Division is never defaulted to Accessories.** A blank division is resolved from Class Name
  using the `CLASS_TO_DIVISION` lookup in `refresh_reebok.py` (T Shirt, Shorts, GL HOODIE, Jogger → Apparel, etc.).
  Unknown classes are reported by the refresh job and kept out of the FW/APP/ACC buckets until mapped.
- **Similar-looking lines are separate units.** Two rows with the same Bill No., Class Name, Qty and
  Taxable Amount are different items (different stock numbers/sizes). Do not de-duplicate on those fields.
- **Returns** are negative rows inside exchange bills; keep them netted against sales.

---

## 3. Amount Source Rule

For Uppal Reebok, the final amount used for sales/KPI calculations is always the **Taxable Amount**.

Therefore:

```text
NSV Achieved = SUM(Taxable Amount)
```

and:

```text
RSV = SUM(Taxable Amount)
```

Do not substitute MRP, gross amount, or another amount field unless this document is explicitly changed.

---

## 4. Achievement Percentage

```text
ACH% = (NSV Achieved / Target) × 100
```

Example:

```text
NSV Achieved = ₹60,000
Target = ₹1,00,000

ACH% = (60,000 / 1,00,000) × 100
     = 60%
```

Achievement percentage must use the report's **NSV Achieved** and the applicable **Target**.

### Target rule

```text
Monthly Target   = ₹14,00,000 by default; a month can have its own target (see the table below)
Daywise Target   = that month's Monthly Target ÷ days in that month
MTD Target       = Daywise Target × day-of-month  (sum of daywise targets 1st → report date)
```

Monthly targets in force:

| Month | Monthly target |
|---|---|
| Every month unless listed | ₹14,00,000 |
| September 2026 | ₹8,00,000 |

Example (August, 31 days): Daywise Target = 14,00,000 ÷ 31 = ₹45,161; MTD Target on 3-Aug = ₹1,35,484.
Example (September, 30 days): Daywise Target = 8,00,000 ÷ 30 = ₹26,667; MTD Target on 17-Sep = ₹4,53,333.
YTD Target = each completed month's own target since 1 July (the most recent 1 July on or before the report date) + the current MTD target.
To change a month's target, edit `MONTHLY_TARGET_OVERRIDES` in `src/lib/email/reebokHelpers.js` (one line per month).
The daywise value is not rounded in calculations (rounding is display-only) so MTD sums stay exact.
Canonical implementation: `calcTarget`, `MTD_TARGET`, `calcAchievement` in `src/lib/email/reebokHelpers.js`.

### Color coding

Achievement % is the only value that is color coded, and it is coloured **relatively** (decided 21-Sep-2026), the same way in the on-screen report, the email images and the Excel download:

- Within each comparison group the **lowest** value is **red**, the **highest** is **green**, and values in between are blended through yellow (the standard red-yellow-green color scale). There are no fixed percentage cut-offs.
- Comparison groups: the ACH% column of the salespeople in each Staffwise KPI table (the STORE TOTAL is placed on the same scale), and the three Achievement % cells (Daywise, MTD, YTD) of the first table.
- If every value in a group is the same there is nothing to rank, so they all get the middle (yellow) color.
- Colors are computed in one place (`heatColor` and `applyRelativeHeat` in `src/lib/email/reebokReportModel.js`).

---

## 5. Transaction KPIs

### ATV — Average Transaction Value

```text
ATV = NSV / Bills
```

Meaning: average NSV generated by each bill.

### UPT — Units Per Transaction

```text
UPT = Qty Sold / Bills
```

Meaning: average number of units purchased in one bill.

### ASP — Average Selling Price

```text
ASP = NSV / Qty Sold
```

Meaning: average selling value per unit sold.

### FUPT — Footwear Per Unit Transaction

```text
FUPT = Footwear Qty / Bills
```

Meaning: average footwear units sold per bill.

---

## 6. Cross-Sell KPIs

### SFR — Socks to Footwear Ratio

```text
SFR = Socks Qty / Footwear Qty
```

Meaning: how many socks are bought per footwear unit.

### AFR — Apparel to Footwear Ratio

```text
AFR = Apparel Qty / Footwear Qty
```

Meaning: how many apparel units are sold per footwear unit.

These ratios must be recalculated from their underlying numerator and denominator at every aggregation level. Never sum or average already-calculated ratios.

---

## 7. Daywise vs MTD

Every applicable report must distinguish between:

### Today / Daywise

Use only the sales for the selected report date.

### MTD

Use cumulative sales from:

```text
1st day of the month → selected report date
```

The same KPI formulas apply at both levels. Only the underlying date range changes.

---

## 8. Staffwise KPI Rules

There are exactly three Sales Associates:

1. Balraj Gaddam
2. Rambabu Dharavath
3. Erri Srija

### Staffwise actual sales

For both Today and MTD, use the salesperson attached to each actual sales record.
Do not divide quantity, NSV, or any staff total equally among associates. Sales targets
are calculated separately and are not staff sales values.

For each Sales Associate calculate:

- Total Qty Sold
- Total NSV
- Footwear Qty
- Footwear NSV
- Apparel Qty
- Apparel NSV
- Accessories Qty
- Accessories NSV

Repeat for:

- Today
- MTD

The staffwise FW/APP/ACC quantities and NSV must be calculated from **what that salesperson actually sold**.

---

## 9. Gender-wise % Mix

Gender mix is calculated as:

```text
Men % Mix =
Men NSV / (Men NSV + Women NSV + Unisex NSV) × 100
```

Similarly:

```text
Women % Mix =
Women NSV / (Men NSV + Women NSV + Unisex NSV) × 100
```

```text
Unisex % Mix =
Unisex NSV / (Men NSV + Women NSV + Unisex NSV) × 100
```

Repeat the same calculation for:

- Today
- MTD

Use the relevant underlying sales quantity data.

---

## 10. Division-wise Report

The division-wise report must be generated for:

- Today
- MTD

Division values must come directly from the underlying sales data.

Do not hardcode division values.

---

## 11. Division Split Within Gender

The gender × division report must show the division split within each gender, following the supplied visual reference.

Apply it for:

- Today
- MTD

Use actual underlying sales data for the calculation.

Do not hardcode division/gender values.

---

## 12. Dependency / Single Source of Truth Rule

Every KPI has a stable definition and should have one canonical implementation.

### Required dependency chain

```text
Source Sales Data
       ↓
Taxable Amount
       ↓
NSV / RSV
       ↓
Target
       ↓
ACH%

Source Sales Data
       ↓
Bills + Qty
       ↓
ATV / UPT / ASP / FUPT

Source Sales Data
       ↓
Footwear Qty + Socks Qty + Apparel Qty
       ↓
SFR / AFR

Source Sales Data
       ↓
Gender / Division / Salesperson
       ↓
Gender Mix / Division Split / Staffwise Report
```

### Critical coding rule

If a KPI formula changes:

1. Change the formula in this document.
2. Update the single canonical implementation/configuration used by the code.
3. All reports must consume that canonical definition.
4. Do not create report-specific versions of the same formula.

For example, if `ASP` changes from:

```text
NSV / Qty
```

to another formula, the Daywise report, MTD report, Staffwise KPI, HTML output, and Excel output must all use the updated definition.

---

## 13. Unknown Values

When the source data or approved business rules do not provide enough information to calculate a value:

```text
NULL
```

must be used.

Do not:

- Guess
- Reverse-engineer
- Hardcode
- Copy a value from another report
- Use a fabricated default

The ₹45,161 daywise target is now derived by the Target rule in section 4 (₹14,00,000 ÷ 31).

---

## 14. Implementation Requirement

The implementation must maintain a **single source of truth** for these KPI definitions.

The HTML/email reports and Excel reports must never contain separate hardcoded formula implementations.

All calculations should flow through the canonical KPI/metrics definitions so that changing one definition propagates everywhere.

---

## 15. Change Log

| Date | Change | Impact |
|---|---|---|
| 05-Sep-2026 | Initial Uppal Reebok KPI source of truth created | All report KPI calculations must follow this document |
| 05-Sep-2026 | ₹8L monthly budget assumption added | Target calculations use this assumption where applicable |
| 05-Sep-2026 | Weekday/weekend allocation added | Weekday = 15%, Weekend = 50% |
| 05-Sep-2026 | Taxable Amount established as final amount | NSV/RSV calculations use Taxable Amount |
| 05-Sep-2026 | Staffwise rules added | Exact 3 associates and staffwise product calculations |
| 19-Sep-2026 | Target rule replaced: ₹14L/month ÷ days in month; MTD = sum of daywise targets | Supersedes the ₹8L / weekday-weekend assumption; ACH% now computed for Daywise and MTD |
| 19-Sep-2026 | % Mix and % within Gender now NSV-based; SFR/AFR displayed as %; per-staff Target = store target ÷ 3; store-total rows added | Sales report tables and Excel follow public/SALES-REPORT-LAYOUT.md via src/lib/email/reebokReportModel.js |
| 19-Sep-2026 | YTD column added (calendar year, derived from gold MTD rows) | Daywise + MTD + YTD table and Excel show YTD NSV, Target, ACH%, Bills, Qty |
| 19-Sep-2026 | YTD is now computed in the pipeline (new `ytd` period_type) instead of summing MTD rows | Migration 2026_09_19_reebok_ytd.sql + refresh_reebok.py; YTD target = ₹14L × completed months + MTD target |
| 19-Sep-2026 | Carry Bag lines excluded from unit counts; blank Item Division resolved from Class Name (no default to Accessories) | Fixes inflated Qty (120→66), Accessories and Unisex; refresh_reebok.py must be re-run |
| 20-Sep-2026 | MD % defined as (MRP - NSV) / MRP; master dashboard tables added (gold.reebok_master_dashboard, gold.reebok_master_dashboard_payments); Account DSR loader maps the real Reebok headers | Migration 2026_09_20_reebok_master_dashboard.sql; DSR files must be re-uploaded |
| 20-Sep-2026 | Monthly target is now per month: default ₹14,00,000, September 2026 = ₹8,00,000 | Daywise, MTD and YTD targets and ACH% in the sales report, Excel and (later) the dashboard follow the month's own target |
| 20-Sep-2026 | YTD confirmed as the calendar year, 1 January to the report date | No change to the calculation; YTD target counts every month since 1 January at its own target |
| 21-Sep-2026 | ACH% color coding changed from fixed thresholds (80 / 60) to relative coloring (lowest red, highest green) | Sales report tables, email images and Excel |
| 22-Sep-2026 | YTD now starts on 1 July (most recent 1 July on or before the report date), not 1 January; client decision | Pipeline `ytd` row, YTD target, footnote and Master Dashboard YTD quick range all use 1 July. Re-run refresh_reebok.py to rebuild the `ytd` rows |
