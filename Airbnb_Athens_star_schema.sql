-- ============================================================
-- PROJECT  : Airbnb Athens Data Warehouse
-- PHASE    : 1 – Database Creation, Import & Star Schema Build
-- AUTHOR   : Aristea Kampanaraki
-- DATE     : 2026
-- SOURCE   : Inside Airbnb – Athens, Greece
--            Snapshot 1: 24 June 2025  (2025-06-24_listings.csv)
--            Snapshot 2: 26 Sept 2025  (2025-09-26_listings.csv)
-- RAW      : listings, reviews
--            (imported via Import Flat File wizard)
-- STAR     : FactListings, FactReviews, DimHost, DimLocation,
--            DimPropertyType, DimRoomType, DimListings, DimDate
-- ============================================================
-- ARCHITECTURE DECISION — Wizard + SQL Pipeline
-- Raw CSV ingestion uses Import Flat File wizard in SSMS.
-- SQL Server Express limitation: FORMAT='CSV' not supported
-- preventing BULK INSERT column skipping without a format file —
-- wizard import and snapshot-date tagging (Sections 1–2) stay
-- manual each quarter.
-- Everything from Section 4 onward — dim tables, fact tables,
-- and performance indexes — is fully automated: rerunning the
-- script rebuilds them all cleanly.
-- FK constraints (Section 7) are skipped.
-- Quarterly loads: Airbnb_Athens_quarterly_load.sql
--
-- Phase 3 enhancement: Python + pyodbc pipeline to replace
-- wizard ingestion — planned future automation.
-- ============================================================

-- ============================================================
-- Best practice: explicitly set database context, even when
-- this query file is dedicated solely to Airbnb_Athens_Database
-- — avoids relying on the session's prior active database
-- and keeps the script self-contained and portable.
-- ============================================================
USE [Airbnb_Athens_Database];
GO

-- ============================================================
-- PRE-FLIGHT CHECK
-- ============================================================

SELECT DB_NAME();  -- Expected: Airbnb_Athens_Database

-- ============================================================
-- SECTION 1 – RAW TABLE IMPORT (IMPORT FLAT FILE WIZARD)
-- ============================================================
-- Run the Import Flat File wizard BEFORE executing this script.
-- The wizard creates and populates the listings and reviews
-- tables automatically from the CSV files.
--
-- WIZARD STEPS:
--   In SSMS Object Explorer:
--   Right-click Airbnb_Athens_Database
--   → Tasks → Import Flat File
--   → Browse → select CSV file
--   → Table name: YYYY-MM-DD_listings (or YYYY-MM-DD_reviews)
--   → Apply schema fixes in Modify Columns (see below)
--   → ⚠️ Do NOT set Primary Key on listings or reviews
--   → Finish
--
-- FILE NAMING CONVENTION: YYYY-MM-DD_listings.csv
-- e.g. 2025-06-24_listings.csv, 2025-09-26_listings.csv
--
-- DICTIONARY PROCESS:
-- Data dictionary (listings_data_dictionary.xlsx) was built by
-- providing Claude with the CSV header row + first data row
-- and a screenshot of the wizard Modify Columns screen.
-- Claude identified wizard defaults, recommended type overrides,
-- flagged columns to drop after load, and documented all
-- decisions in the Staging Table sheet (green = keep, red = drop).
-- Apply Modify Columns steps based on the dictionary.
-- ============================================================

-- ── WIZARD SCHEMA FIXES — listings ───────────────────────────
-- Apply these overrides in the Modify Columns step of the wizard
--
--   Column                      Wizard Default   → Override
--   id                          int              → BIGINT
--   host_id                     int              → BIGINT
--   host_name                   nvarchar(50)     → nvarchar(100), 
--   host_is_superhost           bit              → nvarchar(1)    (source is t/f string, NOT boolean)
--   host_has_profile_pic        bit              → nvarchar(1)    (source is t/f string, NOT boolean)
--   host_identity_verified      bit              → nvarchar(1)    (source is t/f string, NOT boolean)
--   price                       money            → nvarchar(20),  
--                                                  (source format '$50.00' — cleaned in FactListings
--                                                   via TRY_CAST(REPLACE(REPLACE(price,'$',''),',','') AS DECIMAL(10,2)))
--   amenities                   nvarchar(1800)   → nvarchar(MAX)
--   number_of_reviews_ltm       tinyint          → SMALLINT       (overflow risk > 255)
--   number_of_reviews_ly        tinyint          → SMALLINT       (overflow risk > 255)
--   review_scores_rating        float            → DECIMAL(4,2)
--   review_scores_accuracy      float            → DECIMAL(4,2)
--   review_scores_cleanliness   float            → DECIMAL(4,2)
--   review_scores_checkin       float            → DECIMAL(4,2)
--   review_scores_communication float            → DECIMAL(4,2)
--   review_scores_location      float            → DECIMAL(4,2)
--   review_scores_value         float            → DECIMAL(4,2)
--   reviews_per_month           float            → DECIMAL(5,2)   (avoids truncation warnings)
--   instant_bookable            bit              → nvarchar(1)    (source is t/f string, NOT boolean)
--
-- ⚠️ Do NOT set Primary Key on listings in the wizard
--    id alone is NOT unique across snapshots — same listing
--    appears in both June and September data.
--    Composite PK (listing_id + snapshot_date) enforced
--    in FactListings Section 6. listings is a raw layer.
--    Setting PK in wizard causes constraint violations on
--    quarterly append and must be dropped immediately after.

-- ⚠️ Do NOT Allow Nulls on these columns (uncheck Allow Nulls in wizard):
--   id                    — every listing must have an Airbnb ID
--   host_id               — every listing must have a host
--   latitude              — map visuals break without coordinates
--   longitude             — map visuals break without coordinates
--   neighbourhood_cleansed— core join key to DimLocation
--   property_type         — core join key to DimPropertyType
--   room_type             — core join key to DimRoomType
--   accommodates          — investor analysis requires guest capacity
--   minimum_nights        — booking constraint, always present in source


-- ── WIZARD SCHEMA FIXES — reviews ────────────────────────────
--   listing_id                  int              → BIGINT
--   reviewer_id                 int              → BIGINT
--   reviewer_name                nvarchar(50)     → nvarchar(100), Allow Nulls ✅
--   comments                    nvarchar(1800)   → nvarchar(MAX), Allow Nulls ✅
--
-- ⚠️ Do NOT set Primary Key on reviews in the wizard
--    review_id PK enforced in FactReviews Section 6.
--    Setting PK in wizard causes constraint violations on
--    quarterly append and must be dropped immediately after.

-- ⚠️ Do NOT Allow Nulls on these columns for reviews (uncheck Allow Nulls in wizard):
--   listing_id    — every review must reference a valid listing
--   id            — every review must have a unique Airbnb review ID
--   date          — every review must have a submission date
--   reviewer_id   — every review must have a reviewer identifier

-- ── POST-IMPORT: DROP UNNECESSARY COLUMNS ────────────────────
-- Run immediately after each wizard import on the wizard table
-- BEFORE renaming or appending into main listings table.
-- Removes columns not needed for analysis (red rows in
-- data dictionary Staging Table sheet).
-- Keeping only analytical columns ensures:
--   1. listings stays lean — no irrelevant data stored
--   2. Quarterly appends work cleanly — column structure
--      of wizard table matches main listings every time
--   3. Star schema builds from pre-filtered raw table
-- ⚠️ Change date to match your actual wizard table name
-- ============================================================

ALTER TABLE [2025-06-24_listings] DROP COLUMN
    scrape_id,
    last_scraped,
    source,
    neighborhood_overview,
    host_thumbnail_url,
    neighbourhood_group_cleansed,
    minimum_minimum_nights,
    maximum_minimum_nights,
    minimum_maximum_nights,
    maximum_maximum_nights,
    minimum_nights_avg_ntm,
    maximum_nights_avg_ntm,
    calendar_updated,
    has_availability,
    availability_30,
    availability_60,
    availability_90,
    calendar_last_scraped,
    number_of_reviews_l30d,
    availability_eoy,
    first_review,
    last_review;

-- ── VERIFY AFTER WIZARD IMPORT ───────────────────────────────

-- 🔹 Query 1: Table name, column names, data types and nullability
SELECT
    TABLE_NAME,
    COLUMN_NAME,
    DATA_TYPE,
    CHARACTER_MAXIMUM_LENGTH,
    IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_CATALOG = DB_NAME()
AND TABLE_NAME IN ('2025-06-24_listings', '2025-06-24_reviews')
ORDER BY TABLE_NAME, ORDINAL_POSITION;

-- 🔹 Confirm both tables loaded correctly
SELECT 'listings' AS table_name, COUNT(*) AS row_count FROM [2025-06-24_listings]
UNION ALL
SELECT 'reviews', COUNT(*) FROM [2025-06-24_reviews];

-- ============================================================
-- SECTION 2 – RENAME TABLES AND ADD SNAPSHOT DATE
-- ============================================================
-- CONTEXT: Import Flat File wizard creates tables named after
-- the CSV filename (e.g. 2025-06-24_listings).
-- This section standardises names, tags each row with its
-- scrape date, and merges all snapshots into single tables.
--
-- EXECUTION ORDER:
--   A) Run immediately after importing June 2025 files
--   B) Import September 2025 files via wizard
--   C) Run immediately after importing September 2025 files
--   D) Every new quarter: repeat pattern B → C
-- ============================================================

-- ============================================================
-- A) RUN AFTER IMPORTING JUNE 2025 FILES
-- ============================================================

-- 🔹 Step 1: Rename wizard-created tables to standard names
-- Wizard names tables after the CSV filename — standard names
-- required for all subsequent sections of this script
-- ⚠️ Only run once — will error if listings already exists
EXEC sp_rename '2025-06-24_listings', 'listings';
EXEC sp_rename '2025-06-24_reviews',  'reviews';

-- 🔹 No PK drop needed — wizard imported without Primary Key
-- as per Section 1 instructions. Composite PK (listing_id +
-- snapshot_date) enforced in FactListings Section 6.

-- 🔹 Step 2: Add snapshot_date column (first time only)
-- snapshot_date tracks which quarterly scrape each row belongs to
-- taken from CSV filename: 2025-06-24_listings.csv → '2025-06-24'
-- IF NOT EXISTS prevents error if column already exists on re-run
IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'listings' AND COLUMN_NAME = 'snapshot_date'
)
ALTER TABLE listings ADD snapshot_date DATE;

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'reviews' AND COLUMN_NAME = 'snapshot_date'
)
ALTER TABLE reviews ADD snapshot_date DATE;

-- 🔹 Step 3: Tag all current rows as June 2025 snapshot
-- WHERE clause not needed — all rows at this point are June
-- since September not yet loaded
UPDATE listings SET snapshot_date = '2025-06-24';
UPDATE reviews  SET snapshot_date = '2025-06-24';

