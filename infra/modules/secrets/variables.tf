variable "config" {
  description = "The secrets and who may read them"
  type = object({
    readers = map(list(string)) # secret id => names of the VMs that may read it
    members = map(string)       # VM name => its service account as an IAM member
    labels  = map(string)
  })
}
