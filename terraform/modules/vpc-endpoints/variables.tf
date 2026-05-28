variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "region" {
  type = string
}

variable "endpoints_mode" {
  type        = string
  description = "'full' or 'minimal'."
  validation {
    condition     = contains(["full", "minimal"], var.endpoints_mode)
    error_message = "endpoints_mode must be 'full' or 'minimal'."
  }
}