-- 🔹 Verify June snapshot loaded and tagged correctly
SELECT
    'listings'  AS table_name,
    snapshot_date,
    COUNT(*)    AS row_count
FROM listings
GROUP BY snapshot_date
UNION ALL
SELECT
    'reviews'   AS table_name,
    snapshot_date,
    COUNT(*)    AS row_count
FROM reviews
GROUP BY snapshot_date
ORDER BY table_name, snapshot_date;
-- Expected:
-- listings | 2025-06-24 | 15,632
-- reviews  | 2025-06-24 | 827,725

-- ============================================================
-- B) IMPORT SEPTEMBER 2025 FILES VIA WIZARD
-- ============================================================
-- Right-click Airbnb_Athens_Database → Tasks → Import Flat File
-- listings: table name → 2025-09-26_listings
-- reviews:  table name → 2025-09-26_reviews
-- Apply same schema fixes as June (see Section 1)
-- ⚠️ Do NOT set Primary Key on either table
-- ⚠️ Run POST-IMPORT DROP block from Section 1 on new tables
-- Then continue with Section C below
-- ============================================================

-- ============================================================
-- C) RUN AFTER IMPORTING SEPTEMBER 2025 FILES
-- ============================================================

-- 🔹 Step 3: Drop unnecessary columns from September wizard tables
-- Column structure must match listings before appending
-- Same drop list as Section 1 — applied to September tables
ALTER TABLE [2025-09-26_listings] DROP COLUMN
    scrape_id, last_scraped, source, neighborhood_overview,
    host_thumbnail_url, neighbourhood_group_cleansed,
    minimum_minimum_nights, maximum_minimum_nights,
    minimum_maximum_nights, maximum_maximum_nights,
    minimum_nights_avg_ntm, maximum_nights_avg_ntm,
    calendar_updated, has_availability,
    availability_30, availability_60, availability_90,
    calendar_last_scraped, number_of_reviews_l30d,
    availability_eoy, first_review, last_review;
    
-- 🔹 Step 4: Add snapshot_date to September wizard tables
-- Tag BEFORE merging — ensures rows correctly identified
-- after INSERT into main tables where both snapshots coexist
-- IF NOT EXISTS prevents error if script is re-run and column
-- already exists — same safe pattern used for June in Step 2
IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = '2025-09-26_listings' AND COLUMN_NAME = 'snapshot_date'
)
ALTER TABLE [2025-09-26_listings] ADD snapshot_date DATE;

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = '2025-09-26_reviews' AND COLUMN_NAME = 'snapshot_date'
)
ALTER TABLE [2025-09-26_reviews] ADD snapshot_date DATE;

-- Tag all current rows as September snapshot
UPDATE [2025-09-26_listings] SET snapshot_date = '2025-09-26';
UPDATE [2025-09-26_reviews]  SET snapshot_date = '2025-09-26';

-- 🔹 Step 4: Append September into main tables
-- INSERT adds rows to existing table — does NOT overwrite
-- listings now contains June + September rows combined
INSERT INTO listings SELECT * FROM [2025-09-26_listings];
INSERT INTO reviews  SELECT * FROM [2025-09-26_reviews];

-- 🔹 Verify both snapshots present before dropping wizard tables
SELECT
    'listings'  AS table_name,
    snapshot_date,
    COUNT(*)    AS row_count
FROM listings
GROUP BY snapshot_date
UNION ALL
SELECT
    'reviews'   AS table_name,
    snapshot_date,
    COUNT(*)    AS row_count
FROM reviews
GROUP BY snapshot_date
ORDER BY table_name, snapshot_date;
-- Expected:
-- listings | 2025-06-24 | 15,632
-- listings | 2025-09-26 | 15,584
-- reviews  | 2025-06-24 | 827,725
-- reviews  | 2025-09-26 | 874,286

-- 🔹 Step 5: Drop September wizard tables
-- Data is now safely in listings and reviews
-- Wizard tables no longer needed
DROP TABLE [2025-09-26_listings];
DROP TABLE [2025-09-26_reviews];

-- ============================================================
-- D) EVERY NEW QUARTER — REPEAT THIS PATTERN
-- ============================================================
-- 1. Wizard → import CSV → table: YYYY-MM-DD_listings / reviews
--    Apply same schema fixes as Section 1
--    ⚠️ Do NOT set Primary Key in wizard
-- 2. DROP unnecessary columns from wizard table (Section 1 list)
--      BEFORE snapshot tagging or appending
-- 3. Add snapshot_date safely (IF NOT EXISTS)
-- 4. Tag wizard tables BEFORE merging
-- 5. INSERT into main tables
-- 6. Verify before dropping (UNION ALL query)
-- 7. DROP wizard tables
-- 8. Re-run Sections 4-10 to rebuild star schema
-- ============================================================

-- ============================================================
-- SECTION 3A – VERIFY COLUMN STRUCTURE
-- ============================================================
-- Columns were dropped from wizard tables in Sections 1 and 2
-- before merging into listings. Verify here that listings
-- has the correct analytical column set before data profiling.
-- ============================================================

-- 🔹 Verify remaining columns after all drops and merges
SELECT
    COLUMN_NAME,
    DATA_TYPE,
    IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'listings'
ORDER BY ORDINAL_POSITION;
-- Expected: 58 columns remaining

-- ============================================================
-- SECTION 3B – DATA PROFILING (categorical / dimension source columns)
-- Exploratory checks before building dimension tables
-- ============================================================

SELECT DISTINCT room_type               FROM listings;
SELECT DISTINCT property_type           FROM listings;
SELECT DISTINCT neighbourhood,neighbourhood_cleansed  FROM listings;
SELECT DISTINCT instant_bookable        FROM listings;
SELECT DISTINCT host_is_superhost       FROM listings;

-- 🔹 Add property_category column to listings for analysis
-- Clusters 48 granular property types into 5 meaningful groups
-- for investor neighbourhood and ROI analysis
-- IF NOT EXISTS prevents error if the script is re-run and the
-- column already exists (same pattern as snapshot_date, Section 2)

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'listings' AND COLUMN_NAME = 'property_category'
)
ALTER TABLE listings ADD property_category NVARCHAR(50) NULL;

-- ============================================================
-- Re-tag ALL rows when category rules change
-- ⚠️ No WHERE clause — overwrites all existing tags
-- For quarterly load (new rows only) add:
-- WHERE property_category IS NULL
-- ============================================================
UPDATE listings
SET property_category = CASE
    -- Entire properties — highest revenue potential
    WHEN property_type LIKE 'Entire%'       
      OR property_type = 'Cycladic home'      THEN 'Entire Property'
    -- Private rooms — mid-range, shared infrastructure
    WHEN property_type LIKE 'Private room%'
      OR property_type = 'Casa particular'          THEN 'Private Room'
    -- Shared rooms — budget segment
    WHEN property_type LIKE 'Shared room%'          THEN 'Shared Room'
    -- Hotel-style — professional operators
    WHEN property_type LIKE '%hotel%'
      OR property_type LIKE '%aparthotel%'
      OR property_type LIKE '%serviced%'            THEN 'Hotel / Serviced'
    -- Unique / unusual properties — niche, not comparable
    -- for standard investment analysis
    WHEN property_type IN ('Boat', 'Barn',
        'Camper/RV', 'Tent', 'Cave',
        'Earthen home','Tiny home', 'Floor', 'Castle')  THEN 'Unique / Other'
    -- Catch-all — folded into Unique / Other (no separate 'Other' bucket).
    -- Check property_types_included below periodically to catch any
    -- genuinely new/unclassified property_type values from future scrapes.
    ELSE 'Unique / Other'
END;

-- 🔹 Verify clustering — property types listed per category with count
SELECT
    property_category,
    STRING_AGG(property_type, ', ') -- use of STRING_AGG for exporting all propery_category data in one row
        WITHIN GROUP (ORDER BY property_type) AS property_types_included,
    COUNT(DISTINCT property_type)             AS type_count
FROM (
    SELECT DISTINCT property_category, property_type
    FROM listings
) AS distinct_types
GROUP BY property_category
ORDER BY
    CASE WHEN property_category = 'Other' THEN 1 ELSE 0 END,  --used to always sort "other" category last
    property_category;

-- ============================================================
-- 🔹 price_quote_* fields — added 2026-06-28
-- Inside Airbnb's 2026-06-28 export introduced 11 new raw columns.
-- 6 are dropped as redundant (see quarterly load Step 3 drop list —
-- host_profile_id, host_profile_url, hosts_time_as_user_years/months,
-- hosts_time_as_host_years/months). The remaining 5 are kept:
--   price_quote_checkin_date, price_quote_checkout_date,
--   price_quote_total_price, price_quote_price_per_night, price_quote_raw
--
-- DESIGN DECISION — kept as NVARCHAR, not DECIMAL/DATE:
-- Mixed date formats observed across rows — parse via TRY_CONVERT
-- downstream (Power Query/DAX) rather than forcing a cast here that
-- could silently NULL out rows with a non-standard format.
--
-- DESIGN DECISION — price_quote_raw excluded from FactListings:
-- Kept archived in `listings` only (same treatment as `amenities`) —
-- illustrative reference data tied to a specific date range per
-- listing, not a comparable cross-listing KPI. See Section 6 /
-- FactListings for where the other four fields get pulled through.
--
-- IF NOT EXISTS guard — same idempotent pattern as snapshot_date and
-- property_category. Added here so a full rebuild of THIS script
-- (disaster recovery / fresh environment) is self-sufficient and
-- does not depend on Airbnb_Athens_quarterly_load.sql having been
-- run first — that script re-applies this same guarded ALTER TABLE
-- on every new quarter for the same reason.
--
-- Pre-2026-06-28 snapshots (June/Sept 2025) read NULL across all
-- five columns — the field didn't exist yet, not missing data.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'listings' AND COLUMN_NAME = 'price_quote_checkin_date')
ALTER TABLE listings ADD price_quote_checkin_date NVARCHAR(20) NULL;

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'listings' AND COLUMN_NAME = 'price_quote_checkout_date')
ALTER TABLE listings ADD price_quote_checkout_date NVARCHAR(20) NULL;

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'listings' AND COLUMN_NAME = 'price_quote_total_price')
ALTER TABLE listings ADD price_quote_total_price NVARCHAR(20) NULL;

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'listings' AND COLUMN_NAME = 'price_quote_price_per_night')
ALTER TABLE listings ADD price_quote_price_per_night NVARCHAR(20) NULL;

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'listings' AND COLUMN_NAME = 'price_quote_raw')
ALTER TABLE listings ADD price_quote_raw NVARCHAR(MAX) NULL;


