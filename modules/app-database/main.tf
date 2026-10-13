# One Vercel project gets one database user on the shared Aurora cluster:
# either a new database it owns, or read-only access to an existing one.
# No password exists anywhere. The app signs in with a 15-minute IAM token,
# using an IAM role it assumes through Vercel OIDC.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    vercel = {
      source  = "vercel/vercel"
      version = "~> 5.21"
    }
  }
}

data "vercel_project" "app" {
  name = var.vercel_project
}

locals {
  p       = var.platform
  db_user = "app_${replace(var.vercel_project, "-", "_")}"
  db_host = var.access == "owner" ? local.p.writer_endpoint : local.p.reader_endpoint
  issuer  = "oidc.vercel.com/${local.p.vercel_team}"
  scripts = "${path.module}/scripts"
  sql_env = {
    AWS_REGION      = local.p.aws_region
    RDS_CLUSTER_ARN = local.p.cluster_arn
    RDS_SECRET_ARN  = local.p.master_secret_arn
  }
}

# 1. Database and user, through the RDS Data API. It's a regular AWS API, so
#    the pipeline needs no network path into the private VPC.
resource "terraform_data" "database" {
  triggers_replace = [local.db_user, var.database, var.access, local.p.cluster_arn]

  # Destroy-time provisioners may only read self, so keep what they need here.
  input = {
    user     = local.db_user
    database = var.database
    access   = var.access
    script   = "${local.scripts}/rds_sql.py"
    env      = local.sql_env
  }

  provisioner "local-exec" {
    command     = "python3 '${self.input.script}' create --user '${self.input.user}' --database '${self.input.database}' --access '${self.input.access}'"
    environment = self.input.env
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "python3 '${self.input.script}' drop --user '${self.input.user}' --database '${self.input.database}' --access '${self.input.access}'"
    environment = self.input.env
  }
}

# 2. The app's AWS identity. Only this project's OIDC tokens, in these
#    environments, can assume it. The permissions boundary caps it at
#    "connect to the shared cluster", whatever its own policy says.
resource "aws_iam_role" "app" {
  name                 = "vercel-app-${var.vercel_project}"
  description          = "Vercel project ${var.vercel_project}: ${var.access} access to ${var.database}"
  permissions_boundary = local.p.role_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = local.p.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${local.issuer}:aud" = "https://vercel.com/${local.p.vercel_team}"
          "${local.issuer}:sub" = [
            for env in var.environments :
            "owner:${local.p.vercel_team}:project:${var.vercel_project}:environment:${env}"
          ]
        }
      }
    }]
  })

  lifecycle {
    precondition {
      # The trust policy expects tokens from https://oidc.vercel.com/<team>.
      condition     = try(data.vercel_project.app.oidc_token_config.issuer_mode, "") == "team"
      error_message = "Set ${var.vercel_project}'s OIDC Federation issuer mode to Team (Project Settings, Security)."
    }
  }
}

resource "aws_iam_role_policy" "db_connect" {
  name = "connect-as-${local.db_user}"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "rds-db:connect"
      Resource = "arn:aws:rds-db:${local.p.aws_region}:${local.p.aws_account_id}:dbuser:${local.p.cluster_resource_id}/${local.db_user}"
    }]
  })
}

# 3. Configuration for the app. None of it is secret.
resource "vercel_project_environment_variable" "app" {
  for_each = {
    AWS_ROLE_ARN = aws_iam_role.app.arn
    DB_HOST      = local.db_host
    DB_NAME      = var.database
    DB_USER      = local.db_user
    DB_REGION    = local.p.aws_region
    DB_ACCESS    = var.access
  }

  project_id = data.vercel_project.app.id
  key        = each.key
  value      = each.value
  target     = var.environments
  sensitive  = false
  comment    = "Not a secret. Managed by platform-infra"
}

# 4. Run the project's functions on the Secure Compute network, which is peered
#    with the database VPC. A helper script sets the link through the Vercel REST API.
resource "terraform_data" "network" {
  triggers_replace = [data.vercel_project.app.id, local.p.vercel_network_id, join(",", var.environments)]

  input = {
    script     = "${local.scripts}/vercel_api.py"
    team       = local.p.vercel_team
    project_id = data.vercel_project.app.id
  }

  provisioner "local-exec" {
    command = "python3 '${self.input.script}' link-network --team '${self.input.team}' --project-id '${self.input.project_id}' --network '${local.p.vercel_network_id}' --environments '${join(",", var.environments)}'"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "python3 '${self.input.script}' unlink-network --team '${self.input.team}' --project-id '${self.input.project_id}'"
  }
}

# 5. Redeploy production so the running app picks all of this up.
resource "terraform_data" "redeploy" {
  count = var.redeploy ? 1 : 0

  triggers_replace = [
    terraform_data.database.id,
    terraform_data.network.id,
    aws_iam_role_policy.db_connect.id,
    sha1(jsonencode({ for k, v in vercel_project_environment_variable.app : k => v.value })),
  ]

  provisioner "local-exec" {
    command = "python3 '${local.scripts}/vercel_api.py' redeploy --team '${local.p.vercel_team}' --project-id '${data.vercel_project.app.id}'"
  }
}
