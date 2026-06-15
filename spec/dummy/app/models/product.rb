class Product < ActiveRecord::Base
  STATUSES = %w[draft published archived].freeze

  validates :name, presence: true
  validates :sku, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  scope :published, -> { where(status: "published") }
end
