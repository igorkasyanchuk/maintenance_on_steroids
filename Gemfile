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
gem "devise"
gem "any_login"
