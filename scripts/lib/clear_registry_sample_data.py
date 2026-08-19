#!/usr/bin/env python3
"""Delete previously seeded registry sample rows before a fresh sample load."""

from __future__ import annotations

import os
import sys

import psycopg2

FARMER_TABLES = [
    "g2p_completion_score_computation_queue",
    "g2p_register_scores",
    "g2p_register_score_history",
    "g2p_register_document_history",
    "g2p_register_history_crops",
    "g2p_register_history_livestocks",
    "g2p_register_history_farm_inputs",
    "g2p_register_history_membership_details",
    "g2p_register_history_lands",
    "g2p_register_history_household_members",
    "g2p_register_history_households",
    "g2p_register_history_farmers",
    "g2p_register_crops",
    "g2p_register_livestocks",
    "g2p_register_farm_inputs",
    "g2p_register_membership_details",
    "g2p_register_lands",
    "g2p_register_household_members",
    "g2p_register_households",
    "g2p_register_farmers",
]

NSR_TABLES = [
    "g2p_completion_score_computation_queue",
    "g2p_register_scores",
    "g2p_register_household_programs",
    "g2p_register_household_housing_and_services",
    "g2p_register_household_assets",
    "g2p_register_individual_programs",
    "g2p_register_individual_vulnerability",
    "g2p_register_individual_disabilities",
    "g2p_register_individual_shocks",
    "g2p_register_individual_land",
    "g2p_register_individual_livestock",
    "g2p_register_individual_livelihoods",
    "g2p_register_households",
    "g2p_register_individuals",
]

VSSS_TABLES = NSR_TABLES

TABLES_BY_VARIANT = {
    "farmer-registry": FARMER_TABLES,
    "national-social-registry": NSR_TABLES,
    "village-social-security-registry": VSSS_TABLES,
}


def _connect() -> psycopg2.extensions.connection:
    return psycopg2.connect(
        host=os.environ["PGHOST"],
        port=os.environ.get("PGPORT", "5432"),
        dbname=os.environ["PGDATABASE"],
        user=os.environ["PGUSER"],
        password=os.environ["PGPASSWORD"],
    )


def clear_sample_data(variant: str) -> None:
    tables = TABLES_BY_VARIANT.get(variant)
    if not tables:
        print(f"[clear-sample-data] No sample tables configured for {variant}; skipping.")
        return

    conn = _connect()
    try:
        with conn:
            with conn.cursor() as cur:
                for table in tables:
                    cur.execute(
                        """
                        SELECT EXISTS (
                          SELECT 1
                          FROM information_schema.tables
                          WHERE table_schema = 'public' AND table_name = %s
                        )
                        """,
                        (table,),
                    )
                    if not cur.fetchone()[0]:
                        continue
                    cur.execute(f'DELETE FROM "public"."{table}"')
                    deleted = cur.rowcount
                    if deleted:
                        print(f"[clear-sample-data]   deleted {deleted} row(s) from {table}")
    finally:
        conn.close()


def main() -> None:
    variant = os.environ.get("VARIANT") or (sys.argv[1] if len(sys.argv) > 1 else "")
    if not variant:
        print(f"Usage: VARIANT=<variant> {sys.argv[0]}", file=sys.stderr)
        sys.exit(1)
    print(f"[clear-sample-data] Clearing sample data for {variant} ...")
    clear_sample_data(variant)
    print("[clear-sample-data] Done.")


if __name__ == "__main__":
    main()
