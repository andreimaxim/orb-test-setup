class ArticlesController < ApplicationController
  # A plain read out of PostgreSQL.
  def index
    render json: Article.order(:id)
  end

  # The same row, but read through the Redis-backed cache.
  def show
    render json: Article.cached(params[:id])
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end
end