-- ============================================================
-- SECTION 3C – DimHost DATA PROFILING
-- ============================================================
-- Purpose: Profile host-related columns before building DimHost
-- and FactListings. Document data quality findings and design
-- decisions inline — this section is the audit trail for all
-- host attribute placement decisions in Sections 4 and 7.
--
-- KEY DESIGN DECISION — Host attributes split across two tables:
--   DimHost      → stable host attributes (latest snapshot)
--   FactListings → snapshot-varying host measures
--
-- This separation resolves the Slowly Changing Dimension (SCD)
-- problem discovered during DimHost build:
--   host_id 37177 (Emmanouil, Athens Quality Apartments)
--   June 2025:      host_is_superhost = t (Superhost)
--   September 2025: host_is_superhost = f (lost Superhost status)
--   SELECT DISTINCT produced duplicate host_id → PK violation
--   Solution: ROW_NUMBER() for DimHost (latest snapshot wins)
--             host_is_superhost moved to FactListings per snapshot
-- ============================================================

-- ── Boolean columns ──────────────────────────────────────────
-- Expect only t, f, NULL — converted to 0/1 in DimHost/FactListings

SELECT DISTINCT host_is_superhost      FROM listings ORDER BY host_is_superhost;
-- ⚠️ DESIGN DECISION: lives in FactListings — proven to change between
-- snapshots (host 37177 lost superhost status June → September 2025)
-- Enables quarter-over-quarter superhost analysis in Power BI:
--   Lost Superhost / Gained Superhost / Retained / Never

SELECT DISTINCT host_has_profile_pic   FROM listings ORDER BY host_has_profile_pic;
-- → DimHost: rarely changes — stable trust indicator

SELECT DISTINCT host_identity_verified FROM listings ORDER BY host_identity_verified;
-- → DimHost: rarely changes — stable trust indicator

-- ── Rate columns ─────────────────────────────────────────────
-- Expect %, N/A, NULL
-- % stripped in DimHost → DECIMAL(5,2) | N/A and NULL → -1 sentinel
-- Filter -1 in Power BI to exclude from AVG calculations

SELECT DISTINCT host_response_rate   FROM listings ORDER BY host_response_rate;
SELECT DISTINCT host_acceptance_rate FROM listings ORDER BY host_acceptance_rate;
-- → DimHost: used as Power BI slicers (filter responsive hosts)
-- Slowly changing — stable enough for dimension attribute

-- ── Response time ────────────────────────────────────────────
SELECT DISTINCT host_response_time FROM listings ORDER BY host_response_time;
-- → DimHost: text category slicer ("within an hour", "a few days")
-- N/A and NULL → 'Unknown' in DimHost

-- ── Text columns ─────────────────────────────────────────────
SELECT DISTINCT host_name     FROM listings ORDER BY host_name;
SELECT DISTINCT host_location FROM listings ORDER BY host_location;
-- → DimHost: stable display attributes
-- ISNULL + REPLACE pattern handles N/A and NULL → 'Unknown'

-- ── host_verifications ───────────────────────────────────────
SELECT DISTINCT host_verifications FROM listings ORDER BY host_verifications;
-- Check for 'None', 'N/A', NULL — double REPLACE needed:
-- ISNULL(REPLACE(REPLACE(host_verifications,'None','Unknown'),'N/A','Unknown'),'Unknown')
-- → DimHost: stable trust indicator

-- ── host_since ───────────────────────────────────────────────
SELECT
    MIN(host_since)                                                 AS earliest_host,
    MAX(host_since)                                                 AS latest_host,
    SUM(CASE WHEN host_since IS NULL THEN 1 ELSE 0 END)            AS null_host_since
FROM listings;
-- Expected: range from ~2008 to present, some NULLs acceptable
-- → DimHost: never changes — Airbnb join date is immutable

-- ── Host listing count columns ───────────────────────────────
SELECT
    SUM(CASE WHEN host_listings_count                          IS NULL THEN 1 ELSE 0 END) AS null_listings_count,
    SUM(CASE WHEN host_total_listings_count                    IS NULL THEN 1 ELSE 0 END) AS null_total_listings,
    SUM(CASE WHEN calculated_host_listings_count               IS NULL THEN 1 ELSE 0 END) AS null_calc_count,
    SUM(CASE WHEN calculated_host_listings_count_entire_homes  IS NULL THEN 1 ELSE 0 END) AS null_calc_entire,
    SUM(CASE WHEN calculated_host_listings_count_private_rooms IS NULL THEN 1 ELSE 0 END) AS null_calc_private,
    SUM(CASE WHEN calculated_host_listings_count_shared_rooms  IS NULL THEN 1 ELSE 0 END) AS null_calc_shared
FROM listings;
-- Results (June + September 2025):
-- host_listings_count         → 571 NULLs (HOST-REPORTED — some hosts leave blank)
-- host_total_listings_count   → 571 NULLs (HOST-REPORTED — same issue)
-- calculated_host_listings_count* → 0 NULLs (AIRBNB-CALCULATED — always populated)
--
-- ⚠️ DESIGN DECISION: all listing count columns → FactListings
-- Reason 1: change each snapshot (snapshot-specific measures)
-- Reason 2: host_listings_count is host-reported with 571 NULLs
--           calculated_host_listings_count is Airbnb-calculated, 0 NULLs
--           → use calculated_host_listings_count in Power BI investor analysis
--           → host_listings_count kept as reference only

-- ── Duplicate host_id check ───────────────────────────────────
-- ============================================================
-- WHY THIS PROFILING IS NECESSARY:
-- Before building DimHost we must understand how many hosts
-- changed attributes between snapshots. If host attributes
-- change between quarters, SELECT DISTINCT on host_id will
-- produce duplicate PKs — breaking the DimHost build entirely.
--
-- BUSINESS RELEVANCE FOR INVESTOR DASHBOARD:
-- Superhost status directly affects listing visibility,
-- booking rates and revenue potential on Airbnb.
-- A property managed by a host who lost Superhost status
-- between quarters represents a management risk for investors
-- — this cannot be detected without snapshot tracking.
--
-- ⚠️ DESIGN DECISION CONFIRMED:
-- host_is_superhost → FactListings (snapshot-varying measure)
-- not DimHost (static) — preserves quarter-over-quarter
-- management risk analysis for investor ROI projections.
-- ============================================================

SELECT
    -- 🔹 Total unique hosts across both snapshots
    COUNT(DISTINCT host_id)                                         AS total_unique_hosts,

    -- 🔹 Hosts holding Superhost status in at least one snapshot
    COUNT(DISTINCT CASE WHEN host_is_superhost = 't'
        THEN host_id END)                                           AS superhost_hosts,
    ROUND(100.0 * COUNT(DISTINCT CASE WHEN host_is_superhost = 't'
        THEN host_id END)
        / COUNT(DISTINCT host_id), 1)                              AS superhost_pct,

    -- 🔹 Hosts appearing as non-Superhost in at least one snapshot
    COUNT(DISTINCT CASE WHEN host_is_superhost = 'f'
        THEN host_id END)                                           AS non_superhost_hosts,
    ROUND(100.0 * COUNT(DISTINCT CASE WHEN host_is_superhost = 'f'
        THEN host_id END)
        / COUNT(DISTINCT host_id), 1)                              AS non_superhost_pct,
    -- Note: superhost_pct + non_superhost_pct > 100% is expected
    -- 646 hosts appear in both categories (changed status between snapshots)

    -- 🔹 Hosts who changed superhost status between snapshots
    -- These are the hosts that would cause PK violation in DimHost
    -- if host_is_superhost stayed as a static dimension attribute
    (
        SELECT COUNT(*)
        FROM (
            SELECT host_id
            FROM listings
            GROUP BY host_id
            HAVING COUNT(DISTINCT host_is_superhost) > 1
        ) AS changed
    )                                                               AS hosts_superhost_changed,
    ROUND(100.0 *
    (
        SELECT COUNT(*)
        FROM (
            SELECT host_id
            FROM listings
            GROUP BY host_id
            HAVING COUNT(DISTINCT host_is_superhost) > 1
        ) AS changed
    )
    / COUNT(DISTINCT host_id), 1)                                   AS superhost_changed_pct

FROM listings;

-- ============================================================
-- Results (June + September 2025):
-- total_unique_hosts:      6,616
-- superhost_hosts:         2,931  (44.3%)
-- non_superhost_hosts:     4,173  (63.1%)
-- hosts_superhost_changed:   646  (9.8% changed status in one quarter)
-- Note: pct values exceed 100% combined — expected, see above
--
-- INVESTOR INSIGHT:
-- A property managed by a host in the 9.8% who changed status
-- represents elevated management risk — Superhost loss reduces
-- listing visibility and booking rates, directly impacting
-- projected annual revenue
-- (estimated_revenue_l365d — Inside Airbnb estimate, not verified figure)
-- This analysis enables the investor dashboard to flag
-- "at-risk" properties where host performance is declining.
--
-- PHASE 3 ENHANCEMENT (4+ snapshots):
-- Multi-quarter trend: Lost/Gained Superhost per quarter transition
-- Enables: "Is Athens host quality improving or declining?"
-- Relevant for portfolio re-valuation at asset management firms
-- ============================================================

-- ── Host attribute placement summary ─────────────────────────
-- ┌─────────────────────────────────┬──────────┬──────────────┐
-- │ Attribute                       │ DimHost  │ FactListings │
-- ├─────────────────────────────────┼──────────┼──────────────┤
-- │ host_id                         │ PK       │ FK           │
-- │ host_name, url, picture, about  │ ✅       │              │
-- │ host_since                      │ ✅       │              │
-- │ host_location                   │ ✅       │              │
-- │ host_has_profile_pic            │ ✅       │              │
-- │ host_identity_verified          │ ✅       │              │
-- │ host_verifications              │ ✅       │              │
-- │ host_response_time              │ ✅       │              │
-- │ host_response_rate              │ ✅       │              │
-- │ host_acceptance_rate            │ ✅       │              │
-- │ host_is_superhost               │          │ ✅ (changes) │
-- │ calculated_host_listings_count* │          │ ✅ (changes) │
-- │ host_listings_count             │          │ ✅ (changes) │
-- │ host_total_listings_count       │          │ ✅ (changes) │
-- └─────────────────────────────────┴──────────┴──────────────┘

