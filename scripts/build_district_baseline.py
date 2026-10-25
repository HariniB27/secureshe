"""
Build the district-level safety baseline.

Run:
    python3 scripts/build_district_baseline.py

Produces:
    data/district_baseline.csv

Output columns:
    state, district, lat, lng, baseline_risk

The script:
1. Loads the NCRB crime dataset.
2. Removes obvious police/special/aggregate units.
3. Normalizes known old district names.
4. Reuses existing geocoding cache.
5. Geocodes only genuine districts that are still missing.
6. Calculates min-max normalized baseline risk.
"""

from pathlib import Path

import pandas as pd
from geopy.geocoders import Nominatim
from geopy.extra.rate_limiter import RateLimiter


RAW_PATH = Path("data/raw/crime_by_district.csv")
OUT_PATH = Path("data/district_baseline.csv")
CACHE_PATH = Path("data/geocode_cache.csv")


# ---------------------------------------------------------------------
# KNOWN DISTRICT NAME FIXES
# ---------------------------------------------------------------------

DISTRICT_ALIASES = {
    # Chhattisgarh
    ("Chhattisgarh", "Bemetra"): "Bemetara",
    ("Chhattisgarh", "Bizapur"): "Bijapur",
    ("Chhattisgarh", "Mungali"): "Mungeli",
    ("Chhattisgarh", "Sarguja"): "Surguja",

    # Bihar
    ("Bihar", "Bhabhua"): "Kaimur",

    # Assam
    ("Assam", "Sadia"): "Tinsukia",

    # Daman / Dadra and Nagar Haveli
    ("D&N Haveli", "D&N Haveli"): "Dadra and Nagar Haveli",

    # Gujarat
    ("Gujarat", "Arvalli"): "Aravalli",
    ("Gujarat", "Chhotaudepur"): "Chhota Udaipur",

    # Jharkhand
    ("Jharkhand", "Lohardagga"): "Lohardaga",

    # Uttar Pradesh
    ("Uttar Pradesh", "Chandoli"): "Chandauli",
    ("Uttar Pradesh", "Gautambudh Nagar"): "Gautam Buddha Nagar",
    ("Uttar Pradesh", "Khiri"): "Kheri",
    ("Uttar Pradesh", "Kushi Nagar"): "Kushinagar",
    ("Uttar Pradesh", "Raibareilly"): "Rae Bareli",
    ("Uttar Pradesh", "Sant Kabirnagar"): "Sant Kabir Nagar",
    ("Uttar Pradesh", "Shrawasti"): "Shravasti",
    ("Uttar Pradesh", "Sidharthnagar"): "Siddharthnagar",

    # Uttarakhand
    ("Uttarakhand", "Rudra Prayag"): "Rudraprayag",
    ("Uttarakhand", "Udhamsingh Nagar"): "Udham Singh Nagar",

    # Tripura
    ("Tripura", "Kowai"): "Khowai",

    # Tamil Nadu
    ("Tamil Nadu", "Thirunelveli City"): "Tirunelveli",
}


# ---------------------------------------------------------------------
# UNITS THAT ARE NOT ACTUAL DISTRICTS
# ---------------------------------------------------------------------

NON_DISTRICT_KEYWORDS = [
    "crime branch",
    "anti terrorist",
    "economic offences",
    "railway",
    "g. r. p",
    "g.r.p",
    "w.rly",
    "cyber cell",
    "spl narcotic",
    "spl traffic",
    "cid, cb",
    "dcp ",
    "hrpc",
    "srp ",
    "special unit",
    "other units",
    "irrigation",
    "power",
    "vigilance",
    "spuwac",
    "metro",
    "igi airport",
    "eow",
    "commr.",
    "comr.",
    "commissionerate",
    "police district",
    "police",
]


def load_geocode_cache():
    """
    Load previously geocoded locations.

    The existing cache contains 708 successful locations,
    so we reuse them instead of querying Nominatim again.
    """

    if not CACHE_PATH.exists():
        return {}

    df = pd.read_csv(CACHE_PATH)

    required = {"state", "district", "lat", "lng"}

    if not required.issubset(df.columns):
        print("Warning: invalid geocode cache. Starting with empty cache.")
        return {}

    cache = {}

    for row in df.itertuples(index=False):
        try:
            state = str(row.state).strip()
            district = str(row.district).strip()

            lat = float(row.lat)
            lng = float(row.lng)

            cache[(state, district)] = (lat, lng)

        except (ValueError, TypeError):
            continue

    return cache


def save_geocode_cache(cache):
    """Save all known coordinates."""

    rows = [
        {
            "state": state,
            "district": district,
            "lat": lat,
            "lng": lng,
        }
        for (state, district), (lat, lng) in cache.items()
    ]

    pd.DataFrame(
        rows,
        columns=["state", "district", "lat", "lng"],
    ).to_csv(
        CACHE_PATH,
        index=False,
    )


