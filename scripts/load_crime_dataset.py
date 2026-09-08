import csv
import os

from app import create_app, db
from app.models import CrimeDistrict


BASE_DIR = os.path.dirname(
    os.path.dirname(
        os.path.abspath(__file__)
    )
)

CRIME_FILE = os.path.join(
    BASE_DIR,
    "data",
    "raw",
    "crime_by_district.csv"
)

GEOCODE_FILE = os.path.join(
    BASE_DIR,
    "data",
    "geocode_cache.csv"
)


def load_geocodes():
    geocodes = {}

    with open(
        GEOCODE_FILE,
        "r",
        encoding="utf-8"
    ) as file:

        reader = csv.DictReader(file)

        for row in reader:
            state = row.get("State", "").strip()
            district = row.get("District", "").strip()

            if not state or not district:
                continue

            try:
                lat = float(row["Latitude"])
                lng = float(row["Longitude"])
            except (KeyError, TypeError, ValueError):
                continue

            key = (
                state.lower(),
                district.lower()
            )

            geocodes[key] = (
                lat,
                lng
            )

    return geocodes


def load_dataset():
    app = create_app()

    with app.app_context():

        geocodes = load_geocodes()

        print(
            f"Loaded {len(geocodes)} district coordinates."
        )

        inserted = 0
        skipped = 0

        with open(
            CRIME_FILE,
            "r",
            encoding="utf-8"
        ) as file:

            reader = csv.DictReader(file)

            for row in reader:

                state = row[
                    "State/ UT"
                ].strip()

                district = row[
                    "District/ Area"
                ].strip()

                try:
                    year = int(
                        row["Year"]
                    )

                    total_crimes = int(
                        float(
                            row[
                                "Total Crimes against Women"
                            ]
                        )
                    )

                except (
                    KeyError,
                    TypeError,
                    ValueError
                ):
                    skipped += 1
                    continue

                key = (
                    state.lower(),
                    district.lower()
                )

                coordinates = geocodes.get(
                    key
                )

                latitude = None
                longitude = None

                if coordinates:
                    latitude, longitude = coordinates

                crime = CrimeDistrict(
                    state=state,
                    district=district,
                    year=year,
                    latitude=latitude,
                    longitude=longitude,
                    total_crimes=total_crimes
                )

                db.session.add(crime)

                inserted += 1

        db.session.commit()

        print(
            f"Inserted: {inserted}"
        )

        print(
            f"Skipped: {skipped}"
        )


if __name__ == "__main__":
    load_dataset()