-- ============================================================
-- SECTION 3D – DimListings DATA PROFILING
-- ============================================================
-- Purpose: Profile listing descriptive columns before building DimListings
-- and FactListings. Document data quality findings and design
-- decisions inline — this section is the audit trail for all
-- listing attribute placement decisions in Sections 4 and 7.
--
-- KEY DESIGN DECISION — Listing attributes split across two tables:
--   DimListings  → stable descriptive attributes (latest snapshot)
--   FactListings → snapshot-varying numeric facts/measures
--
-- This separation resolves the Slowly Changing Dimension (SCD)
-- problem discovered during tracking, preventing PK violations:
--   listing_id 105223 (Luxury Apartment, Athens)
--   June 2025:      name = "Luxury Apt - 10% Off Summer"
--   September 2025: name = "Luxury Apt - Acropolis View"
--   SELECT DISTINCT produced duplicate id → PK violation
--   Solution: ROW_NUMBER() for DimListings (latest snapshot wins)
--
-- ⚠️ latitude / longitude are included in DimListings — one
-- coordinate pair per physical listing, does not change between
-- snapshots, not an aggregatable measure. Same reasoning as
-- bathrooms_text (see below).
-- ============================================================

-- ── DimListings profiling ──────────────────────────

-- Expect strings, 'N/A', or NULL -> Cleaned to 'Unknown' in DimListings
-- Moved to DimListings as stable display identifiers

SELECT DISTINCT name         FROM listings ORDER BY name;
SELECT DISTINCT listing_url  FROM listings ORDER BY listing_url;
SELECT DISTINCT picture_url  FROM listings ORDER BY picture_url;
SELECT 
        SUM(CASE WHEN name IS NULL THEN 1 ELSE 0 END) AS name_null_count,
        SUM(CASE WHEN listing_url IS NULL THEN 1 ELSE 0 END) AS listing_url_null_count,
        SUM(CASE WHEN picture_url IS NULL THEN 1 ELSE 0 END) AS picture_url_null_count
FROM listings;
-- Results (June + September 2025):
-- 0 NULLs, 0 'N/A' strings across name / listing_url / picture_url
-- ISNULL + REPLACE cleaning kept in DimListings build as a
-- defensive safeguard for future quarterly loads — not currently
-- triggered by this dataset.

-- → DimListings: core textual labels used for front-end rendering and search dashboards.

-- ── Heavy Text Columns ───────────────────────────────────────
-- Expect multi-line descriptions, HTML formatting, 'N/A', or NULL
-- Checked for extreme character lengths to prevent memory bloat in Fact table

SELECT 
    MIN(LEN(description)) AS description_min_len, 
    MAX(LEN(description)) AS description_max_len,
    SUM(CASE WHEN description IS NULL THEN 1 ELSE 0 END) AS description_null_count
FROM listings;
-- → DimListings: heavy string objects are isolated here. 
-- Keeping them out of FactListings ensures high-speed column scans on numeric measures.

-- ── bathrooms_text column ────────────────────────────────────
SELECT DISTINCT bathrooms_text FROM listings ORDER BY bathrooms_text;
-- Expect configurations like '1 shared bath', '2.5 baths', 'Private half-bath'
-- → DimListings: Used as a category slicer in Power BI. 
-- Note: Raw numeric count 'bathrooms' goes to FactListings for calculations, 
-- but this textual representation belongs in the dimension.

-- ── latitude / longitude ─────────────────────────────────────
SELECT
    MIN(latitude)  AS min_lat, MAX(latitude)  AS max_lat,
    MIN(longitude) AS min_long, MAX(longitude) AS max_long,
    SUM(CASE WHEN latitude IS NULL OR longitude IS NULL THEN 1 ELSE 0 END) AS null_coordinates
FROM listings;
-- Expected: 0 NULLs (wizard import blocks NULL on these — Section 1)
-- Grain check: one coordinate pair per physical listing, not per
-- neighbourhood — cannot live in DimLocation (45-row grain).
-- → DimListings: stable descriptive attribute, not an aggregatable measure.

-- ── Duplicate listing_id check ───────────────────────────────
-- ============================================================
-- WHY THIS PROFILING IS NECESSARY:
-- Hosts frequently optimize names, descriptions, and amenities 
-- between quarters to drive conversions. If listing descriptions 
-- shift between snapshots, a SELECT DISTINCT on id will trigger 
-- duplicate PK errors.
--
-- BUSINESS RELEVANCE FOR INVESTOR DASHBOARD:
-- Text shifts like changes in bathroom text layouts ('1 bath' to '1 shared bath')
-- or drastic description re-writes can highlight structural property renovations 
-- or asset repositioning. By tracking the exact instance via Fact snapshot dates 
-- while keeping the latest state in DimListings, we retain full operational reporting.
-- ============================================================

SELECT
    -- 🔹 Total unique physical listings across all snapshots
    COUNT(DISTINCT id) AS total_unique_listings,

    -- 🔹 Listings whose descriptive names changed between snapshots
    -- These are the records that would break DimListings without ROW_NUMBER()
    (
        SELECT COUNT(*)
        FROM (
            SELECT id
            FROM listings
            GROUP BY id
            HAVING COUNT(DISTINCT name) > 1
        ) AS changed_names
    ) AS listings_name_changed,
    
    ROUND(100.0 * (
        SELECT COUNT(*)
        FROM (
            SELECT id
            FROM listings
            GROUP BY id
            HAVING COUNT(DISTINCT name) > 1
        ) AS changed_names
    ) / COUNT(DISTINCT id), 1) AS name_changed_pct
FROM listings;

-- ============================================================
-- Expected Results Analysis:
-- listings_name_changed represents promotional title pivoting 
-- (e.g., "Winter Special" -> "Summer Special"). 
-- Confirms necessity of ROW_NUMBER() OVER (...) filtering for DimListings.
-- ============================================================

-- ── Listing attribute placement summary ──────────────────────
-- ┌─────────────────────────────────┬──────────────┬──────────────┐
-- │ Attribute                       │ DimListings  │ FactListings │
-- ├─────────────────────────────────┼──────────────┼──────────────┤
-- │ id                              │ PK           │ FK / Join    │
-- │ name, description               │ ✅           │              │
-- │ listing_url, picture_url        │ ✅           │              │
-- │ bathrooms_text                  │ ✅           │              │
-- │ latitude, longitude             │ ✅           │              │
-- │ neighbourhood_cleansed          │ ❌(DimLoc)   │              │
-- │ accommodates, bathrooms,        │              │ ✅ (Measure) │
-- │ bedrooms, beds, price           │              │ ✅ (Measure) │
-- │ license                         │              │ ✅ (changes) │
-- │ review_scores_* (All ratings)   │              │ ✅ (Measure) │
-- │ availability_365, occupancy     │              │ ✅ (Measure) │
-- │ host_is_superhost               │              │ ✅ (changes) │
-- └─────────────────────────────────┴──────────────┴──────────────┘

-- ============================================================
-- SECTION 3E – FactListings MEASURES PROFILING
-- ============================================================
 
-- 🔹 Price — confirm source format before cleaning
SELECT DISTINCT TOP 10 price FROM listings ORDER BY price;
-- Expected: '$50.00' format
-- Cleaned in FactListings via TRY_CAST(REPLACE(REPLACE(price,'$',''),',','') AS DECIMAL(10,2))
 
-- 🔹 Price distribution by snapshot
SELECT
    snapshot_date,
    MIN(TRY_CAST(REPLACE(REPLACE(price, '$', ''), ',', '') AS DECIMAL(10,2))) AS min_price,
    MAX(TRY_CAST(REPLACE(REPLACE(price, '$', ''), ',', '') AS DECIMAL(10,2))) AS max_price,
    AVG(TRY_CAST(REPLACE(REPLACE(price, '$', ''), ',', '') AS DECIMAL(10,2))) AS avg_price
FROM listings
GROUP BY snapshot_date
ORDER BY snapshot_date;

-- 🔹 NULL price by snapshot — confirmed genuine source NULLs, not a
-- TRY_CAST failure (raw_price for a sampled listing was NULL before
-- any cleaning was applied). Not evenly distributed across quarters:
--   2025-06-24: 781 / 15,632  (5.0%)
--   2025-09-26: 1,060 / 15,584 (6.8%)
--   2026-06-28: 138 / 14,337  (1.0%)
-- The drop after 2026-06-28 lines up with the same export that added
-- price_quote_*, but that's an observed correlation, not a confirmed
-- cause — worth re-checking once a second 2026+ snapshot exists to
-- see if ~1% holds or 2026-06-28 was a one-off. Listings with NULL
-- price are silently excluded from any price-based AVG/SUM in
-- FactListings — see DESIGN_DECISIONS.md Known Limitations.
SELECT
    snapshot_date,
    COUNT(*)                                                        AS total_listings,
    SUM(CASE WHEN price IS NULL OR price = '' THEN 1 ELSE 0 END)    AS null_price_listings,
    CAST(100.0 * SUM(CASE WHEN price IS NULL OR price = '' THEN 1 ELSE 0 END)
        / COUNT(*) AS DECIMAL(4,1))                                 AS null_price_pct
FROM listings
GROUP BY snapshot_date
ORDER BY snapshot_date;
 
-- 🔹 Review score distribution
-- ⚠️ Do NOT replace NULLs with 0 — AVG() ignores NULLs automatically
SELECT
    MIN(review_scores_rating)                                       AS min_rating,
    MAX(review_scores_rating)                                       AS max_rating,
    AVG(review_scores_rating)                                       AS avg_rating,
    COUNT(review_scores_rating)                                     AS rated_listings,
    COUNT(*) - COUNT(review_scores_rating)                          AS unrated_listings
FROM listings;
 
-- 🔹 NULL distribution across key measure columns
SELECT
    SUM(CASE WHEN bathrooms               IS NULL THEN 1 ELSE 0 END) AS null_bathrooms,
    SUM(CASE WHEN bedrooms                IS NULL THEN 1 ELSE 0 END) AS null_bedrooms,
    SUM(CASE WHEN beds                    IS NULL THEN 1 ELSE 0 END) AS null_beds,
    SUM(CASE WHEN review_scores_rating    IS NULL THEN 1 ELSE 0 END) AS null_rating,
    SUM(CASE WHEN estimated_revenue_l365d IS NULL THEN 1 ELSE 0 END) AS null_revenue,
    SUM(CASE WHEN license                 IS NULL THEN 1 ELSE 0 END) AS null_license,
    SUM(CASE WHEN reviews_per_month       IS NULL THEN 1 ELSE 0 END) AS null_reviews_per_month
FROM listings;
 
-- 🔹 Duplicate check per snapshot (data quality gate)
SELECT id, snapshot_date, COUNT(*) AS duplicates
FROM listings
GROUP BY id, snapshot_date
HAVING COUNT(*) > 1;
-- Expected: 0 rows

