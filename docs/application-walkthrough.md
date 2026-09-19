# Virata Retail Operations Platform

## Application Walkthrough and Scope Validation

**Project:** Virata Retail Operations and Reporting Platform  
**Store in scope:** Uppal Reebok, store code `R1157`  
**Validated:** 8 September 2026  
**Live URL:** https://virata-retail-reebok.vercel.app/

## 1. Application Entry and Access

1. Open the live URL.
2. The application redirects unauthenticated visitors to the **Virata Retail** login screen.
3. Enter an approved internal username and password and select **Sign in**.
4. Authenticated users enter the operational shell with the Virata Retail brand, sidebar navigation, and the following working areas:
   - Master Dashboard
   - Data Upload
   - Upload History
   - Data Coverage
   - Sales Reports

The sidebar also shows Store Board, Store Dashboard, Store Performance, Target Management, Assets, and Merchandiser as disabled navigation items. These are placeholders and should not be treated as delivered scope.

## 2. Upload Walkthrough

Open **Data Upload**.

1. Select a report type:
   - Sales
   - Inventory / Stock
   - Account DSR / payment mode split
2. Select or drop an Excel file.
3. The browser calculates a SHA-256 hash before upload.
4. The application checks the hash against `public.upload_audit_log`.
5. If the hash already exists, the upload is blocked and the prior upload details are shown.
6. For a new file, the server:
   - validates the report type and required fields;
   - generates a standard filename such as `sales_YYYY_MM_DD_HHmmss.xlsx`;
   - stores the file in the private Supabase `retail-ops` bucket under `raw/<type>/`;
   - writes the storage path, file hash, file size, source filename, report type, and status to the audit log.
7. The upload appears in recent upload history with a pending or uploaded status.
8. Select **Run Processing** to trigger the GitHub Actions pipeline.

Relevant implementation: [upload page](../../src/app/upload/page.js), [upload API](../../src/app/api/upload/route.js), [file naming helpers](../../src/lib/fileRename.js), and [database schema](../../backend/database/schema.sql).

## 3. Processing Walkthrough

The processing workflow is a Medallion-style pipeline:

```text
Supabase Storage raw files
        |
        v
raw.sales / raw.inventory / raw.account_dsr
        |
        v
staging dimensions and facts
        |
        v
gold reporting tables
        |
        v
web reports and Excel export
```

The web application calls `/api/process`, which dispatches the `run-pipeline.yml` GitHub Actions workflow. The Python pipeline then:

1. Finds pending and uploaded audit records.
2. Recovers records left in `failed` or `processing` by returning them to `pending` at the start of a later run.
3. Downloads files from Supabase Storage.
4. Loads sales, inventory, and Account DSR data into raw tables.
5. Builds dimensions and refreshes stock facts.
6. Refreshes gold dashboard facts and Uppal Reebok metrics.
7. Marks successfully ingested files as completed and records row counts.
8. Marks file-level failures as failed with an error message.

Relevant implementation: [pipeline orchestrator](../../pipeline/scripts/run_pipeline.py), [gold refresh](../../pipeline/scripts/refresh_gold.py), [Reebok refresh](../../pipeline/scripts/refresh_reebok.py), and [stock refresh](../../pipeline/scripts/refresh_stock.py).

## 4. Reporting Walkthrough

### Master Dashboard

**Master Dashboard** supports a date range, quick ranges, and division filtering. It displays:

- RSV, average per day, markdown percentage, quantity sold, bills, and ATV;
- Account DSR payment totals split into UPI, cash, card, and other;
- store performance and top-store views;
- category and retail-metric tabs in the page interface.

The API reads gold dashboard and payment facts. The current implementation is scoped to the Uppal Reebok record in the returned store summaries.

See [Master Dashboard page](../../src/app/master-dashboard/page.js) and [Master Dashboard API](../../src/app/api/reports/master-dashboard/route.js).

### Uppal Reebok Sales Reports

Open **Sales Reports**. The report page supports a report date, refresh, quick navigation, and four report sections:

1. Daywise + MTD
2. Staff KPI
3. FW / APP / ACC category breakdown
4. Gender / Division

The report page reads from `/api/reports/reebok-sales` and can download an Excel workbook from `/api/reports/reebok-export`.

The workbook contains five sheets:

- Cover
- Daywise MTD
- Staff KPI
- FW / APP / ACC
- Gender Division

See [Reebok reports page](../../src/app/reebok-reports/page.js), [HTML report API](../../src/app/api/reports/reebok-sales/route.js), and [Excel export API](../../src/app/api/reports/reebok-export/route.js).

### Data Coverage

**Data Coverage** requests a month, year, and report type and presents upload coverage by date. It is intended to show whether expected sales, stock, and payment source files are present.

See [coverage page](../../src/app/data-coverage/page.js), [coverage component](../../src/components/DataCoverageMatrix.js), and [coverage API](../../src/app/api/reports/upload-coverage/route.js).

### Upload History

**Upload History** lists recent audit records with report type, original filename, uploader, timestamp, status, and storage path. Statuses are displayed as Pending, Processed, or Failed based on the audit record.

See [history page](../../src/app/upload-history/page.js) and [history component](../../src/components/UploadHistory.js).

