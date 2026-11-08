# Fixture root for the fresh-deploy plan regression test
# (alb_iam_policy_fresh_deploy.tftest.hcl).
#
# Mirrors how terraform/main.tf wires modules/eks-addons: the module has a
# module-level depends_on on something that does not exist yet
# (module.eks_system_nodegroup on a brand-new cluster). That defers every data
# source inside the module — data.aws_partition included — to apply time, so
# anything derived from them is unknown during the first plan. A count /
# for_each built from such a value fails with "Invalid count argument".
#
# terraform_data stands in for the not-yet-created nodegroup. All providers
# are mocked in the test file — no AWS / GitHub access.

variable "alb_controller_iam_policy_source" {
  type = string
}

resource "terraform_data" "system_nodegroup_placeholder" {
  input = "pending"
}

module "eks_addons" {
  source = "../../modules/eks-addons"

  cluster_name                     = "test-cluster"
  vpc_id                           = "vpc-12345678"
  region                           = "us-west-2"
  k8s_version                      = "1.34"
  alb_controller_chart_version     = "1.16.0"
  alb_controller_app_version       = "v2.14.1"
  alb_controller_iam_policy_source = var.alb_controller_iam_policy_source
  system_node_label_key            = "workload-type"
  system_node_label_value          = "eks-utils"

  depends_on = [terraform_data.system_nodegroup_placeholder]
}
