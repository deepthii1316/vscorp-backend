# Merch Dashboard — Walkthrough

**Store:** Uppal Reebok (`R1157`) · **Page:** sidebar → **Merch Dashboard** (`/merch-dashboard`) · **Who:** admin only
**Written:** 2 October 2026, numbers below are from the 1 Oct 2026 stock report.

The Master Dashboard answers *"how much did we sell?"*. The Merch Dashboard answers the
merchandiser's question: **"is our stock healthy, and is it moving?"** It puts today's stock
next to recent sales, barcode by barcode, and shows what is selling, what is stuck, and
what to act on.

---

## 1. How it was built (where the numbers come from)

```text
Stock Balance Report (.xlsx)          Bill-wise sales report (.xlsx)
  uploaded daily on Data Upload         uploaded daily on Data Upload
        │                                       │
        ▼                                       ▼
raw.inventory  (one row per EAN)        raw.sales  (one row per bill line)
        │                                       │
        ▼        Run Processing (pipeline)      ▼
staging.fact_stock  ◄── joined on EAN ──►  staging.fact_sales
  stock qty, MRP value, last inward date      qty, NSV, bill date
        │                                       │
        └──────────────┬────────────────────────┘
                       ▼
       public.rpt_merch_sku()   — one row per barcode (EAN)
                       ▼
       /api/merchandiser        — admin-only, sends all rows once
                       ▼
       Merch Dashboard page     — every filter, tab and total is calculated in the browser
```

**Step by step:**

1. **The stock file.** Every day the store exports *Stock Balance – Detailed* from SAP and uploads it
   as *Inventory / Stock*. It has one row per barcode with: EAN, style code, size, colour, category,
   quantity, MRP, and **Last Inwarded Date** (when that barcode last came into the store).
2. **The join key is the EAN** (the 13-digit barcode on the tag). The sales report's "Bar Code"
   is the same EAN, so each stock line can be matched to its sales. Style code (+ colour) groups
   the sizes of one article.
   *Before 2 Oct the ingest saved the style code instead of the EAN, dropped the inward date, and
   silently loaded 0 rows from 6 of 8 stock files. That was fixed first — without it none of this
   dashboard could work.*
3. **Processing** (the Run Processing button) loads both files into the staging tables. Each stock
   file is stamped with the date it describes (taken from the export file name), so the dashboard
   always uses the **latest stock snapshot**.
4. **One database function, `rpt_merch_sku()`**, returns one row per barcode: what is in stock now,
   its MRP value, its age, when it last sold, and how much sold in the last 30 days / this month /
   since the store opened. It includes barcodes that sold in the last 30 days but are now sold out
   (so sell-through is not overstated). Paper carry bags and promotional trolleys are left out —
   they are not merchandise (1,416 bags + 22 trolleys would otherwise swamp Accessories).
5. **The page downloads all ~2,850 rows once**, then does every calculation in the browser. That is
   why changing a filter or threshold is instant — nothing is refetched.

**Stock value is always at MRP** (quantity × MRP), the same basis as every other Virata report.

---

## 2. Words used on the page

| Term | Meaning |
|---|---|
| **As of** | The date of the latest stock report (shown under the page title). Sales are counted up to the same day. |
| **EAN / barcode** | One size of one article. The smallest unit on the dashboard. |
| **Article** | One style in one colour, all sizes together (Sell-Through tab). |
| **Age** | Days since the barcode's **last inward** (it last arrived in the store). |
| **Idle days** | Days since **anything happened** to the barcode: the later of its last sale and its last inward. A shoe that arrived 90 days ago but sold yesterday has 1 idle day. |
| **Healthy / Slow / At Risk / Dead** | Idle-day buckets. Defaults: under 30 = Healthy, 30–59 = Slow, 60–89 = At Risk, 90+ = Dead. Adjustable on screen. |
| **Sell-through (30d)** | Units sold in the last 30 days ÷ (those units + units on hand now). 50% = half of what we had was sold. |
| **Cover** | How many days the current stock lasts at the average daily sales rate since the store opened (up to 6 months). |
| **MTD** | Month to date: the 1st of the month up to the "as of" date. |
| **NSV** | Net sales value = Taxable Amount, same as the sales reports. |

