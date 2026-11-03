# Regression guard for issue #2: EKS Pod Identity associations are eventually
# consistent, so every module that creates associations must hold its
# consumers (helm releases / EKS addons) behind a time_sleep that re-runs
# whenever an association is created or replaced. These tests pin that the
# wait exists, honours the configured duration, and tracks every association
# the module can create (including count-gated optional ones).
#
# Ordering itself (consumer depends_on the time_sleep) is enforced by
# depends_on in the modules and checked via `tofu graph` in review; tftest
# has no way to assert graph edges.

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
mock_provider "http" {
  mock_data "http" {
    defaults = { response_body = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}
mock_provider "time" {}

run "eks_addons_default_wait" {
  command = plan

  module {
    source = "../../modules/eks-addons"
  }

  variables {
    cluster_name                     = "test-cluster"
    vpc_id                           = "vpc-12345678"
    region                           = "us-west-2"
    k8s_version                      = "1.34"
    install_cluster_autoscaler       = true
    alb_controller_chart_version     = "1.13.0"
    alb_controller_app_version       = "v2.13.0"
    alb_controller_iam_policy_source = "http"
    system_node_label_key            = "workload-type"
    system_node_label_value          = "eks-utils"
  }

  assert {
    condition     = time_sleep.pod_identity_propagation.create_duration == "30s"
    error_message = "eks-addons must wait var.pod_identity_propagation_wait (default 30s) after its Pod Identity associations (issue #2)."
  }
  assert {
    condition     = toset(keys(time_sleep.pod_identity_propagation.triggers)) == toset(["alb_controller", "cluster_autoscaler"])
    error_message = "eks-addons wait must re-run when the CA or ALB controller association is created/replaced."
  }
}

run "eks_addons_custom_wait_without_ca" {
  command = plan

  module {
    source = "../../modules/eks-addons"
  }

  variables {
    cluster_name                     = "test-cluster"
    vpc_id                           = "vpc-12345678"
    region                           = "us-west-2"
    k8s_version                      = "1.34"
    install_cluster_autoscaler       = false
    alb_controller_chart_version     = "1.13.0"
    alb_controller_app_version       = "v2.13.0"
    alb_controller_iam_policy_source = "http"
    system_node_label_key            = "workload-type"
    system_node_label_value          = "eks-utils"
    pod_identity_propagation_wait    = "1m"
  }

  # The wait must still exist (ALB controller) when CA is disabled, and the
  # CA trigger must collapse to a constant instead of failing on [0].
  assert {
    condition     = time_sleep.pod_identity_propagation.create_duration == "1m"
    error_message = "eks-addons must honour a custom pod_identity_propagation_wait."
  }
  assert {
    condition     = time_sleep.pod_identity_propagation.triggers["cluster_autoscaler"] == ""
    error_message = "with install_cluster_autoscaler=false the CA trigger must be the empty-string placeholder."
  }
}

run "eks_csi_drivers_all_drivers" {
  command = plan

  module {
    source = "../../modules/eks-csi-drivers"
  }

  variables {
    cluster_name            = "test-cluster"
    region                  = "us-west-2"
    k8s_version             = "1.34"
    install_efs             = true
    install_fsx             = true
    install_s3              = true
    s3_bucket_arns          = ["arn:aws:s3:::example-bucket"]
    system_node_label_key   = "workload-type"
    system_node_label_value = "eks-utils"
  }

  assert {
    condition     = time_sleep.pod_identity_propagation.create_duration == "30s"
    error_message = "eks-csi-drivers must wait var.pod_identity_propagation_wait (default 30s) after its Pod Identity associations (issue #2)."
  }
  assert {
    condition     = toset(keys(time_sleep.pod_identity_propagation.triggers)) == toset(["ebs_csi", "efs_csi", "fsx_csi", "s3_csi"])
    error_message = "eks-csi-drivers wait must track every CSI association (EBS + optional EFS/FSx/S3)."
  }
}

run "eks_csi_drivers_ebs_only" {
  command = plan

  module {
    source = "../../modules/eks-csi-drivers"
  }

  variables {
    cluster_name            = "test-cluster"
    region                  = "us-west-2"
    k8s_version             = "1.34"
    system_node_label_key   = "workload-type"
    system_node_label_value = "eks-utils"
  }

  assert {
    condition = alltrue([
      for k in ["efs_csi", "fsx_csi", "s3_csi"] : time_sleep.pod_identity_propagation.triggers[k] == ""
    ])
    error_message = "disabled optional CSI drivers must collapse to the empty-string trigger placeholder."
  }
}

run "eks_karpenter_default_wait" {
  command = plan

  module {
    source = "../../modules/eks-karpenter"
  }

  variables {
    cluster_name              = "test-cluster"
    cluster_endpoint          = "https://ABC.gr7.us-west-2.eks.amazonaws.com"
    cluster_security_group_id = "sg-12345678"
    region                    = "us-west-2"
    karpenter_version         = "1.6.0"
    system_node_label_key     = "workload-type"
    system_node_label_value   = "eks-utils"
    private_subnet_ids        = ["subnet-11111111", "subnet-22222222"]
  }

  assert {
    condition     = time_sleep.pod_identity_propagation.create_duration == "30s"
    error_message = "eks-karpenter must wait var.pod_identity_propagation_wait (default 30s) after its Pod Identity association (issue #2)."
  }
  assert {
    condition     = toset(keys(time_sleep.pod_identity_propagation.triggers)) == toset(["karpenter"])
    error_message = "eks-karpenter wait must re-run when the Karpenter association is created/replaced."
  }
}
