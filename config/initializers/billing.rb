# frozen_string_literal: true

# The single read site for billing-related ENV. Adding a new ENV.fetch here
# means adding its row to .env.example in the same change.
module Billing
  POLL_INTERVAL = ENV.fetch("BILLING_POLL_INTERVAL", 5).to_i
  LEASE_TTL     = ENV.fetch("BILLING_LEASE_TTL", 60).to_i
  MAX_ATTEMPTS  = ENV.fetch("BILLING_MAX_ATTEMPTS", 5).to_i
end
