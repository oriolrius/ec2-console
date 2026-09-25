# DBAI initial controller workspace root. It consumes the shared workspace
# module (RECOVERY-01) — the SAME module, resource addresses, provider config
# and inputs the student S6 `ai-workbench/infra/` root uses, so S6 adoption
# changes the editable root path, not resource identity (doc-18 §4).

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

module "workspace" {
  source = "../modules/workspace"

  student_id                 = var.student_id
  aws_region                 = var.aws_region
  my_ip_cidr                 = var.my_ip_cidr
  ssh_public_key_path        = var.ssh_public_key_path
  deploy_public_key_path     = var.deploy_public_key_path
  instructor_public_key_path = var.instructor_public_key_path
  eip_allocation_id          = var.eip_allocation_id
  bootstrap_template_path    = coalesce(var.bootstrap_template_path, "${path.root}/templates/bootstrap.cloudinit.yaml.tftpl")
  instance_type              = var.instance_type
  app_ingress_cidrs          = var.app_ingress_cidrs
  root_volume_gb             = var.root_volume_gb
  web_ingress_cidrs          = var.web_ingress_cidrs
  web_ingress_self           = var.web_ingress_self
  cost_tags                  = var.cost_tags
}

variable "aws_region" {
  description = "AWS region for the course environment."
  type        = string
  default     = "eu-west-1"
}

variable "student_id" {
  description = "Per-student/instructor environment identity (non-secret)."
  type        = string
}

variable "my_ip_cidr" {
  description = "Explicit CIDR for application-port access."
  type        = string
  default     = "0.0.0.0/32" # no app access until set
}

variable "ssh_public_key_path" {
  description = "Controller-local SSH public key path."
  type        = string
}

variable "deploy_public_key_path" {
  description = "Controller-local S5 deploy public key path (null until enrolled in S5)."
  type        = string
  default     = null
}

variable "instructor_public_key_path" {
  description = "Controller-local instructor public key path (null until required at S6)."
  type        = string
  default     = null
}

variable "eip_allocation_id" {
  description = "EIP allocation id from the address state."
  type        = string
}

variable "bootstrap_template_path" {
  description = "Bootstrap (cloud-init) template path; defaults to this root's templates/."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "EC2 instance type (from the phase profile)."
  type        = string
  default     = "t3.small"
}

variable "app_ingress_cidrs" {
  description = "Explicit CIDRs for application ports."
  type        = list(string)
  default     = []
}

variable "cost_tags" {
  description = "Additional cost/ownership tags."
  type        = map(string)
  default     = {}
}

output "public_ip" {
  description = "Persistent public IP of the workspace."
  value       = module.workspace.public_ip
}

output "instance_id" {
  description = "Workspace VM instance id."
  value       = module.workspace.instance_id
}

variable "root_volume_gb" {
  description = "Root volume size in GB (profile-driven; 25 before operations-0.3.0)."
  type        = number
  default     = 25
}

variable "web_ingress_cidrs" {
  description = "Explicit CIDRs allowed on TCP 80 (S9 ingress)."
  type        = list(string)
  default     = []
}

variable "web_ingress_self" {
  description = "Allow TCP 80 from the VM's own EIP (hairpin for in-cluster probes)."
  type        = bool
  default     = false
}
