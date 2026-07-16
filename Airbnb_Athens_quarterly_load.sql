-- ============================================================
-- PROJECT  : Airbnb Athens Data Warehouse
-- PHASE    : 1B – Quarterly Load (recurring script)
-- AUTHOR   : Aristea Kampanaraki
-- SOURCE   : Inside Airbnb – Athens, Greece (new quarterly snapshot)
-- PAIRS WITH: Airbnb_Athens_star_schema.sql (Section 2, part D)
--
-- HOW TO USE THIS SCRIPT
-- Find/replace the placeholder YYYY-MM-DD everywhere in this file
-- with the new snapshot date (e.g. 2025-12-18), then run top to
-- bottom. Steps mirror Section 2 (part D) of the main build
-- script — see that file for the full design rationale.
--
-- BEFORE RUNNING:
--   1. Import new listings/reviews CSVs via wizard
--      → table names: YYYY-MM-DD_listings / YYYY-MM-DD_reviews
--      → apply the same Modify Columns overrides as the main
--        script Section 1 (price → nvarchar(20), host_is_superhost
--        → nvarchar(1), etc.)
--      → do NOT set a Primary Key on either wizard table
--   2. Import the new neighbourhoods.csv via wizard
--      → table name: YYYY-MM-DD_neighbourhoods
--   3. Replace YYYY-MM-DD with the current quarter date, in
--      same format, everywhere in this script
-- ============================================================

USE [Airbnb_Athens_Database];
GO

-- ============================================================
-- STEP 1 – GUARD AGAINST RE-LOADING AN ALREADY-LOADED SNAPSHOT
-- Run this before touching anything. If this snapshot_date is
-- already in `listings`, Steps 3-6 would silently duplicate it
-- into your historical tables — and you wouldn't find out until
-- FactListings' composite PK (listing_id + snapshot_date) fails
-- during the Step 11 rebuild, by which point the wizard staging
-- tables are already dropped (Step 7) and the duplicate rows are
-- stuck in `listings`/`reviews` needing manual cleanup. Catching
-- it here costs nothing.
-- ============================================================

IF EXISTS (SELECT 1 FROM listings WHERE snapshot_date = 'YYYY-MM-DD')
BEGIN
    RAISERROR('Snapshot YYYY-MM-DD already exists in listings — aborting to prevent a duplicate load. Check you have the right date before re-running.', 16, 1);
    RETURN;
END
ELSE
BEGIN
    PRINT 'Snapshot YYYY-MM-DD not yet loaded — proceeding.';
END

-- ============================================================
-- STEP 2 – VERIFY AFTER WIZARD IMPORT
-- Run this BEFORE Step 3 touches the table — confirms the wizard
-- did its job correctly (right columns, right types, no accidental
-- PK) while the table is still in its raw, untouched state. Fix
-- anything wrong here in the wizard now — once Step 3 drops
-- columns, this raw baseline is gone.
--
-- ⚠️ 2026-06-28 baseline: 90 raw columns, not the original 79.
-- Inside Airbnb added 11 new fields this quarter — Step 3 drops 6
-- as redundant and keeps 5 (the price_quote_* fields). See Step
-- 3's drop list for the column-by-column breakdown.
-- ============================================================

-- Row counts
SELECT 'listings'      AS table_name, COUNT(*) AS row_count FROM [YYYY-MM-DD_listings]
UNION ALL
SELECT 'reviews',      COUNT(*) FROM [YYYY-MM-DD_reviews]
UNION ALL
SELECT 'neighbourhoods', COUNT(*) FROM [YYYY-MM-DD_neighbourhoods];

-- Column counts — listings should read 79 (raw, before Step 3 drops down to 57)
SELECT TABLE_NAME, COUNT(*) AS col_count
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME IN ('YYYY-MM-DD_listings', 'YYYY-MM-DD_reviews', 'YYYY-MM-DD_neighbourhoods')
GROUP BY TABLE_NAME;

