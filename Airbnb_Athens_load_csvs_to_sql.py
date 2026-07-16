r"""
Airbnb Athens Data Warehouse — CSV Loader
==========================================
Replaces the manual "Import Flat File" wizard step (Section 1 of
Airbnb_Athens_star_schema.sql) with a repeatable script, so you can
tear down and rebuild the raw staging tables for testing without
clicking through the wizard every time.

SCOPE: listings only. Reviews and neighbourhoods are NOT loaded by
this script — it loads `listings` exclusively, and will skip any
`_reviews` or `_neighbourhoods` file it finds with a message telling
you so, rather than loading it.
For `reviews`, use the wizard: reviews tables run into the hundreds
of thousands of rows, and this script's insert has to run with
pyodbc's fast_executemany turned OFF (a pyodbc buffer-sizing bug with
variable-length text columns makes fast_executemany unreliable on
real data — see the comment above cursor.fast_executemany in
load_csv() below), which is significantly slower than the wizard's
native bulk copy. Reviews only has 5 columns to configure in the
wizard's Modify Columns step, so the wizard is the faster path there.
For `neighbourhoods`, use the wizard too — it's a tiny file (tens of
rows) that only ever needs loading once per quarter, and the wizard's
manual overrides for it are minimal, so there's no real time saved by
scripting it.
(Reviews/neighbourhoods support can be re-enabled — see
FILE_PATTERNS below.)

INTENDED WORKFLOW: this script is meant to be re-run once per new
quarter, loading only that quarter's listings — not re-loading
quarters you've already brought in. Control this with the
INCLUDE_SUBFOLDERS setting in CONFIG below: point it at just the new
quarter's subfolder each time, rather than leaving it empty (which
would re-scan every quarter under CSV_DIR, including ones already
loaded — harmless, since re-running just recreates the same staging
tables, but slower and unnecessary).

WHAT THIS DOES
  - Creates the target database if it doesn't already exist
  - For each CSV, creates a staging table named after the CSV
    filename (matching the wizard's own naming convention:
    2025-12-15_listings.csv -> table [2025-12-15_listings])
  - Applies the EXACT column type overrides documented in Section 1
    of the main build script (price stays text, booleans stay
    single-char text, review scores become DECIMAL(4,2), etc.) —
    this matters because the star schema build logic depends on
    these specific raw types. Letting pandas auto-infer types would
    silently break TRY_CAST/REPLACE logic downstream.
  - Checks real data against every assumed type before creating the
    table, and auto-corrects (with a printed explanation) if a
    column's actual values don't fit — e.g. a text column longer
    than expected, or a column assumed to be a whole number that
    actually contains decimals
  - Applies the NOT NULL constraints documented in Section 1
  - Does NOT set a Primary Key on any table — same as the wizard
    instructions (composite PK is enforced later, in FactListings)

WHAT THIS DOES NOT DO
  - Doesn't drop unnecessary columns (Section 1's ALTER TABLE DROP
    COLUMN step) — run that from the SQL script yourself afterward,
    same as you would after a real wizard import
  - Doesn't run any of the star schema build (Sections 2 onward) —
    this script's only job is standing in for the wizard

SETUP
  This script must be run from an Anaconda-managed Python — a
  standalone IDLE or Spyder install (one not launched through
  Anaconda Navigator) may be a completely different Python
  interpreter with its own separate packages, and won't have
  pandas/pyodbc installed even if you've already installed them
  once. Use the Anaconda terminal for both setup and running:

  1. Open Anaconda Navigator
  2. Environments tab -> select your environment (e.g. base) ->
     green Play button -> "Open Terminal"
  3. In that terminal:
       conda install pandas pyodbc
     (or, if that fails: pip install pandas pyodbc)
  4. Confirm your ODBC driver is installed:
       python -c "import pyodbc; print(pyodbc.drivers())"
     'ODBC Driver 17 for SQL Server' (or 18) should appear in the
     printed list. If not, install it from Microsoft first.

USAGE
  1. Edit the CONFIG block below (SERVER, DATABASE, CSV_DIR, etc.)
  2. In the same Anaconda terminal from SETUP above:
       cd path\to\folder\containing\this\script
       python Airbnb_Athens_load_csvs_to_sql.py

  Each CSV filename must already follow the wizard naming
  convention: YYYY-MM-DD_listings.csv, YYYY-MM-DD_reviews.csv,
  YYYY-MM-DD_neighbourhoods.csv
"""

