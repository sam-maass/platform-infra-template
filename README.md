# Non-public databases, one pull request at a time

This repository gives any Vercel project its own Postgres database, or read-only access to a shared one, when you merge a pull request. A few minutes after the merge, the app is redeployed, reaches the database over a private network, and signs in with an IAM token that expires after 15 minutes. The app never gets a database password, because none exists.

```hcl
module "my_application" {
  source   = "../modules/app-database"
  platform = local.platform

  vercel_project = "my-application"
  database       = "my_application"
  access         = "owner"
}
```

That block in `apps/apps.tf` is the whole request. Terraform, GitHub Actions, AWS IAM, Aurora and the Vercel API do the rest.

## Why you'd want it

Connecting an internal app to a database often means a ticket, a shared password pasted into environment variables, and a firewall rule that outlives the app.

| | ❌ Common setup | ✅ This pipeline |
|---|---|---|
| Asking for a database | Ticket to the platform team | Pull request, applied a few minutes after merge |
| App credentials | Long-lived password in env vars | IAM token signed at runtime, valid for 15 minutes |
| Who can use them | Anyone who copies the password | Only this project's production and preview deployments |
| Network path | Public endpoint or IP allowlist | Secure Compute network, peered with the database VPC |
| CI access to AWS | Access keys stored as CI secrets | GitHub OIDC, no AWS keys stored anywhere |
| Audit trail | Ticket comments | Git history, with the Terraform plan on every pull request |
| Removing an app | Manual cleanup, often skipped | Delete the block: database, login, role, env vars and network link go with it |

It suits platform teams that run internal tools and AI agents on Vercel and keep their data in AWS. Because a request is a small code change with a predictable plan, an agent can file one too, and it goes through the same plan and review. The repository includes a Claude Code skill for that.

## How it fits together

```mermaid
flowchart TB
    req["You or an agent"] -->|pull request| repo["GitHub repository"]
    repo --> actions["GitHub Actions<br/>plan on PR, apply on merge"]

    subgraph vercel["Vercel"]
        project["Vercel project<br/>env vars, deployments"]
        sc["Secure Compute network"]
    end

    subgraph aws["AWS"]
        iam["IAM<br/>app role + boundary"]
        aurora[("Aurora PostgreSQL<br/>private VPC")]
    end

    actions -->|"Vercel API: env vars, network, redeploy"| project
    actions -->|"GitHub OIDC: create the app role"| iam
    actions -->|"RDS Data API: database + login"| aurora
    project -->|"Vercel OIDC: assume the app role"| iam
    project --- sc
    sc -->|"VPC peering, TLS, IAM token"| aurora

    style actions stroke:#66f,stroke-width:3px
    style iam stroke:#f96,stroke-width:3px
    style aurora stroke:#6f6,stroke-width:3px
    style project stroke:#f9f,stroke-width:3px
```

Requests flow down through GitHub Actions, which sets up both sides. At runtime the app talks to AWS directly: it trades its Vercel OIDC token for the app role, then connects to Aurora through the Secure Compute network.

## Life of a request

```
1. Pull request   add a module block to apps/apps.tf
2. Plan           Actions runs terraform plan with a read-only AWS role and posts it as a comment
3. Review         one new app plans exactly "Plan: 11 to add, 0 to change, 0 to destroy."
4. Merge, apply   Actions applies with the apply role: database, IAM role, env vars, network, redeploy
5. Live           the redeployed app can sign in to its database
```

The plan takes under a minute. The apply takes a few minutes, most of it waiting for the production redeploy.

For read-only access to an existing database, use `access = "read"` and the database's name, for example `database = "hr_reporting"`.

## What one app gets

Each module call creates 11 resources:

| Resource | What it does |
|---|---|
| `terraform_data.database` | Creates the Postgres login `app_<project>` through the RDS Data API and, for `owner` access, a new database |
| `aws_iam_role.app` | The role `vercel-app-<project>`, which only this project's Vercel OIDC tokens can assume. The permissions boundary caps it. |
| `aws_iam_role_policy.db_connect` | Allows `rds-db:connect` as `app_<project>`, and nothing else |
| 6 × `vercel_project_environment_variable.app` | `AWS_ROLE_ARN`, `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_REGION` and `DB_ACCESS` for production and preview. None of them is a secret. |
| `terraform_data.network` | Runs the project's functions on the Secure Compute network |
| `terraform_data.redeploy` | Redeploys production and waits until the new deployment is ready |

`DB_HOST` is the cluster's writer endpoint for `owner` access and its reader endpoint for `read` access.

## How the app connects

```mermaid
sequenceDiagram
    autonumber
    participant F as Vercel Function
    participant STS as AWS STS
    participant DB as Aurora PostgreSQL
    Note over F: Request arrives with this project's OIDC token
    F->>STS: AssumeRoleWithWebIdentity with AWS_ROLE_ARN and the token
    STS-->>F: Temporary credentials, if aud and sub match the trust policy
    Note over F: Sign a 15-minute IAM auth token locally
    F->>DB: Connect as DB_USER over TLS, with the token as password
    DB-->>F: Session as the app's own login
```

