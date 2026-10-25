#!/usr/bin/env python
"""Bring the database up to date with the models.

Additive and idempotent: it only CREATEs missing tables and ADDs missing
columns, never drops, renames or rewrites anything, and running it twice
does nothing the second time. Every statement is printed.

    python scripts/migrate.py --dry-run     # show what would run, change nothing
    python scripts/migrate.py               # asks you to type the database name
    python scripts/migrate.py --yes         # no prompt (CI / local throwaway DBs)

It uses DATABASE_URL from .env. THE APP NEVER DOES THIS FOR YOU: it only
warns at startup when the schema is behind.
"""
import argparse
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from dotenv import load_dotenv  # noqa: E402

load_dotenv(os.path.join(ROOT, '.env'))

import sqlalchemy as sa  # noqa: E402
from sqlalchemy.schema import CreateTable  # noqa: E402

from app import models  # noqa: E402,F401  (importing registers every table)
from app.schema import find_schema_gaps  # noqa: E402


def build_statements(engine):
    missing_tables, missing_columns = find_schema_gaps(engine)
    dialect = engine.dialect
    quote = dialect.identifier_preparer.quote
    statements = []

    for table in missing_tables:
        ddl = str(CreateTable(table, if_not_exists=True).compile(dialect=dialect)).strip()
        statements.append(' '.join(ddl.split()))

    # PostgreSQL has ADD COLUMN IF NOT EXISTS; SQLite doesn't, but we only
    # emit columns that are actually missing, so it stays idempotent.
    if_not_exists = 'IF NOT EXISTS ' if dialect.name == 'postgresql' else ''

    for table_name, columns in missing_columns.items():
        for col in columns:
            default = ''
            if col.server_default is not None:
                arg = col.server_default.arg
                text = arg.compile(dialect=dialect) if hasattr(arg, 'compile') else f"'{arg}'"
                default = f' DEFAULT {text}'
            if not col.nullable and not default:
                sys.exit(f'Refusing: {table_name}.{col.name} is NOT NULL without a default.')
            statements.append(
                f'ALTER TABLE {quote(table_name)} ADD COLUMN {if_not_exists}'
                f'{quote(col.name)} {col.type.compile(dialect=dialect)}{default}'
            )

    return statements


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--dry-run', action='store_true', help='print the statements and change nothing')
    parser.add_argument('--yes', action='store_true', help='skip the confirmation prompt')
    args = parser.parse_args()

    url = os.getenv('DATABASE_URL')
    if not url:
        sys.exit('DATABASE_URL is not set (put it in .env).')

    engine = sa.create_engine(url)
    target = f'{engine.dialect.name}  host={engine.url.host or "(local file)"}  database={engine.url.database}'
    print(f'Target: {target}')

    statements = build_statements(engine)
    if not statements:
        print('Nothing to do: the schema is already up to date.')
        return

    print(f'{len(statements)} statement(s):')
    for s in statements:
        print(f'  {s};')

    if args.dry_run:
        print('DRY RUN: nothing was executed.')
        return

    if not args.yes:
        if not sys.stdin.isatty():
            sys.exit('Not a terminal: pass --yes to run without the prompt.')
        answer = input(f'Type the database name ("{engine.url.database}") to apply these: ')
        if answer.strip() != str(engine.url.database):
            sys.exit('Aborted: nothing was changed.')

    with engine.begin() as conn:
        for s in statements:
            conn.execute(sa.text(s))
            print(f'  ok: {s[:90]}')

    left_tables, left_columns = find_schema_gaps(engine)
    if left_tables or left_columns:
        sys.exit('Applied, but the schema still differs from the models; inspect it manually.')
    print('Done: the schema is up to date.')


if __name__ == '__main__':
    main()
