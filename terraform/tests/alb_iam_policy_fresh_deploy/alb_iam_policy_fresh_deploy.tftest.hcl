# Regression guard: the FIRST plan of a brand-new cluster must succeed in both
# alb_controller_iam_policy_source modes.
#
# modules/eks-addons is called with depends_on on resources that are still
# pending on a fresh deploy, so data.aws_partition (and every value derived
# from it) is unknown at plan time. data.http.alb_iam_policy's count used to
# include `local.alb_iam_policy_file != ""` (derived from the partition) and
# failed every fresh deploy with "Invalid count argument" in the default
# "http" mode. count must depend only on plan-time-known inputs.
#
# The partition-specific behaviour itself (URL / bundled file per partition,
# unknown-partition precondition) is covered by tests/alb_iam_policy.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_eks_addon_version" {
    defaults = { version = "v1.0.0-eksbuild.1" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/mock" }
  }
}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "time" {}
mock_provider "http" {
  mock_data "http" {
    defaults = { response_body = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

run "fresh_deploy_file_mode_plans" {
  command = plan

  variables {
    alb_controller_iam_policy_source = "file"
  }
}

run "fresh_deploy_http_mode_plans" {
  command = plan

  variables {
    alb_controller_iam_policy_source = "http"
  }
}
