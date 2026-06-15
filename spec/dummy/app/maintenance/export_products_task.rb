class ExportProductsTask < MaintenanceOnSteroids::Task
  about do
    title "Export Products"
    description "Exports all products to a downloadable CSV"
  end

  artifact :export,
           type: :csv,
           headers: %w[id name sku price_cents status],
           label: "Product export",
           description: "One row per product, downloadable as CSV"

  def call
    Product.order(:id).find_each do |product|
      artifacts[:export] << [product.id, product.name, product.sku, product.price_cents, product.status]
    end
    # No save! needed -- RunJob auto-flushes the CSV artifact on completion.
  end
end
