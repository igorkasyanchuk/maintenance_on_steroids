class PublishProductsTask < MaintenanceOnSteroids::Task
  about do
    title "Publish Products"
    description "Slowly publishes draft products and refreshes their prices (0.01s per record)"
    owner "Test Suite"
  end

  form do
    input :price_increase_percent, type: :integer, default: 5, help_text: "Applied to every product price"
  end

  artifact :summary, type: :jsonb, default: {}

  after_complete :save_summary

  def collection
    Product.order(:id)
  end

  def process(product)
    sleep 0.01

    multiplier = 1 + params.fetch(:price_increase_percent, 5).to_i / 100.0
    product.update!(
      status: "published",
      price_cents: (product.price_cents * multiplier).round
    )
  end

  private

  # No explicit save! needed -- RunJob auto-flushes dirty artifacts after
  # after_complete callbacks run.
  def save_summary
    artifacts[:summary]["published"] = Product.published.count
    artifacts[:summary]["total"] = Product.count
  end
end
