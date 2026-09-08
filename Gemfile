source "https://rubygems.org"

gemspec

gem "sqlite3"

# DB=postgres runs the suite against PostgreSQL (see spec/dummy/config/database.yml).
# An optional group rather than an `if ENV[...]` around the gem list: the
# resolved bundle must not depend on ambient shell state, or a plain
# `bundle exec rspec` after a DB=postgres install finds no sqlite3.
# Install with `bundle install --with postgres` (CI sets BUNDLE_WITH).
group :postgres, optional: true do
  gem "pg"
end
gem "rspec-rails"
gem "puma"
gem "csv"
# json 3.0 dropped the positional options argument from JSON.parse, which
# ActiveSupport::JSON.decode (activesupport 8.1.3.1) still passes -- every JSON
# column read blows up with ArgumentError. Drop this once Rails ships a fix.
gem "json", "< 3"
gem "devise"
gem "any_login"
gem "bundler-audit", require: false
gem "brakeman", require: false
