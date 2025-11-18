# frozen_string_literal: true

class CreateIdempotencyKeys < ActiveRecord::Migration[7.0]
  def change
    create_table :idempotency_keys do |t|
      t.integer :credential_id, null: false
      t.string :idempotency_key, null: false
      t.string :request_method, limit: 10
      t.string :request_path
      t.string :request_params_hash, limit: 64
      t.integer :response_code
      t.text :response_body, limit: 16_777_215 # mediumtext
      t.datetime :locked_at
      t.datetime :expires_at, null: false
      t.timestamps

      t.index [:credential_id, :idempotency_key], unique: true, name: "index_idempotency_on_credential_and_key"
      t.index :expires_at
      t.index :locked_at
    end

    add_foreign_key :idempotency_keys, :credentials
  end
end
