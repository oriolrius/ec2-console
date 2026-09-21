# DBAI address state (ENV-03). The persistent Elastic IP has its OWN state
# root and lifecycle, independent of the workspace, so VM rebuilds keep the
# same address (doc-18 §3). `path` is injected by
# `terraform init -backend-config=path=<controller-state>/address.tfstate`.
terraform {
  required_version = ">= 1.5.0"

  backend "local" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