import os
import re
import sys
import glob
import pandas as pd
import pyodbc

# ============================================================
# CONFIG — edit these before running
# ============================================================
 
SERVER = r"localhost\SQLEXPRESS"      
DATABASE = "Airbnb_Athens_Database"   
DRIVER = "{ODBC Driver 17 for SQL Server}"  # check `pyodbc.drivers()` if this fails
CSV_DIR = r"C:\path\to\Quarter_files"
                                       # dedicated data-only folder — contains just the
                                       # quarter subfolders, nothing else to filter out
INCLUDE_SUBFOLDERS = ["YYYY-MM-DD"]
                                       # THE ONE LINE TO CHANGE EACH NEW QUARTER.
                                       # Only files in these subfolder(s) get loaded —
                                       # already-loaded quarters are left alone, not
                                       # re-scanned. When a new quarter arrives:
                                       # create its subfolder under CSV_DIR, drop the
                                       # new _listings.csv in it, then update this
                                       # list to just that folder's name before
                                       # running.
                                       # [] = include every subfolder instead (rarely
                                       # what you want for a routine quarterly run).
                                       # Only _listings files are actually loaded —
                                       # see SCOPE at the top of this file for why
                                       # reviews/neighbourhoods are handled separately.
TRUSTED_CONNECTION = True             # True = Windows auth, False = username/password below
UID = ""
PWD = ""

# ============================================================
# COLUMN TYPE OVERRIDES
# Copied directly from Section 1's "WIZARD SCHEMA FIXES" tables.
# Any column NOT listed here falls back to a generic type via
# infer_fallback_type() below.
# ============================================================

LISTINGS_OVERRIDES = {
    "id": "BIGINT",
    "host_id": "BIGINT",
    "host_name": "NVARCHAR(100)",
    "host_is_superhost": "NVARCHAR(1)",
    "host_has_profile_pic": "NVARCHAR(1)",
    "host_identity_verified": "NVARCHAR(1)",
    "price": "NVARCHAR(20)",
    "amenities": "NVARCHAR(MAX)",
    "number_of_reviews_ltm": "SMALLINT",
    "number_of_reviews_ly": "SMALLINT",
    "review_scores_rating": "DECIMAL(4,2)",
    "review_scores_accuracy": "DECIMAL(4,2)",
    "review_scores_cleanliness": "DECIMAL(4,2)",
    "review_scores_checkin": "DECIMAL(4,2)",
    "review_scores_communication": "DECIMAL(4,2)",
    "review_scores_location": "DECIMAL(4,2)",
    "review_scores_value": "DECIMAL(4,2)",
    "reviews_per_month": "DECIMAL(5,2)",
    "instant_bookable": "NVARCHAR(1)",
}

LISTINGS_NOT_NULL = {
    "id", "host_id", "latitude", "longitude", "neighbourhood_cleansed",
    "property_type", "room_type", "accommodates", "minimum_nights",
}

REVIEWS_OVERRIDES = {
    "listing_id": "BIGINT",
    "id": "BIGINT",
    "reviewer_id": "BIGINT",
    "reviewer_name": "NVARCHAR(100)",
    "comments": "NVARCHAR(MAX)",
}

REVIEWS_NOT_NULL = {"listing_id", "id", "date", "reviewer_id"}

NEIGHBOURHOODS_OVERRIDES = {
    "neighbourhood_group": "NVARCHAR(50)",
    "neighbourhood": "NVARCHAR(100)",
}

NEIGHBOURHOODS_NOT_NULL = {"neighbourhood"}