def is_non_district(name):
    """
    Return True when the NCRB row represents a police/special unit
    rather than an actual geographical district.
    """

    value = str(name).strip().lower()

    for keyword in NON_DISTRICT_KEYWORDS:
        if keyword in value:
            return True

    return False


def apply_alias(state, district):
    """
    Convert known historical/alternate district names into
    names that are easier to geocode.
    """

    key = (
        str(state).strip(),
        str(district).strip(),
    )

    return DISTRICT_ALIASES.get(
        key,
        str(district).strip(),
    )


def geocode_one(geocode, state, district):
    """
    Try several progressively simpler queries.
    """

    queries = [
        f"{district}, {state}, India",
        f"{district} district, {state}, India",
        f"{district}, India",
    ]

    for query in queries:
        try:
            location = geocode(query)

            if location:
                return location

        except Exception as exc:
            print(
                f"Geocoding error for {query}: {exc}"
            )

    return None


def geocode_all(pairs, cache):
    """
    Geocode only districts missing from the cache.
    """

    if not pairs:
        return cache

    print()
    print("Starting geocoding...")
    print("This may take some time because Nominatim requires rate limiting.")
    print()

    geolocator = Nominatim(
        user_agent="secureshe_safety_baseline",
        timeout=10,
    )

    geocode = RateLimiter(
        geolocator.geocode,
        min_delay_seconds=1.1,
        max_retries=1,
        error_wait_seconds=2.0,
        swallow_exceptions=False,
    )

    for index, (state, district) in enumerate(pairs, start=1):

        key = (
            state,
            district,
        )

        if key in cache:
            continue

        location = geocode_one(
            geocode,
            state,
            district,
        )

        if location:
            cache[key] = (
                location.latitude,
                location.longitude,
            )

            print(
                f"[{index}/{len(pairs)}] "
                f"OK: {state} / {district} "
                f"-> "
                f"({location.latitude:.4f}, "
                f"{location.longitude:.4f})"
            )

            save_geocode_cache(cache)

        else:
            print(
                f"[{index}/{len(pairs)}] "
                f"NOT FOUND: {state} / {district}"
            )

    return cache


def read_raw_csv(path):
    """
    Read the data.gov.in CSV.

    utf-8-sig handles files containing a UTF-8 BOM.
    cp1252 is used as a fallback for some exported files.
    """

    try:
        return pd.read_csv(
            path,
            encoding="utf-8-sig",
        )

    except UnicodeDecodeError:
        print(
            "UTF-8 decoding failed. "
            "Retrying with cp1252..."
        )

        return pd.read_csv(
            path,
            encoding="cp1252",
        )


