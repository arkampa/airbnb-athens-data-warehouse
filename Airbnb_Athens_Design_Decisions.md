# Design Decisions — Airbnb Athens Data Warehouse

The full reasoning behind every architectural choice in this project — worked examples, attribute tables, trade-offs, and the profiling that surfaced each decision in the first place. See the [main README](https://github.com/arkampa/airbnb-athens-data-warehouse/blob/main/README.md) for the project summary and repo structure.

---

## Data profiling — before building anything

Before any dimension or fact table gets built, the main script profiles the source data (Section 3 of `Airbnb_Athens_star_schema.sql`) — deliberately, not as an afterthought. This is a "measure twice, cut once" discipline: understand what's actually in the data before writing derivation logic against assumptions about it.

What gets profiled, specifically:
- **Column structure** — confirms `listings` has exactly the expected columns after the drop step, before anything downstream reads from it
- **Categorical distributions** — `SELECT DISTINCT` on `room_type`, `property_type`, `neighbourhood`/`neighbourhood_cleansed`, `instant_bookable`, `host_is_superhost`, so the `property_category` clustering logic is written against the real 48 granular values, not a guess
- **Host-level stats** — Superhost percentage, how many hosts changed status between snapshots (this is where the `37177` case study below was actually found — profiling surfaced it, the design decision followed from it)
- **Listing-level stats** — coordinate ranges (catches bad geocoding early), how many listing names changed between snapshots
- **Measure distributions** — price ranges, review score ranges, before deciding how to handle NULLs and outliers in `FactListings`

Every "why we chose X" decision documented below traces back to something this profiling step actually revealed, not a decision made in the abstract.

---

## Strategic design decisions

### Snapshot-based history, not a single point-in-time table

`listings` and `reviews` are never truncated or overwritten — every quarterly load *appends* a new snapshot, tagged with `snapshot_date`. This is what makes trend analysis possible at all: "did this host lose Superhost status between June and September" is a question that only has an answer because both snapshots coexist in the same table, distinguished by date.

The composite primary key on `FactListings` is `(listing_id, snapshot_date)` — deliberately not just `listing_id`, since the same physical listing legitimately has multiple rows, one per quarter it was scraped in.

### `listings` and `reviews` are a permanent archive, not disposable staging

The raw `listings` and `reviews` tables are never dropped or pruned after being consumed into the star schema — every column, for every quarter loaded so far, is still sitting there. This is more than a backup; it's what makes a specific class of analysis possible that the star schema alone can't answer.

**Worth being precise about what actually needs the raw tables and what doesn't:** "how many times has a host gained or lost Superhost status" is already fully answerable from `FactListings` alone — `host_is_superhost` lives at the fact grain specifically so its full history is queryable without touching raw data (see "SCD Type 1" below).

What genuinely *does* require the raw tables: **the underlying factors behind that change.** Attributes like `host_response_rate` and `host_acceptance_rate` live in `DimHost` as SCD Type 1 — the dimension only ever exposes the *latest* value; each rebuild overwrites whatever was there before. So a question like "did a host's response rate decline in the lead-up to losing Superhost status" can't be answered from `DimHost`/`FactListings` at all — by the time September's rebuild runs, June's response rate is gone from the dimension. Only `listings`, which still holds every quarter's raw value for every column, can answer it. Keeping the raw tables permanently is what leaves that door open for exploratory or retrospective analysis the star schema wasn't originally designed around, without needing to re-import any historical CSVs to get there.

### `price_quote_*` fields — Inside Airbnb's 2026-06-28 schema addition

The 2026-06-28 export added 11 new raw columns Inside Airbnb hadn't previously published. 6 are dropped as redundant with data already kept elsewhere (`host_profile_id`/`host_profile_url` duplicate `host_id`/`host_url`; the four `hosts_time_as_*` fields are all derivable from `host_since` via `DATEDIFF`). The remaining 5 are kept and added to the permanent `listings` table with a guarded `ALTER TABLE ... ADD ... IF NOT EXISTS` — the same idempotent pattern already used for `snapshot_date` and `property_category`:

- `price_quote_checkin_date`, `price_quote_checkout_date`, `price_quote_total_price`, `price_quote_price_per_night` — flow through into `FactListings`
- `price_quote_raw` — stays archived in `listings` only, same treatment as `amenities`

**Kept as `NVARCHAR`, not `DECIMAL`/`DATE`.** Mixed date formats were observed across rows in the new columns; casting at load time risked silently `NULL`-ing out any row that didn't match the assumed format. Parsing is deferred to `TRY_CONVERT` downstream (Power Query/DAX), where a failed parse is visible rather than swallowed.

**Why `price_quote_raw` doesn't reach `FactListings`.** Each quote reflects a specific, listing-chosen check-in/check-out date range — it isn't a comparable cross-listing KPI the way `price` is, so it's treated as illustrative reference data rather than something to average or rank across listings.

**Pre-2026-06-28 snapshots (June and September 2025) read `NULL`** across all five `price_quote_*` columns — the field didn't exist yet at scrape time, which is a schema fact, not a data quality gap.

**Added in two places, on purpose, not by drift.** The `ALTER TABLE ... IF NOT EXISTS` block lives in both `Airbnb_Athens_star_schema.sql` (Section 3B) and `Airbnb_Athens_quarterly_load.sql` (Step 6). This is deliberate, not duplicated logic that got out of sync: the main script needs it so a full rebuild from scratch (disaster recovery, fresh environment) is self-sufficient without depending on the quarterly load having run first; the quarterly load needs its own copy because that's the script that actually ran the 2026-06-28 import and is what future quarters re-run. Both use the identical guarded statement, so whichever runs first wins and the other is a safe no-op.

### SCD Type 1 via `ROW_NUMBER()` — with two real worked examples

Dimension tables (`DimHost`, `DimListings`) need exactly one row per real-world entity, even though the source data has multiple snapshot rows per entity. The pattern used throughout:

```sql
ROW_NUMBER() OVER (PARTITION BY host_id ORDER BY snapshot_date DESC) AS rn
-- ... WHERE rn = 1
```

This keeps the *most recent* snapshot's attributes for anything that changes over time, and correctly deduplicates down to one row per entity regardless of how many quarters have accumulated.

**This wasn't a theoretical concern — it was discovered as an actual build failure.** Profiling `listings` before building `DimHost` (Section 3C) turned up host `37177` (Emmanouil, "Athens Quality Apartments," listing `27262` — a real public Inside Airbnb record): Superhost in the June 2025 snapshot, not Superhost by September. A naive `SELECT DISTINCT host_id, ...` to build the dimension doesn't just give a questionable answer here — it produces **two different rows for the same `host_id`**, which is a hard primary-key violation the moment you try to enforce `host_id` as `DimHost`'s key. The `ROW_NUMBER() ... ORDER BY snapshot_date DESC` pattern is what makes the dimension buildable at all, not just more "correct" — and it's paired with a design decision (below) to keep `host_is_superhost` itself out of `DimHost` entirely, so the dimension never has to choose which snapshot's value is "right."

**The same failure mode showed up independently while profiling `DimListings`** (Section 3D): listing `105223` ("Luxury Apartment, Athens") was named `"Luxury Apt - 10% Off Summer"` in June and `"Luxury Apt - Acropolis View"` in September — a routine promotional-title change, but the same `SELECT DISTINCT id, ...` PK-violation problem applies. Same fix: `ROW_NUMBER() OVER (PARTITION BY id ORDER BY snapshot_date DESC)`, latest snapshot wins for `DimListings`' descriptive attributes. Two independent dimensions, hit by the exact same class of problem, solved the exact same way — confirmation this is a systemic pattern in the data, not a one-off quirk of a single host.

**Attribute placement — `DimHost` vs. `FactListings`:**

| Attribute | DimHost | FactListings |
|---|---|---|
| `host_id` | PK | FK |
| `host_name`, `url`, `picture`, `about`, `since`, `location` | ✅ stable | |
| `host_has_profile_pic`, `host_identity_verified`, `host_verifications` | ✅ stable | |
| `host_response_time`, `host_response_rate`, `host_acceptance_rate` | ✅ stable | |
| `host_is_superhost` | | ✅ changes per snapshot |
| `host_listings_count`, `host_total_listings_count`, `calculated_host_listings_count*` | | ✅ changes per snapshot |

**Attribute placement — `DimListings` vs. `FactListings`:**

| Attribute | DimListings | FactListings |
|---|---|---|
| `id` | PK | FK / join |
| `name`, `description`, `listing_url`, `picture_url`, `bathrooms_text` | ✅ stable | |
| `latitude`, `longitude` | ✅ stable | |
| `neighbourhood_cleansed` | ❌ (lives in `DimLocation` instead) | |
| `accommodates`, `bathrooms`, `bedrooms`, `beds`, `price` | | ✅ measure |
| `review_scores_*`, `availability_365`, occupancy | | ✅ measure |
| `license`, `host_is_superhost` | | ✅ changes per snapshot |

The rule both tables follow: **if a column can change value for the same real-world entity between snapshots, it belongs in a Fact table, never a Dim table.** `latitude`/`longitude` are the one pair worth flagging as a judgment call rather than an obvious case — they're numeric, which might suggest "measure," but a listing's physical coordinates don't change quarter to quarter, so they're treated as stable descriptive attributes and live in `DimListings`, not as an aggregatable fact.

### Snapshot-varying attributes live in Fact tables, not Dimension tables

`host_is_superhost`, `host_listings_count`, and similar fields are **not** in `DimHost` — they're in `FactListings`. This is the design decision that directly enables the Superhost case study above: if `host_is_superhost` lived in `DimHost`, the SCD Type 1 "latest wins" logic would silently overwrite history, and "was this host ever a Superhost before" would become unanswerable. Keeping genuinely time-varying attributes at the fact grain is what makes "Lost Superhost," "Gained Superhost," and "Retained Superhost" trend analysis possible in Power BI at all.

### Sentinel keys instead of NULL foreign keys

Every dimension has a reserved `id = 0` row with `'Unknown'` placeholder values (e.g., `DimHost` has a `host_id = 0` row). Every fact-table join uses `LEFT JOIN ... ISNULL(key, 0)` rather than allowing a NULL foreign key.

**Why this matters practically, beyond "it's tidier":** Power BI relationships and most DAX aggregations handle a foreign key pointing at a real (if placeholder) row far better than a NULL foreign key — NULLs in relationship columns cause silent exclusion from visuals rather than an explicit, filterable "Unknown" bucket. This pattern trades a small amount of upfront complexity for a model that behaves predictably in the BI layer.

### Two different "missing data" patterns — deliberately, not inconsistently

A close read of the schema surfaces what looks like an inconsistency: `review_scores_*` in `FactListings` are left as true `NULL`, while `host_response_rate`/`host_acceptance_rate` in `DimHost` use an explicit `-1` sentinel for the same kind of "no data" case. This is intentional, not sloppy:

- **Review scores stay `NULL`.** Both SQL's `AVG()` and DAX's `AVERAGE()` silently exclude `NULL`/blank values from the calculation by default — so leaving them `NULL` is the *correct* way to make sure a listing with no reviews yet doesn't drag down an average rating toward zero.
- **Response/acceptance rates use `-1`.** These needed to stay auditable and explicitly filterable — you can `COUNT(*) WHERE host_response_rate = -1` to know exactly how many hosts have no data, something a `NULL` makes harder to reason about at a glance in query results. The trade-off: **any `AVG()`/`AVERAGE()` on this field must explicitly exclude `-1`** (`WHERE host_response_rate <> -1` in SQL, `CALCULATE(AVERAGE(...), DimHost[host_response_rate] <> -1)` in DAX) — forgetting this filter silently skews the average toward -1, i.e. artificially low. This exclusion is baked into the DAX measures themselves, not left as a visual-level filter someone could forget to apply.

### `DimLocation` — sourced from the reference file, not from listings

`DimLocation` is deliberately built from Inside Airbnb's separate `neighbourhoods.csv` reference file (45 real Athens neighbourhoods) — **not** from `listings.neighbourhood_cleansed`, even though `listings` does carry that column. This isn't just "the reference file is more authoritative" as a preference — it's a specific bug-avoidance decision: this pipeline has directly seen Greek-text corruption in at least one export of the per-listing column (host `37177`'s own neighbourhood value has appeared mangled in one export pipeline). Building `DimLocation` from the clean reference file **sidesteps that encoding problem entirely** — there's no cleanup or fix-up section needed for `DimLocation`, because the corrupted source is never touched. `listings` then joins *to* `DimLocation` as a lookup, so the dimension's integrity never depends on any individual listing row's text quality.

