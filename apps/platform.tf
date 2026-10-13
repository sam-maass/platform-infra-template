# The shared platform every app plugs into. Set up once by the platform team;
# this file only looks it up. GitHub Actions applies apps/ on every merge.

terraform {
  required_version = ">= 1.10"

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

  # bucket and region come from `terraform init -backend-config=...`
  # (the workflow passes the TF_STATE_BUCKET and AWS_REGION repository variables).
  backend "s3" {
    key          = "apps/terraform.tfstate"
    use_lockfile = true
  }
}

# Set in GitHub Actions from repository variables (TF_VAR_*), or locally in a
# git-ignored terraform.tfvars (see terraform.tfvars.example).
variable "vercel_team" {
  description = "Slug of the Vercel team that owns the app projects."
  type        = string
}

variable "vercel_network_id" {
  description = "ID of the Vercel Secure Compute network peered with the database VPC."
  type        = string
}

variable "aws_region" {
  description = "AWS region of the shared Aurora cluster."
  type        = string
}

variable "cluster_identifier" {
  description = "Identifier of the shared Aurora PostgreSQL cluster."
  type        = string
}

locals {
  vercel_team        = var.vercel_team
  vercel_network_id  = var.vercel_network_id
  aws_region         = var.aws_region
  cluster_identifier = var.cluster_identifier
}

# AWS: GitHub's OIDC token, exchanged for the pipeline role. No stored keys.
provider "aws" {
  region = local.aws_region

  default_tags {
    tags = {
      ManagedBy = "platform-infra/apps"
    }
  }
}

# Vercel: VERCEL_API_TOKEN, a repository secret.
provider "vercel" {
  team = local.vercel_team
}

data "aws_caller_identity" "current" {}

data "aws_rds_cluster" "shared" {
  cluster_identifier = local.cluster_identifier
}

data "aws_iam_openid_connect_provider" "vercel" {
  url = "https://oidc.vercel.com/${local.vercel_team}"
}

data "aws_iam_policy" "app_boundary" {
  name = "vercel-app-boundary"
}

locals {
  platform = {
    vercel_team         = local.vercel_team
    vercel_network_id   = local.vercel_network_id
    aws_region          = local.aws_region
    aws_account_id      = data.aws_caller_identity.current.account_id
    oidc_provider_arn   = data.aws_iam_openid_connect_provider.vercel.arn
    role_boundary_arn   = data.aws_iam_policy.app_boundary.arn
    cluster_arn         = data.aws_rds_cluster.shared.arn
    cluster_resource_id = data.aws_rds_cluster.shared.cluster_resource_id
    writer_endpoint     = data.aws_rds_cluster.shared.endpoint
    reader_endpoint     = data.aws_rds_cluster.shared.reader_endpoint
    master_secret_arn   = data.aws_rds_cluster.shared.master_user_secret[0].secret_arn
  }
}
