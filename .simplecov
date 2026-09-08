# frozen_string_literal: true

SimpleCov.configure do
  enable_coverage :branch
  cover "{lib,app}/**/*.rb"
  skip "/test/"
  skip "/lib/generators/"
  minimum_coverage line: 90, branch: 90
  merging false
end