-- ============================================================
-- SECTION 4 – DIMENSION TABLES
-- Build order matters — dimensions must exist before FactListings
-- references them via LEFT JOIN in Section 7.
-- Pattern per dimension:
--   1. DROP if exists          (safe re-run — rebuilt each quarter)
--   2. CREATE TABLE            (surrogate PK via IDENTITY)
--      OR SELECT DISTINCT INTO (for natural key dims like DimHost)
--   3. INSERT SELECT DISTINCT   (populate — cleaning applied inline)
--      ISNULL + REPLACE pattern applied consistently across all dims:
--      → REPLACE handles 'N/A' text string (common in Airbnb source)
--      → ISNULL handles NULL values
--      → Both map to 'Unknown' — explicit dimension member, not fallback
--      → Reusable each quarter — handles new NULL/N/A values automatically
--   4. INSERT sentinel id = 0  (Unknown — valid FK for unmatched rows)
--   5. SELECT * to verify      (quick QA)

-- Sentinel record pattern — applied to every dimension table:
-- When a listing has no matching dimension value (e.g. NULL
-- room_type), LEFT JOIN in FactListings returns NULL for the FK.
-- ISNULL(..., 0) maps it to this record instead, ensuring every
-- fact row has a valid FK and Power BI relationships never break.
-- ============================================================

-- ============================================================
-- SECTION 4A – DimLocation
-- ============================================================

-- ── DimLocation ─────────────────────────────────────────────
-- Built directly from Inside Airbnb neighbourhoods.csv
-- which is the authoritative reference for Athens neighbourhoods
-- Avoids garbled encoding issues from listings import entirely
-- One row per neighbourhood — clean canonical Greek names
-- No encoding fix section needed with this approach
--
-- ⚠️ latitude / longitude do NOT belong here — grain is one row
-- per neighbourhood (45 rows), coordinates are per-listing.
-- They live in DimListings instead (see Section 3D / Section 4).
--
-- Region/district hierarchy: neighbourhood_group in the source
-- CSV is blank for every Athens row (Inside Airbnb has no official
-- borough structure for Athens). Decision: build any Neighbourhood →
-- Region grouping as a Power BI-side hierarchy/grouping on
-- neighbourhood_cleansed, not as a SQL column — keeps DimLocation
-- unchanged and avoids hardcoding a subjective grouping into the
-- warehouse layer.
--
-- WIZARD STEPS (before running this block):
--   Right-click Airbnb_Athens_Database → Tasks → Import Flat File
--   → Browse → select YYYY-MM-DD_neighbourhoods.csv
--   → Wizard names table: YYYY-MM-DD_neighbourhoods
--   → Modify Columns:
--       neighbourhood_group  nvarchar(50)  Allow Nulls ✅
--       neighbourhood        nvarchar(100) NOT NULL
--   → No Primary Key needed
--   → Finish

IF OBJECT_ID('DimLocation', 'U') IS NOT NULL DROP TABLE DimLocation;

CREATE TABLE DimLocation
(
    location_id            INT           IDENTITY(1,1) PRIMARY KEY,
    neighbourhood_cleansed NVARCHAR(100) NOT NULL
);

INSERT INTO DimLocation (neighbourhood_cleansed)
SELECT DISTINCT
    ISNULL(REPLACE(neighbourhood, 'N/A', 'Unknown'), 'Unknown')
FROM [2025-06-24_neighbourhoods];

-- 🔹 Temporarily disable IDENTITY auto-increment to insert manual id = 0
SET IDENTITY_INSERT DimLocation ON;
-- Sentinel record: id = 0 = Unknown
-- Provides valid FK target for unmatched FactListings rows
INSERT INTO DimLocation (location_id, neighbourhood_cleansed)
SELECT 0, 'Unknown';
-- Re-enable IDENTITY auto-increment
SET IDENTITY_INSERT DimLocation OFF;

-- 🔹 Verify before dropping reference table
SELECT COUNT(*) AS location_count FROM DimLocation;
-- Expected: 45 rows + 1 Unknown sentinel = 46

SELECT * FROM DimLocation ORDER BY neighbourhood_cleansed;

-- 🔹 Drop after verify confirms correct load
DROP TABLE [2025-06-24_neighbourhoods];
/*
-- ============================================================
-- QUARTERLY NOTE: DimLocation update check
-- ============================================================
-- Each quarter Inside Airbnb ships a new neighbourhoods.csv
-- Import via wizard → table: YYYY-MM-DD_neighbourhoods
-- Then run the check below before rebuilding star schema:
--
-- 🔹 Check for new neighbourhoods in latest quarter
SELECT neighbourhood
FROM [YYYY-MM-DD_neighbourhoods]        -- ← change date
WHERE neighbourhood NOT IN
    (SELECT neighbourhood_cleansed FROM DimLocation)
AND neighbourhood IS NOT NULL;
-- If rows found → new neighbourhoods added by Inside Airbnb
--   INSERT INTO DimLocation (neighbourhood_cleansed)
--   SELECT neighbourhood FROM [YYYY-MM-DD_neighbourhoods]
--   WHERE neighbourhood NOT IN
--       (SELECT neighbourhood_cleansed FROM DimLocation);
-- If empty → DimLocation unchanged → proceed with star schema rebuild
--
-- 🔹 Drop reference table after check
-- DROP TABLE [YYYY-MM-DD_neighbourhoods];
-- ============================================================
*/

-- ============================================================
-- SECTION 4B – DimRoomType, DimPropertyType, DimHost, DimListings
-- ============================================================

-- ── DimRoomType ─────────────────────────────────────────────
-- Derived analytical layer — dropped and rebuilt each quarter
-- from listings (permanent raw source)

IF OBJECT_ID('DimRoomType', 'U') IS NOT NULL DROP TABLE DimRoomType;

CREATE TABLE DimRoomType
(
    room_id   INT          IDENTITY(1,1) PRIMARY KEY,
    room_type NVARCHAR(50) NULL
);

-- 🔹 SELECT DISTINCT — prevents duplicate room types across snapshots
INSERT INTO DimRoomType (room_type)
SELECT DISTINCT
    ISNULL(REPLACE(room_type, 'N/A', 'Unknown'), 'Unknown') AS room_type
FROM listings;

-- 🔹 Temporarily disable IDENTITY auto-increment to insert manual id = 0
SET IDENTITY_INSERT DimRoomType ON;
-- Sentinel record: id = 0 = Unknown
-- Provides valid FK target for unmatched FactListings rows
INSERT INTO DimRoomType (room_id, room_type)
SELECT 0, 'Unknown';
-- Re-enable IDENTITY auto-increment
SET IDENTITY_INSERT DimRoomType OFF;

SELECT * FROM DimRoomType ORDER BY room_id;
-- Expected: 5 rows (4 room types + Unknown)

-- ── DimPropertyType ─────────────────────────────────────────
-- Includes property_category for investor-level grouping in Power BI
-- 48 granular types clustered into 5 categories (see Section 3B)

IF OBJECT_ID('DimPropertyType', 'U') IS NOT NULL DROP TABLE DimPropertyType;

CREATE TABLE DimPropertyType
(
    property_id       INT           IDENTITY(1,1) PRIMARY KEY,
    property_type     NVARCHAR(100) NULL,
    property_category NVARCHAR(50)  NULL
);

-- 🔹 SELECT DISTINCT on both columns — one row per unique type+category combination
INSERT INTO DimPropertyType (property_type, property_category)
SELECT DISTINCT property_type, property_category
FROM listings;

SET IDENTITY_INSERT DimPropertyType ON;
INSERT INTO DimPropertyType (property_id, property_type, property_category)
SELECT 0, 'Unknown', 'Unknown';
SET IDENTITY_INSERT DimPropertyType OFF;

SELECT * FROM DimPropertyType ORDER BY property_category, property_type;

-- ── DimHost ──────────────────────────────────────────────────
-- Built using ROW_NUMBER() OVER (PARTITION BY host_id
-- ORDER BY snapshot_date DESC) — most recent snapshot wins.
-- Holds only STABLE host attributes — slowly changing fields
-- (host_is_superhost, listing counts) moved to FactListings.
--
-- Real example from this dataset:
-- host_id 37177 (Emmanouil, Athens Quality Apartments):
--   June 2025:      host_is_superhost = t (Superhost)
--   September 2025: host_is_superhost = f (lost Superhost status)
-- SELECT DISTINCT produced duplicate host_id → PK violation
-- ROW_NUMBER() resolves this — September 2025 values kept
-- as current state of each stable host attribute.
--
-- ⚠️ DESIGN NOTE — Slowly Changing Dimension (SCD Type 1):
-- Old attribute values overwritten by latest snapshot.
-- Historical tracking not implemented in this phase.
-- Phase 3 enhancement: SCD Type 2 with valid_from / valid_to
-- date columns for full host attribute history tracking.
--
-- Cleaning applied inline:
--   ISNULL + REPLACE: N/A and NULL → 'Unknown' for text columns
--   % stripped from rate columns → DECIMAL; -1 sentinel = no data
--   (filter -1 in Power BI to exclude from AVG calculations)
--   t/f string → 0/1 integer for boolean columns
--   host_verifications: double REPLACE handles 'None' and 'N/A'
-- Listing count columns excluded — snapshot-specific measures
-- moved to FactListings (slowly changing dimension problem)
 
IF OBJECT_ID('DimHost', 'U') IS NOT NULL DROP TABLE DimHost;
 
WITH LatestHost AS
(
    SELECT *,                              -- all columns from listings preserved
        ROW_NUMBER() OVER (                -- assign sequential number to each row
            PARTITION BY host_id           -- restart counter for each unique host
            ORDER BY snapshot_date DESC    -- most recent snapshot gets number 1
        ) AS rn                            -- rn = 1 means latest record for that host
    FROM listings                          -- raw source table with all snapshots
)
SELECT
    host_id,
    ISNULL(REPLACE(host_name,        'N/A', 'Unknown'), 'Unknown') AS host_name,
    ISNULL(REPLACE(host_url,         'N/A', 'Unknown'), 'Unknown') AS host_url,
    ISNULL(REPLACE(host_picture_url, 'N/A', 'Unknown'), 'Unknown') AS host_picture_url,
    ISNULL(REPLACE(host_about,       'N/A', 'Unknown'), 'Unknown') AS host_about,
    CASE
        WHEN host_location = 'N/A' THEN 'Unknown'
        ELSE ISNULL(host_location, 'Unknown')
    END                                                             AS host_location,
    host_since,
    CASE
        WHEN host_response_time = 'N/A' THEN 'Unknown'
        ELSE ISNULL(host_response_time, 'Unknown')
    END                                                             AS host_response_time,
    -- 🔹 Strip % symbol; replace N/A and NULL with -1 sentinel
    --    Filter -1 in Power BI to exclude from AVG calculations
    CAST(
        ISNULL(REPLACE(REPLACE(host_response_rate,   '%', ''), 'N/A', '-1'), '-1')
    AS DECIMAL(5,2))                                                AS host_response_rate,
    CAST(
        ISNULL(REPLACE(REPLACE(host_acceptance_rate, '%', ''), 'N/A', '-1'), '-1')
    AS DECIMAL(5,2))                                                AS host_acceptance_rate,
    -- 🔹 t/f string → 0/1 integer
    CASE WHEN host_has_profile_pic   = 't' THEN 1 ELSE 0 END       AS host_has_profile_pic,
    CASE WHEN host_identity_verified = 't' THEN 1 ELSE 0 END       AS host_identity_verified,
    -- 🔹 double REPLACE handles both 'None' and 'N/A'
    ISNULL(REPLACE(REPLACE(host_verifications, 'None', 'Unknown'), 'N/A', 'Unknown'), 'Unknown')
                                                                    AS host_verifications
