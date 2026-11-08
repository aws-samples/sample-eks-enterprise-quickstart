# Regression guard: the EFA device-plugin image must come from the EKS add-on
# ECR registry of the cluster's region. The registry ACCOUNT is per-region —
# 602401143452 only covers the original commercial regions; opt-in regions,
# GovCloud and each China region have their own
# (https://docs.aws.amazon.com/eks/latest/userguide/add-ons-images.html).
# Using 602401143452 in ap-south-2 was AccessDenied -> ImagePullBackOff ->
# vpc.amazonaws.com/efa never registered (hit live).

mock_provider "kubernetes" {}
mock_provider "helm" {}

variables {
  stack_mode = "standard"
}

run "commercial_core_region" {
  command = plan
  module {
    source = "../../modules/eks-gpu-stack"
  }
  variables {
    region = "us-west-2"
  }
  assert {
    condition     = kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].template[0].spec[0].container[0].image == "602401143452.dkr.ecr.us-west-2.amazonaws.com/eks/aws-efa-k8s-device-plugin:v0.5.19"
    error_message = "us-west-2 must use the 602401143452 registry."
  }
}

run "opt_in_region_ap_south_2" {
  command = plan
  module {
    source = "../../modules/eks-gpu-stack"
  }
  variables {
    region = "ap-south-2"
  }
  assert {
    condition     = kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].template[0].spec[0].container[0].image == "900889452093.dkr.ecr.ap-south-2.amazonaws.com/eks/aws-efa-k8s-device-plugin:v0.5.19"
    error_message = "ap-south-2 (opt-in) must use its own 900889452093 registry, not 602401143452."
  }
}

run "china_regions_differ" {
  command = plan
  module {
    source = "../../modules/eks-gpu-stack"
  }
  variables {
    region = "cn-north-1"
  }
  assert {
    condition     = kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].template[0].spec[0].container[0].image == "918309763551.dkr.ecr.cn-north-1.amazonaws.com.cn/eks/aws-efa-k8s-device-plugin:v0.5.19"
    error_message = "cn-north-1 must use 918309763551 (961992271922 is cn-northwest-1 only) on the .amazonaws.com.cn domain."
  }
}

run "china_northwest" {
  command = plan
  module {
    source = "../../modules/eks-gpu-stack"
  }
  variables {
    region = "cn-northwest-1"
  }
  assert {
    condition     = kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].template[0].spec[0].container[0].image == "961992271922.dkr.ecr.cn-northwest-1.amazonaws.com.cn/eks/aws-efa-k8s-device-plugin:v0.5.19"
    error_message = "cn-northwest-1 must use 961992271922 on the .amazonaws.com.cn domain."
  }
}

run "eusc_domain" {
  command = plan
  module {
    source = "../../modules/eks-gpu-stack"
  }
  variables {
    region = "eusc-de-east-1"
  }
  assert {
    condition     = kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].template[0].spec[0].container[0].image == "877088126301.dkr.ecr.eusc-de-east-1.amazonaws.eu/eks/aws-efa-k8s-device-plugin:v0.5.19"
    error_message = "eusc-de-east-1 must use 877088126301 on the .amazonaws.eu domain."
  }
}

run "explicit_override_wins" {
  command = plan
  module {
    source = "../../modules/eks-gpu-stack"
  }
  variables {
    region                  = "ap-south-2"
    efa_device_plugin_image = "mirror.example.com/eks/aws-efa-k8s-device-plugin:v0.5.19"
  }
  assert {
    condition     = kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].template[0].spec[0].container[0].image == "mirror.example.com/eks/aws-efa-k8s-device-plugin:v0.5.19"
    error_message = "efa_device_plugin_image must override the registry map."
  }
}

run "unknown_region_fails_clearly" {
  command = plan
  module {
    source = "../../modules/eks-gpu-stack"
  }
  variables {
    region = "xx-nowhere-1"
  }
  expect_failures = [kubernetes_daemon_set_v1.efa_device_plugin]
}

# Zero-diff guard for Neuron support: the NVIDIA EFA DaemonSet keeps its exact
# placement (workload-type=gpu + nvidia.com/gpu toleration) and identity.
# Neuron nodes get a SEPARATE DaemonSet from modules/eks-neuron-stack.
run "gpu_efa_ds_placement_unchanged" {
  command = plan
  module {
    source = "../../modules/eks-gpu-stack"
  }
  variables {
    region = "us-west-2"
  }
  assert {
    condition     = kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].template[0].spec[0].node_selector == tomap({ "workload-type" = "gpu" })
    error_message = "NVIDIA EFA DaemonSet must keep node_selector workload-type=gpu."
  }
  assert {
    condition     = length(kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].template[0].spec[0].toleration) == 2
    error_message = "NVIDIA EFA DaemonSet must keep exactly 2 tolerations."
  }
  assert {
    condition     = [for t in kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].template[0].spec[0].toleration : t.key] == ["nvidia.com/gpu", "CriticalAddonsOnly"]
    error_message = "NVIDIA EFA DaemonSet tolerations must stay nvidia.com/gpu + CriticalAddonsOnly."
  }
  assert {
    condition     = kubernetes_daemon_set_v1.efa_device_plugin[0].metadata[0].name == "aws-efa-k8s-device-plugin-daemonset"
    error_message = "NVIDIA EFA DaemonSet name must not change."
  }
  assert {
    condition     = kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].selector[0].match_labels == tomap({ name = "aws-efa-k8s-device-plugin" })
    error_message = "NVIDIA EFA DaemonSet selector must not change."
  }
}

# The per-region account map lives in the shared eks-addon-ecr-registry
# module (used by eks-gpu-stack and eks-neuron-stack); docs/AMI_VERSIONS.md
# must point operators adding a region at that file, not the old location.
run "ecr_account_map_doc_location" {
  command = plan
  module {
    source = "../../modules/eks-gpu-stack"
  }
  variables {
    region = "us-west-2"
  }
  assert {
    condition = alltrue([
      # Tie to the plan: the image resolved through the shared map.
      startswith(kubernetes_daemon_set_v1.efa_device_plugin[0].spec[0].template[0].spec[0].container[0].image, "602401143452.dkr.ecr.us-west-2.amazonaws.com/"),
      strcontains(file("../../modules/eks-addon-ecr-registry/main.tf"), "eks_addon_ecr_account_by_region = {"),
      strcontains(file("../../../docs/AMI_VERSIONS.md"), "`eks_addon_ecr_account_by_region` in `modules/eks-addon-ecr-registry/main.tf`"),
      !strcontains(file("../../../docs/AMI_VERSIONS.md"), "`eks_addon_ecr_account_by_region` in `modules/eks-gpu-stack/main.tf`"),
      # .gitleaks.toml's account-ID allowlist comment points maintainers at the same map.
      strcontains(file("../../../.gitleaks.toml"), "mirrored in modules/eks-addon-ecr-registry/main.tf eks_addon_ecr_account_by_region"),
      !strcontains(file("../../../.gitleaks.toml"), "modules/eks-gpu-stack/main.tf eks_addon_ecr_account_by_region"),
      # The root variable description names the real fallback, not "public ECR".
      strcontains(file("../../variables.tf"), "Empty falls back to the per-region EKS add-on ECR registry"),
      !strcontains(file("../../variables.tf"), "Empty falls back to the public ECR image map"),
    ])
    error_message = "docs/AMI_VERSIONS.md, .gitleaks.toml and the efa_device_plugin_image description must locate eks_addon_ecr_account_by_region in modules/eks-addon-ecr-registry/main.tf."
  }
}