-- Confirm no accidental Primary Key was set in the wizard (should return 0 rows for all three)
SELECT TABLE_NAME, CONSTRAINT_NAME
FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS
WHERE TABLE_NAME IN ('YYYY-MM-DD_listings', 'YYYY-MM-DD_reviews')
AND CONSTRAINT_TYPE = 'PRIMARY KEY';

-- Spot-check the wizard applied your Modify Columns overrides correctly
SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'YYYY-MM-DD_listings'
AND COLUMN_NAME IN ('id', 'host_id', 'price', 'host_is_superhost', 'instant_bookable');
-- Expect: id/host_id = bigint, price = nvarchar(20), host_is_superhost/instant_bookable = nvarchar(1)

-- ============================================================
-- STEP 3 – DROP UNNECESSARY COLUMNS FROM THE NEW WIZARD TABLE
-- Same drop list as main script Section 1 — brings the wizard
-- table down to the same 57 analytical columns that `listings`
-- carries from raw import (before snapshot_date / property_category
-- are added).
-- Original 21-column drop list, PLUS 6 new columns first seen
-- in the 2026-06-28 export, dropped as redundant (see comments).
-- ============================================================

ALTER TABLE [2026-06-28_listings] DROP COLUMN
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
    last_review,
    -- New columns introduced by Airbnb, first seen 2026-06-28 export — dropped as
    -- redundant with existing fields already kept elsewhere in this table
    host_profile_id,              -- redundant with host_id, which every join already keys on
    host_profile_url,             -- redundant with host_id / host_url
    hosts_time_as_user_years,     -- redundant with host_since (computable via DATEDIFF anytime)
    hosts_time_as_user_months,    -- redundant with host_since
    hosts_time_as_host_years,     -- redundant with host_since
    hosts_time_as_host_months;    -- redundant with host_since;

-- 🔹 Verify column count before proceeding — should read 62 after 28-june 2026
-- (57 original baseline + 5 new price_quote_* columns kept: total_price,
-- price_per_night, checkin_date, checkout_date, raw)
SELECT COUNT(*) AS wizard_col_count
FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'YYYY-MM-DD_listings';
-- If this isn't 62, the drop list above and the column list in
-- Step 6 have drifted apart — reconcile before continuing.

-- ============================================================
-- STEP 4 – ADD snapshot_date TO THE NEW WIZARD TABLES
-- IF NOT EXISTS guard — safe to re-run if the script fails
-- partway through and is restarted.
-- ============================================================

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'YYYY-MM-DD_listings' AND COLUMN_NAME = 'snapshot_date'
)
ALTER TABLE [YYYY-MM-DD_listings] ADD snapshot_date DATE;

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'YYYY-MM-DD_reviews' AND COLUMN_NAME = 'snapshot_date'
)
ALTER TABLE [YYYY-MM-DD_reviews] ADD snapshot_date DATE;

-- ============================================================
-- STEP 5 – TAG THE NEW SNAPSHOT ROWS
-- Tag BEFORE merging so rows are identifiable once both
-- snapshots coexist in the main tables.
-- ============================================================

UPDATE [YYYY-MM-DD_listings] SET snapshot_date = 'YYYY-MM-DD';
UPDATE [YYYY-MM-DD_reviews]  SET snapshot_date = 'YYYY-MM-DD';

-- 🔹 Verify every row got tagged — should read 0 for both
SELECT
    (SELECT COUNT(*) FROM [YYYY-MM-DD_listings] WHERE snapshot_date IS NULL) AS untagged_listings,
    (SELECT COUNT(*) FROM [YYYY-MM-DD_reviews]  WHERE snapshot_date IS NULL) AS untagged_reviews;