This is also why the quarterly load's new-neighbourhood check requires manual review rather than auto-inserting: a "new" neighbourhood name could be a genuinely new addition to Athens' Airbnb footprint, or it could be a corrupted duplicate of one already in `DimLocation` — the pipeline treats that ambiguity as something a human should glance at, not something to resolve silently.

**Region/district grouping is deliberately left out of the warehouse layer.** Inside Airbnb's `neighbourhood_group` column is blank for every Athens row — there's no official borough structure to load. Rather than inventing one and hardcoding it into a SQL column, any Neighbourhood → Region grouping is built as a Power BI-side hierarchy instead. This keeps `DimLocation` unchanged and avoids baking a subjective grouping decision into the data layer, where it would be harder to revise later than a report-level hierarchy.

### `property_category`: 48 granular types clustered into 5 investor-facing groups

Inside Airbnb's `property_type` column has 48 distinct granular values (`Entire rental unit`, `Room in aparthotel`, `Private room in casa particular`, etc.) — too granular for investor-facing analysis. A derived `property_category` column clusters these into 5 categories (`Entire Property`, `Private Room`, `Shared Room`, `Hotel / Serviced`, `Unique / Other`) via a `CASE` statement, added to `listings` after both raw imports complete.

Two specific decisions worth noting here, since they're the kind of thing that's easy to get subtly wrong:
- **Evaluation order matters in `CASE`.** `'Cycladic home'` needs to resolve to exactly one category — it's listed once, under `Entire Property`, not duplicated across branches (an earlier version of this script had it in two branches simultaneously, which is silently wrong: `CASE` always resolves to the first match, making the second listing dead code with no error to flag it).
- **No separate "Other" catch-all bucket.** The `ELSE` branch resolves to `'Unique / Other'` rather than a distinct `'Other'` category — a deliberate simplification for a 5-category investor-facing model, at the cost of losing an automatic "flag anything unclassified" signal. That trade-off is documented inline in the script for future review.

