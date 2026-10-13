output "database" {
  value = var.database
}

output "db_user" {
  value = local.db_user
}

output "role_arn" {
  value = aws_iam_role.app.arn
}

output "app_url" {
  description = "Open it after the apply finishes: the page shows the live database connection."
  value       = "https://${var.vercel_project}.vercel.app"
}