## 5. KPI and Data Rules Confirmed in Code

- The sales basis is `SUM("Taxable Amount")` for NSV/RSV.
- Bills are distinct bill numbers.
- Qty is the sum of source quantity.
- ATV is NSV divided by bills.
- UPT is quantity divided by bills.
- ASP is NSV divided by quantity.
- Footwear, apparel, and accessories are derived from Item Division.
- Gender is derived from the source Section field.
- Staff metrics are grouped by Salesman.
- Store-specific Reebok calculations filter to `R1157`.
- Ratios are recomputed from aggregate numerators and denominators rather than averaged from row-level ratios.

The underlying definitions are also documented in [REEBOOK_KPI_DEFINITIONS.md](REEBOOK_KPI_DEFINITIONS.md).

## 6. Scope Validation

| Scope item | Status | Evidence / validation note |
|---|---|---|
| Gather and document requirements | Complete | KPI definitions and project context are documented in `artifacts/docs`. |
| Design application interface and database | Complete | Next.js pages/components and Supabase schema are present. |
| Excel upload and duplicate detection | Complete for approved three types | Sales, inventory, and Account DSR are validated by the API; SHA-256 is unique in the audit table. |
| Secure file storage | Partial | Uploads use the private `retail-ops` bucket and server-side Supabase access. Storage policies and production access review still need stakeholder verification. |
| Automated processing layers | Complete in code | Raw, staging, and gold pipeline stages are implemented and dispatched through GitHub Actions. |
| Sales, inventory, and payment processing | Complete in pipeline | `raw.sales`, `raw.inventory`, and `raw.account_dsr` are ingested and refreshed into reporting facts. |
| Sales report | Complete | Daywise + MTD report is available for Uppal Reebok. |
| Stock report | Partial | Inventory upload and stock fact refresh exist, but no dedicated stock-report page/export is exposed in the active navigation. |
| Payment report | Partial | Payment mode breakdown is available in Master Dashboard; a standalone payment report/export is not exposed. |
| Staff and category reports | Complete | Staff KPI and FW / APP / ACC sections are present in the Reebok report and workbook. |
| Coverage report | Complete in code | Monthly upload coverage matrix and API are present. |
| Taxable Amount KPI basis | Complete for NSV/ratios | The pipeline and report notes use Taxable Amount. |
| Approved target and achievement KPIs | Partial / pending approval | The Reebok report currently renders Target and Achievement as `—` and documents that the target formula is not confirmed. |
| Upload history and processing status | Complete | Audit records and status badges are available. |
| Retry handling | Partial | The next pipeline run recovers failed/processing records automatically, but there is no explicit Retry button or per-file retry endpoint in the UI. |
| Error messages | Complete for primary paths | Upload and pipeline errors are surfaced in the upload flow/history; live stakeholder testing is still required. |
| Downloadable Excel reports | Partial | Reebok sales reports export to `.xlsx`; stock and standalone payment exports are not exposed. |
| Automated workflow configuration | Complete in code | `/api/process` dispatches GitHub Actions; deployed secrets and workflow permissions require environment verification. |
| Testing, deployment, and documentation | Partial | The live URL is deployed, the production build passes, and this walkthrough is added. Stakeholder acceptance and source-data reconciliation remain outstanding. |

## 7. Acceptance Criteria Check

| Acceptance criterion | Result |
|---|---|
| Users can securely log in and upload approved files | Partially demonstrated. Login gate and upload flow exist; authentication is a client-side local-storage allowlist and needs production security review. |
| Duplicate files are correctly identified | Implemented through browser SHA-256 checks, server-side recheck, and a unique database constraint. |
| Uploaded data is processed correctly | Pipeline path is implemented; requires execution against representative stakeholder files for final sign-off. |
| Reports match approved calculations and source data | Taxable Amount and ratio rules are implemented; reconciliation and target/achievement approval are still required. |
| Failed processing supports retry | Automatic recovery on the next pipeline run exists; explicit user retry is not implemented. |
| Excel exports match web reports | Reebok sales web report and five-sheet workbook are implemented; a comparison test with real output remains required. |
| System approved by stakeholders | Not yet evidenced in the repository or public deployment. Requires formal UAT sign-off. |

## 8. Recommended Completion Items

1. Replace the client-side hardcoded credential allowlist with Supabase Auth or another server-validated authentication mechanism.
2. Add a dedicated stock report and export, plus a standalone payment report/export if those are required deliverables.
3. Add a visible retry action for failed audit records and a status refresh/polling mechanism.
4. Confirm and implement the approved Target and Achievement formula, then reconcile it against stakeholder examples.
5. Run UAT using representative Sales, Inventory, and Account DSR files for `R1157`.
6. Compare web report values with every exported workbook sheet and record stakeholder approval.
7. Remove or disable unsupported extra upload cards such as Salesperson, GRN, and Site Movement, or implement their server-side support.

## 9. Validation Performed

- Live URL opened successfully and redirected to the branded login page.
- Authenticated operational shell was reachable in the deployed session.
- `npm run build` completed successfully, including lint/type checks and route generation for the active Next.js app.
- Source review covered upload, authentication, audit history, reporting APIs, export generation, database schema, and pipeline scripts.
