variable "region" {
  description = "AWS region; must match the region of infra/bootstrap."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "eu-central-1"], var.region)
    error_message = "The course account only allows us-east-1 or eu-central-1."
  }
}

variable "name_prefix" {
  description = "Prefix for every resource name in the shared course account."
  type        = string
  default     = "martin-"
}

variable "owner" {
  description = "Value of the Owner tag on every resource."
  type        = string
  default     = "martin"
}

variable "admin_cidr" {
  description = "The admin's public IPv4 as a /32; the only source allowed to SSH into the bastion."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && endswith(var.admin_cidr, "/32") && !startswith(var.admin_cidr, "192.0.2.")
    error_message = "admin_cidr must be your own public IPv4 address in /32 form, e.g. 203.0.113.7/32, not the 192.0.2.10 placeholder from the example file."
  }
}

variable "ssh_public_key_path" {
  description = "Public half of the key installed on every instance."
  type        = string
  default     = "~/.ssh/ironhack-project-1.pub"
}

variable "ssh_private_key_path" {
  description = "Private half, written into the generated ssh_config for Ansible."
  type        = string
  default     = "~/.ssh/ironhack-project-1"
}

variable "alarm_email" {
  description = "Address the CloudWatch alarms email through SNS; AWS sends it a confirmation link first."
  type        = string

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$", var.alarm_email))
    error_message = "alarm_email must be an email address, e.g. you@example.com."
  }
}
