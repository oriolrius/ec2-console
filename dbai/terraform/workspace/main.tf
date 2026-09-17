# DBAI course workspace root — provider configuration and environment inputs.
#
# ENV-01 scope: this root exists so the Terraform backend can be *selected*
# and recorded. Workspace resources (network, firewall, EC2 key, VM, address
# association) are added by later M01 tasks (ENV-03/06/07/08). Keeping the root
# resource-free here means `terraform init` selects the backend and `plan`
# reports "no changes" — never a false "ready".

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "ec2-console"
      Course      = "dbai"
      ManagedBy   = "terraform"
      Environment = var.environment_id
    }
  }
}

variable "aws_region" {
  description = "AWS region for the course environment."
  type        = string
  default     = "eu-west-1"
}

variable "environment_id" {
  description = "Per-student/instructor environment identity (non-secret)."
  type        = string
}