INTO DimHost
FROM LatestHost
WHERE rn = 1;
-- 🔹 Listing count columns moved to FactListings
-- host_listings_count, host_total_listings_count → FactListings
-- calculated_host_listings_count* → FactListings (authoritative)

-- 🔹 Enforce NOT NULL then add Primary Key
--    Required order: ALTER COLUMN first, then ADD PRIMARY KEY
ALTER TABLE DimHost ALTER COLUMN host_id BIGINT NOT NULL;
ALTER TABLE DimHost ADD PRIMARY KEY (host_id);
 
-- 🔹 Sentinel record (host_id = 0)
-- No SET IDENTITY_INSERT needed — DimHost uses natural key
-- not an IDENTITY surrogate key
INSERT INTO DimHost
(host_id, host_name, host_url, host_picture_url, host_about,
 host_location, host_since, host_response_time,
 host_response_rate, host_acceptance_rate,
 host_has_profile_pic, host_identity_verified,
 host_verifications)
SELECT 0,'Unknown','Unknown','Unknown','Unknown','Unknown',
       '1900-01-01',  -- ← DATE sentinel: clearly a placeholder, filterable in Power BI
       'Unknown',-1,-1,0,0,'Unknown';
 
-- 🔹 Verify sentinel record exists
SELECT * FROM DimHost WHERE host_id = 0;
SELECT COUNT(*) AS host_count FROM DimHost;
SELECT TOP 5 * FROM DimHost ORDER BY host_id;

-- ── DimListings ──────────────────────────────────────────────
-- Built using ROW_NUMBER() OVER (PARTITION BY id 
-- ORDER BY snapshot_date DESC) — most recent snapshot wins.
-- Holds only STABLE descriptive listing attributes.
--
-- ⚠️ DESIGN NOTE — Slowly Changing Dimension (SCD Type 1):
-- Old attribute values overwritten by latest snapshot.
--
-- ⚠️ latitude / longitude included here — one coordinate pair
-- per physical listing, stable across snapshots, not an
-- aggregatable measure (see Section 3D profiling).
--
-- Cleaning applied inline:
--   ISNULL + REPLACE: N/A and NULL → 'Unknown' for text columns
-- All numeric measures and snapshot metrics moved to FactListings.
-- Neighborhood data excluded (handled via DimLocation / FactListings).

IF OBJECT_ID('DimListings', 'U') IS NOT NULL DROP TABLE DimListings;

WITH LatestListing AS
(
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY id 
            ORDER BY snapshot_date DESC
        ) AS rn -- rn = 1 means latest record for that listing
    FROM listings
)
SELECT 
    id                                                          AS listing_id,
    ISNULL(REPLACE(listing_url, 'N/A', 'Unknown'), 'Unknown')   AS listing_url,
    ISNULL(REPLACE(picture_url, 'N/A', 'Unknown'), 'Unknown')   AS picture_url,
    ISNULL(REPLACE(name,        'N/A', 'Unknown'), 'Unknown')   AS name, 
    ISNULL(REPLACE(description, 'N/A', 'Unknown'), 'Unknown')   AS description,
    
    -- Text descriptive details
    CASE 
        WHEN bathrooms_text = 'N/A' THEN 'Unknown' 
        ELSE ISNULL(bathrooms_text, 'Unknown') 
    END                                                         AS bathrooms_text,

    -- Spatial data — one coordinate pair per physical listing,
    -- stable across snapshots (see Section 3D profiling)
    latitude,
    longitude
INTO DimListings
FROM LatestListing
WHERE rn = 1;

-- 🔹 Enforce NOT NULL then add Primary Key
ALTER TABLE DimListings ALTER COLUMN listing_id BIGINT NOT NULL;
ALTER TABLE DimListings ADD PRIMARY KEY (listing_id);

-- 🔹 Sentinel record (listing_id = 0)
INSERT INTO DimListings
(
    listing_id, listing_url, picture_url, name, 
    description, bathrooms_text, latitude, longitude
)
VALUES 
(
    0, 'Unknown', 'Unknown', 'Unknown', 
    'Unknown', 'Unknown', 0, 0
);

-- 🔹 Verify sentinel record and data integrity
SELECT * FROM DimListings WHERE listing_id = 0;
SELECT TOP 5 * FROM DimListings;
SELECT COUNT(*) AS listing_count FROM DimListings;

-- ============================================================
-- SECTION 5 – DimDate
-- Built via recursive CTE in SQL Server — not DAX CALENDAR()
-- Deliberate decision: date dimension lives in the warehouse
-- layer (SQL Server), not the reporting layer (Power BI).
-- This ensures DimDate is available to any tool connecting
-- to Airbnb_Athens_Database — not just Power BI.
-- Covers 2000-01-01 to 2030-12-31 (11,323 days):
--   From: earliest Airbnb review dates (~2008)
--   To:   5 years of future quarterly loads beyond current date
-- OPTION (MAXRECURSION 0) overrides SQL Server's default
-- 100-recursion safety limit — required for 11,323 iterations
-- ============================================================

IF OBJECT_ID('DimDate', 'U') IS NOT NULL DROP TABLE DimDate;

CREATE TABLE DimDate
(
    date_id      INT          PRIMARY KEY,  -- Format: YYYYMMDD
    date         DATE         NOT NULL,
    year         INT          NOT NULL,
    quarter      INT          NOT NULL,
    quarter_name NVARCHAR(10) NOT NULL,     -- e.g. 'Q3 2025'
    month        INT          NOT NULL,
    month_name   NVARCHAR(20) NOT NULL,     -- e.g. 'September'
    month_short  NVARCHAR(5)  NOT NULL,     -- e.g. 'Sep'
    week         INT          NOT NULL,     -- ISO week number
    day          INT          NOT NULL,
    day_name     NVARCHAR(20) NOT NULL,     -- e.g. 'Monday'
    day_short    NVARCHAR(5)  NOT NULL,     -- e.g. 'Mon'
    is_weekend   INT          NOT NULL      -- 1 = weekend, 0 = weekday
);

WITH DateCTE AS
(
    SELECT CAST('2000-01-01' AS DATE) AS date_value   -- anchor: starting point
    UNION ALL
    SELECT DATEADD(DAY, 1, date_value)                -- recursive: adds 1 day
    FROM DateCTE
    WHERE date_value < '2030-12-31'                   -- stop condition
)
INSERT INTO DimDate
SELECT
    CAST(FORMAT(date_value, 'yyyyMMdd') AS INT)         AS date_id,
    date_value                                           AS date,
    YEAR(date_value)                                     AS year,
    DATEPART(QUARTER, date_value)                        AS quarter,
    'Q' + CAST(DATEPART(QUARTER, date_value) AS NVARCHAR)
        + ' ' + CAST(YEAR(date_value) AS NVARCHAR)      AS quarter_name,
    MONTH(date_value)                                    AS month,
    DATENAME(MONTH, date_value)                          AS month_name,
    LEFT(DATENAME(MONTH, date_value), 3)                 AS month_short,
    DATEPART(ISO_WEEK, date_value)                       AS week,
    DAY(date_value)                                      AS day,
    DATENAME(WEEKDAY, date_value)                        AS day_name,
    LEFT(DATENAME(WEEKDAY, date_value), 3)               AS day_short,
    CASE
        WHEN DATEPART(WEEKDAY, date_value) IN (1, 7) THEN 1
        ELSE 0
    END                                                  AS is_weekend
FROM DateCTE
OPTION (MAXRECURSION 0);

SELECT COUNT(*) AS total_days FROM DimDate;
-- Expected: 11,323

-- ============================================================
-- SECTION 6 – FACT TABLES
-- ============================================================

-- ── FactListings ─────────────────────────────────────────────
-- Grain: one row per listing per snapshot (listing_id + snapshot_date)
-- Explicit column selection — only columns needed for analysis
-- LEFT JOIN preserves all listings even without dimension match
-- INNER JOIN would silently drop unmatched rows
--
-- JOIN vs STORED KEY — the ON clauses match on business/natural
-- keys (property_type, room_type, neighbourhood_cleansed, host_id)
-- because that's the only column listings shares with each Dim
-- table. What gets STORED below is the resolved surrogate key
-- (property_id, room_id, location_id) via ISNULL(..., 0) — never
-- the text value itself. host_id is the one natural exception:
-- DimHost uses host_id as its own PK (no separate surrogate was
-- generated), so storing host_id is correct there.

IF OBJECT_ID('FactListings', 'U') IS NOT NULL DROP TABLE FactListings;
 
