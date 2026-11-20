variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, database.managed and app.db_name"
  type = object({
    prefix = string
    database = object({
      managed = object({
        version             = string
        disk_gb             = number
        deletion_protection = bool
      })
    })
    app = object({ db_name = string })
  })
}

variable "network" {
  description = "Where the database lives and who may reach it (modules/network): our VPC, two private subnets in two zones, the VMs' security group"
  type = object({
    network_id          = string
    database_subnet_ids = list(string)
    vm_firewall         = list(string)
  })
}

variable "zone" {
  description = "The AWS zone of the VMs, e.g. eu-north-1a: the database stands beside them"
  type        = string
}

variable "size" {
  description = "The RDS instance class, e.g. db.t4g.micro (modules/database turns config.json's word into it)"
  type        = string
}
