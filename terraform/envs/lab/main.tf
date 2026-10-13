# Lab environment: wires the three modules. Same modules are reused per account at scale.
module "census_reader" {
  source      = "../../modules/census-reader"
  name_prefix = "poc-02"
}

module "consumer_access" {
  source      = "../../modules/consumer-access"
  name_prefix = "poc-02"
}

module "rotation" {
  source      = "../../modules/rotation"
  name_prefix = "poc-02"
}