-- ============================================================
-- STEP 6 – APPEND INTO MAIN TABLES
-- ⚠️ `listings` now carries 64 columns at rest (57 raw-kept +
-- snapshot_date + property_category + 5 price_quote_* fields),
-- but the wizard table only reaches 63 — property_category still
-- gets filled in by Step 8, as always.
--
-- price_quote_* — new fields, first seen 2026-06-28, didn't exist
-- in the original 79-column structure. Guarded with IF NOT EXISTS
-- (same pattern as snapshot_date/property_category), so older
-- snapshots automatically read NULL — meaning "didn't exist yet,"
-- not missing data. Kept as text, not DECIMAL/DATE — mixed date
-- formats observed across rows, parse via TRY_CONVERT downstream.
-- Treat as illustrative reference data, not a comparable KPI —
-- each quote reflects a different date range per listing.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'listings' AND COLUMN_NAME = 'price_quote_total_price')
ALTER TABLE listings ADD price_quote_total_price NVARCHAR(20) NULL;

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'listings' AND COLUMN_NAME = 'price_quote_price_per_night')
ALTER TABLE listings ADD price_quote_price_per_night NVARCHAR(20) NULL;

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'listings' AND COLUMN_NAME = 'price_quote_checkin_date')
ALTER TABLE listings ADD price_quote_checkin_date NVARCHAR(20) NULL;

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'listings' AND COLUMN_NAME = 'price_quote_checkout_date')
ALTER TABLE listings ADD price_quote_checkout_date NVARCHAR(20) NULL;

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'listings' AND COLUMN_NAME = 'price_quote_raw')
ALTER TABLE listings ADD price_quote_raw NVARCHAR(MAX) NULL;

INSERT INTO listings (
    id, listing_url, name, description, picture_url, host_id,
    host_url, host_name, host_since, host_location, host_about, host_response_time,
    host_response_rate, host_acceptance_rate, host_is_superhost, host_picture_url, host_neighbourhood, host_listings_count,
    host_total_listings_count, host_verifications, host_has_profile_pic, host_identity_verified, neighbourhood, neighbourhood_cleansed,
    latitude, longitude, property_type, room_type, accommodates, bathrooms,
    bathrooms_text, bedrooms, beds, amenities, price, minimum_nights,
    maximum_nights, availability_365, number_of_reviews, number_of_reviews_ltm, number_of_reviews_ly, estimated_occupancy_l365d,
    estimated_revenue_l365d, price_quote_checkin_date, price_quote_checkout_date, price_quote_total_price, price_quote_price_per_night, price_quote_raw,
    review_scores_rating, review_scores_accuracy, review_scores_cleanliness, review_scores_checkin, review_scores_communication,
    review_scores_location, review_scores_value, license, instant_bookable, calculated_host_listings_count, calculated_host_listings_count_entire_homes,
    calculated_host_listings_count_private_rooms, calculated_host_listings_count_shared_rooms, reviews_per_month, snapshot_date
)
SELECT
    id, listing_url, name, description, picture_url, host_id,
    host_url, host_name, host_since, host_location, host_about, host_response_time,
    host_response_rate, host_acceptance_rate, host_is_superhost, host_picture_url, host_neighbourhood, host_listings_count,
    host_total_listings_count, host_verifications, host_has_profile_pic, host_identity_verified, neighbourhood, neighbourhood_cleansed,
    latitude, longitude, property_type, room_type, accommodates, bathrooms,
    bathrooms_text, bedrooms, beds, amenities, price, minimum_nights,
    maximum_nights, availability_365, number_of_reviews, number_of_reviews_ltm, number_of_reviews_ly, estimated_occupancy_l365d,
    estimated_revenue_l365d, price_quote_checkin_date, price_quote_checkout_date, price_quote_total_price, price_quote_price_per_night, price_quote_raw,
    review_scores_rating, review_scores_accuracy, review_scores_cleanliness, review_scores_checkin, review_scores_communication,
    review_scores_location, review_scores_value, license, instant_bookable, calculated_host_listings_count, calculated_host_listings_count_entire_homes,
    calculated_host_listings_count_private_rooms, calculated_host_listings_count_shared_rooms, reviews_per_month, snapshot_date
FROM [YYYY-MM-DD_listings];

INSERT INTO reviews SELECT * FROM [YYYY-MM-DD_reviews];
-- reviews doesn't have this problem — the wizard table's column
-- set matches the main reviews table exactly, no derived columns
-- are ever added to it, so SELECT * is safe here.