# Which override/not-null set applies to which file, matched by
# suffix of the CSV filename (before .csv)
# Which override/not-null set applies to which file, matched by
# suffix of the CSV filename (before .csv).
# _reviews is deliberately NOT included here — see RECOMMENDED USE
# at the top of this file. REVIEWS_OVERRIDES/REVIEWS_NOT_NULL are
# kept above as reference in case you want to re-enable it later —
# just add "_reviews": (REVIEWS_OVERRIDES, REVIEWS_NOT_NULL) back in.
# Which override/not-null set applies to which file, matched by
# suffix of the CSV filename (before .csv).
# _listings is the only active pattern — _reviews and _neighbourhoods
# are deliberately NOT included here. See SCOPE at the top of this
# file. Their override definitions are kept above as reference in
# case you want to re-enable either later — just add the matching
# entry back in, e.g. "_neighbourhoods": (NEIGHBOURHOODS_OVERRIDES, NEIGHBOURHOODS_NOT_NULL).
FILE_PATTERNS = {
    "_listings": (LISTINGS_OVERRIDES, LISTINGS_NOT_NULL),
}


def infer_fallback_type(column_name: str) -> str:
    """
    Generic fallback for any column not explicitly overridden above.
    Deliberately simple and predictable rather than data-driven —
    these are raw staging columns that get cleaned/cast downstream
    in the star schema build anyway, so a generous NVARCHAR is safe.
    """
    lower = column_name.lower()
    if lower == "id" or lower.endswith("_id"):
        return "BIGINT"
    if lower in ("latitude", "longitude"):
        return "FLOAT"
    if lower.endswith("_date") or lower in ("date", "host_since", "last_scraped",
                                             "first_review", "last_review",
                                             "calendar_updated", "calendar_last_scraped"):
        return "NVARCHAR(20)"  # kept as text — dates in Inside Airbnb exports
                                 # are cleaned/cast explicitly in the SQL build,
                                 # not relied upon to auto-parse on import
    if lower.startswith("availability_") or lower.startswith("minimum_") \
            or lower.startswith("maximum_") or lower in ("accommodates", "bedrooms", "beds"):
        return "INT"
    if lower.startswith("calculated_host_listings_count") or lower == "host_listings_count" \
            or lower == "host_total_listings_count" or lower == "number_of_reviews":
        return "INT"
    if lower in ("bathrooms",):
        return "FLOAT"
    # Generous, deliberate default — this is a raw staging table, not the
    # final schema. Free-text columns like description/host_about/
    # neighborhood_overview can legitimately run to 1000+ characters in
    # real Inside Airbnb data, and there's no reliable way to predict
    # which unlisted column might be long. NVARCHAR(MAX) removes the
    # truncation risk entirely; the star schema build casts everything
    # to proper, narrow types later anyway.
    return "NVARCHAR(MAX)"


def check_numeric_fit(series):
    """
    Vectorized check of whether a column's real values actually fit an
    integer type. Returns 'int' (all whole numbers or empty), 'float'
    (has decimals but is numeric), or 'text' (contains non-numeric
    values — shouldn't have been typed as numeric at all).
    """
    non_null = series.dropna()
    if non_null.empty:
        return "int"
    numeric = pd.to_numeric(non_null, errors="coerce")
    if numeric.isna().any():
        return "text"
    if (numeric % 1 == 0).all():
        return "int"
    return "float"


def build_column_defs(df, columns, overrides, not_null_cols):
    """
    Build the CREATE TABLE column definition list.

    Both text and numeric types are checked against the REAL data in
    df before the table is created, and auto-corrected if needed:
      - Fixed-width NVARCHAR(n) types are widened to NVARCHAR(MAX) if
        any actual value is longer than declared.
      - INT/BIGINT/SMALLINT types are widened to FLOAT if actual values
        contain decimals (e.g. Inside Airbnb's *_avg_ntm columns are
        genuinely fractional, not whole numbers), or to NVARCHAR(MAX)
        if they contain non-numeric values entirely.
    This catches type-mismatch failures proactively — with a clear
    report of exactly which column and why — instead of only
    discovering them via a failed INSERT partway through a large load.
    """
    defs = []
    widened = []
    for col in columns:
        sql_type = overrides.get(col, infer_fallback_type(col))

        if sql_type in ("INT", "BIGINT", "SMALLINT") and col in df.columns:
            fit = check_numeric_fit(df[col])
            if fit == "text":
                widened.append((col, sql_type, "NVARCHAR(MAX)", "non-numeric value found"))
                sql_type = "NVARCHAR(MAX)"
            elif fit == "float":
                widened.append((col, sql_type, "FLOAT", "decimal value found"))
                sql_type = "FLOAT"

        match = re.match(r"^NVARCHAR\((\d+)\)$", sql_type)
        if match and col in df.columns:
            declared_len = int(match.group(1))
            lengths = df[col].dropna().astype(str).map(len)
            actual_max = int(lengths.max()) if len(lengths) else 0
            if actual_max > declared_len:
                widened.append((col, sql_type, "NVARCHAR(MAX)",
                                 f"longest actual value: {actual_max} characters"))
                sql_type = "NVARCHAR(MAX)"

        nullability = "NOT NULL" if col in not_null_cols else "NULL"
        defs.append(f"[{col}] {sql_type} {nullability}")

    if widened:
        print("  ⚠ Auto-corrected columns (real data didn't match the assumed type):")
        for col, original_type, new_type, reason in widened:
            print(f"      {col}: {original_type} -> {new_type} ({reason})")

    return defs


