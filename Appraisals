# frozen_string_literal: true

appraise "rails-7.2" do
  gem "minitest", "~> 5.25"
  group :development, :test do
    remove_gem "minitest"
  end
  gem "rails", ">= 7.2.3.2", "< 8.0.a"
end

appraise "rails-8.0" do
  gem "rails", ">= 8.0.5.1", "< 8.1.a"
end

appraise "rails-8.1" do
  gem "rails", ">= 8.1.3.1", "< 8.2.a"
end
