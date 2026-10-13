# platform-infra

Connects databases to Vercel projects. Each app gets either a new database of its own or read-only access to an existing one, both on a shared Aurora cluster in a private AWS VPC. A pull request requests the change; merging it applies it. There are no passwords and no tickets.

```
portal or agent ──▶ pull request ──▶ GitHub Actions ──▶ AWS: database user, IAM role
  (module call)      (plan comment)    (apply on merge)  Vercel: env vars, network, redeploy
```

## What happens for one app

`apps/apps.tf` holds one module call per app (`modules/app-database`). Applying it:

1. Creates the database user, and for a new database the database itself, through the RDS Data API. The pipeline needs no network path into the VPC.
2. Creates an IAM role that only this Vercel project's OIDC tokens can assume. It's capped by a permissions boundary: at most, connect to the shared cluster as an `app_*` user.
3. Sets the project's non-secret env vars (`AWS_ROLE_ARN`, `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_REGION`, `DB_ACCESS`).
4. Runs the project on the Secure Compute network, which is peered with the database VPC.
5. Redeploys production so the app picks up the change.

At runtime the app exchanges its Vercel OIDC token for the role, signs a 15-minute IAM database token, and connects over TLS.

## Credentials

| Who | Authenticates with | Stored secret |
|---|---|---|
| GitHub Actions → AWS | GitHub OIDC token → `platform-infra-plan` (pull requests) or `platform-infra-apply` (main) | None |
| GitHub Actions → Vercel | `VERCEL_API_TOKEN` repository secret, scoped to the team | One |
| App → AWS and database | Vercel OIDC token → app role → IAM database token | None |

## Layout

| Path | Applied by | Purpose |
|---|---|---|
| `bootstrap/` | A platform admin, once, locally | State bucket, GitHub OIDC roles, app role boundary, the attachable `hr_reporting` database |
| `apps/` | GitHub Actions | One module call per app |
| `modules/app-database/` | | The per-app module and its helper scripts (standard library Python plus the AWS CLI) |
| `.claude/skills/provision-app-database/` | | Lets Claude Code make the same request through a pull request |

## Prerequisites

The pipeline plugs into a shared platform that exists before it:

- A Vercel team with a Secure Compute network, peered with an AWS VPC.
- An Aurora PostgreSQL cluster in that VPC with IAM database authentication, the RDS Data API, and an RDS-managed master secret.
- An IAM OIDC provider for the team's Vercel issuer (`https://oidc.vercel.com/<team>`). App projects use the Team issuer mode.

## Setup

1. Copy `bootstrap/terraform.tfvars.example` to `bootstrap/terraform.tfvars`, fill it in, and apply `bootstrap/` once with admin credentials.
2. Set the repository variables from the `github_variables` output, plus `VERCEL_NETWORK_ID`: `gh variable set NAME --body VALUE`.
3. Add a Vercel access token scoped to the team as the `VERCEL_API_TOKEN` repository secret.
4. In `.claude/skills/provision-app-database/SKILL.md`, replace `<owner>/<repo>` and `<team>` with your values.

Keep your working copy private. Plan comments and workflow logs include your AWS account ID, resource ARNs, and Vercel project IDs.

## Removing an app

Delete its module call in a pull request and merge it. The apply drops the app's login, drops its database if the app owns it, unlinks the network, and deletes the role and env vars. Terraform skips destroy-time provisioners when a module call is removed, so the apply job runs those steps from the saved plan first (`modules/app-database/scripts/cleanup_removed.py`).