---

## 3. The page, top to bottom

**Header**
- **Barcode box** (top right) — scan or type an EAN and press *Look up*. Opens the product panel (§8).
- **Refresh** — reloads the data (use after a processing run).

**Filter bar** — Division › Department › Section › Article type. They cascade: picking *Footwear*
limits Department to footwear departments, and so on. *Clear* resets. The filter applies to every tab.

**Tabs** — Overview, Inventory Health, Dead Stock, Sell-Through. Each has an **Excel** button that
exports exactly what is on screen (current filter, current thresholds).

---

## 4. Tab 1 — Overview

**Question:** *How much stock do we hold, where is it, and is it selling?*

**Tiles (1 Oct 2026, all categories):**

| Tile | Value | How it is calculated |
|---|---|---|
| Stock units | 4,538 | Sum of quantity in the latest stock report (2,776 barcodes in stock). |
| Stock value (MRP) | ₹1,64,07,920 | Σ quantity × MRP. |
| Sales units MTD | 9 | Units sold from the 1st to the as-of date. |
| NSV MTD | ₹15,399 | Taxable amount of those sales. |
| Sell-through 30d | 5.2% | 247 sold in 30 days ÷ (247 + 4,538 on hand). |
| Stock cover | ~647 days | 4,538 ÷ (units sold since opening ÷ days open). |

**Table — "Stock and sales by category":** Division › Department › Section › Article type, biggest
stock value first. Click a row with › to open the level below. Columns: stock qty, stock value, its
share of total stock (bar), sales qty and NSV MTD, sales qty 30 days, sell-through 30d (green ≥ 60%,
red < 15%), cover.

**How to use it:** find categories where the **share of stock is much bigger than their share of
sales** (high stock %, low sell-through, long cover) — that is where money is tied up. Today:
footwear holds ₹1.08 Cr of the ₹1.64 Cr at 4.9% sell-through.

*Why 30 days and not MTD for sell-through?* On the 1st of a month MTD sales are near zero, so MTD
sell-through would always look terrible early in the month. 30 days is steady all month.

---

## 5. Tab 2 — Inventory Health

**Question:** *How much of our stock is moving, and how much is stuck?*

**Threshold bar:** the three idle-day limits (Slow / At risk / Dead). Change them and press
*Apply*; your browser remembers them. Every barcode is re-bucketed instantly.

**Four bucket cards (1 Oct, defaults 30 / 60 / 90):**

| Bucket | Stock value | Units | Barcodes |
|---|---|---|---|
| Healthy (< 30 idle days) | ₹34,40,837 | 1,163 | 632 |
| Slow (30–59) | ₹31,32,126 | 961 | 546 |
| At Risk (60–89) | ₹21,29,819 | 651 | 387 |
| Dead (90+) | ₹77,05,138 | 1,763 | 1,208 |

**Health mix** — one bar split into the four buckets, with the same numbers in a small table.

**Age profile** — stock value by age band (≤30, 31–60, 61–90, 91–180 days… since last inward),
and the average age (unit-weighted).

**Health by category** — the category tree again, each row with a mini mix bar, the value in each
bucket, **Dead %** (red ≥ 20%, amber ≥ 10%) and average age.

**Important:** every barcode is judged on its own, then added up. A category that looks mostly
healthy can still hide a pile of dead barcodes — the Dead Stock tab lists them.

**Reading today's numbers:** 47% of stock value is Dead. Almost all of it is the opening stock that
arrived on 29 Jun 2026 and has not sold once since. It is real (it is the stock to act on), but
remember the store only opened in July — as months pass, Dead will reflect genuinely old stock.

---

## 6. Tab 3 — Dead Stock

**Question:** *Exactly which barcodes are stuck?*

The barcode-level list behind the Dead bucket — same rule, same rows, so it always agrees with
Inventory Health.

- **Dead / Dead + At risk** switch — widen the list to everything idle 60+ days.
- **Search** — barcode, article name, style code or article type.
- **Columns** — article, barcode (click it for the product panel), size, category, stock qty, value,
  age, last sale (or *Never*), idle days, bucket. Click a column heading to sort.
