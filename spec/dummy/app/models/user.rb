class User < ActiveRecord::Base
  devise :database_authenticatable, :registerable, :recoverable, :rememberable, :validatable

  ROLES = %w[user admin].freeze

  scope :admin, -> { where(role: "admin") }
  scope :user, -> { where(role: "user") }

  def admin?
    role == "admin"
  end

  def self.grouped_collection_by_role
    {
      'admin' => User.admin.limit(10),
      'user'  => User.user.limit(10)
    }
  end
end
