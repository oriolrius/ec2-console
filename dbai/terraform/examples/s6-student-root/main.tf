# Fixture: the shape of the student S6 `ai-workbench/infra/` root. It consumes
# the SAME workspace module at the SAME resource addresses as the initial
# controller root (dbai/terraform/workspace), so S6 adoption is a zero-change
# plan on the same backend/state — only the editable root path changes
# (doc-18 §4). This example is instructor reference; the real file lives in the
# student's ai-workbench repo and is versioned, reviewable coursework.

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "local" {} # controller-owned local backend/state (ignored in the student repo)
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "ec2-console"
      Course      = "dbai"
      ManagedBy   = "terraform"
      Environment = var.student_id
    }
  }
}

# IDENTICAL module block (source-relative path differs by location only).
module "workspace" {
  source = "../../modules/workspace"

  student_id                 = var.student_id
  aws_region                 = var.aws_region
  my_ip_cidr                 = var.my_ip_cidr
  ssh_public_key_path        = var.ssh_public_key_path
  deploy_public_key_path     = var.deploy_public_key_path
  instructor_public_key_path = var.instructor_public_key_path
  eip_allocation_id          = var.eip_allocation_id
  bootstrap_template_path    = var.bootstrap_template_path
  instance_type              = var.instance_type
  app_ingress_cidrs          = var.app_ingress_cidrs
  cost_tags                  = var.cost_tags
}

variable "aws_region" {
  type    = string
  default = "eu-west-1"
}
variable "student_id" {
  type = string
}
variable "my_ip_cidr" {
  type    = string
  default = "0.0.0.0/32"
}
variable "ssh_public_key_path" {
  type = string
}
variable "deploy_public_key_path" {
  type    = string
  default = null
}
variable "instructor_public_key_path" {
  type    = string
  default = null
}
variable "eip_allocation_id" {
  type = string
}
variable "bootstrap_template_path" {
  type = string
}
variable "instance_type" {
  type    = string
  default = "t3.medium"
}
variable "app_ingress_cidrs" {
  type    = list(string)
  default = []
}
variable "cost_tags" {
  type    = map(string)
  default = {}
}

output "public_ip" { value = module.workspace.public_ip }
output "instance_id" { value = module.workspace.instance_id }
