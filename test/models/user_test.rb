require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "downcases and strips email_address" do
    user = User.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", user.email_address)
  end

  test "model validation rejects a duplicate email regardless of case" do
    user = User.new(email_address: "ONE@example.com", password: "password")

    assert_not user.valid?
    assert user.errors[:email_address].any?, "expected a uniqueness error on email_address"
  end

  test "citext unique index rejects a case-variant duplicate email at the DB level" do
    assert_raises ActiveRecord::RecordNotUnique do
      User.connection.execute(<<~SQL)
        INSERT INTO users (email_address, password_digest, created_at, updated_at)
        VALUES ('ONE@EXAMPLE.COM', 'not-a-real-digest', NOW(), NOW())
      SQL
    end
  end

  test "password is stored as a bcrypt digest" do
    user = User.create!(email_address: "bcrypt-check@example.com", password: "password")

    assert user.password_digest.start_with?("$2a$", "$2b$"), "expected a bcrypt digest"
    assert user.authenticate("password")
    assert_not user.authenticate("wrong")
  end
end
