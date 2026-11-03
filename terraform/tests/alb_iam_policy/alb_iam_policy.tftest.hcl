# Regression guard for the ALB controller IAM policy source:
#   - alb_controller_iam_policy_source = "file" must work out of the box for
#     the default app version (the bundled copy used to be missing from the
#     repo — it was .gitignored as a legacy-script download cache), and
#   - both modes must pick the partition-specific upstream variant
#     (iam_policy.json / _cn / _us-gov / _iso / _isob) — the commercial
#     document's arn:aws: resources match nothing in China / GovCloud.

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

variables {
  cluster_name                 = "test-cluster"
  vpc_id                       = "vpc-12345678"
  region                       = "us-west-2"
  k8s_version                  = "1.34"
  alb_controller_chart_version = "1.16.0"
  alb_controller_app_version   = "v2.14.1"
  system_node_label_key        = "workload-type"
  system_node_label_value      = "eks-utils"
}

run "file_mode_commercial" {
  command = plan

  module {
    source = "../../modules/eks-addons"
  }

  variables {
    alb_controller_iam_policy_source = "file"
  }

  assert {
    condition     = aws_iam_policy.alb_controller.policy == file("../../assets/iam/alb-controller/v2.14.1/iam_policy.json")
    error_message = "file mode must use the bundled v2.14.1 commercial policy verbatim."
  }
  assert {
    condition     = length(data.http.alb_iam_policy) == 0
    error_message = "file mode must not fetch the policy over HTTP."
  }
}

run "file_mode_china" {
  command = plan

  module {
    source = "../../modules/eks-addons"
  }

  variables {
    alb_controller_iam_policy_source = "file"
  }

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws-cn" }
  }

  assert {
    condition     = aws_iam_policy.alb_controller.policy == file("../../assets/iam/alb-controller/v2.14.1/iam_policy_cn.json")
    error_message = "aws-cn must use the bundled iam_policy_cn.json (arn:aws-cn: resources)."
  }
  assert {
    condition     = !strcontains(aws_iam_policy.alb_controller.policy, "arn:aws:")
    error_message = "the aws-cn policy must not contain commercial arn:aws: resources."
  }
}

run "file_mode_missing_version_fails_clearly" {
  command = plan

  module {
    source = "../../modules/eks-addons"
  }

  variables {
    alb_controller_iam_policy_source = "file"
    alb_controller_app_version       = "v9.9.9"
  }

  expect_failures = [aws_iam_policy.alb_controller]
}

run "http_mode_govcloud_url" {
  command = plan

  module {
    source = "../../modules/eks-addons"
  }

  variables {
    alb_controller_iam_policy_source = "http"
  }

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws-us-gov" }
  }

  assert {
    condition     = data.http.alb_iam_policy[0].url == "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/iam_policy_us-gov.json"
    error_message = "http mode must fetch the partition-specific upstream policy (iam_policy_us-gov.json for aws-us-gov)."
  }
}

run "unknown_partition_fails_clearly" {
  command = plan

  module {
    source = "../../modules/eks-addons"
  }

  variables {
    alb_controller_iam_policy_source = "http"
  }

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws-unknown" }
  }

  expect_failures = [aws_iam_policy.alb_controller]
}
