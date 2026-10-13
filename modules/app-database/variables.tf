variable "platform" {
  description = "The shared platform: Vercel team and network, AWS account, Aurora cluster. apps/platform.tf builds this as local.platform."
  type = object({
    vercel_team         = string
    vercel_network_id   = string
    aws_region          = string
    aws_account_id      = string
    oidc_provider_arn   = string
    role_boundary_arn   = string
    cluster_arn         = string
    cluster_resource_id = string
    writer_endpoint     = string
    reader_endpoint     = string
    master_secret_arn   = string
  })
}

variable "vercel_project" {
  description = "Name of an existing Vercel project in the platform team."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,50}[a-z0-9])?$", var.vercel_project))
    error_message = "Use the Vercel project name: lowercase letters, digits and hyphens, at most 52 characters."
  }
}

variable "database" {
  description = "With access = \"owner\": the new database to create. With access = \"read\": an existing database that publishes a <database>_read profile."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,40}$", var.database))
    error_message = "Database names use lowercase letters, digits and underscores, start with a letter, at most 41 characters."
  }
}

variable "access" {
  description = "\"owner\" creates a new database that only this app uses. \"read\" attaches an existing database read-only."
  type        = string
  default     = "owner"

  validation {
    condition     = contains(["owner", "read"], var.access)
    error_message = "access must be \"owner\" or \"read\"."
  }
}

variable "environments" {
  description = "Vercel environments that get the database. They run on the Secure Compute network and may assume the app's role."
  type        = list(string)
  default     = ["production", "preview"]

  validation {
    condition     = length(var.environments) > 0 && alltrue([for e in var.environments : contains(["production", "preview"], e)])
    error_message = "environments may contain \"production\" and \"preview\"."
  }
}

variable "redeploy" {
  description = "Redeploy production after the database is ready, so the app picks up its configuration."
  type        = bool
  default     = true
}
