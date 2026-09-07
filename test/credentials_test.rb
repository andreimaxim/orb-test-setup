require "test_helper"

# The third thing a sandbox has to provide, after PostgreSQL and Redis: an
# environment variable that reached the session. config/credentials.yml.enc is
# committed, config/master.key is not, so this only passes when the key arrived
# — from RAILS_MASTER_KEY in a cloud session, or from config/master.key on a
# machine where someone wrote it out by hand. See the README.
class CredentialsTest < ActiveSupport::TestCase
  test "the encrypted credentials can be decrypted" do
    assert Rails.application.credentials.config.any?,
      "could not decrypt config/credentials.yml.enc — set RAILS_MASTER_KEY, see README.md"
  end

  test "the canary survives the round trip" do
    assert_equal "the master key reached the sandbox", Rails.application.credentials.canary
  end

  test "secret_key_base comes from the credentials rather than a local fallback" do
    assert_equal Rails.application.credentials.secret_key_base,
      Rails.application.secret_key_base
  end
end
