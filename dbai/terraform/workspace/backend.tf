# DBAI course Terraform backend selection (ENV-01).
#
# The course path uses an EXPLICIT local backend. State, keys and credentials
# stay on the student/instructor controller, outside any Git repository
# (doc-18 §2, §3). The concrete state path is supplied at `terraform init`
# time via `-backend-config=path=<controller-state>/workspace.tfstate` by the
# dbai console, so this file pins the backend TYPE without hardcoding a
# per-student path.
#
# Per-student isolation and locking are properties of this local backend as
# driven by the console (doc-18 §3). Moving to a remote backend later requires
# a versioned amendment and must preserve per-student isolation/locking.
terraform {
  required_version = ">= 1.9"

  backend "local" {
    # `path` is injected by `terraform init -backend-config=...`.
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