The column itself is created with `IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS ...) ALTER TABLE ...` rather than a bare `ALTER TABLE ADD` — the same idempotency guard used for `snapshot_date` in Section 2. This is a recurring pattern throughout the pipeline: any `ALTER TABLE ADD` on `listings` (a table that's never dropped and rebuilt, unlike the derived Dim/Fact tables) is guarded this way, so re-running the main script doesn't fail with "column already exists" partway through.

### Index strategy tied to actual business questions, not blanket coverage

Every index on `FactListings`/`FactReviews` maps to a specific query pattern the dashboard needs — foreign keys for join performance, `price` and `snapshot_date` for slicer/filter speed, `is_active` for the "reviews still active vs. dropped off" question. Indexes are built *after* the large `INSERT INTO ... SELECT` population step, not before, since maintaining a B-tree during bulk insert is pure overhead until the data's actually there to query.

### `DimDate` lives in SQL Server, not Power BI

`DimDate` is built once via a recursive CTE (2000-01-01 through 2030-12-31 — 11,323 days), inside the warehouse itself, rather than relying on Power BI's auto date/time tables or a DAX `CALENDAR()` function. The reasoning: a date dimension generated in DAX only exists inside that one Power BI model. Building it in SQL Server instead means it's available to *any* tool that connects to this database — a different BI tool, an ad hoc SQL analysis, a Python script — without needing to be recreated. Given this warehouse is deliberately built with reusability beyond a single dashboard in mind, keeping foundational infrastructure like the date dimension at the database layer rather than the presentation layer follows the same logic.

The specific date range isn't arbitrary: the start (`2000-01-01`) comfortably precedes Airbnb's earliest review dates (the platform itself launched in 2008), and the end (`2030-12-31`) gives roughly five years of headroom past the current data, so quarterly loads won't run out of date coverage for a long time without needing to touch this table again. Building 11,323 recursive rows also requires explicitly overriding SQL Server's default 100-level recursion safety limit (`OPTION (MAXRECURSION 0)`) — a small technical detail, but one that causes a confusing silent-truncation failure if forgotten.

---

## The data dictionary — built collaboratively, used twice

The dictionary (`Airbnb_Athens_Data_Dictionary.xlsx`) wasn't written by hand — it was built through an iterative process: providing Claude with the raw CSV's header row + one real data row, plus a screenshot of the wizard's Modify Columns screen, and having it work out the correct type overrides, which columns to drop, and why.

That output then serves **two separate downstream purposes**, not just documentation:
1. **Manually, in the wizard** — the dictionary's "Staging Table" sheet (green = keep, red = drop) is the direct reference for configuring the Modify Columns step during a wizard import of `reviews`/`neighbourhoods`.
2. **Programmatically, in the Python loader** — the same type-override logic is hardcoded into `LISTINGS_OVERRIDES` in the Python script, so the scripted load and the manual wizard load produce *identical* column types for the same source data. Neither path is "the real one" with the other as a fallback; they're deliberately kept in sync.

The dictionary also documents the full Dim/Fact schema (grain, derivation, sentinel handling per table) — not just the raw staging layer — so it doubles as the canonical schema reference independent of reading the SQL directly.

---

## Quarterly loading — the recurring pattern

After the initial two-snapshot bootstrap (`Airbnb_Athens_star_schema.sql`), every subsequent quarter goes through `Airbnb_Athens_quarterly_load.sql` — a 12-step script designed to be safely re-run, not a one-off:

1. **Guards against re-loading an already-loaded snapshot** — checks `snapshot_date` before touching anything, since accidentally re-running a load would silently duplicate an entire quarter into permanent history
2. Verifies the wizard/Python import landed correctly (right columns, right types, no accidental primary key) *before* any transformation happens
3–5. Drops unneeded columns, adds `snapshot_date`, tags the new rows
6. **Appends into `listings`/`reviews` using an explicit column list**, not `SELECT *` — as of the 2026-06-28 quarter, `listings` has 64 columns at rest (57 raw + `snapshot_date` + `property_category` + 5 `price_quote_*` fields; 59 for the June/September 2025 snapshots, before Inside Airbnb added the `price_quote_*` fields) but a freshly-imported quarter's wizard table never lines up column-for-column with that (`property_category` doesn't exist yet on new rows, and older snapshots never had `price_quote_*` at all); a bare `SELECT *` would fail on the column-count mismatch every single quarter
7. Drops the temporary staging tables — **only after** verifying row counts match, since this step is irreversible
8. Tags `property_category` for the new rows only (`WHERE property_category IS NULL`), leaving prior quarters' tags untouched
9. Checks for genuinely new neighbourhoods (rare, but checked every time) — flagged for manual review before insertion, not auto-inserted, since Greek text encoding issues elsewhere in this pipeline mean a "new" neighbourhood could be a garbled duplicate of an existing one
10. A duplicate `(listing_id, snapshot_date)` data-quality gate — catches what would otherwise be a raw primary-key-violation crash during the rebuild, with an actual explanation instead
11. Rebuilds the star schema from the now-current `listings`/`reviews`
12. Post-load QA — row counts, orphaned foreign key checks, snapshot distribution

