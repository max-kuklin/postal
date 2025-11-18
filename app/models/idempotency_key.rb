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

class IdempotencyKey < ApplicationRecord

  belongs_to :credential

  validates :idempotency_key, presence: true, length: { maximum: 255 }
  validates :credential_id, presence: true
  validates :expires_at, presence: true

  scope :expired, -> { where("expires_at < ?", Time.current) }
  scope :locked, -> { where.not(locked_at: nil) }
  scope :unlocked, -> { where(locked_at: nil) }

  # Default expiration time is 24 hours
  DEFAULT_EXPIRATION_HOURS = 24

  before_validation :set_expires_at, on: :create

  # Lock this idempotency key to prevent concurrent requests
  def lock!
    update_column(:locked_at, Time.current)
  end

  # Unlock this idempotency key after processing
  def unlock!
    update_column(:locked_at, nil)
  end

  # Check if this key is currently locked
  def locked?
    locked_at.present?
  end

  # Check if this key has expired
  def expired?
    expires_at < Time.current
  end

  # Store the response for this idempotent request
  def store_response(code, body)
    update!(
      response_code: code,
      response_body: body.is_a?(String) ? body : body.to_json,
      locked_at: nil
    )
  end

  # Generate a SHA256 hash of the request parameters
  def self.hash_params(params)
    Digest::SHA256.hexdigest(params.to_json)
  end

  # Find or create an idempotency key record
  # Returns [record, :cached|:locked|:new]
  def self.find_or_initialize_for_request(credential, key, request_method, request_path, params)
    params_hash = hash_params(params)

    # Try to find existing record
    record = find_by(credential_id: credential.id, idempotency_key: key)

    if record
      # Check if expired - treat as new if so
      if record.expired?
        record.destroy
        record = nil
      elsif record.locked?
        return [record, :locked]
      elsif record.request_params_hash == params_hash
        return [record, :cached]
      else
        # Same key, different params
        return [record, :mismatch]
      end
    end

    # Create new locked record
    record ||= new(
      credential: credential,
      idempotency_key: key,
      request_method: request_method,
      request_path: request_path,
      request_params_hash: params_hash,
      locked_at: Time.current
    )

    [record, :new]
  end

  private

  def set_expires_at
    self.expires_at ||= DEFAULT_EXPIRATION_HOURS.hours.from_now
  end

end
