class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    enable_extension "citext"

    create_table :users do |t|
      t.citext :email_address, null: false
      t.string :password_digest, null: false

      t.timestamps
    end
    add_index :users, :email_address, unique: true
  end
end
