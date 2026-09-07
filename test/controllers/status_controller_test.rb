require "test_helper"

class StatusControllerTest < ActionDispatch::IntegrationTest
  # Nothing listens here, so a store pointed at it fails the way a Redis that
  # was never started fails.
  UNREACHABLE_REDIS = "redis://127.0.0.1:6399/0"

  setup do
    Rails.cache.clear
  end

  test "reports every dependency as healthy" do
    get status_url

    assert_response :success
    assert response.parsed_body["ok"]
  end

  test "counts articles in PostgreSQL" do
    get status_url

    assert response.parsed_body.dig("checks", "postgres", "ok")
    assert_equal Article.count, response.parsed_body.dig("checks", "postgres", "articles")
  end

  test "round trips a token through Redis" do
    get status_url

    assert response.parsed_body.dig("checks", "redis", "ok")
    assert_not_nil Rails.cache.read(StatusController::PROBE_KEY),
      "expected the probe to have been left behind in the cache"
  end

  test "decrypts a value out of the credentials" do
    get status_url

    assert response.parsed_body.dig("checks", "credentials", "ok")
    assert_equal "the master key reached the sandbox",
      response.parsed_body.dig("checks", "credentials", "canary")
  end

  test "answers 503 when a dependency is down" do
    with_cache ActiveSupport::Cache::RedisCacheStore.new(url: UNREACHABLE_REDIS) do
      get status_url
    end

    assert_response :service_unavailable
    assert_not response.parsed_body["ok"]

    # The probe never made it back, and Rails.cache swallowed the connection
    # error rather than raising, so there is nothing to report but the failure.
    assert_not response.parsed_body.dig("checks", "redis", "ok")

    # The dependencies that are still up are still reported as up.
    assert response.parsed_body.dig("checks", "postgres", "ok")
    assert response.parsed_body.dig("checks", "credentials", "ok")
  end

  test "names the failure when a dependency raises rather than swallowing" do
    raising = ActiveSupport::Cache::RedisCacheStore.new(
      url: UNREACHABLE_REDIS,
      error_handler: ->(method:, returning:, exception:) { raise exception }
    )

    with_cache(raising) { get status_url }

    assert_response :service_unavailable
    assert_not response.parsed_body.dig("checks", "redis", "ok")
    assert_match "Connection refused", response.parsed_body.dig("checks", "redis", "error")
  end

  private
    def with_cache(store)
      original = Rails.cache
      Rails.cache = store
      yield
    ensure
      Rails.cache = original
    end
end
