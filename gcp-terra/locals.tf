locals {
  config = jsondecode(file("${path.root}/../config.json"))
}
