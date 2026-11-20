variable "project_id" {
  description = "The GCP project (TF_VAR_project_id in infra/bootstrap/gcp/terraform.env)"
  type        = string
}

variable "my_ip" {
  description = "Your public IPv4: only it may SSH to the bastion"
  type        = string

  validation {
    condition     = can(cidrhost("${var.my_ip}/32", 0))
    error_message = "my_ip must be one IPv4 address, e.g. 203.0.113.7 (without /32)."
  }
}

variable "aws_account_id" {
  description = "The only AWS account Terraform may work in (TF_VAR_aws_account_id, written by bootstrap.sh); empty = AWS not set up"
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^([0-9]{12})?$", var.aws_account_id))
    error_message = "aws_account_id is 12 digits, or empty when AWS is not set up."
  }
}
