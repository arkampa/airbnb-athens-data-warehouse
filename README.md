# Airbnb Athens Data Warehouse

A SQL Server data warehouse built from Inside Airbnb's Athens, Greece listings — designed to answer investor-facing questions (which neighbourhoods perform best, what drives ROI, where regulatory risk concentrates) rather than to be a generic Airbnb clone dataset. Snapshot-based, quarterly-updated, built on a star schema for Power BI.

**→ [Full design decisions writeup](https://github.com/arkampa/airbnb-athens-data-warehouse/blob/main/Airbnb_Athens_Design_Decisions.md)** — worked examples (including a real primary-key-violation bug this schema exists to prevent), attribute placement tables, and the reasoning behind every choice below. This README is the summary; that doc is the deep dive.

---

## Repo structure

| File | Purpose |
|---|---|
| `Airbnb_Athens_star_schema.sql` | One-time build: raw import, star schema creation, indexes |
| `Airbnb_Athens_quarterly_load.sql` | Recurring script: run once per new quarterly snapshot |
| `Airbnb_Athens_load_csvs_to_sql.py` | Python loader for `listings` — scripted alternative to SSMS's Import Flat File wizard |
| `Airbnb_Athens_Data_Dictionary.xlsx` | Column-level documentation: raw source, staging treatment, and final Dim/Fact schema |
| `docs/Airbnb_Athens_Design_Decisions.md` | Full reasoning behind every architectural choice |
| `Airbnb_Athens_Sample_Tables/` | Illustrative rows (full `reviews.csv` files excluded — too large for the repo, available from Inside Airbnb directly) |
| `README.md` | This file |

---

## Architecture overview

**The pipeline in one sentence:** raw quarterly CSVs → staged into SQL Server → merged into two permanent history tables (`listings`, `reviews`) → transformed into a star schema (6 dimensions, 2 fact tables) → connected to Power BI.

**Why a hybrid wizard/Python + SQL pipeline:** SQL Server Express doesn't support `BULK INSERT ... WITH (FORMAT='CSV')`, so two ingestion paths exist:

- **`listings`** — loaded via `Airbnb_Athens_load_csvs_to_sql.py`, which replicates the wizard's exact column-type overrides in code, making quarterly reloads scriptable.
- **`reviews` and `neighbourhoods`** — loaded via SSMS's Import Flat File wizard: native bulk copy is roughly 10–30x faster than a row-by-row Python/`pyodbc` insert for a file this size (~800K rows). A deliberate choice, not a workaround.

**Everything from the dimension tables onward is fully automated** — re-running the relevant sections rebuilds the entire star schema cleanly from whatever is currently in `listings`/`reviews`.

**Star schema:**
- **Dimensions:** `DimHost`, `DimListings`, `DimLocation`, `DimPropertyType`, `DimRoomType`, `DimDate`
- **Facts:** `FactListings` (grain: listing × snapshot), `FactReviews` (grain: one row per unique review)

---

## Key design decisions

Full reasoning for each of these lives in [`docs/Airbnb_Athens_Design_Decisions.md`](https://github.com/arkampa/airbnb-athens-data-warehouse/blob/main/Airbnb_Athens_Design_Decisions.md) — this is the summary.

- **Snapshot-based history.** `listings`/`reviews` are never truncated — every quarter appends, tagged with `snapshot_date`. Never dropped after being consumed into the star schema either, so historical values for anything that's SCD Type 1 in a Dim table (e.g. `host_response_rate`) stay analyzable even after a dimension rebuild overwrites them.
- **SCD Type 1 via `ROW_NUMBER()`, found through an actual build failure.** Profiling surfaced a real host who lost Superhost status between snapshots — a naive dedup on that data produces a primary-key violation, not just a wrong answer. `ROW_NUMBER() OVER (PARTITION BY ... ORDER BY snapshot_date DESC)` is what makes `DimHost`/`DimListings` buildable at all.
- **Snapshot-varying attributes stay in Fact tables, never Dim tables** — `host_is_superhost`, listing counts, etc. — so "Lost/Gained/Retained Superhost" trend analysis is possible in Power BI.
- **Sentinel keys (`id = 0` = Unknown), never NULL foreign keys** — Power BI relationships handle a placeholder row far better than a NULL.
- **Two deliberate "missing data" patterns**, not an inconsistency: review scores stay `NULL` (so `AVG()` naturally excludes them); response/acceptance rates use an explicit `-1` sentinel instead (auditable, but requires excluding `-1` from any average explicitly).
- **`DimLocation` is sourced from Inside Airbnb's reference file, not from `listings`** — sidesteps a real Greek-text encoding corruption issue seen elsewhere in this pipeline entirely, rather than needing to clean it up.
- **`property_category` clusters 48 granular types into 5 investor-facing groups**, with an idempotent `IF NOT EXISTS` guard — the same pattern used for every column added to the permanent `listings` table.
- **`price_quote_*` fields, added by Inside Airbnb on 2026-06-28**, are onboarded with that same `IF NOT EXISTS` guard in both the main build and quarterly load scripts. Kept as text (mixed date formats seen across rows), `NULL` for all pre-2026 snapshots by design, and `price_quote_raw` stays archived in `listings` only — never a like-for-like substitute for `price` in cross-listing analysis.
- **`DimDate` lives in SQL Server, not Power BI/DAX** — available to any tool that connects to the database, not locked into one BI model.
- **Fully recoverable, no manual patching.** Every Dim/Fact table is derived, never hand-edited — deleting a bad snapshot from `listings`/`reviews` and rebuilding Sections 4B → 4A → 6 → 8 regenerates everything cleanly. Tested in practice, not theoretical.

---

## Quarterly loading

After the initial two-snapshot bootstrap, every new quarter runs through `Airbnb_Athens_quarterly_load.sql` — a 12-step script safe to re-run, with guards against re-loading an already-loaded snapshot, verification before and after each irreversible step, and a data-quality gate that catches what would otherwise be a raw primary-key-violation crash. Full step-by-step breakdown in [`docs/Airbnb_Athens_Design_Decisions.md`](docs/Airbnb_Athens_Design_Decisions.md).

---

## Known limitations

- Foreign key constraints are intentionally not enforced — correctness comes from the sentinel-key pattern instead
- `estimated_revenue_l365d`/`estimated_occupancy_l365d` are Inside Airbnb's own unverified estimates, not real booking data
- `price_quote_*` fields (added 2026-06-28) are `NULL` for every pre-2026 snapshot by schema design, not a data gap
- `price` is genuinely `NULL` at the source for 1.0–6.8% of listings depending on snapshot — excluded from price-based aggregates; see `docs/Airbnb_Athens_Design_Decisions.md` for the per-quarter breakdown
- ~29.5K reviews reference listings delisted before the current snapshot — expected, not a bug
- Greek text encoding has shown corruption in at least one export pipeline — why new-neighbourhood detection requires manual review

---

## Tech stack

`SQL Server` · `T-SQL` · `Python` (`pandas`, `pyodbc`) · `Power BI` / `DAX` · Star schema data warehousing · SCD Type 1

---

*Built by Aristea Kampanaraki as part of a Power BI / data analytics portfolio, demonstrating construction/real-estate domain expertise applied to PropTech data modeling.*
