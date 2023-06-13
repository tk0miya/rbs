source "https://rubygems.org"

# Specify your gem's dependencies in rbs.gemspec
gemspec

# Development dependencies
gem "rake"
gem "rake-compiler"
gem "test-unit"
gem "rspec"
gem "rubocop"
gem "rubocop-rubycw"
gem "json"
gem "json-schema"
gem 'stackprof'
gem "goodcheck"
gem "dbm"
gem 'digest'
gem 'tempfile'
gem "prime"
gem "rdoc", "~> 6.4.0"

# FIXME: Workaround for Parser 3.2.2.2 or lower with Ruby 3.3.0dev.
# When the Praser gem releases a new version of Racc that includes the runtime dependencies,
# it will be able to upgrade the Parser gem dependency and remove the workaround.
gem 'racc', '>= 1.6.2'

# Test gems
gem "rbs-amber", path: "test/assets/test-gem"

group :development do
  gem "ruby-lsp", require: false
end

group :minitest do
  gem "minitest"
end
