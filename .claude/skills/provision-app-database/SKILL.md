---
name: provision-app-database
description: Connect a database to a Vercel project in the platform team through the platform pipeline in this GitHub repository (<owner>/<repo>). Use when someone asks to give a Vercel app a database, create a new database for a project, or attach an existing database such as hr_reporting. Works directly against GitHub with no local checkout. It adds a module call to apps/apps.tf on a new branch, opens a pull request, checks the Terraform plan, merges, waits for the GitHub Actions apply, and verifies the live app. Never runs Terraform itself.
---

# Provision a database for a Vercel project

Setup: replace `<owner>/<repo>`, `<owner>`, `<repo>` and `<team>` in this file with your repository and Vercel team.

You act for the person asking, entirely through GitHub. You don't need a local copy of the repository. The change is a pull request in `<owner>/<repo>`. After the merge, GitHub Actions applies it with its own short-lived AWS role. You never run Terraform, never use AWS credentials, and never print tokens.

## Constants

| Item | Value |
|---|---|
| Repository | `<owner>/<repo>`, base branch `main` |
| File to change | `apps/apps.tf` |
| Vercel team | `<team>` |
| Workflow | `apps.yml`: job `plan` on pull requests, job `apply` on pushes to `main` |
| Attachable databases | `hr_reporting` (headcount views, synthetic data), read-only |

## Tools

Use whichever is available:

- **GitHub connector** (Claude desktop app, chat or Cowork): the GitHub MCP server tools `get_file_contents`, `create_branch`, `create_or_update_file`, `create_pull_request`, `pull_request_read`, `merge_pull_request`, and the Actions tools for workflow runs.
- **gh CLI** (Claude Code): the `gh` commands in each step, always against `<owner>/<repo>`. No clone needed.

If neither is available, stop and tell the person to add the GitHub connector (Customize → Connectors) with write access to the repository and the Actions tools enabled.

## 1. Pin down the request

You need two answers. Ask only for what the person hasn't said.

- **Vercel project:** the exact project name in the `<team>` team. If it doesn't exist, the plan in step 4 fails with an error about the project. Report that and stop.
- **Database:** either
  - a **new database** owned by the app (`access = "owner"`). Default name: the project name with hyphens replaced by underscores. Rules: start with a letter; lowercase letters, digits and underscores; at most 41 characters; not `postgres`, `template0`, `template1`, `rdsadmin` or `hr_reporting`.
  - an **existing database**, read-only (`access = "read"`). Attachable today: `hr_reporting` only.

## 2. Read the file and prepare the change

Read `apps/apps.tf` from `main`, and keep its blob `sha`. You need it to update the file.

- Connector: `get_file_contents` with owner `<owner>`, repo `<repo>`, path `apps/apps.tf`, ref `main`.
- gh: `gh api 'repos/<owner>/<repo>/contents/apps/apps.tf?ref=main'`. The `content` field is base64; `sha` is the blob sha.

Stop if the file already contains `vercel_project = "<project>"`. One project gets one database. Also stop if the branch `app/<project>` already exists (create_branch fails), and tell the person.

The new file content is the current content, then one blank line, then exactly this block. It's the same code the portal generates. Module name: the project name with hyphens replaced by underscores, prefixed with `app_` if it starts with a digit.

```hcl
# <project>: new database, owned by the app
module "<module_name>" {
  source   = "../modules/app-database"
  platform = local.platform

  vercel_project = "<project>"
  database       = "<database>"
  access         = "owner"
}
```

For an existing database, use `access         = "read"` and the comment `# <project>: read-only access to <database>`. Keep the alignment exactly as shown and end the file with a newline. The plan check runs `terraform fmt -check` and fails on misaligned `=` signs.

## 3. Branch, commit, pull request

1. Create the branch `app/<project>` from `main`.
   - Connector: `create_branch` with branch `app/<project>`, from_branch `main`.
   - gh: `gh api repos/<owner>/<repo>/git/refs -f ref=refs/heads/app/<project> -f sha=<sha of main>`. Get the sha with `gh api repos/<owner>/<repo>/git/ref/heads/main --jq .object.sha`.
2. Commit the new content of `apps/apps.tf` to that branch. Message: `Connect <database> to <project> (<access>)`. Pass the blob sha from step 2.
   - Connector: `create_or_update_file` with path `apps/apps.tf`, the full new content, message, branch `app/<project>`, and sha.
   - gh: `gh api -X PUT repos/<owner>/<repo>/contents/apps/apps.tf -f message='<message>' -f branch=app/<project> -f sha=<blob sha> -f content=<new content, base64 without line breaks>`.
3. Open the pull request. Title: `Connect <database> to <project>`. Body: `Requested by <person> through the provision-app-database skill. access = <access>.`
   - Connector: `create_pull_request` with head `app/<project>`, base `main`, title, body.
   - gh: `gh pr create -R <owner>/<repo> --head app/<project> --base main --title '<title>' --body '<body>'`.

## 4. Check the plan

The `plan` check takes about 40 seconds. Check every 20 seconds or so until it finishes. Then read the newest pull request comment, which starts with "### Terraform plan for `apps/`".

- Connector: `pull_request_read` with method `get_check_runs` for the checks (wait until `plan` has status `completed`; `apply` shows `skipped` on pull requests), then method `get_comments` for the comment. Don't use `get_status`: GitHub Actions reports check runs, so it always shows `pending`.
- gh: `gh pr checks <number> -R <owner>/<repo> --watch`, then `gh pr view <number> -R <owner>/<repo> --comments`.

Expect `Plan: 11 to add, 0 to change, 0 to destroy.` for one app. If the plan changes or destroys anything, or the check failed, stop and show the person the plan or the error. Don't merge.

## 5. Merge, and wait for the apply

Self-service requests (a new database, or `hr_reporting` read-only) may be merged directly. For anything else, stop and ask the data owner to approve the pull request.

- Connector: `merge_pull_request` with merge_method `squash`.
- gh: `gh pr merge <number> -R <owner>/<repo> --squash --delete-branch`.

Then follow the newest run of the `apps.yml` workflow on `main` that the merge triggered (event `push`). Check every 30 seconds or so until it completes. It takes about 3 minutes, including a fresh production deployment of the app.

- Connector: `actions_list` with method `list_workflow_runs`, resource_id `apps.yml`, and workflow_runs_filter `{"branch": "main", "event": "push"}`. Take the newest run whose title matches the merged pull request, then call `actions_get` with method `get_workflow_run` and that run ID until its status is `completed`.
- gh: `gh run list -R <owner>/<repo> --workflow apps.yml --branch main --event push --limit 1`, then `gh run watch <run-id> -R <owner>/<repo> --exit-status`.

If the run failed, report it with the failing job's log.

## 6. Verify the app

Fetch `https://<project>.vercel.app/api/db`, with web fetch or `curl -sS`.

Success: `"connected": true`, `db_user` is `app_` plus the project name with underscores, `db_server_private_ip` is a private address in the database VPC, and `tls` is `true`. For `hr_reporting`, `tables` lists the `reporting.*` views. Report those values and the pull request link.

If the URL can't be fetched (a protected deployment or a different domain), ask the person to open the app. The page shows "Connected to <database>". If it reports an error, show its `reason` field.

## Rules

- Change only `apps/apps.tf`, and only through a pull request. Never commit to `main` directly.
- Never run Terraform, and never change anything in AWS.
- Never print or paste tokens or secrets.
