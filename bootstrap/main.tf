# One-time setup by a platform admin, applied from a laptop (local state).
# Everything per app happens later in apps/, applied by GitHub Actions.
#
# Creates:
#   - the S3 bucket for apps/ state
#   - GitHub's OIDC provider and two roles: plan (pull requests, read-only)
#     and apply (main branch). No AWS keys are stored in GitHub.
#   - the permissions boundary every app role must carry
#   - hr_reporting, an existing database that apps can attach read-only

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "eu-central-1"
}

variable "github_repository" {
  description = "owner/name of this repository, for descriptions."
  type        = string
}

variable "github_sub_prefix" {
  description = <<-EOT
    Start of the OIDC sub claim for this repository. New repositories use GitHub's
    immutable format, which includes the owner and repository IDs, so a renamed or
    re-created repository can't inherit the trust. Read it with:
    gh api repos/OWNER/REPO/actions/oidc/customization/sub --jq .sub_claim_prefix
  EOT
  type        = string
}

variable "vercel_team" {
  description = "Vercel team slug. Its OIDC provider already exists in AWS (created with the shared cluster)."
  type        = string
}

variable "cluster_identifier" {
  description = "The shared Aurora cluster, created with the platform network."
  type        = string
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      ManagedBy = "platform-infra/bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_rds_cluster" "shared" {
  cluster_identifier = var.cluster_identifier
}

data "aws_iam_openid_connect_provider" "vercel" {
  url = "https://oidc.vercel.com/${var.vercel_team}"
}

locals {
  account_id    = data.aws_caller_identity.current.account_id
  state_bucket  = "platform-infra-tfstate-${local.account_id}"
  secret_arn    = data.aws_rds_cluster.shared.master_user_secret[0].secret_arn
  app_roles_arn = "arn:aws:iam::${local.account_id}:role/vercel-app-*"
}

# --- State for apps/ ---------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- The most an app role can ever do ----------------------------------------
# Every role the pipeline creates must carry this boundary: sign in to the
# shared cluster as an app_* database user. Nothing else, whatever its own
# policy says.

resource "aws_iam_policy" "app_boundary" {
  name        = "vercel-app-boundary"
  description = "Upper limit for Vercel app roles: connect to the shared Aurora cluster as an app_* user"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "rds-db:connect"
      Resource = "arn:aws:rds-db:${var.aws_region}:${local.account_id}:dbuser:${data.aws_rds_cluster.shared.cluster_resource_id}/app_*"
    }]
  })
}

# --- GitHub Actions, without stored AWS keys ---------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "trust" {
  for_each = {
    plan  = "${var.github_sub_prefix}:pull_request"
    apply = "${var.github_sub_prefix}:ref:refs/heads/main"
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value]
    }
  }
}

# Both roles: read what apps/ manages, and use the state bucket.
data "aws_iam_policy_document" "read" {
  statement {
    sid       = "SharedCluster"
    actions   = ["rds:DescribeDBClusters"]
    resources = [data.aws_rds_cluster.shared.arn]
  }

  statement {
    sid       = "PlatformLookups"
    actions   = ["iam:ListOpenIDConnectProviders", "iam:ListPolicies"]
    resources = ["*"]
  }

  statement {
    sid       = "VercelOidcProvider"
    actions   = ["iam:GetOpenIDConnectProvider"]
    resources = [data.aws_iam_openid_connect_provider.vercel.arn]
  }

  statement {
    sid       = "Boundary"
    actions   = ["iam:GetPolicy", "iam:GetPolicyVersion"]
    resources = [aws_iam_policy.app_boundary.arn]
  }

  statement {
    sid = "ReadAppRoles"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRoleTags",
    ]
    resources = [local.app_roles_arn]
  }

  statement {
    sid       = "StateList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "StateRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.state.arn}/apps/*"]
  }

  statement {
    sid       = "StateLock"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/apps/*.tflock"]
  }
}

# Apply only: create app roles (always with the boundary), run the database
# setup through the Data API, and write state.
data "aws_iam_policy_document" "write" {
  statement {
    sid       = "AppRolesWithBoundary"
    actions   = ["iam:CreateRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy"]
    resources = [local.app_roles_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.app_boundary.arn]
    }
  }

  statement {
    sid = "ManageAppRoles"
    actions = [
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = [local.app_roles_arn]
  }

  statement {
    sid       = "KeepTheBoundary"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary", "iam:PutRolePermissionsBoundary"]
    resources = ["*"]
  }

  statement {
    sid       = "DatabaseSetup"
    actions   = ["rds-data:ExecuteStatement", "rds-data:BatchExecuteStatement"]
    resources = [data.aws_rds_cluster.shared.arn]
  }

  statement {
    sid       = "DatabaseSetupSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.secret_arn]
  }

  statement {
    sid       = "StateWrite"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/apps/*"]
  }
}

resource "aws_iam_role" "pipeline" {
  for_each = data.aws_iam_policy_document.trust

  name                 = "platform-infra-${each.key}"
  description          = "GitHub Actions in ${var.github_repository}: terraform ${each.key} for apps/"
  assume_role_policy   = each.value.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "read" {
  for_each = aws_iam_role.pipeline

  name   = "read"
  role   = each.value.id
  policy = data.aws_iam_policy_document.read.json
}

resource "aws_iam_role_policy" "write" {
  name   = "write"
  role   = aws_iam_role.pipeline["apply"].id
  policy = data.aws_iam_policy_document.write.json
}

# --- An existing database apps can attach read-only --------------------------
# Synthetic data. Apps see the reporting views through the hr_reporting_read
# profile, never the raw table.

resource "terraform_data" "hr_reporting" {
  triggers_replace = [filesha1("${path.module}/../sql/hr_reporting.sql"), data.aws_rds_cluster.shared.arn]

  provisioner "local-exec" {
    command = <<-EOT
      python3 '${path.module}/../modules/app-database/scripts/rds_sql.py' ensure-database --database hr_reporting
      python3 '${path.module}/../modules/app-database/scripts/rds_sql.py' run-file --database hr_reporting --file '${path.module}/../sql/hr_reporting.sql'
    EOT

    environment = {
      AWS_REGION      = var.aws_region
      RDS_CLUSTER_ARN = data.aws_rds_cluster.shared.arn
      RDS_SECRET_ARN  = local.secret_arn
    }
  }
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "github_variables" {
  description = "Set these as repository variables: gh variable set NAME --body VALUE. Also set VERCEL_NETWORK_ID."
  value = {
    AWS_REGION         = var.aws_region
    AWS_PLAN_ROLE_ARN  = aws_iam_role.pipeline["plan"].arn
    AWS_APPLY_ROLE_ARN = aws_iam_role.pipeline["apply"].arn
    TF_STATE_BUCKET    = aws_s3_bucket.state.bucket
    VERCEL_TEAM        = var.vercel_team
    CLUSTER_IDENTIFIER = var.cluster_identifier
  }
}
