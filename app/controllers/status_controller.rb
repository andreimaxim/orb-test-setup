class StatusController < ApplicationController
  PROBE_KEY = "status/probe"

  # One request that touches everything the sandbox has to provide: a query to
  # PostgreSQL, a round trip through Redis, and a value decrypted out of
  # config/credentials.yml.enc with the master key. 200 when all three answer,
  # 503 when any of them does not, so `curl --fail` is a usable smoke test.
  def show
    checks = { postgres: postgres, redis: redis, credentials: credentials }
    ok = checks.values.all? { |check| check[:ok] }

    render json: { ok: ok, checks: checks }, status: ok ? :ok : :service_unavailable
  end

  private
    def postgres
      { ok: true, articles: Article.count }
    rescue StandardError => e
      failure(e)
    end

    # Rails.cache swallows connection errors and hands back nil rather than
    # raising, so a Redis that is down shows up as a token that did not survive
    # the round trip rather than as an exception.
    def redis
      token = SecureRandom.hex(8)
      Rails.cache.write(PROBE_KEY, token, expires_in: 1.minute)

      { ok: Rails.cache.read(PROBE_KEY) == token }
    rescue StandardError => e
      failure(e)
    end

    # A missing master key is not an exception either: the credentials read back
    # as empty, so canary comes out nil.
    def credentials
      canary = Rails.application.credentials.canary

      { ok: canary.present?, canary: canary }
    rescue StandardError => e
      failure(e)
    end

    # Blanket rescues would be a smell anywhere else, but reporting a broken
    # dependency is this endpoint's whole job — a 500 would say much less.
    def failure(error)
      { ok: false, error: "#{error.class}: #{error.message}" }
    end
end