### The `snapshot_date` mechanism, specifically

`snapshot_date` isn't part of Inside Airbnb's raw export — it's added by this pipeline (`ALTER TABLE ... ADD snapshot_date DATE`, guarded with `IF NOT EXISTS` so re-running the script doesn't error), then populated via `UPDATE ... SET snapshot_date = 'YYYY-MM-DD'` immediately after each import, before that batch ever gets merged into the permanent history tables. It's what makes every downstream design decision in this document possible — the SCD logic, the composite fact-table key, the "Lost Superhost" trend analysis — all ultimately trace back to this one column existing.

---

## Recoverability — rebuilding from source, with zero manual patching

Because every dimension and fact table is **fully derived** — never hand-edited, always dropped and rebuilt from `listings`/`reviews` — bad data in a snapshot is fully recoverable without touching anything downstream by hand:

1. Delete the affected rows from the two source-of-truth tables: `DELETE FROM listings WHERE snapshot_date = '...'` and the same for `reviews`
2. Rebuild **Section 4B** (`DimRoomType`, `DimPropertyType`, `DimHost`, `DimListings`)
3. Rebuild **Section 4A** (`DimLocation`)
4. Rebuild **Section 6** (`FactListings`, `FactReviews`)
5. Rebuild **Section 8** (indexes)

