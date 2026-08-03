require "minitest/autorun"
require "orb/test/setup"

class OrbTestSetupTest < Minitest::Test
  def test_says_hello
    assert_equal "Hello from the orb!", Orb::Test::Setup.hello
  end

  def test_has_a_version
    refute_empty Orb::Test::Setup::VERSION
  end
end
