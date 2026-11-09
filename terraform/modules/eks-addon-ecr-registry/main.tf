# =====================================================================
# eks-addon-ecr-registry — region -> EKS add-on ECR registry host
# =====================================================================
# Single source of truth for the per-region ECR registry EKS replicates its
# add-on images into (used for the AWS EFA device-plugin image by both
# eks-gpu-stack and eks-neuron-stack). Pure locals — no providers, no
# resources, nothing in state.
# =====================================================================

variable "region" {
  type        = string
  description = "AWS region whose EKS add-on ECR registry to resolve."
}

locals {
  # AWS EFA device-plugin image. EKS replicates its add-on images into a
  # per-region ECR registry, and the registry ACCOUNT differs by region:
  # 602401143452 only covers the original commercial regions — opt-in regions
  # (ap-south-2, me-south-1, ...), GovCloud and EACH China region have their
  # own. Pulling from the wrong account is AccessDenied → ImagePullBackOff →
  # vpc.amazonaws.com/efa never registers (hit live in ap-south-2).
  # Source (keep in sync when AWS adds regions):
  #   https://docs.aws.amazon.com/eks/latest/userguide/add-ons-images.html
  eks_addon_ecr_account_by_region = {
    "af-south-1"     = "877085696533"
    "ap-east-1"      = "800184023465"
    "ap-east-2"      = "533267051163"
    "ap-northeast-1" = "602401143452"
    "ap-northeast-2" = "602401143452"
    "ap-northeast-3" = "602401143452"
    "ap-south-1"     = "602401143452"
    "ap-south-2"     = "900889452093"
    "ap-southeast-1" = "602401143452"
    "ap-southeast-2" = "602401143452"
    "ap-southeast-3" = "296578399912"
    "ap-southeast-4" = "491585149902"
    "ap-southeast-5" = "151610086707"
    "ap-southeast-6" = "333609536671"
    "ap-southeast-7" = "121268973566"
    "ca-central-1"   = "602401143452"
    "ca-west-1"      = "761377655185"
    "cn-north-1"     = "918309763551"
    "cn-northwest-1" = "961992271922"
    "eu-central-1"   = "602401143452"
    "eu-central-2"   = "900612956339"
    "eu-north-1"     = "602401143452"
    "eu-south-1"     = "590381155156"
    "eu-south-2"     = "455263428931"
    "eu-west-1"      = "602401143452"
    "eu-west-2"      = "602401143452"
    "eu-west-3"      = "602401143452"
    "eusc-de-east-1" = "877088126301"
    "il-central-1"   = "066635153087"
    "me-central-1"   = "759879836304"
    "me-south-1"     = "558608220178"
    "mx-central-1"   = "730335286997"
    "sa-east-1"      = "602401143452"
    "us-east-1"      = "602401143452"
    "us-east-2"      = "602401143452"
    "us-gov-east-1"  = "151742754352"
    "us-gov-west-1"  = "013241004608"
    "us-west-1"      = "602401143452"
    "us-west-2"      = "602401143452"
  }
  eks_addon_ecr_account = lookup(local.eks_addon_ecr_account_by_region, var.region, "")
  eks_addon_ecr_domain = (
    startswith(var.region, "cn-") ? "amazonaws.com.cn" :
    startswith(var.region, "eusc-") ? "amazonaws.eu" :
    "amazonaws.com"
  )

  # Full registry host, e.g. 602401143452.dkr.ecr.us-west-2.amazonaws.com.
  # "" when the region is not in the map above (callers turn that into a
  # precondition failure or require an explicit image override).
  registry = local.eks_addon_ecr_account == "" ? "" : "${local.eks_addon_ecr_account}.dkr.ecr.${var.region}.${local.eks_addon_ecr_domain}"
}

output "account" {
  description = "EKS add-on ECR registry account for var.region (\"\" = unknown region)."
  value       = local.eks_addon_ecr_account
}

output "domain" {
  description = "Partition DNS suffix for var.region (amazonaws.com / amazonaws.com.cn / amazonaws.eu)."
  value       = local.eks_addon_ecr_domain
}

output "registry" {
  description = "EKS add-on ECR registry host for var.region, e.g. 602401143452.dkr.ecr.us-west-2.amazonaws.com (\"\" = unknown region)."
  value       = local.registry
}
