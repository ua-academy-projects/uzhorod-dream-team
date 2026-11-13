output "metrics" {
  value = {
    for k, m in google_logging_metric.this : k => {
      filter     = m.filter
      labels     = toset(keys(m.label_extractors))
      value_type = m.metric_descriptor[0].value_type
      buckets = try({
        count  = m.bucket_options[0].exponential_buckets[0].num_finite_buckets
        growth = m.bucket_options[0].exponential_buckets[0].growth_factor
        scale  = m.bucket_options[0].exponential_buckets[0].scale
      }, null)
    }
  }
}

output "log_filters" {
  value = local.log_filters
}

output "promql" {
  value = { for k, m in google_logging_metric.this : k => "logging_googleapis_com:user_${m.name}" }
}
