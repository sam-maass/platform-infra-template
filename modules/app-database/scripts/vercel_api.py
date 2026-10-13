#!/usr/bin/env python3
"""Vercel REST API calls for the steps the Terraform module runs as scripts.

Standard library only (Python 3.9+). Reads VERCEL_API_TOKEN from the environment.

Commands:
  link-network   --team T --project-id P --network N --environments production,preview
  unlink-network --team T --project-id P
  redeploy       --team T --project-id P [--wait-seconds 600]
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.vercel.com"


def call(method, path, team, body=None, query=None):
    params = {"slug": team}
    params.update(query or {})
    url = f"{API}{path}?{urllib.parse.urlencode(params)}"
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", "Bearer " + os.environ["VERCEL_API_TOKEN"])
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:500]
        sys.exit(f"Vercel API {method} {path} failed with {error.code}: {detail}")


def link_network(team, project_id, network, environments):
    # The project's functions in these environments run on the Secure Compute
    # network, so they can reach the database over the VPC peering.
    configurations = [
        {
            "envId": env,
            "connectConfigurationId": network,
            "passive": False,
            "buildsEnabled": False,  # the build doesn't need the database
        }
        for env in environments
    ]
    call("PATCH", f"/v9/projects/{project_id}", team, {"connectConfigurations": configurations})
    print(f"linked {', '.join(environments)} to network {network}")


def unlink_network(team, project_id):
    # The API rejects an empty list (minItems 1); null removes every link.
    call("PATCH", f"/v9/projects/{project_id}", team, {"connectConfigurations": None})
    print("unlinked from the Secure Compute network")


def redeploy(team, project_id, wait_seconds):
    # Env vars and the network link only apply to new deployments.
    found = call("GET", "/v6/deployments", team, query={
        "projectId": project_id, "target": "production", "state": "READY", "limit": "1",
    }).get("deployments", [])
    if not found:
        print("no production deployment yet: the first deployment will pick up the configuration")
        return
    latest = found[0]
    created = call("POST", "/v13/deployments", team, {
        "name": latest["name"],
        "deploymentId": latest["uid"],
        "target": "production",
    }, query={"forceNew": "1"})
    deployment_id = created["id"]
    print(f"redeploying production as {deployment_id}", flush=True)

    deadline = time.time() + wait_seconds
    while time.time() < deadline:
        state = call("GET", f"/v13/deployments/{deployment_id}", team).get("readyState")
        if state == "READY":
            print("production deployment is ready")
            return
        if state in ("ERROR", "CANCELED"):
            sys.exit(f"redeploy ended as {state}")
        time.sleep(10)
    sys.exit(f"redeploy not ready after {wait_seconds}s")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("link-network", "unlink-network", "redeploy"):
        p = sub.add_parser(name)
        p.add_argument("--team", required=True)
        p.add_argument("--project-id", required=True)
        if name == "link-network":
            p.add_argument("--network", required=True)
            p.add_argument("--environments", required=True)
        if name == "redeploy":
            p.add_argument("--wait-seconds", type=int, default=600)
    args = parser.parse_args()

    if not os.environ.get("VERCEL_API_TOKEN"):
        sys.exit("missing environment variable: VERCEL_API_TOKEN")

    if args.command == "link-network":
        link_network(args.team, args.project_id, args.network, args.environments.split(","))
    elif args.command == "unlink-network":
        unlink_network(args.team, args.project_id)
    else:
        redeploy(args.team, args.project_id, args.wait_seconds)


if __name__ == "__main__":
    main()