Every table downstream of `listings`/`reviews` regenerates cleanly from the corrected source — no dimension needs manual editing, no fact row needs a targeted `DELETE`, and nothing is left half-updated. This isn't theoretical: it's the exact procedure used to fully remove a contaminated test snapshot from this warehouse during development, confirmed clean afterward by re-running the same profiling and QA queries described above.

The one thing this recovery procedure depends on: never patch `FactListings`/`FactReviews` directly. Deleting fact rows in isolation without also correcting `listings`/`reviews` first leaves dimensions reflecting stale data — the source tables are the only place a correction should ever start.

---

## The Python loader

`Airbnb_Athens_load_csvs_to_sql.py` replaces the wizard specifically for `listings` — deliberately **not** for `reviews` or `neighbourhoods`. That scope decision came from real testing, not a guess upfront:

- **Reviews tables run into the hundreds of thousands of rows.** A known `pyodbc` limitation (`fast_executemany` pre-sizes its buffers from the first rows in a batch, and errors on a later row with a longer string than what was sized — a client-side buffering bug, not a schema issue) means the reliable insert path for this script has to run with `fast_executemany` disabled, which is significantly slower than the wizard's native bulk copy for a file this large. Reviews only needs 5 columns configured in the wizard's Modify Columns step, making the manual path genuinely faster for that one file.
  **In practice:** SQL Server's native bulk copy (used by the wizard) is roughly 10–30x faster than a row-by-row `pyodbc` insert for a file this size (~800K rows) — the exact multiplier depends on hardware and column widths, but the gap holds regardless. A few clicks in the wizard beats a substantially slower automated path; this is the concrete reason `reviews` stays manual rather than scripted.
