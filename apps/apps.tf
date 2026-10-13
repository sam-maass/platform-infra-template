# One module call per app. Paste the snippet from the portal below, open a
# pull request, and merge it: GitHub Actions applies it.
#
# Example:
#
# # expense-tracker: new database, owned by the app
# module "expense_tracker" {
#   source   = "../modules/app-database"
#   platform = local.platform
#
#   vercel_project = "expense-tracker"
#   database       = "expense_tracker"
#   access         = "owner"
# }
