"""Read-only comparison of the live database with the models.

Used by app startup (to warn, never to change anything) and by
scripts/migrate.py (to work out what to create)."""
from sqlalchemy import inspect

from app import db


def find_schema_gaps(engine):
    """Returns (missing_tables, missing_columns) where missing_columns maps
    table name -> [column objects] for tables that exist but lack columns."""
    inspector = inspect(engine)
    existing = set(inspector.get_table_names())

    missing_tables = []
    missing_columns = {}
    for table in db.metadata.sorted_tables:
        if table.name not in existing:
            missing_tables.append(table)
            continue
        present = {c['name'] for c in inspector.get_columns(table.name)}
        lacking = [c for c in table.columns if c.name not in present]
        if lacking:
            missing_columns[table.name] = lacking

    return missing_tables, missing_columns
