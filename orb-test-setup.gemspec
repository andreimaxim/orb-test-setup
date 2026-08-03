require_relative "lib/orb/test/setup/version"

Gem::Specification.new do |spec|
  spec.name = "orb-test-setup"
  spec.version = Orb::Test::Setup::VERSION
  spec.authors = ["andreimaxim"]

  spec.summary = "A small gem for verifying Ruby setup in Amp orbs"
  spec.homepage = "https://github.com/andreimaxim/orb-test-setup"
  spec.license = "MIT"
  spec.required_ruby_version = "= 4.0.6"

  spec.files = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]
end