-- 🔹 Verify all snapshots present
SELECT 'listings' AS table_name, snapshot_date, COUNT(*) AS row_count
FROM listings GROUP BY snapshot_date
UNION ALL
SELECT 'reviews', snapshot_date, COUNT(*)
FROM reviews GROUP BY snapshot_date
ORDER BY table_name, snapshot_date;

-- 🔹 Verify row counts match BEFORE dropping the wizard tables —
-- once Step 7 drops them, this is unrecoverable. wizard_count and
-- appended_count must be equal on both rows below.
SELECT 'listings' AS table_name,
    (SELECT COUNT(*) FROM [YYYY-MM-DD_listings]) AS wizard_count,
    (SELECT COUNT(*) FROM listings WHERE snapshot_date = 'YYYY-MM-DD') AS appended_count
UNION ALL
SELECT 'reviews',
    (SELECT COUNT(*) FROM [YYYY-MM-DD_reviews]) AS wizard_count,
    (SELECT COUNT(*) FROM reviews WHERE snapshot_date = 'YYYY-MM-DD') AS appended_count;
-- ⚠️ If either row shows a mismatch, STOP — do not proceed to Step 7.
-- Investigate before the wizard tables become unrecoverable.


-- 🔹 Verify price_quote_* fields — checks the RAW SOURCE table (listings)
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

-- ============================================================
-- STEP 7 – DROP WIZARD STAGING TABLES
-- Data is now safely in listings / reviews.
-- ============================================================

DROP TABLE [YYYY-MM-DD_listings];
DROP TABLE [YYYY-MM-DD_reviews];

-- ============================================================
-- STEP 8 – TAG property_category FOR NEW ROWS ONLY
-- Same CASE logic as main script Section 3B, scoped with
-- WHERE property_category IS NULL so existing snapshots keep
-- their prior tag untouched. This is also what backfills the
-- NULL left behind by Step 6's explicit column list, since
-- property_category isn't populated at insert time.
-- ============================================================

UPDATE listings
SET property_category = CASE
    -- Entire properties — highest revenue potential
    WHEN property_type LIKE 'Entire%'
      OR property_type = 'Cycladic home'      THEN 'Entire Property'
    -- Private rooms — mid-range, shared infrastructure
    WHEN property_type LIKE 'Private room%'
      OR property_type = 'Casa particular'    THEN 'Private Room'
    -- Shared rooms — budget segment
    WHEN property_type LIKE 'Shared room%'    THEN 'Shared Room'
    -- Hotel-style — professional operators
    WHEN property_type LIKE '%hotel%'
      OR property_type LIKE '%aparthotel%'
      OR property_type LIKE '%serviced%'      THEN 'Hotel / Serviced'
    -- Unique / unusual properties — niche, not comparable
    -- for standard investment analysis
    WHEN property_type IN ('Boat', 'Barn',
        'Camper/RV', 'Tent', 'Cave',
        'Earthen home', 'Tiny home', 'Floor', 'Castle') THEN 'Unique / Other'
    -- Catch-all — folded into Unique / Other (no separate 'Other' bucket).
    -- Check property_types_included below periodically to catch any
    -- genuinely new/unclassified property_type values from future scrapes.
    ELSE 'Unique / Other'
END
WHERE property_category IS NULL;

-- 🔹 Verify no rows were missed
SELECT COUNT(*) AS untagged_rows FROM listings WHERE property_category IS NULL;
-- Expected: 0

-- 🔹 Verify distinct property categories
SELECT DISTINCT property_category       FROM listings;

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
-- STEP 9 – DimLocation: CHECK FOR NEW NEIGHBOURHOODS
-- Inside Airbnb rarely changes the Athens neighbourhood list,
-- but check every quarter before rebuilding the star schema.
-- ⚠️ PLACEHOLDER — find/replace [YYYY-MM-DD_neighbourhoods] with
-- the actual wizard table name for this quarter before running.
-- This block will error (invalid object name) if run as-is.
-- ============================================================

