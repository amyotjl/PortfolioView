class Portfolio < ApplicationRecord
  belongs_to :user
  belongs_to :benchmark, optional: true

  validates :name, presence: true
  # Mirrors UNIQUE (user_id, name).
  validates :name, uniqueness: { scope: :user_id }
  validates :series_version, presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 1 }
end
