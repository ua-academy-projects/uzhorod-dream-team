variable "config" {
  type = object({
    vms = map(object({}))
    app = object({
      POSTGRES_BACKEND = string
      QUEUE_BACKEND    = string
      SESSION_BACKEND  = string
    })
  })
}
