terraform {
  # 1.9 needed for cross-variable validation (variable validation block can
  # reference other variables). Drops the null_resource precondition pattern
  # in eks-csi-drivers / similar.
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.9.0, < 7.0"
    }
    # helm 3.0 (2025-06) and kubernetes 3.0 (2025-12) ported to the
    # Plugin Framework with a non-backward-compatible schema rewrite —
    # blocks became nested objects, set/set_list/set_sensitive became
    # lists. Upgrading would require rewriting every helm_release and
    # kubernetes_* resource in this stack. We deliberately stay on 2.x
    # until that effort is scheduled. See:
    #   https://github.com/hashicorp/terraform-provider-helm/blob/v3.0.0/docs/guides/v3-upgrade-guide.md
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = ">= 2.3"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.4"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2"
    }
  }
}
