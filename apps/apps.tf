# One module call per app. Paste the snippet from the portal below, open a
# pull request, and merge it: GitHub Actions applies it.
#
# Example:
#
# # my-application: new database, owned by the app
# module "my_application" {
#   source   = "../modules/app-database"
#   platform = local.platform
#
#   vercel_project = "my-application"
#   database       = "my_application"
#   access         = "owner"
# }
