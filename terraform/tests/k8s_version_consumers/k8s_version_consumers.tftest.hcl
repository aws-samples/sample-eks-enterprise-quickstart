# Version-dependent consumers of the resolved Kubernetes / Karpenter version.

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
  mock_resource "aws_sqs_queue" {
    defaults = {
      arn = "arn:aws:sqs:us-west-2:123456789012:mock"
      url = "https://sqs.us-west-2.amazonaws.com/123456789012/mock"
    }
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
  cluster_name                     = "test-cluster"
  vpc_id                           = "vpc-12345678"
  region                           = "us-west-2"
  install_cluster_autoscaler       = true
  alb_controller_iam_policy_source = "file"
  alb_controller_chart_version     = "1.14.0"
  alb_controller_app_version       = "v2.14.1"
  system_node_label_key            = "app"
  system_node_label_value          = "eks-utils"
  cluster_endpoint                 = "https://ABC.gr7.us-west-2.eks.amazonaws.com"
  cluster_security_group_id        = "sg-12345678"
  private_subnet_ids               = ["subnet-11111111", "subnet-22222222"]
}

# --- Cluster Autoscaler matrix (existing rows must not move) -----------
run "ca_row_135_unchanged" {
  command = plan
  module {
    source = "../../modules/eks-addons"
  }
  variables {
    k8s_version = "1.35"
  }
  assert {
    condition     = helm_release.cluster_autoscaler[0].version == "9.57.0" && yamldecode(helm_release.cluster_autoscaler[0].values[0]).image.tag == "v1.35.0"
    error_message = "1.35 row must stay chart 9.57.0 / image v1.35.0, got ${helm_release.cluster_autoscaler[0].version} / ${yamldecode(helm_release.cluster_autoscaler[0].values[0]).image.tag}"
  }
}

# --- Karpenter controller IAM ------------------------------------------
# Golden: the 1.12.1 policy document is byte-identical to the one before the
# 1.37-default change (zero diff for existing installs).
run "karpenter_1121_policy_golden" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    karpenter_version = "1.12.1"
  }
  assert {
    condition     = sha256(aws_iam_role_policy.karpenter_controller.policy) == "0ebea6674a3dd8ed5c03f81041788294ba605dc35a2f1f0f1390934335369d5c"
    error_message = "Karpenter 1.12.1 controller policy changed: ${sha256(aws_iam_role_policy.karpenter_controller.policy)}"
  }
}

run "ca_row_136" {
  command = plan
  module {
    source = "../../modules/eks-addons"
  }
  variables {
    k8s_version = "1.36"
  }
  assert {
    condition     = helm_release.cluster_autoscaler[0].version == "9.60.0" && yamldecode(helm_release.cluster_autoscaler[0].values[0]).image.tag == "v1.36.2"
    error_message = "1.36 row must be chart 9.60.0 / image v1.36.2"
  }
}

run "ca_row_137" {
  command = plan
  module {
    source = "../../modules/eks-addons"
  }
  variables {
    k8s_version = "1.37"
  }
  assert {
    condition     = helm_release.cluster_autoscaler[0].version == "9.60.0" && yamldecode(helm_release.cluster_autoscaler[0].values[0]).image.tag == "v1.37.0"
    error_message = "1.37 row must be chart 9.60.0 / image v1.37.0"
  }
}

# Karpenter >= 1.13: the extra controller permissions are appended.
run "karpenter_1151_policy_extras" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    karpenter_version = "1.15.1"
  }
  assert {
    condition = toset([for st in jsondecode(aws_iam_role_policy.karpenter_controller.policy).Statement : st.Action if st.Sid == "AllowRegionalReadActions"][0]) == toset([
      "ec2:DescribeAvailabilityZones", "ec2:DescribeCapacityReservations", "ec2:DescribeImages",
      "ec2:DescribeInstances", "ec2:DescribeInstanceStatus", "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes", "ec2:DescribeLaunchTemplates", "ec2:DescribePlacementGroups",
      "ec2:DescribeSecurityGroups", "ec2:DescribeSpotPriceHistory", "ec2:DescribeSubnets",
    ])
    error_message = "Karpenter >= 1.13 needs the upstream regional read actions."
  }
  assert {
    condition     = contains([for st in jsondecode(aws_iam_role_policy.karpenter_controller.policy).Statement : st.Resource if st.Sid == "AllowScopedEC2InstanceAccessActions"][0], "arn:aws:ec2:us-west-2:*:placement-group/*")
    error_message = "Karpenter >= 1.13 needs placement-group/* for RunInstances / CreateFleet."
  }
}

