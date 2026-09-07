require "test_helper"

class ArticlesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
  end

  test "index reads every article from the database" do
    get articles_url

    assert_response :success
    assert_equal Article.count, response.parsed_body.size
    assert_includes response.parsed_body.map { |article| article["title"] }, "Reading from PostgreSQL"
  end

  test "show reads a single article through the cache" do
    article = articles(:redis)

    get article_url(article)

    assert_response :success
    assert_equal article.title, response.parsed_body["title"]
    assert_equal article.title, Rails.cache.read(Article.cache_key_for(article.id))["title"]
  end

  test "show returns 404 for an unknown article" do
    get article_url(id: 0)

    assert_response :not_found
  end
end