def main():

    print()
    print("==============================================")
    print("SecureShe District Safety Baseline")
    print("==============================================")
    print()

    # ---------------------------------------------------------------
    # LOAD DATA
    # ---------------------------------------------------------------

    print("Loading crime dataset...")

    if not RAW_PATH.exists():
        raise FileNotFoundError(
            f"Dataset not found: {RAW_PATH}"
        )

    df = read_raw_csv(RAW_PATH)

    df.columns = [
        str(column).strip()
        for column in df.columns
    ]

    required_columns = [
        "State/ UT",
        "District/ Area",
        "Total Crimes against Women",
    ]

    missing = [
        column
        for column in required_columns
        if column not in df.columns
    ]

    if missing:
        raise ValueError(
            f"Required columns are missing: {missing}\n"
            f"Available columns: {df.columns.tolist()}"
        )

    # ---------------------------------------------------------------
    # CLEAN CRIME COUNT
    # ---------------------------------------------------------------

    df["Total Crimes against Women"] = pd.to_numeric(
        df["Total Crimes against Women"],
        errors="coerce",
    ).fillna(0)

    # ---------------------------------------------------------------
    # GROUP DISTRICT DATA
    # ---------------------------------------------------------------

    grouped = (
        df.groupby(
            [
                "State/ UT",
                "District/ Area",
            ]
        )["Total Crimes against Women"]
        .sum()
        .reset_index()
    )

    grouped["State/ UT"] = (
        grouped["State/ UT"]
        .astype(str)
        .str.strip()
        .str.title()
    )

    grouped["District/ Area"] = (
        grouped["District/ Area"]
        .astype(str)
        .str.strip()
    )

    print(
        f"Initial district/unit rows: {len(grouped)}"
    )

    # ---------------------------------------------------------------
    # REMOVE AGGREGATES
    # ---------------------------------------------------------------

    aggregate_pattern = (
        r"^\s*total\s*$"
        r"|^\s*total\s+district"
        r"|^\s*state\s+total"
        r"|^\s*district\s+total"
    )

    aggregate_mask = grouped[
        "District/ Area"
    ].str.contains(
        aggregate_pattern,
        case=False,
        na=False,
        regex=True,
    )

    aggregate_count = int(
        aggregate_mask.sum()
    )

    grouped = grouped.loc[
        ~aggregate_mask
    ].copy()

    print(
        f"Removed aggregate rows: {aggregate_count}"
    )

    # ---------------------------------------------------------------
    # REMOVE POLICE / SPECIAL UNITS
    # ---------------------------------------------------------------

    special_mask = grouped[
        "District/ Area"
    ].apply(is_non_district)

    special_count = int(
        special_mask.sum()
    )

    grouped = grouped.loc[
        ~special_mask
    ].copy()

    print(
        f"Removed non-district police/special units: "
        f"{special_count}"
    )

    # ---------------------------------------------------------------
    # APPLY DISTRICT NAME ALIASES
    # ---------------------------------------------------------------

    grouped["Geocode District"] = grouped.apply(
        lambda row: apply_alias(
            row["State/ UT"],
            row["District/ Area"],
        ),
        axis=1,
    )

    # ---------------------------------------------------------------
    # LOAD EXISTING CACHE
    # ---------------------------------------------------------------

    cache = load_geocode_cache()

    print(
        f"Existing cached coordinates: {len(cache)}"
    )

    # ---------------------------------------------------------------
    # BUILD LIST OF MISSING DISTRICTS
    # ---------------------------------------------------------------

    pairs = []

    for row in grouped.itertuples(index=False):

        state = str(row[0]).strip()
        district = str(row[3]).strip()

        key = (
            state,
            district,
        )

        if key not in cache:
            pairs.append(key)

    print(
        f"Districts still requiring geocoding: "
        f"{len(pairs)}"
    )

    # ---------------------------------------------------------------
    # GEOCODE
    # ---------------------------------------------------------------

    cache = geocode_all(
        pairs,
        cache,
    )

    # ---------------------------------------------------------------
    # ATTACH COORDINATES
    # ---------------------------------------------------------------

    def get_coordinates(row):

        state = str(
            row["State/ UT"]
        ).strip()

        district = str(
            row["Geocode District"]
        ).strip()

        return cache.get(
            (
                state,
                district,
            ),
            (None, None),
        )

    coordinates = grouped.apply(
        get_coordinates,
        axis=1,
    )

    grouped["lat"] = coordinates.apply(
        lambda value: value[0]
    )

    grouped["lng"] = coordinates.apply(
        lambda value: value[1]
    )

    # ---------------------------------------------------------------
    # REMOVE FAILED GEOCODING
    # ---------------------------------------------------------------

    before = len(grouped)

    grouped = grouped.dropna(
        subset=[
            "lat",
            "lng",
        ]
    ).copy()

    dropped = before - len(grouped)

    print()
    print(
        f"Successfully geocoded: {len(grouped)}"
    )

    print(
        f"Could not geocode: {dropped}"
    )

    if grouped.empty:
        raise RuntimeError(
            "No districts remain after geocoding."
        )

    # ---------------------------------------------------------------
    # CALCULATE BASELINE RISK
    # ---------------------------------------------------------------

    minimum = grouped[
        "Total Crimes against Women"
    ].min()

    maximum = grouped[
        "Total Crimes against Women"
    ].max()

    if maximum == minimum:

        grouped["baseline_risk"] = 0.0

    else:

        grouped["baseline_risk"] = (
            grouped[
                "Total Crimes against Women"
            ]
            - minimum
        ) / (
            maximum
            - minimum
        )

    # ---------------------------------------------------------------
    # CREATE FINAL OUTPUT
    # ---------------------------------------------------------------

    output = grouped.rename(
        columns={
            "State/ UT": "state",
            "District/ Area": "district",
        }
    )

    output = output[
        [
            "state",
            "district",
            "lat",
            "lng",
            "baseline_risk",
        ]
    ].copy()

    output["lat"] = pd.to_numeric(
        output["lat"],
        errors="coerce",
    )

    output["lng"] = pd.to_numeric(
        output["lng"],
        errors="coerce",
    )

    output["baseline_risk"] = (
        output["baseline_risk"]
        .clip(0.0, 1.0)
    )

    # ---------------------------------------------------------------
    # SAVE
    # ---------------------------------------------------------------

    OUT_PATH.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    output.to_csv(
        OUT_PATH,
        index=False,
    )

    print()
    print("==============================================")
    print("Baseline generation completed successfully.")
    print("==============================================")
    print()
    print(
        f"Wrote {len(output)} districts to:"
    )
    print(
        f"  {OUT_PATH}"
    )
    print()


if __name__ == "__main__":
    main()