- **Totals** above the table — barcodes, units and value of the current list.
- 50 rows per page. **Excel** exports *all* rows (not just the visible page) plus a by-category summary.

**How to use it:** sort by value, take the top of the list to the store / buying team for
**markdown, transfer back, or display changes**. Barcodes with *Last sale: Never* and high age are
the first candidates.

---

## 7. Tab 4 — Sell-Through

**Question:** *Which articles are flying, and which are not moving?*

Works at **article level** (style + colour, all sizes together), because buying decisions are
made per article, not per size.

**Tiles:** articles (718), fast movers (≥ 60% sell-through — 1 today, plus 8 already sold out),
slow movers (< 15% while holding stock, or no sale in 30 days — 628), and units sitting in slow movers.

**Speed filter:** All · Fast · Moderate · Slow · No sales 30d · Sold out (with counts).

**Table:** article, category, MRP, stock, sold 30d, sell-through 30d, sold MTD, cover, last sale,
speed. **Click an article to see its sizes** — each size with its own stock, sales and sell-through,
which shows **size gaps** (e.g. size 9 sold out while 6 and 11 sit).

**How to use it:**
- **Fast / Sold out** → reorder or move stock in before it runs out (check which sizes are gone).
- **Slow / No sales 30d** with lots of stock → markdown or reduce the next order.

*Why are thresholds 60% / 15%?* They come from the Skechers template. With a new store and
~250 units sold per month against ~4,500 in stock, very few articles reach 60% yet — rank by
sell-through rather than waiting for the green label.

---

## 8. Barcode lookup (product panel)

Type or scan an EAN in the header box, or click any barcode in a table. A panel slides in with:

- **Identity** — article, division › department › section › type, style, size, colour.
- **Facts** — stock now, MRP, stock value, last inward, age, last sale, idle days, health bucket,
  sold in 30 days, sell-through, cover.
- **Sales** — every bill line for that barcode (date, bill no., salesperson, qty, MRP, NSV); returns
  are highlighted.
- **Stock snapshots** — quantity on each stock report date.

A barcode that is sold out still shows its sales history. Close with ✕, Esc, or by clicking outside.

---

## 9. Keeping it up to date

1. Upload the daily **Stock Balance Report** (and the sales report) on **Data Upload**.
2. Press **Run Processing** and wait for *Processed* in Upload History.
3. Open the Merch Dashboard and press **Refresh**. The "as of" date moves to the new stock date.

If two stock files describe the same day, the most recently uploaded one is used — never both.

---

## 10. Known limitations (2 Oct 2026)

- **Stock history:** only the 1 Oct snapshot is loaded so far; the 22–30 Sep files are fixed in code
  and waiting to be reprocessed. Ages and Dead Stock are unaffected (they use inward dates and the
  full sales history); only the "Stock snapshots" list in the product panel is short.
- **Young store:** sales start 1 Jul 2026, so the cover rate uses ~3 months, and "Dead" is mostly
  opening stock (see §5).
- **No season, cluster, store or transfer views** — the Skechers template has them, but Uppal is a
  single store and the Reebok files carry no season.
- **Thresholds are per browser** — set on one computer, they are not shared with others.

---

## 11. Where the code lives

| Piece | File |
|---|---|
| Stock ingest (sheet detection, EAN, inward date) | `backend/worker/pipeline/ingest_file.py` |
| Stock staging refresh (EAN join, snapshots) | `backend/worker/pipeline/scripts/refresh_stock.py` |
| Database functions | `backend/database/migrations/2026_10_02_merch_dashboard_rpcs.sql` (`rpt_merch_sku`, `rpt_merch_product_history`) |
| API | `frontend/src/app/api/merchandiser/route.js`, `.../merchandiser/product/route.js` |
| Calculations (buckets, sell-through, cover, trees) | `frontend/src/lib/merchShared.js` |
| Page and tabs | `frontend/src/app/merch-dashboard/page.js`, `frontend/src/components/merch/*` |
| Template it is based on (Skechers) | `frontend/public/docs/MERCHANDISER_DASHBOARD_REFERENCE.md` |