SELECT neighbourhood
FROM [YYYY-MM-DD_neighbourhoods]
WHERE neighbourhood NOT IN (SELECT neighbourhood_cleansed FROM DimLocation)
AND neighbourhood IS NOT NULL;

-- If rows are returned, review them before inserting — Greek text encoding
-- issues elsewhere in this pipeline mean a "new" neighbourhood could be a
-- mangled duplicate of an existing one, not genuinely new. Only run the
-- INSERT below after eyeballing the SELECT results above.
/*
INSERT INTO DimLocation (neighbourhood_cleansed)
SELECT neighbourhood FROM [YYYY-MM-DD_neighbourhoods]
WHERE neighbourhood NOT IN (SELECT neighbourhood_cleansed FROM DimLocation);
*/

-- 🔹 Verify before dropping reference table
SELECT COUNT(*) AS location_count FROM DimLocation;
SELECT * FROM DimLocation ORDER BY neighbourhood_cleansed;

-- 🔹 Drop the reference table after the check
DROP TABLE [YYYY-MM-DD_neighbourhoods];

-- ============================================================
-- STEP 10 – DUPLICATE (id, snapshot_date) DATA QUALITY GATE
-- Same check as main script Section 3E. FactListings' rebuild in
-- Step 11 enforces a composite PK on (listing_id, snapshot_date) —
-- if any duplicate exists here, that rebuild fails with a raw PK
-- violation error. Catching it here gives a clear signal instead.
-- ============================================================

SELECT id, snapshot_date, COUNT(*) AS duplicates
FROM listings
GROUP BY id, snapshot_date
HAVING COUNT(*) > 1;
-- Expected: 0 rows. If any are returned, resolve before Step 11.

-- ============================================================
-- STEP 11 – REBUILD THE STAR SCHEMA
-- Dimensions, FactListings, FactReviews and indexes are all
-- fully derived — safe to drop and rebuild from `listings` /
-- `reviews`, which now hold every snapshot to date.
-- Run Sections 4B through 8 of Airbnb_Athens_star_schema.sql
-- in order:
--   Section 4B – DimRoomType, DimPropertyType, DimHost, DimListings
--                (Section 4A – DimLocation is already handled by
--                 Step 9 above — skip that block this run)
--   Section 5  – DimDate (only if extending past 2030-12-31;
--                otherwise this table doesn't need to be touched)
--   Section 6  – FactListings, FactReviews
--   Section 8  – Performance indexes
-- ============================================================

-- ============================================================
-- STEP 12 – POST-LOAD QA
-- Reuse Section 9 of the main script in full. At minimum check:
-- ============================================================

SELECT 'FactListings' AS table_name, COUNT(*) AS row_count FROM FactListings
UNION ALL
SELECT 'FactReviews', COUNT(*) FROM FactReviews;

SELECT COUNT(*) AS orphaned_host_ids
FROM FactListings F
WHERE NOT EXISTS (SELECT 1 FROM DimHost H WHERE H.host_id = F.host_id);
-- Expected: 0

SELECT snapshot_date, COUNT(DISTINCT listing_id) AS distinct_listings, COUNT(*) AS total_rows
FROM FactListings GROUP BY snapshot_date ORDER BY snapshot_date;


-- TOP 5 queries — all 8 star schema tables

USE [Airbnb_Athens_Database];
GO

SELECT TOP 5 * FROM DimHost         ORDER BY host_id;
SELECT TOP 5 * FROM DimListings     ORDER BY listing_id;
SELECT TOP 5 * FROM DimLocation     ORDER BY location_id;
SELECT TOP 5 * FROM DimPropertyType ORDER BY property_id;
SELECT TOP 5 * FROM DimRoomType     ORDER BY room_id;
SELECT TOP 5 * FROM DimDate         ORDER BY date_id;
SELECT TOP 5 * FROM FactListings    ORDER BY listing_id, snapshot_date;
SELECT TOP 5 * FROM FactReviews     ORDER BY review_id;

-- ============================================================
-- END OF QUARTERLY LOAD SCRIPT
-- ============================================================

