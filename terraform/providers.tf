provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(
      {
        Cluster    = var.cluster_name
        managed-by = "terraform"
      },
      var.default_tags,
    )
  }
}

# kubernetes/helm providers authenticate against the EKS cluster created by
# the eks-cluster module. Using exec auth (aws eks get-token) so the token
# is fetched at apply time and never stored in state.
provider "kubernetes" {
  host                   = module.eks_cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_cluster.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks_cluster.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks_cluster.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_cluster.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks_cluster.cluster_name, "--region", var.aws_region]
    }
  }
}