def get_overrides_for_file(filename: str):
    """
    Returns None if the filename doesn't match a known pattern, so the
    caller can skip it gracefully. Inside Airbnb ships other files
    (calendar.csv, etc.) alongside listings/reviews/neighbourhoods —
    those aren't part of this warehouse and should be skipped, not
    treated as an error that halts the whole run.
    """
    stem = os.path.splitext(filename)[0]
    for suffix, (overrides, not_null) in FILE_PATTERNS.items():
        if stem.endswith(suffix):
            return stem, overrides, not_null
    return None


def ensure_database_exists(server, database, driver, trusted, uid, pwd):
    """Connect to master and create the target database if missing."""
    conn_str = (
        f"DRIVER={driver};SERVER={server};DATABASE=master;"
        + (f"Trusted_Connection=yes;" if trusted else f"UID={uid};PWD={pwd};")
    )
    conn = pyodbc.connect(conn_str, autocommit=True)
    cursor = conn.cursor()
    cursor.execute(
        "IF NOT EXISTS (SELECT * FROM sys.databases WHERE name = ?) "
        "EXEC('CREATE DATABASE [' + ? + ']')",
        database, database,
    )
    conn.close()
    print(f"✔ Database '{database}' ready.")


def load_csv(csv_path, conn):
    filename = os.path.basename(csv_path)
    match = get_overrides_for_file(filename)

    if match is None:
        stem = os.path.splitext(filename)[0]
        if stem.endswith("_reviews") or stem.endswith("_neighbourhoods"):
            kind = "reviews" if stem.endswith("_reviews") else "neighbourhoods"
            print(f"\n── Skipping {filename} — {kind} are loaded via the wizard, "
                  f"not this script. See SCOPE at the top of this file. ──")
        else:
            print(f"\n── Skipping {filename} — not a recognized file for this "
                  f"warehouse (e.g. Inside Airbnb's calendar.csv). ──")
        return

    table_name, overrides, not_null_cols = match

    print(f"\n── Loading {filename} → [{table_name}] ──")

    # Read everything as string — avoids pandas silently coercing
    # types (e.g. turning '$50.00' into a float, or dropping leading
    # zeros from license numbers). SQL Server handles the string ->
    # typed-column conversion correctly on INSERT for well-formed
    # values, matching what the wizard itself effectively does.
    df = pd.read_csv(csv_path, dtype=str, keep_default_na=False, na_values=[""])
    df = df.where(pd.notnull(df), None)  # empty/NaN -> Python None -> SQL NULL

    columns = list(df.columns)
    col_defs = build_column_defs(df, columns, overrides, not_null_cols)

    cursor = conn.cursor()

    # Drop and recreate — same "safe re-run" pattern used throughout
    # the SQL scripts themselves
    cursor.execute(f"IF OBJECT_ID('[{table_name}]', 'U') IS NOT NULL DROP TABLE [{table_name}]")
    create_sql = f"CREATE TABLE [{table_name}] (\n    " + ",\n    ".join(col_defs) + "\n)"
    cursor.execute(create_sql)
    conn.commit()
    print(f"  ✔ Table created ({len(columns)} columns)")

    # Bulk insert
    placeholders = ", ".join(["?"] * len(columns))
    col_list = ", ".join(f"[{c}]" for c in columns)
    insert_sql = f"INSERT INTO [{table_name}] ({col_list}) VALUES ({placeholders})"

    # fast_executemany is deliberately OFF here. pyodbc's fast_executemany
    # pre-sizes its internal parameter buffers based on the first rows it
    # sees in a batch — when a column has widely varying string lengths
    # (a two-word host_name next to a 2000-character description, for
    # example), a later row longer than what the buffer was sized for
    # causes "String data, right truncation" even though the actual SQL
    # Server column (NVARCHAR(MAX)) is plenty wide. This is a client-side
    # buffering issue, not a schema issue, and there's no reliable way to
    # predict which column will be long enough to trigger it across
    # different quarterly exports — turning it off trades some speed for
    # a load that doesn't randomly fail on real-world text data.
    cursor.fast_executemany = False
    rows = [tuple(row) for row in df.itertuples(index=False, name=None)]

    CHUNK_SIZE = 2000
    total = len(rows)
    try:
        for start in range(0, total, CHUNK_SIZE):
            chunk = rows[start:start + CHUNK_SIZE]
            cursor.executemany(insert_sql, chunk)
            conn.commit()
            done = min(start + CHUNK_SIZE, total)
            if total > CHUNK_SIZE:
                print(f"    ... {done:,} / {total:,} rows inserted")
    except pyodbc.Error as e:
        conn.rollback()
        print(f"  ✘ Insert failed: {e}")
        print("  This usually means a NOT NULL column has blank values in the "
              "source CSV, or a value doesn't fit its overridden type "
              "(e.g. a price string longer than NVARCHAR(20)). Check the CSV "
              "against the column list above.")
        raise

    print(f"  ✔ {len(rows)} rows loaded")

    # Quick verify — mirrors the row-count check you'd run manually
    # after a wizard import
    cursor.execute(f"SELECT COUNT(*) FROM [{table_name}]")
    count = cursor.fetchone()[0]
    status = "✔" if count == len(rows) else "✘ MISMATCH"
    print(f"  {status} Row count in table: {count}")


