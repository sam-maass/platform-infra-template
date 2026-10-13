#!/usr/bin/env python3
"""Clean up apps whose module call was removed from apps/apps.tf.

Terraform skips destroy-time provisioners when a resource's block is gone from
the configuration, which is exactly what removing a module call does. So the
apply job saves the plan, and this script reads it: for every app-database
resource the plan deletes outright, it runs the same drop and unlink steps the
provisioners would have, using the values stored in state.

Standard library only (Python 3.9+).

Usage: cleanup_removed.py PLAN_JSON   (from `terraform show -json tfplan`)
"""

import json
import os
import subprocess
import sys

SCRIPTS = os.path.dirname(os.path.abspath(__file__))


def removed(plan, name):
    """terraform_data.<name> inside app-database modules that the plan deletes, not replaces."""
    for change in plan.get("resource_changes", []):
        if (
            change.get("type") == "terraform_data"
            and change.get("name") == name
            and change.get("module_address")
            and change["change"]["actions"] == ["delete"]
        ):
            yield change["module_address"], (change["change"]["before"] or {}).get("input") or {}


def run(command, env=None):
    print("  " + " ".join(command[1:3]), flush=True)
    subprocess.run(command, check=True, env={**os.environ, **(env or {})})


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with open(sys.argv[1], encoding="utf-8") as handle:
        plan = json.load(handle)

    count = 0
    for module, data in removed(plan, "network"):
        print(f"{module}: disconnect from the Secure Compute network", flush=True)
        run([sys.executable, os.path.join(SCRIPTS, "vercel_api.py"), "unlink-network",
             "--team", data["team"], "--project-id", data["project_id"]])
        count += 1
    for module, data in removed(plan, "database"):
        print(f"{module}: drop database user {data['user']}", flush=True)
        run([sys.executable, os.path.join(SCRIPTS, "rds_sql.py"), "drop",
             "--user", data["user"], "--database", data["database"], "--access", data["access"]],
            env=data["env"])
        count += 1
    print(f"cleanup done ({count} step{'s' if count != 1 else ''})")


if __name__ == "__main__":
    main()
