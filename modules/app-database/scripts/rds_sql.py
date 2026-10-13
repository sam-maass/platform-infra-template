#!/usr/bin/env python3
"""Run SQL on the shared Aurora cluster through the RDS Data API.

The Data API is a regular AWS API, so this works from a laptop or a GitHub
Actions runner without any network path into the private VPC. It signs in with
the RDS-managed master secret; nobody sees the password.

Standard library only (Python 3.9+), plus the AWS CLI.

Connection settings come from the environment:
  AWS_REGION, RDS_CLUSTER_ARN, RDS_SECRET_ARN

Commands:
  create  --user U --database D --access owner|read   database and user for one app
  drop    --user U --database D --access owner|read   undo `create`
  ensure-database --database D                         CREATE DATABASE if missing
  run-file --database D --file F                       run a SQL file, statement by statement
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

IDENTIFIER = re.compile(r"^[a-z_][a-z0-9_]{0,62}$")
CONNECTION_LIMIT = 10
STATEMENT_TIMEOUT = "30s"


def ident(name):
    if not IDENTIFIER.match(name):
        sys.exit(f"invalid identifier: {name!r} (lowercase letters, digits, underscores)")
    return '"' + name + '"'


def literal(name):
    ident(name)  # same rules, so it's safe inside quotes
    return "'" + name + "'"


def execute(database, sql):
    """One statement, autocommit. Retries while a paused cluster resumes."""
    command = [
        "aws", "rds-data", "execute-statement",
        "--region", os.environ["AWS_REGION"],
        "--resource-arn", os.environ["RDS_CLUSTER_ARN"],
        "--secret-arn", os.environ["RDS_SECRET_ARN"],
        "--database", database,
        "--sql", sql,
        "--output", "json",
    ]
    for attempt in range(30):
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode == 0:
            return json.loads(result.stdout or "{}").get("records", [])
        if "DatabaseResumingException" in result.stderr or "resuming" in result.stderr.lower():
            print("  cluster is resuming, retrying in 5s", flush=True)
            time.sleep(5)
            continue
        first_line = sql.strip().splitlines()[0]
        sys.exit(f"SQL failed on {database}: {first_line}\n{result.stderr.strip()}")
    sys.exit("cluster did not resume in time")


def run(database, sql):
    execute(database, sql)
    print(f"  {database}: {sql.strip().splitlines()[0]}", flush=True)


def scalar(database, sql):
    records = execute(database, sql)
    return list(records[0][0].values())[0] if records else None


def database_exists(name):
    return bool(scalar("postgres", f"SELECT count(*) FROM pg_database WHERE datname = {literal(name)}"))


def role_exists(name):
    return bool(scalar("postgres", f"SELECT count(*) FROM pg_roles WHERE rolname = {literal(name)}"))


def ensure_database(name):
    # CREATE DATABASE can't run inside a transaction or a DO block, so check first.
    if database_exists(name):
        print(f"  database {name} exists", flush=True)
    else:
        run("postgres", f"CREATE DATABASE {ident(name)}")


def create(user, database, access):
    u, d = ident(user), ident(database)

    # A login role without a password. rds_iam makes Aurora accept IAM tokens
    # for it, and only IAM tokens. Guardrails keep one app from overloading
    # the shared cluster.
    run("postgres", f"""DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = {literal(user)}) THEN
    CREATE ROLE {u} LOGIN;
  END IF;
END
$$""")
    run("postgres", f"GRANT rds_iam TO {u}")
    run("postgres", f"ALTER ROLE {u} CONNECTION LIMIT {CONNECTION_LIMIT}")
    run("postgres", f"ALTER ROLE {u} SET statement_timeout = '{STATEMENT_TIMEOUT}'")

    if access == "owner":
        # A new database only this app can use. It may create its own tables.
        ensure_database(database)
        run("postgres", f"REVOKE ALL ON DATABASE {d} FROM PUBLIC")
        run("postgres", f"GRANT CONNECT, TEMPORARY ON DATABASE {d} TO {u}")
        run(database, f"GRANT USAGE, CREATE ON SCHEMA public TO {u}")
    else:
        # An existing database: read-only, through the access profile the data
        # owner published (a NOLOGIN role named <database>_read).
        profile = f"{database}_read"
        if not database_exists(database) or not role_exists(profile):
            sys.exit(f"{database} isn't attachable: it needs the database and a {profile} role")
        run("postgres", f"GRANT {ident(profile)} TO {u}")


def drop(user, database, access):
    u = ident(user)
    if access == "owner":
        # The app's own database goes with it.
        run("postgres", f"DROP DATABASE IF EXISTS {ident(database)} WITH (FORCE)")
    elif role_exists(user) and role_exists(f"{database}_read"):
        run("postgres", f"REVOKE {ident(database + '_read')} FROM {u}")
    run("postgres", f"DROP ROLE IF EXISTS {u}")


def split_statements(sql):
    """Split on semicolons at line ends, keeping $$ ... $$ blocks intact."""
    statements, current, in_block = [], [], False
    for line in sql.splitlines():
        if not current and (not line.strip() or line.lstrip().startswith("--")):
            continue
        current.append(line)
        if line.count("$$") % 2:
            in_block = not in_block
        if not in_block and line.rstrip().endswith(";"):
            statements.append("\n".join(current).rstrip()[:-1])
            current = []
    if "".join(current).strip():
        statements.append("\n".join(current).strip())
    return statements


def run_file(database, path):
    ident(database)
    with open(path, encoding="utf-8") as handle:
        for statement in split_statements(handle.read()):
            run(database, statement)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("create", "drop"):
        p = sub.add_parser(name)
        p.add_argument("--user", required=True)
        p.add_argument("--database", required=True)
        p.add_argument("--access", choices=["owner", "read"], required=True)
    p = sub.add_parser("ensure-database")
    p.add_argument("--database", required=True)
    p = sub.add_parser("run-file")
    p.add_argument("--database", required=True)
    p.add_argument("--file", required=True)
    args = parser.parse_args()

    missing = [k for k in ("AWS_REGION", "RDS_CLUSTER_ARN", "RDS_SECRET_ARN") if not os.environ.get(k)]
    if missing:
        sys.exit("missing environment variables: " + ", ".join(missing))

    if args.command == "create":
        create(args.user, args.database, args.access)
    elif args.command == "drop":
        drop(args.user, args.database, args.access)
    elif args.command == "ensure-database":
        ensure_database(args.database)
    else:
        run_file(args.database, args.file)
    print("done", flush=True)


if __name__ == "__main__":
    main()
