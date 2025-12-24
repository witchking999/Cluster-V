terraform {
  required_version = ">= 1.6.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

variable "role" {
  description = "Node role to bootstrap (head or worker)"
  type        = string
  validation {
    condition     = contains(["head", "worker"], lower(var.role))
    error_message = "role must be either \"head\" or \"worker\"."
  }
}

variable "head_ip" {
  description = "IP address of the Nomad/Consul head node"
  type        = string
  default     = "192.168.128.111"
}

variable "nfs_server" {
  description = "Optional override for the NFS server address; defaults to head_ip"
  type        = string
  default     = null
}

variable "extra_api_keys" {
  description = "List of additional API key names to prompt for (values are requested interactively)"
  type        = list(string)
  default     = []
}

locals {
  repo_root  = abspath("${path.module}/..")
  nfs_server = coalesce(var.nfs_server, var.head_ip)
}

resource "null_resource" "bootstrap" {
  triggers = {
    role       = lower(var.role)
    head_ip    = var.head_ip
    nfs_server = local.nfs_server
  }

  provisioner "local-exec" {
    environment = {
      ROLE                = lower(var.role)
      HEAD_IP             = var.head_ip
      NFS_SERVER          = local.nfs_server
      REPO_ROOT           = local.repo_root
      EXTRA_API_KEYS_JSON = jsonencode(var.extra_api_keys)
    }
    command     = "bash ${path.module}/scripts/bootstrap.sh"
    working_dir = local.repo_root
  }
}
