# frozen_string_literal: true

require_relative "lib/bouncy/version"

Gem::Specification.new do |spec|
  spec.name = "bouncy"
  spec.version = Bouncy::VERSION
  spec.authors = ["rameerez"]
  spec.email = ["rubygems@rameerez.com"]
  spec.summary = "Email bounce handling and suppression management for Rails."
  spec.description = "Know when your app's emails bounce. Mirror provider restrictions, query email status locally, " \
                     "and recover addresses with an audited, provider-aware release."
  spec.homepage = "https://github.com/rameerez/bouncy"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.metadata = {
    "allowed_push_host" => "https://rubygems.org",
    "source_code_uri" => "#{spec.homepage}/tree/main",
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }
  # An allowlist keeps private research and host application data out of releases.
  spec.files = Dir.chdir(__dir__) { Dir["{lib,app,config,guides}/**/*", "README.md", "LICENSE.txt", "CHANGELOG.md"].select { |path| File.file?(path) } }
  spec.require_paths = ["lib"]
  spec.add_dependency "rails", ">= 7.2.3.2", "< 9"
  # Rails 7.2–8.1 pass a positional options hash to JSON.parse.
  spec.add_dependency "json", ">= 2.0", "< 3"
end
