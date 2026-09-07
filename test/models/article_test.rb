require "test_helper"

class ArticleTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
  end

  test "reads rows back out of the test database" do
    article = Article.find_by(title: "Reading from PostgreSQL")

    assert_not_nil article, "expected the fixtures to have been loaded into the test database"
    assert_equal "GET /articles queries the database directly.", article.body
  end

  test "requires a title and a body" do
    article = Article.new

    assert_not article.valid?
    assert_equal [ "can't be blank" ], article.errors[:title]
    assert_equal [ "can't be blank" ], article.errors[:body]
  end

  test "cached read populates the cache on a miss" do
    article = articles(:postgres)

    assert_nil Rails.cache.read(Article.cache_key_for(article.id))

    assert_equal article.title, Article.cached(article.id)["title"]
    assert_equal article.title, Rails.cache.read(Article.cache_key_for(article.id))["title"]
  end

  test "cached read is served from the cache on a hit" do
    article = articles(:redis)
    Article.cached(article.id)

    # Stale on purpose: if the second read still returns the old title, it came
    # out of Redis rather than out of PostgreSQL.
    article.update!(title: "Written straight to the database")

    assert_equal "Reading from Redis", Article.cached(article.id)["title"]
  end
end
