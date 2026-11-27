variable "config" {
  description = "infra/config.json as a whole; this module uses prefix, default_cloud, region, zone, clouds.<cloud> (location, network) and k3s (cloud, api_nlb_ip_index, nodes)"
  type = object({
    prefix        = string
    default_cloud = string
    region        = string
    zone          = string
    clouds        = any
    k3s = optional(object({
      cloud            = optional(string)
      api_nlb_ip_index = number
      nodes = map(object({
        role = string
      }))
    }))
  })

  validation {
    # the control plane: 1, 3, 5... nodes (etcd keeps a majority)
    condition     = length(try(var.config.k3s.nodes, {})) == 0 ? true : length([for node in values(var.config.k3s.nodes) : node if node.role == "control_plane"]) % 2 == 1
    error_message = "config.json: k3s.nodes needs an odd number of control_plane nodes (1, 3, 5: etcd keeps a majority)."
  }

  validation {
    condition     = length(try(var.config.k3s.nodes, {})) == 0 || coalesce(try(var.config.k3s.cloud, null), var.config.default_cloud) == "gcp"
    error_message = "config.json: the k3s cluster is built in GCP only (for now): k3s.cloud (or default_cloud) must be gcp."
  }
}

variable "networks" {
  description = "cloud => its network (modules/network by_cloud)"
  type        = any
}

variable "instances" {
  description = "VM name => { cloud, id, internal_ip } (modules/vm instances: the k3s nodes among them)"
  type = map(object({
    cloud       = string
    id          = string
    internal_ip = string
  }))
}