SELECT 
    List.id                                     AS listing_id, -- Maps 1:1 to DimListings
    List.snapshot_date,
    ISNULL(H.host_id, 0)                        AS host_id,       
    ISNULL(P.property_id, 0)                    AS property_id,
    ISNULL(R.room_id, 0)                        AS room_id,
    ISNULL(L.location_id, 0)                    AS location_id,
    
    -- Numeric Measures (NULLs kept to preserve mathematical averages)
    -- 🔹 Strip formatting characters ($ and ,) and convert string to clean numeric data
    -- TRY_CAST returns NULL instead of erroring on unconvertible values
    TRY_CAST(
        REPLACE(REPLACE(List.price, '$', ''), ',', '') 
    AS DECIMAL(10,2))                           AS price,
    List.accommodates,
    List.bathrooms,
    List.bedrooms,
    List.beds,
    List.minimum_nights,
    List.maximum_nights,
    List.availability_365,
    List.number_of_reviews,
    List.number_of_reviews_ltm,
    List.number_of_reviews_ly,
    List.estimated_occupancy_l365d,
    List.estimated_revenue_l365d,
    List.reviews_per_month,
    -- 🔹 price_quote_* — added 2026-06-28 (see Section 3B for the
    -- ALTER TABLE / design rationale). NULL for any snapshot before
    -- this field existed — by design, not missing data.
    -- price_quote_raw is deliberately NOT pulled into FactListings —
    -- it stays archived in `listings` only, same treatment as
    -- `amenities`. Illustrative reference data, not a KPI — see the
    -- design decision note in Section 3B before building any
    -- cross-listing average or ranking on these fields.
    List.price_quote_checkin_date,
    List.price_quote_checkout_date,
    List.price_quote_total_price,
    List.price_quote_price_per_night,
    -- 🔹 License — snapshot-varying: needed to detect when a listing
    -- gains/loses its registration license between quarters. Moving
    -- this to DimListings (SCD Type 1) would overwrite and lose that
    -- signal — same reasoning as host_is_superhost below.
    -- Stored as two derived flags, not raw text — the registration
    -- number itself isn't needed for analysis:
    --   has_license    : 0/1, enables Lost/Gained License tracking
    --   license_status : 'Licensed' / 'Exempt' / 'Unknown'
    -- 'Exempt' is a real Airbnb platform value (listing legally
    -- excused from registration, not missing data) — confirmed via
    -- Airbnb Help Center, not documented in the local data dictionary.
    -- Treated as has_license = 0 (no registration number held) but
    -- kept distinct from 'Unknown' in license_status, since exempt
    -- and unreported are different compliance signals for investor risk.
    CASE 
        WHEN List.license IS NULL OR List.license = '' OR List.license = 'Exempt' THEN 0 
        ELSE 1 
    END AS has_license,
    CASE 
        WHEN List.license IS NULL OR List.license = '' THEN 'Unknown'
        WHEN List.license = 'Exempt' THEN 'Exempt'
        ELSE 'Licensed'
    END AS license_status,
    -- Review Scores (NULLs kept so unrated properties don't skew data to 0)
    List.review_scores_rating,
    List.review_scores_accuracy,
    List.review_scores_cleanliness,
    List.review_scores_checkin,
    List.review_scores_communication,
    List.review_scores_location,
    List.review_scores_value,
    
    -- Boolean flags (Converted to 1/0 for easy aggregation)
    CASE WHEN List.instant_bookable   = 't' THEN 1 ELSE 0 END AS instant_bookable,
    -- 🔹 Snapshot-varying host measure — moved here per SCD design
    -- decision (host 37177 lost Superhost status June → September 2025).
    -- Enables Lost/Gained/Retained Superhost analysis in Power BI.
    CASE WHEN List.host_is_superhost  = 't' THEN 1 ELSE 0 END AS host_is_superhost,
    
    -- Host snapshot counts (Missing data defaulted to 0 counts)
    ISNULL(List.calculated_host_listings_count, 0) AS calculated_host_listings_count,
    ISNULL(List.calculated_host_listings_count_entire_homes, 0) AS calc_listings_entire_homes,
    ISNULL(List.calculated_host_listings_count_private_rooms, 0) AS calc_listings_private_rooms,
    ISNULL(List.calculated_host_listings_count_shared_rooms, 0) AS calc_listings_shared_rooms,
    ISNULL(List.host_listings_count, 0)            AS host_listings_count,
    ISNULL(List.host_total_listings_count, 0)      AS host_total_listings_count
 
INTO FactListings
FROM listings AS List
    LEFT JOIN DimPropertyType  AS P  ON List.property_type          = P.property_type
    LEFT JOIN DimRoomType      AS R  ON List.room_type              = R.room_type
    LEFT JOIN DimLocation      AS L  ON List.neighbourhood_cleansed = L.neighbourhood_cleansed
    LEFT JOIN DimHost          AS H  ON List.host_id                = H.host_id;
 
-- 🔹 Composite PK: listing_id + snapshot_date
--    Same listing appears once per snapshot — neither alone is unique
ALTER TABLE FactListings ALTER COLUMN listing_id   BIGINT NOT NULL;
ALTER TABLE FactListings ALTER COLUMN snapshot_date DATE   NOT NULL;
ALTER TABLE FactListings ADD PRIMARY KEY (listing_id, snapshot_date);
 
SELECT TOP 5 * FROM FactListings;
SELECT DISTINCT has_license FROM FactListings;
SELECT DISTINCT license_status FROM FactListings;
 
-- 🔹 Verify price_quote_* fields — checks the RAW SOURCE table
-- (listings), not FactListings. This confirms the raw data itself
-- has the correct NULL/populated pattern across snapshots,
-- independent of whether FactListings' build logic (Section 6,
-- above) pulled these columns through correctly — two different
-- possible failure points, checked separately on purpose.
--
-- 5 sample rows per snapshot. Pre-2026 snapshots should show NULL
-- across all five columns (the field didn't exist yet — by design,
-- not missing data). 2026-06-28 onward should show real quote
-- data. See Section 3B for the full price_quote_* design decision.
WITH Sampled AS (
    SELECT
        snapshot_date,
        listing_id = id,
        price_quote_checkin_date,
        price_quote_checkout_date,
        price_quote_total_price,
        price_quote_price_per_night,
        price_quote_raw,
        ROW_NUMBER() OVER (PARTITION BY snapshot_date ORDER BY (SELECT NULL)) AS rn
    FROM listings
)
SELECT snapshot_date, listing_id, price_quote_checkin_date, price_quote_checkout_date, price_quote_total_price, price_quote_price_per_night, price_quote_raw
FROM Sampled
WHERE rn <= 5
ORDER BY snapshot_date, rn;

-- ── FactReviews ──────────────────────────────────────────────
-- Grain: one row per review — review_id is the natural unique key
-- Scope trimmed to counts/ratings/dates/trends only — no text
-- analysis planned, so comments (NVARCHAR(MAX)) and reviewer_name
-- are dropped. This avoids the large memory-grant request that
-- NVARCHAR(MAX) triggers on a large INSERT INTO ... SELECT (hit
-- RESOURCE_SEMAPHORE wait on SQL Server Express with the full
-- 6-column version).
-- reviewer_id kept — cheap BIGINT, still enables distinct
-- reviewer counts without pulling in review text.
--
-- ⚠️ Inside Airbnb's reviews.csv is not purely cumulative:
-- June 827,725 + Sept 874,286 → 903,845 deduplicated rows.
-- Overlap 798,166 | June-only 29,559 | Sept-only 76,120.
-- ~29.5K reviews present in June had disappeared by September —
-- likely delisted properties or moderated reviews, not a load error.
--
-- first_snapshot_date / is_active are REUSABLE across future
-- quarterly loads — no hardcoded dates. is_active always compares
-- against whatever the CURRENT latest snapshot_date in `reviews`
-- is at run time, so appending Q1 2026 (or any future quarter)
-- recalculates correctly with no script edits needed.
--
-- reviews.date confirmed as native DATE type (INFORMATION_SCHEMA
-- check) — CONVERT style argument has no effect on an already-typed
-- date source, kept as 103 (DD/MM/YYYY) for readability/consistency.

IF OBJECT_ID('FactReviews', 'U') IS NOT NULL DROP TABLE FactReviews;

CREATE TABLE FactReviews
(
    review_id           BIGINT NOT NULL PRIMARY KEY,
    listing_id          BIGINT NOT NULL,
    date                DATE   NOT NULL,
    reviewer_id         BIGINT NOT NULL,
    first_snapshot_date DATE   NOT NULL,  -- quarter this review was first captured in
    is_active           BIT    NOT NULL   -- 1 = still present in the latest snapshot
);

WITH ReviewSnapshots AS
(
    SELECT
        id,
        listing_id,
        date,
        reviewer_id,
        snapshot_date,
        MIN(snapshot_date) OVER (PARTITION BY id) AS first_snapshot_date,
        MAX(snapshot_date) OVER (PARTITION BY id) AS last_snapshot_date,
        ROW_NUMBER() OVER (PARTITION BY id ORDER BY snapshot_date DESC) AS rn
    FROM reviews
)
INSERT INTO FactReviews (review_id, listing_id, date, reviewer_id, first_snapshot_date, is_active)
SELECT
    id,
    listing_id,
    CONVERT(DATE, date, 103) AS date,
    reviewer_id,
    first_snapshot_date,
    CASE 
        WHEN last_snapshot_date = (SELECT MAX(snapshot_date) FROM reviews) THEN 1 
        ELSE 0 
    END AS is_active
FROM ReviewSnapshots
WHERE rn = 1;

SELECT TOP 5 * FROM FactReviews;
SELECT COUNT(*) AS review_count FROM FactReviews;
-- Expected: 903,845 for June + September

-- ============================================================
-- SECTION 7 – FOREIGN KEY CONSTRAINTS (optional — skipped)
-- Power BI manages relationships visually, and that's what this
-- project relies on. This section is NOT active — kept here as
-- reference only, for future you or a future project, in case
-- database-level enforcement is ever wanted.
--
-- WHAT IT WOULD DO: reject any INSERT/UPDATE that would create
-- an orphaned FK value (e.g. a host_id in FactListings that
-- doesn't exist in DimHost) — catches the mistake immediately
-- instead of it silently corrupting a Power BI report later.
--
-- TO ACTIVATE, IF EVER NEEDED — three steps, in order:
--   1. Add this block to the TOP of Section 4 (before any
--      dimension DROP TABLE runs), because DimHost/DimListings/
--      etc. cannot be dropped and rebuilt while a FK from
--      FactListings/FactReviews still references them:
--         IF OBJECT_ID('FactListings', 'U') IS NOT NULL DROP TABLE FactListings;
--         IF OBJECT_ID('FactReviews', 'U')  IS NOT NULL DROP TABLE FactReviews;
--   2. Uncomment the ALTER TABLE block below.
--   3. Before running, check for orphaned reviews (a review can
--      reference a listing_id that's been delisted and no longer
--      exists in the current listings snapshot):
--         SELECT COUNT(*) AS orphaned_reviews
--         FROM reviews r
--         WHERE NOT EXISTS (
--             SELECT 1 FROM DimListings d WHERE d.listing_id = r.listing_id
--         );
--      If non-zero, the FactReviews FK below will fail on load —
--      those rows need excluding or routing to a sentinel listing_id
--      first.
-- ============================================================

/*
ALTER TABLE FactListings ADD CONSTRAINT FK_FactListings_DimHost
    FOREIGN KEY (host_id) REFERENCES DimHost (host_id);
ALTER TABLE FactListings ADD CONSTRAINT FK_FactListings_DimPropertyType
    FOREIGN KEY (property_id) REFERENCES DimPropertyType (property_id);
ALTER TABLE FactListings ADD CONSTRAINT FK_FactListings_DimRoomType
    FOREIGN KEY (room_id) REFERENCES DimRoomType (room_id);
ALTER TABLE FactListings ADD CONSTRAINT FK_FactListings_DimLocation
    FOREIGN KEY (location_id) REFERENCES DimLocation (location_id);
ALTER TABLE FactReviews ADD CONSTRAINT FK_FactReviews_DimListings
    FOREIGN KEY (listing_id) REFERENCES DimListings (listing_id);
*/

-- ============================================================
-- SECTION 8 – PERFORMANCE INDEXES
-- Added AFTER data load — building indexes before the large
-- INSERT INTO ... SELECT statements significantly slows import,
-- since SQL Server rebuilds the index on every row inserted.
-- IF EXISTS before each DROP prevents "index does not exist"
-- error when the script is re-run on an already built database
--
-- Indexed on two grounds:
--   1. JOIN keys — every FK column used to relate to a Dim table
--      (host_id, room_id, property_id, location_id) — supports
--      any Power BI relationship or SQL-side JOIN.
--   2. Business questions the investor dashboard is built to
--      answer — filter/group columns those specific questions
--      hit repeatedly:
--        - "What's the price distribution by neighbourhood /
--           property type this quarter?" → price, snapshot_date
--        - "Which listings are unlicensed or exempt, and where?"
--           → license_status, has_license
--        - "Which hosts lost/gained Superhost status between
--           quarters?" → host_is_superhost, host_id
--        - "Is review volume growing or shrinking, and which
--           reviews are still active vs. dropped off?" →
--           FactReviews.is_active, first_snapshot_date
-- ============================================================

-- 🔹 FactListings — covers the most frequent join and filter
--    operations expected in Power BI investor analysis queries

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactListings_host_id'        AND object_id = OBJECT_ID('FactListings')) DROP INDEX IX_FactListings_host_id        ON FactListings;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactListings_room_id'        AND object_id = OBJECT_ID('FactListings')) DROP INDEX IX_FactListings_room_id        ON FactListings;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactListings_property_id'    AND object_id = OBJECT_ID('FactListings')) DROP INDEX IX_FactListings_property_id    ON FactListings;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactListings_location_id'    AND object_id = OBJECT_ID('FactListings')) DROP INDEX IX_FactListings_location_id    ON FactListings;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactListings_snapshot_date'  AND object_id = OBJECT_ID('FactListings')) DROP INDEX IX_FactListings_snapshot_date  ON FactListings;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactListings_price'         AND object_id = OBJECT_ID('FactListings')) DROP INDEX IX_FactListings_price          ON FactListings;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactListings_license_status' AND object_id = OBJECT_ID('FactListings')) DROP INDEX IX_FactListings_license_status ON FactListings;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactListings_superhost'      AND object_id = OBJECT_ID('FactListings')) DROP INDEX IX_FactListings_superhost      ON FactListings;

