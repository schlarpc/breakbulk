# `--features` values for `-p core` over tests/fixtures/accepts-feature:
# `testAcceptsFeature` (lib-unit) checks breakbulk.lib.acceptsFeature's
# answers by hand, `accepts-feature-cargo` against Cargo's.
[
  "fast"
  "json"
  "core/fast"
  "core?/json"
  "serde/derive"
  "json?/std"
  "winapi/everything"
  "dep:json"
  "slow"
  "core/slow"
  "app/fast"
  "serde_json/std"
]