In Python, with `boto3`, `psycopg` and Vercel's `vercel-oidc` package:

```python
import os

import boto3
import psycopg
from vercel.oidc.aio import get_vercel_oidc_token

# Vercel sends the OIDC token with each request. Add a middleware that calls
# vercel.headers.set_headers(request.headers) so the SDK can read it.


async def connect():
    region = os.environ["DB_REGION"]

    # 1. Trade the Vercel OIDC token for temporary credentials of the app role.
    credentials = boto3.client("sts", region_name=region).assume_role_with_web_identity(
        RoleArn=os.environ["AWS_ROLE_ARN"],
        RoleSessionName="vercel-app",
        WebIdentityToken=await get_vercel_oidc_token(),
    )["Credentials"]

    # 2. Sign a database token. This happens locally, with no network call.
    rds = boto3.client(
        "rds",
        region_name=region,
        aws_access_key_id=credentials["AccessKeyId"],
        aws_secret_access_key=credentials["SecretAccessKey"],
        aws_session_token=credentials["SessionToken"],
    )
    token = rds.generate_db_auth_token(
        DBHostname=os.environ["DB_HOST"], Port=5432, DBUsername=os.environ["DB_USER"], Region=region
    )

    # 3. Connect. Aurora accepts IAM tokens only over TLS. Use sslmode="verify-full"
    #    with the RDS CA bundle to verify the server certificate as well.
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=token,
        sslmode="require",
    )
```

## Exploring the repository

Read the files in this order to follow one request from the module block to the resources it creates, then the guardrails around it.

| # | File | What it holds | What to look for |
|---|---|---|---|
| 1 | [`apps/apps.tf`](apps/apps.tf) | The requests: one module call per app | Every request adds a block like the commented example. |
| 2 | [`modules/app-database/variables.tf`](modules/app-database/variables.tf) | What a request can say | Validation rejects bad project and database names before anything runs. `environments` accepts only production and preview. |
| 3 | [`modules/app-database/main.tf`](modules/app-database/main.tf) | The five steps for one app | Step 2's trust policy `sub` claims and the `precondition` that checks the issuer mode. Steps 1 and 4 keep what their destroy-time provisioners need in `input`. |
| 4 | [`modules/app-database/scripts/rds_sql.py`](modules/app-database/scripts/rds_sql.py) | The SQL behind step 1, through the RDS Data API | `create` and `drop`: a login without a password, the `rds_iam` grant, the guardrails and both access levels. `ident()` and `literal()` validate every name, so a name can't inject SQL. |
| 5 | [`modules/app-database/scripts/vercel_api.py`](modules/app-database/scripts/vercel_api.py) | Steps 4 and 5, through the Vercel API | `connectConfigurations` on the project, then a redeploy of the current production deployment. |
| 6 | [`apps/platform.tf`](apps/platform.tf) | Where `local.platform` comes from | It only looks up the shared cluster, the Vercel OIDC provider and the boundary, and creates nothing. |
| 7 | [`bootstrap/main.tf`](bootstrap/main.tf) | One-time setup: state bucket, pipeline roles, boundary, `hr_reporting` | The GitHub OIDC trust conditions of the plan and apply roles, the `vercel-app-boundary` policy, and the `iam:PermissionsBoundary` condition and explicit deny that make the boundary mandatory. |
| 8 | [`.github/workflows/apps.yml`](.github/workflows/apps.yml) | Plan on pull requests, apply on merge | How the plan comment is posted, and the cleanup step between plan and apply. |
| 9 | [`modules/app-database/scripts/cleanup_removed.py`](modules/app-database/scripts/cleanup_removed.py) | Cleanup for removed module calls | Terraform skips destroy-time provisioners when a module call disappears, so this script reads the saved plan and runs those steps itself. |
| 10 | [`sql/hr_reporting.sql`](sql/hr_reporting.sql) | An example shared database | A raw table, curated views over it, and the `hr_reporting_read` profile apps get. |
| 11 | [`.claude/skills/provision-app-database/SKILL.md`](.claude/skills/provision-app-database/SKILL.md) | The request flow, written for an agent | The checks the agent must pass before it merges. |
|  | [`modules/app-database/outputs.tf`](modules/app-database/outputs.tf) | Database, login, role ARN and app URL for each app |  |
|  | [`apps/terraform.tfvars.example`](apps/terraform.tfvars.example) | Platform values for local plans |  |
|  | [`bootstrap/terraform.tfvars.example`](bootstrap/terraform.tfvars.example) | Values for the bootstrap |  |

For the security model alone, read 3, 4 and 7.

> [!IMPORTANT]
> Keep your working copy private. Plan comments and workflow logs include your AWS account ID, resource ARNs and Vercel project IDs.
