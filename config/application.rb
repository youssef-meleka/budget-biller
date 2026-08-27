require "rails"
require "active_model/railtie"
require "active_record/railtie"

Bundler.require(*Rails.groups)

# Ruby block-buffers $stdout when it's not a tty, which is the case inside a
# container. Without this, log lines sit in the buffer and `docker compose
# logs worker` stays empty while work is actually happening.
$stdout.sync = true

module BudgetBiller
  class Application < Rails::Application
    config.load_defaults 7.2

    # Only the frameworks this app actually uses — no HTTP surface, so no
    # action_controller/action_view/action_mailer/active_storage/action_cable.
    config.autoload_paths += %W[#{config.root}/app/services]

    # allocator.rb and errors.rb each define several constants that don't
    # match their filename (Billing::Error, Billing::BudgetSnapshot, …), which
    # Zeitwerk can't infer, so both are loaded via explicit require_relative
    # instead. Keeping the allocator out of the autoloader also lets its spec
    # run with no Rails and no database.
    Rails.autoloaders.main.ignore(
      "#{config.root}/app/services/billing/errors.rb",
      "#{config.root}/app/services/billing/allocator.rb"
    )

    config.time_zone = "UTC"
    config.active_record.default_timezone = :utc

    config.generators { |g| g.test_framework :rspec }
  end
end
