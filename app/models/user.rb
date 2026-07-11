class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  # Column is citext, so the DB-level unique index is case-insensitive too.
  validates :email_address, presence: true, uniqueness: true
end
