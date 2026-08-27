require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your whole application. When running a single test locally,
  # this is usually not necessary, and can slow down your test suite.
  config.eager_load = ENV["CI"].present?

  # Show full error reports and disable caching.
  config.consider_all_requests_local = true

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raise exceptions for disallowed deprecations.
  config.active_support.disallowed_deprecation = :raise

  # Tell Active Support which deprecation messages to disallow.
  config.active_support.disallowed_deprecation_warnings = []

  config.logger = ActiveSupport::Logger.new($stdout)
  config.log_level = :warn
end
