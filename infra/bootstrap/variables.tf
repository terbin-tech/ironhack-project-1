variable "region" {
  description = "AWS region for the state bucket; must match the region of infra/main."
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