def main():
    if not os.path.isdir(CSV_DIR):
        print(f"CSV_DIR '{CSV_DIR}' not found — edit the CONFIG block at the top of this script.")
        sys.exit(1)

    csv_files = sorted(glob.glob(os.path.join(CSV_DIR, "**", "*.csv"), recursive=True))

    if INCLUDE_SUBFOLDERS:
        def in_allowed_subfolder(path):
            rel = os.path.relpath(path, CSV_DIR)
            top_level_folder = rel.split(os.sep)[0]
            return top_level_folder in INCLUDE_SUBFOLDERS
        csv_files = [f for f in csv_files if in_allowed_subfolder(f)]
    if not csv_files:
        scope = f"in subfolders {INCLUDE_SUBFOLDERS}" if INCLUDE_SUBFOLDERS else "in any subfolder"
        print(f"No CSV files found under '{CSV_DIR}' {scope}.")
        sys.exit(1)

    scope_msg = f"(filtered to {INCLUDE_SUBFOLDERS})" if INCLUDE_SUBFOLDERS else "(including all subfolders)"
    print(f"Found {len(csv_files)} CSV file(s) under {CSV_DIR} {scope_msg}:")
    for f in csv_files:
        print(f"  - {os.path.relpath(f, CSV_DIR)}")

    ensure_database_exists(SERVER, DATABASE, DRIVER, TRUSTED_CONNECTION, UID, PWD)

    conn_str = (
        f"DRIVER={DRIVER};SERVER={SERVER};DATABASE={DATABASE};"
        + (f"Trusted_Connection=yes;" if TRUSTED_CONNECTION else f"UID={UID};PWD={PWD};")
    )
    conn = pyodbc.connect(conn_str)

    try:
        for csv_path in csv_files:
            load_csv(csv_path, conn)
    finally:
        conn.close()

    print("\n✔ All files loaded. Next step: run Section 1's DROP COLUMN block "
          "(or your quarterly load script's Step 3) against these tables, "
          "then continue the SQL pipeline as normal.")


if __name__ == "__main__":
    main()
