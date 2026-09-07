class Article < ApplicationRecord
  validates :title, presence: true
  validates :body, presence: true

  # The cached half of the demo: the first call hits PostgreSQL and writes the
  # result to Redis, later calls are served straight out of Redis until the
  # entry expires.
  def self.cached(id)
    Rails.cache.fetch(cache_key_for(id), expires_in: 1.minute) do
      find(id).as_json
    end
  end

  def self.cache_key_for(id)
    "articles/#{id}"
  end
end