CREATE INDEX IX_FactListings_host_id        ON FactListings (host_id);                            -- JOIN to DimHost
CREATE INDEX IX_FactListings_room_id        ON FactListings (room_id);                            -- JOIN to DimRoomType
CREATE INDEX IX_FactListings_property_id    ON FactListings (property_id);                        -- JOIN to DimPropertyType
CREATE INDEX IX_FactListings_location_id    ON FactListings (location_id);                        -- JOIN to DimLocation
CREATE INDEX IX_FactListings_snapshot_date  ON FactListings (snapshot_date);                       -- filter by quarter
CREATE INDEX IX_FactListings_price          ON FactListings (price);                              -- investor price range filter
CREATE INDEX IX_FactListings_license_status ON FactListings (license_status);                     -- "which listings are unlicensed/exempt"
CREATE INDEX IX_FactListings_superhost      ON FactListings (host_is_superhost, snapshot_date);   -- Lost/Gained Superhost trend

-- 🔹 FactReviews — listing_id and date are the primary join and
--    filter keys; is_active and first_snapshot_date support the
--    review volume / churn trend questions

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactReviews_listing_id'  AND object_id = OBJECT_ID('FactReviews')) DROP INDEX IX_FactReviews_listing_id  ON FactReviews;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactReviews_date'       AND object_id = OBJECT_ID('FactReviews')) DROP INDEX IX_FactReviews_date        ON FactReviews;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactReviews_is_active'  AND object_id = OBJECT_ID('FactReviews')) DROP INDEX IX_FactReviews_is_active   ON FactReviews;

CREATE INDEX IX_FactReviews_listing_id ON FactReviews (listing_id);   -- JOIN reviews to listings
CREATE INDEX IX_FactReviews_date       ON FactReviews (date);         -- filter by review date / year
CREATE INDEX IX_FactReviews_is_active  ON FactReviews (is_active);    -- "reviews still active vs. dropped off"


-- 🔹 QA — confirm indexes exist and are active after every rebuild
SELECT 
    t.name AS [Table Name],
    i.name AS [Index Name],
    i.type_desc AS [Index Type],
    i.is_disabled AS [Is Disabled]
FROM sys.indexes i
INNER JOIN sys.tables t ON i.object_id = t.object_id
WHERE t.name IN ('FactListings', 'FactReviews')
  AND i.name LIKE 'IX_%';
-- Expected: 8 rows for FactListings, 3 rows for FactReviews,
-- all Is Disabled = 0


/*
========================================================================================
⚡ DATABASE INDEXING STRATEGY FOR BI REPORTING & POWER BI WORKLOADS ⚡
========================================================================================

1. PURPOSE & PERFORMANCE IMPACT:
   - This script builds highly optimized physical lookup structures (B-Trees) designed 
     to handle intensive analytical queries generated by Power BI.
   - Without these indexes, SQL Server must perform slow "Table Scans" — reading millions 
     of rows from top to bottom (O(N) complexity) whenever a user clicks a visual or slicer.
   - By creating these indexes, we enable fast "Index Seeks" (O(log N) complexity), 
     essentially creating a physical "XLOOKUP" cheat-sheet for the database engine.

2. WHY WE INDEX SPECIFIC COLUMNS:
   - Foreign Keys (FKs): Indexing host_id, room_id, etc., prevents performance bottlenecks 
     during multi-table JOINs. (Note: SQL Server does NOT automatically index FKs!)
   - Range & Slicer Columns: Indexing snapshot_date and price speeds up time-series 
     analysis and custom price filtering.
   - Categorical Fields: Indexing status columns allows rapid, server-side groupings and counts.
   - Composite Indexes: Multi-column indexes are structured based on the Left-Prefix Rule 
     to accelerate complex historical trends (e.g., tracking Superhosts over time).

3. INTEGRATION WITH POWER BI RELATIONSHIPS:
   - These indexes do not load into Power BI as tables; they run silently under the hood.
   - While Power BI's relationship lines define the LOGICAL flow of data, these SQL indexes 
     act as the PHYSICAL high-speed highways that execute those queries in milliseconds.

4. TRADE-OFF — WRITE COST:
   - Every index adds overhead to INSERT/UPDATE/DELETE, since SQL Server must maintain
     the B-Tree on every row written, not just at query time. This is why indexes are
     built AFTER the data load in this script, not before — building them first would
     slow every row during the large INSERT INTO ... SELECT statements that populate
     FactListings and FactReviews.
========================================================================================
*/



-- ============================================================
-- SECTION 9 – QA QUERIES
-- ============================================================

-- 🔹 Confirm all tables were created
SELECT TABLE_NAME
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE = 'BASE TABLE'
ORDER BY TABLE_NAME;
-- Expected: DimDate, DimHost, DimListings, DimLocation,
--           DimPropertyType, DimRoomType,
--           FactListings, FactReviews, listings, reviews

-- 🔹 Confirm row counts
SELECT 'FactListings'    AS table_name, COUNT(*) AS row_count FROM FactListings
UNION ALL
SELECT 'FactReviews',                   COUNT(*)              FROM FactReviews
UNION ALL
SELECT 'DimHost',                       COUNT(*)              FROM DimHost
UNION ALL
SELECT 'DimListings',                   COUNT(*)              FROM DimListings
UNION ALL
SELECT 'DimRoomType',                   COUNT(*)              FROM DimRoomType
UNION ALL
SELECT 'DimPropertyType',               COUNT(*)              FROM DimPropertyType
UNION ALL
SELECT 'DimLocation',                   COUNT(*)              FROM DimLocation
UNION ALL
SELECT 'DimDate',                       COUNT(*)              FROM DimDate;

-- 🔹 Verify sentinel records exist in every dimension
SELECT 'DimRoomType'     AS dim, room_id     AS id, room_type              AS val FROM DimRoomType     WHERE room_id     = 0
UNION ALL
SELECT 'DimPropertyType',        property_id,       property_type                  FROM DimPropertyType WHERE property_id = 0
UNION ALL
SELECT 'DimLocation',            location_id,       neighbourhood_cleansed         FROM DimLocation     WHERE location_id = 0
UNION ALL
SELECT 'DimHost',                host_id,           host_name                      FROM DimHost         WHERE host_id     = 0
UNION ALL
SELECT 'DimListings',            listing_id,        name                           FROM DimListings     WHERE listing_id  = 0;

-- 🔹 Check for orphaned fact records
SELECT COUNT(*) AS orphaned_host_ids
FROM FactListings F
WHERE NOT EXISTS (SELECT 1 FROM DimHost H WHERE H.host_id = F.host_id);
-- Expected: 0

SELECT COUNT(*) AS orphaned_review_listing_ids
FROM FactReviews R
WHERE NOT EXISTS (SELECT 1 FROM DimListings L WHERE L.listing_id = R.listing_id);
-- Non-zero here is expected/known — some reviews reference listings
-- delisted before the current snapshot (see FactReviews section notes)

-- 🔹 Snapshot distribution
SELECT
    snapshot_date,
    COUNT(DISTINCT listing_id)  AS distinct_listings,
    COUNT(*)                    AS total_rows
FROM FactListings
GROUP BY snapshot_date
ORDER BY snapshot_date;

-- 🔹 Price distribution by snapshot
SELECT
    snapshot_date,
    MIN(price)                              AS min_price,
    MAX(price)                              AS max_price,
    ROUND(AVG(price), 2)                    AS avg_price
FROM FactListings
GROUP BY snapshot_date
ORDER BY snapshot_date;

-- 🔹 License status distribution
SELECT license_status, has_license, COUNT(*) AS listing_count
FROM FactListings
GROUP BY license_status, has_license
ORDER BY listing_count DESC;

-- 🔹 Review volume by year, and active vs. dropped-off split
SELECT YEAR(date) AS review_year, COUNT(*) AS review_count
FROM FactReviews
GROUP BY YEAR(date)
ORDER BY review_year;

SELECT is_active, COUNT(*) AS review_count
FROM FactReviews
GROUP BY is_active;
-- Expected: is_active=1 → 874,286 | is_active=0 → 29,559

-- 🔹 DimDate covers all review dates
SELECT MIN(date) AS min_review, MAX(date) AS max_review FROM FactReviews;
SELECT MIN(date) AS dim_start,  MAX(date) AS dim_end   FROM DimDate;

-- ============================================================
-- END OF SCRIPT
-- Next step: Connect Airbnb_Athens_Database to Power BI Desktop
-- for Phase 2 – Dashboard Visualization
-- Quarterly loads: Airbnb_Athens_quarterly_load.sql
-- (to be exported once this main script is finalized)
-- ============================================================