- **Neighbourhoods is a handful of rows, loaded once per quarter** — no real time savings from scripting something that small.

**What the script does, concretely:**
- Creates the target database if missing
- Creates a staging table per CSV, named to match the wizard's own convention
- Applies the exact type overrides from the data dictionary — critical, since letting pandas auto-infer types would silently break the `TRY_CAST`/`REPLACE` cleaning logic downstream (e.g. `price` needs to arrive as text `'$50.00'`, not a pre-parsed float that's already lost its `$` and precision)
- **Validates real data against every assumed type before creating the table**, auto-correcting and reporting when needed — this exists because real data broke two initial type assumptions during testing: a free-text column exceeded its assumed width, and Inside Airbnb's `*_avg_ntm` columns turned out to be genuinely fractional despite being grouped with whole-number fields by a naive prefix-matching rule. Rather than patch each column individually as new data surfaces new edge cases, the script checks itself against the real values every time it runs.
- Loads via chunked inserts with progress output, since large files can otherwise look frozen for minutes with no feedback

---

## Known limitations

- **Foreign key constraints are intentionally not enforced** (Section 7, main script) — the composite key relationships are correct by construction from the `LEFT JOIN ... ISNULL(..., 0)` sentinel pattern, and skipping FK enforcement avoids constraint-violation friction during quarterly appends
- **`estimated_revenue_l365d` and `estimated_occupancy_l365d` are Inside Airbnb's own unverified estimates**, not actual booking data — treated as illustrative in any investor-facing output, not ground truth
- **`price_quote_*` fields (added 2026-06-28) are `NULL` for all pre-2026 snapshots** by schema design, not a data gap — and `price_quote_total_price`/`price_quote_price_per_night` reflect a single listing-chosen date range each, so they aren't a like-for-like substitute for `price` in cross-listing comparisons
- **`price` itself is genuinely `NULL` at the source for a meaningful slice of listings, not evenly across quarters:** 5.0% (2025-06-24), 6.8% (2025-09-26), 1.0% (2026-06-28). Confirmed as a real source `NULL` — not a `TRY_CAST` failure — by checking `raw_price` on a sampled listing before any cleaning. These listings are silently excluded from any `AVG`/`SUM` on `price` in `FactListings`, which any price-based investor metric should account for. The sharp drop after 2026-06-28 lines up with the same export that introduced `price_quote_*`, but that's an observed correlation across a single data point, not a confirmed cause — worth re-checking once a second 2026+ snapshot exists to see if the ~1% rate holds.
- **~29.5K reviews reference listings that were delisted before the current snapshot** — expected and documented, not a data quality bug
- **Greek text encoding has shown corruption in at least one export pipeline** (`neighbourhood_cleansed` values have appeared mangled in some exports) — this is why new-neighbourhood detection in the quarterly load requires manual review rather than automatic insertion
