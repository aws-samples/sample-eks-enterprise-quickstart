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