# Lower boundary of the >= 1.13 gate: 1.13.0 already gets the extras.
run "karpenter_1130_policy_extras" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    karpenter_version = "1.13.0"
  }
  assert {
    condition = toset([for st in jsondecode(aws_iam_role_policy.karpenter_controller.policy).Statement : st.Action if st.Sid == "AllowRegionalReadActions"][0]) == toset([
      "ec2:DescribeAvailabilityZones", "ec2:DescribeCapacityReservations", "ec2:DescribeImages",
      "ec2:DescribeInstances", "ec2:DescribeInstanceStatus", "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes", "ec2:DescribeLaunchTemplates", "ec2:DescribePlacementGroups",
      "ec2:DescribeSecurityGroups", "ec2:DescribeSpotPriceHistory", "ec2:DescribeSubnets",
    ])
    error_message = "Karpenter 1.13.0 needs the upstream regional read actions."
  }
  assert {
    condition     = contains([for st in jsondecode(aws_iam_role_policy.karpenter_controller.policy).Statement : st.Resource if st.Sid == "AllowScopedEC2InstanceAccessActions"][0], "arn:aws:ec2:us-west-2:*:placement-group/*")
    error_message = "Karpenter 1.13.0 needs placement-group/* for RunInstances / CreateFleet."
  }
}

# Only the >= 1.13 gate moves the policy ("v" prefix and 1.12.x stay golden).
run "karpenter_v1121_prefix_policy_golden" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    karpenter_version = "v1.12.1"
  }
  assert {
    condition     = sha256(aws_iam_role_policy.karpenter_controller.policy) == "0ebea6674a3dd8ed5c03f81041788294ba605dc35a2f1f0f1390934335369d5c"
    error_message = "a v-prefixed 1.12.1 must keep the 1.12.1 policy"
  }
}

# A minor-only pin ("1.15", a Helm tag constraint) still gets the >= 1.13 extras.
run "karpenter_minor_pin_policy_extras" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    karpenter_version = "1.15"
  }
  assert {
    condition     = contains([for st in jsondecode(aws_iam_role_policy.karpenter_controller.policy).Statement : st.Action if st.Sid == "AllowRegionalReadActions"][0], "ec2:DescribeInstanceStatus")
    error_message = "a \"1.15\" pin must get the Karpenter >= 1.13 controller IAM"
  }
}

# "1.12" / "~1.12" stay golden.
run "karpenter_minor_pin_1_12_policy_golden" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    karpenter_version = "~1.12"
  }
  assert {
    condition     = sha256(aws_iam_role_policy.karpenter_controller.policy) == "0ebea6674a3dd8ed5c03f81041788294ba605dc35a2f1f0f1390934335369d5c"
    error_message = "a \"~1.12\" pin must keep the 1.12.1 policy"
  }
}

# Helm resolves range constraints, so the gate reads the lower bound:
# ">=1.15.0" installs >= 1.13 and must get the extras; ">=1.12" stays golden;
# no major.minor ("^1") may resolve to the newest release -> extras.
run "karpenter_range_pin_policy_extras" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    karpenter_version = ">=1.15.0"
  }
  assert {
    condition     = contains([for st in jsondecode(aws_iam_role_policy.karpenter_controller.policy).Statement : st.Action if st.Sid == "AllowRegionalReadActions"][0], "ec2:DescribeInstanceStatus")
    error_message = "a \">=1.15.0\" pin must get the Karpenter >= 1.13 controller IAM"
  }
}

run "karpenter_range_pin_1_12_policy_golden" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    karpenter_version = ">=1.12"
  }
  assert {
    condition     = sha256(aws_iam_role_policy.karpenter_controller.policy) == "0ebea6674a3dd8ed5c03f81041788294ba605dc35a2f1f0f1390934335369d5c"
    error_message = "a \">=1.12\" pin must keep the 1.12.1 policy"
  }
}

run "karpenter_major_only_pin_policy_extras" {
  command = plan
  module {
    source = "../../modules/eks-karpenter"
  }
  variables {
    karpenter_version = "^1"
  }
  assert {
    condition     = contains([for st in jsondecode(aws_iam_role_policy.karpenter_controller.policy).Statement : st.Action if st.Sid == "AllowRegionalReadActions"][0], "ec2:DescribeInstanceStatus")
    error_message = "an unparseable pin (\"^1\") must get the Karpenter >= 1.13 controller IAM"
  }
}
