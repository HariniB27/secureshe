# scripts/load_crime_district.py

"""
Loads the year-by-year NCRB crime dataset into the CrimeDistrict table.

Run (dry run first; it reads the CSV and reports, but writes nothing):
    PYTHONPATH=. python3 scripts/load_crime_district.py --dry-run
    PYTHONPATH=. python3 scripts/load_crime_district.py

Needs pandas and geopy (pip install -r requirements-dev.txt).
Deletes existing crime_district rows first, then reloads the dataset.
"""

import sys
from pathlib import Path

import pandas as pd

from app import create_app, db
from app.models import CrimeDistrict

from scripts.build_district_baseline import (
    read_raw_csv,
    is_non_district,
    apply_alias,
    load_geocode_cache,
)


RAW_PATH = Path("data/raw/crime_by_district.csv")


def main(dry_run=False):

    app = create_app()

    with app.app_context():

        # Read CSV
        df = read_raw_csv(RAW_PATH)

        # Clean column names
        df.columns = [str(c).strip() for c in df.columns]

        # Required columns
        required = [
            "State/ UT",
            "District/ Area",
            "Year",
            "Total Crimes against Women",
        ]

        missing = [
            c for c in required
            if c not in df.columns
        ]

        if missing:
            raise ValueError(
                f"Missing columns: {missing}\n"
                f"Available: {df.columns.tolist()}"
            )

        # Clean state
        df["State/ UT"] = (
            df["State/ UT"]
            .astype(str)
            .str.strip()
            .str.title()
        )

        # Clean district
        df["District/ Area"] = (
            df["District/ Area"]
            .astype(str)
            .str.strip()
        )

        # Convert crime count to number
        df["Total Crimes against Women"] = pd.to_numeric(
            df["Total Crimes against Women"],
            errors="coerce",
        ).fillna(0)

        # Convert year to number
        df["Year"] = pd.to_numeric(
            df["Year"],
            errors="coerce",
        )

        # Remove aggregate rows
        aggregate_pattern = (
            r"^\s*total\s*$"
            r"|^\s*total\s+district"
            r"|^\s*state\s+total"
            r"|^\s*district\s+total"
        )

        before = len(df)

        df = df[
            ~df["District/ Area"].str.contains(
                aggregate_pattern,
                case=False,
                na=False,
                regex=True,
            )
        ]

        # Rows without a year can't be placed in time; skip them
        # (rather than storing them as year 0).
        df = df[df["Year"].notna()]

        # Remove other non-district entries
        df = df[
            ~df["District/ Area"].apply(is_non_district)
        ]

        print(
            f"Filtered {before - len(df)} "
            "aggregate/non-district rows."
        )

        # Load existing geocode cache
        cache = load_geocode_cache()

        missing_coords = 0
        rows_to_insert = []

        # Process every CSV row
        for _, row in df.iterrows():

            state = str(
                row["State/ UT"]
            ).strip()

            raw_district = str(
                row["District/ Area"]
            ).strip()

            # Apply district aliases
            geocode_district = apply_alias(
                state,
                raw_district,
            )

            # Try aliased district first
            lat, lng = cache.get(
                (state, geocode_district),
                (None, None),
            )

            # Try original district as fallback
            if lat is None:

                lat, lng = cache.get(
                    (state, raw_district),
                    (None, None),
                )

            # Count missing coordinates
            if lat is None or lng is None:
                missing_coords += 1

            # Create database object
            rows_to_insert.append(
                CrimeDistrict(
                    state=state,
                    district=raw_district,
                    year=(
                        int(row["Year"])
                        if pd.notna(row["Year"])
                        else 0
                    ),
                    latitude=lat,
                    longitude=lng,
                    total_crimes=int(
                        row["Total Crimes against Women"]
                    ),
                )
            )

        print(
            f"Prepared {len(rows_to_insert)} rows, "
            f"{missing_coords} still missing coordinates."
        )

        years = sorted({r.year for r in rows_to_insert})
        existing = db.session.query(CrimeDistrict).count()
        print(f"Years in CSV: {years[0]}..{years[-1]} ({len(years)} years)" if years else "No rows.")
        print(f"crime_district currently has {existing} rows.")

        if dry_run:
            print("Dry run: nothing written.")
            return

        # Delete old data
        db.session.query(
            CrimeDistrict
        ).delete()

        # Insert new data
        db.session.bulk_save_objects(
            rows_to_insert
        )

        # Commit
        db.session.commit()

        print(
            f"Loaded {len(rows_to_insert)} rows "
            "into crime_district."
        )


if __name__ == "__main__":
    main(dry_run="--dry-run" in sys.argv)
