# Enough rows for `GET /articles` to return something in development.
[
  { title: "Reading from PostgreSQL", body: "GET /articles queries the database directly." },
  { title: "Reading from Redis", body: "GET /articles/:id serves the row out of Rails.cache." }
].each do |attributes|
  Article.find_or_create_by!(title: attributes[:title]) do |article|
    article.body = attributes[:body]
  end
end
