Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Log to STDOUT so `docker compose logs` is the single place to look.
  # :info, not :debug — debug logs every SQL statement in a money pipeline
  # and buries the events that matter.
  config.logger = ActiveSupport::Logger.new($stdout)
  config.log_tags = []
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info").to_sym

  # Don't log any deprecations.
  config.active_support.report_deprecations = false
end
