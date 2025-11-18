# frozen_string_literal: true

# == Schema Information
#
# Table name: idempotency_keys
#
#  id                  :bigint           not null, primary key
#  expires_at          :datetime         not null
#  idempotency_key     :string(255)      not null
#  locked_at           :datetime
#  request_method      :string(10)
#  request_params_hash :string(64)
#  request_path        :string(255)
#  response_body       :text(16777215)
#  response_code       :integer
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  credential_id       :integer          not null
#
# Indexes
#
#  index_idempotency_keys_on_expires_at     (expires_at)
#  index_idempotency_keys_on_locked_at      (locked_at)
#  index_idempotency_on_credential_and_key  (credential_id,idempotency_key) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (credential_id => credentials.id)
#
FactoryBot.define do
  factory :idempotency_key do
    association :credential
    sequence(:idempotency_key) { |n| "idempotency-key-#{n}" }
    request_method { "POST" }
    request_path { "/api/v1/send/message" }
    request_params_hash { Digest::SHA256.hexdigest({ test: "params" }.to_json) }
    expires_at { 24.hours.from_now }
  end
end
