#!/usr/bin/env python3
"""Apply extension seed SQL: patch known schema drift, delete keys, then insert."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

import psycopg2

INSERT_RE = re.compile(
    r'INSERT\s+INTO\s+(?:"public"\.)?"(\w+)"\s*\(([^)]+)\)\s*VALUES',
    re.IGNORECASE | re.DOTALL,
)
TUPLE_START_RE = re.compile(r"^\s*\(\s*'((?:[^']|'')*)'", re.MULTILINE)
REGISTER_ID_IN_SCORE_RE = re.compile(
    r"INSERT\s+INTO\s+\"public\"\.\"g2p_register_score_definitions\".*?VALUES\s*\("
    r"'([^']+)',\s*'([^']+)',\s*'([^']+)'",
    re.IGNORECASE | re.DOTALL,
)
USER_ID_JSON_RE = re.compile(r'"user_id"\s*:\s*"[^"]*"')
AWE_MULTI_STAGE_CLEANUP = """
DELETE FROM "public"."approver_rule" ar
WHERE ar.stage_id IN (
  SELECT s.id FROM "public"."approval_stage" s
  INNER JOIN "public"."approval_policy" p ON p.id = s.policy_id
  WHERE s.stage_order > 1 AND p.created_by = 'seed'
);
DELETE FROM "public"."approval_stage" s
USING "public"."approval_policy" p
WHERE s.policy_id = p.id AND s.stage_order > 1 AND p.created_by = 'seed';
"""


def _strip_comments(sql: str) -> str:
    lines = []
    for line in sql.splitlines():
        if line.strip().startswith("--"):
            continue
        lines.append(line)
    return "\n".join(lines)


def _unescape(value: str) -> str:
    return value.replace("''", "'")


def _patch_incoming_templates(sql: str) -> str:
    if "jsonld_expansion_required" in sql:
        return sql
    sql = sql.replace(
        '"template_file_id","created_at"',
        '"template_file_id","jsonld_expansion_required","created_at"',
    )
    return re.sub(
        r"(\'[^']+\.j2\')\s*,\s*('[\d:-]+ +[\d:.]+'|NULL)",
        r"\1,'FALSE',\2",
        sql,
        count=1,
    )


def _stage_order_from_row(row: str) -> int:
    match = re.search(r"^\s*\(\s*'[^']+'\s*,\s*'[^']+'\s*,\s*(\d+)\s*,", row)
    return int(match.group(1)) if match else 0


def _approver_stage_id_from_row(row: str) -> str | None:
    match = re.search(r"^\s*\(\s*'[^']+'\s*,\s*'([^']+)'\s*,", row)
    return match.group(1) if match else None


def _stage_one_ids_from_stage_sql(stage_sql: str) -> set[str]:
    ids: set[str] = set()
    for line in stage_sql.splitlines():
        if not line.strip().startswith("("):
            continue
        if _stage_order_from_row(line) != 1:
            continue
        match = re.search(r"^\s*\(\s*'([^']+)'\s*,", line)
        if match:
            ids.add(match.group(1))
    return ids


def _filter_insert_value_rows(sql: str, keep_row) -> str:
    lines = sql.splitlines()
    prefix_end = 0
    for index, line in enumerate(lines):
        if ") VALUES" in line:
            prefix_end = index + 1
            break
    else:
        return sql

    value_rows: list[str] = []
    suffix_start = len(lines)
    for index in range(prefix_end, len(lines)):
        stripped = lines[index].strip()
        if stripped.startswith("ON CONFLICT"):
            suffix_start = index
            break
        if stripped.startswith("("):
            value_rows.append(lines[index])

    kept = [row for row in value_rows if keep_row(row)]
    if not kept:
        return sql

    result = lines[:prefix_end]
    for index, row in enumerate(kept):
        trimmed = row.rstrip().rstrip(",")
        result.append(trimmed + ("," if index < len(kept) - 1 else ""))
    result.extend(lines[suffix_start:])
    return "\n".join(result)


def _filter_awe_stage_sql(sql: str) -> str:
    return _filter_insert_value_rows(sql, lambda row: _stage_order_from_row(row) == 1)


def _patch_awe_approval_stage(sql: str) -> str:
    """Collapse multi-stage AWE seeds to a single stage for local e2e.

    Farmer/NSR awe_meta_data uses INSERT ... SELECT FROM (VALUES ...), so
    row-filter helpers that look for ") VALUES" cannot strip stage 2. Run the
    cleanup *after* the insert instead; FK cascade removes stage-2 rules, and
    30_approver_rule.sql's WHERE EXISTS then only seeds stage 1.
    """
    dev_user = os.environ.get("KEYCLOAK_DEV_USER", "staff")
    print(
        "[apply-seed-sql]   AWE: single approval stage per policy "
        f"(approver={dev_user})",
        file=sys.stderr,
    )
    return sql.rstrip() + "\n" + AWE_MULTI_STAGE_CLEANUP


def _patch_awe_approver_rule(sql: str, path: Path) -> str:
    del path  # kept for call-site compatibility
    dev_user = os.environ.get("KEYCLOAK_DEV_USER", "staff")
    # Point every seeded approver at the local Keycloak dev user.
    return USER_ID_JSON_RE.sub(f'"user_id": "{dev_user}"', sql)


def _patch_score_definitions(sql: str, conn) -> str:
    match = REGISTER_ID_IN_SCORE_RE.search(sql)
    if not match:
        return sql

    score_definition_id, register_id, score_type = match.groups()
    register_mnemonic = None
    with conn.cursor() as cur:
        cur.execute(
            'SELECT register_mnemonic FROM "public"."g2p_register_definitions" '
            "WHERE register_id = %s",
            (register_id,),
        )
        row = cur.fetchone()
        if row:
            register_mnemonic = row[0]

    if not register_mnemonic:
        print(
            f"[apply-seed-sql] Warning: no register_mnemonic for {register_id}; "
            "skipping g2p_register_score_definitions patch.",
            file=sys.stderr,
        )
        return sql

    return (
        'INSERT INTO "public"."g2p_register_score_definitions" '
        '("score_definition_id","register_mnemonic","score_type","is_enabled") VALUES '
        f"('{score_definition_id}','{register_mnemonic}','{score_type}','TRUE');"
    )


def _patch_sql(path: Path, sql: str, conn) -> str:
    name = path.name
    if name == "incoming_templates.sql":
        return _patch_incoming_templates(sql)
    if name == "g2p_register_score_definitions.sql":
        if '"register_id"' in sql:
            return _patch_score_definitions(sql, conn)
    if name == "20_approval_stage.sql" and '"approval_stage"' in sql:
        return _patch_awe_approval_stage(sql)
    if name == "30_approver_rule.sql" and '"approver_rule"' in sql:
        return _patch_awe_approver_rule(sql, path)
    return sql


def _split_sql_statements(sql: str) -> list[str]:
    """Split SQL on statement terminators, ignoring semicolons inside strings."""
    statements: list[str] = []
    current: list[str] = []
    in_string = False
    index = 0
    length = len(sql)

    while index < length:
        char = sql[index]
        if in_string:
            current.append(char)
            if char == "'":
                if index + 1 < length and sql[index + 1] == "'":
                    current.append(sql[index + 1])
                    index += 2
                    continue
                in_string = False
            index += 1
            continue

        if char == "'":
            in_string = True
            current.append(char)
            index += 1
            continue

        if char == ";":
            statement = "".join(current).strip()
            if statement:
                statements.append(statement)
            current = []
            index += 1
            continue

        current.append(char)
        index += 1

    statement = "".join(current).strip()
    if statement:
        statements.append(statement)
    return statements


def _execute_sql_script(cur, sql: str) -> None:
    for statement in _split_sql_statements(sql):
        cur.execute(statement)


def _parse_insert(sql: str) -> tuple[str, str, list[str]] | None:
    body = _strip_comments(sql)
    match = INSERT_RE.search(body)
    if not match:
        return None

    table = match.group(1)
    columns = [col.strip().strip('"') for col in match.group(2).split(",")]
    pk_col = columns[0]
    values_section = body[match.end() :]
    pk_values = [_unescape(value) for value in TUPLE_START_RE.findall(values_section)]
    if not pk_values:
        return None
    return table, pk_col, pk_values


def _connect() -> psycopg2.extensions.connection:
    return psycopg2.connect(
        host=os.environ["PGHOST"],
        port=os.environ.get("PGPORT", "5432"),
        dbname=os.environ["PGDATABASE"],
        user=os.environ["PGUSER"],
        password=os.environ["PGPASSWORD"],
    )


def _table_exists(cur, table: str) -> bool:
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
    return bool(cur.fetchone()[0])


def apply_sql_file(path: Path) -> None:
    original = path.read_text(encoding="utf-8")
    body = _strip_comments(original).strip()
    if not body:
        print(f"[apply-seed-sql]   skipped (no SQL statements)")
        return

    conn = _connect()
    try:
        sql = _patch_sql(path, original, conn)
        sql_body = _strip_comments(sql).strip()
        if not sql_body:
            print(f"[apply-seed-sql]   skipped (no SQL statements after patch)")
            return

        parsed = _parse_insert(sql)
        with conn:
            with conn.cursor() as cur:
                if parsed:
                    table, pk_col, pk_values = parsed
                    if not _table_exists(cur, table):
                        print(
                            f"[apply-seed-sql]   skipped {table} "
                            "(table missing — run make vsss-registry-migrate first)"
                        )
                        return
                    cur.execute("SAVEPOINT seed_delete")
                    try:
                        cur.execute(
                            f'DELETE FROM "public"."{table}" WHERE "{pk_col}" = ANY(%s)',
                            (pk_values,),
                        )
                        deleted = cur.rowcount
                        if deleted:
                            print(
                                f"[apply-seed-sql]   deleted {deleted} row(s) from {table}"
                            )
                    except psycopg2.errors.UndefinedTable:
                        cur.execute("ROLLBACK TO SAVEPOINT seed_delete")
                        print(
                            f"[apply-seed-sql]   skipped {table} "
                            "(table missing — run make vsss-registry-migrate first)"
                        )
                        return
                    except psycopg2.errors.ForeignKeyViolation:
                        cur.execute("ROLLBACK TO SAVEPOINT seed_delete")
                        print(
                            f"[apply-seed-sql]   kept existing {table} row(s) "
                            "(referenced by runtime data); applying upsert"
                        )
                _execute_sql_script(cur, sql_body)
    finally:
        conn.close()


def main() -> None:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <seed.sql>", file=sys.stderr)
        sys.exit(1)

    path = Path(sys.argv[1]).resolve()
    if not path.is_file():
        print(f"[apply-seed-sql] Missing file: {path}", file=sys.stderr)
        sys.exit(1)

    apply_sql_file(path)


if __name__ == "__main__":
    main()
