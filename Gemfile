source "https://rubygems.org"

gemspec

# DB=postgres runs the suite against PostgreSQL (see spec/dummy/config/database.yml).
if ENV["DB"] == "postgres"
  gem "pg"
else
  gem "sqlite3"
end
gem "rspec-rails"
gem "puma"
gem "csv"
gem "devise"
gem "any_login"
