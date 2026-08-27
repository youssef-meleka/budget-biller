source "https://rubygems.org"
ruby "3.3.12"

gem "rails", "~> 7.2"
gem "pg"
# No puma, no action_pack — nothing here ever serves HTTP.

group :development, :test do
  gem "rspec-rails"
  gem "factory_bot_rails"
  gem "database_cleaner-active_record"
  gem "rubocop-rails-omakase", require: false
end
