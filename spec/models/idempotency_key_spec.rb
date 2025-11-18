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
require "rails_helper"

RSpec.describe IdempotencyKey, type: :model do
  let(:server) { create(:server) }
  let(:credential) { create(:credential, server: server) }

  describe "validations" do
    it "requires an idempotency_key" do
      key = described_class.new(credential: credential)
      expect(key).not_to be_valid
      expect(key.errors[:idempotency_key]).to include("can't be blank")
    end

    it "requires a credential_id" do
      key = described_class.new(idempotency_key: "test-key")
      expect(key).not_to be_valid
      expect(key.errors[:credential_id]).to include("can't be blank")
    end

    it "validates idempotency_key length" do
      key = described_class.new(
        credential: credential,
        idempotency_key: "a" * 256
      )
      expect(key).not_to be_valid
      expect(key.errors[:idempotency_key]).to include("is too long (maximum is 255 characters)")
    end
  end

  describe "scopes" do
    let!(:expired_key) do
      create(:idempotency_key, credential: credential, expires_at: 1.hour.ago)
    end

    let!(:active_key) do
      create(:idempotency_key, credential: credential, expires_at: 1.hour.from_now)
    end

    let!(:locked_key) do
      create(:idempotency_key, credential: credential, locked_at: Time.current)
    end

    describe ".expired" do
      it "returns only expired keys" do
        expect(described_class.expired).to include(expired_key)
        expect(described_class.expired).not_to include(active_key)
      end
    end

    describe ".locked" do
      it "returns only locked keys" do
        expect(described_class.locked).to include(locked_key)
        expect(described_class.locked).not_to include(active_key)
      end
    end

    describe ".unlocked" do
      it "returns only unlocked keys" do
        expect(described_class.unlocked).to include(active_key)
        expect(described_class.unlocked).not_to include(locked_key)
      end
    end
  end

  describe "#lock!" do
    let(:key) { create(:idempotency_key, credential: credential, locked_at: nil) }

    it "sets locked_at to current time" do
      expect { key.lock! }.to change { key.reload.locked_at }.from(nil)
      expect(key.locked_at).to be_within(1.second).of(Time.current)
    end
  end

  describe "#unlock!" do
    let(:key) { create(:idempotency_key, credential: credential, locked_at: Time.current) }

    it "clears locked_at" do
      expect { key.unlock! }.to change { key.reload.locked_at }.to(nil)
    end
  end

  describe "#locked?" do
    it "returns true when locked_at is set" do
      key = build(:idempotency_key, locked_at: Time.current)
      expect(key.locked?).to be true
    end

    it "returns false when locked_at is nil" do
      key = build(:idempotency_key, locked_at: nil)
      expect(key.locked?).to be false
    end
  end

  describe "#expired?" do
    it "returns true when expires_at is in the past" do
      key = build(:idempotency_key, expires_at: 1.hour.ago)
      expect(key.expired?).to be true
    end

    it "returns false when expires_at is in the future" do
      key = build(:idempotency_key, expires_at: 1.hour.from_now)
      expect(key.expired?).to be false
    end
  end

  describe "#store_response" do
    let(:key) { create(:idempotency_key, credential: credential, locked_at: Time.current) }

    it "stores the response code and body" do
      key.store_response(200, { status: "success" })
      expect(key.reload.response_code).to eq(200)
      expect(key.response_body).to eq('{"status":"success"}')
    end

    it "unlocks the key" do
      key.store_response(200, { status: "success" })
      expect(key.reload.locked_at).to be_nil
    end

    it "handles string response body" do
      key.store_response(200, "plain text response")
      expect(key.reload.response_body).to eq("plain text response")
    end
  end

  describe ".hash_params" do
    it "generates consistent SHA256 hash" do
      params = { to: "test@example.com", subject: "Test" }
      hash1 = described_class.hash_params(params)
      hash2 = described_class.hash_params(params)
      expect(hash1).to eq(hash2)
      expect(hash1).to match(/\A[a-f0-9]{64}\z/)
    end

    it "generates different hashes for different params" do
      params1 = { to: "test1@example.com" }
      params2 = { to: "test2@example.com" }
      expect(described_class.hash_params(params1)).not_to eq(described_class.hash_params(params2))
    end
  end

  describe ".find_or_initialize_for_request" do
    let(:params) { { to: "test@example.com", subject: "Test" } }

    context "when no existing key" do
      it "returns a new locked record" do
        record, status = described_class.find_or_initialize_for_request(
          credential,
          "new-key",
          "POST",
          "/api/v1/send/message",
          params
        )

        expect(status).to eq(:new)
        expect(record).to be_new_record
        expect(record.locked_at).to be_present
        expect(record.idempotency_key).to eq("new-key")
      end
    end

    context "when existing key with same params" do
      let!(:existing_key) do
        create(:idempotency_key,
               credential: credential,
               idempotency_key: "existing-key",
               request_params_hash: described_class.hash_params(params),
               response_code: 200,
               response_body: '{"status":"success"}',
               locked_at: nil)
      end

      it "returns the cached record" do
        record, status = described_class.find_or_initialize_for_request(
          credential,
          "existing-key",
          "POST",
          "/api/v1/send/message",
          params
        )

        expect(status).to eq(:cached)
        expect(record).to eq(existing_key)
      end
    end

    context "when existing key with different params" do
      let!(:existing_key) do
        create(:idempotency_key,
               credential: credential,
               idempotency_key: "existing-key",
               request_params_hash: "different-hash",
               locked_at: nil)
      end

      it "returns mismatch status" do
        record, status = described_class.find_or_initialize_for_request(
          credential,
          "existing-key",
          "POST",
          "/api/v1/send/message",
          params
        )

        expect(status).to eq(:mismatch)
        expect(record).to eq(existing_key)
      end
    end

    context "when existing key is locked" do
      let!(:existing_key) do
        create(:idempotency_key,
               credential: credential,
               idempotency_key: "existing-key",
               locked_at: Time.current)
      end

      it "returns locked status" do
        record, status = described_class.find_or_initialize_for_request(
          credential,
          "existing-key",
          "POST",
          "/api/v1/send/message",
          params
        )

        expect(status).to eq(:locked)
        expect(record).to eq(existing_key)
      end
    end

    context "when existing key is expired" do
      let!(:expired_key) do
        create(:idempotency_key,
               credential: credential,
               idempotency_key: "expired-key",
               expires_at: 1.hour.ago)
      end

      it "deletes the expired key and returns new status" do
        expect do
          record, status = described_class.find_or_initialize_for_request(
            credential,
            "expired-key",
            "POST",
            "/api/v1/send/message",
            params
          )

          expect(status).to eq(:new)
          expect(record).to be_new_record
        end.to change(described_class, :count).by(-1)
      end
    end
  end

  describe "before_validation :set_expires_at" do
    it "sets expires_at to 24 hours from now by default" do
      key = described_class.new(credential: credential, idempotency_key: "test")
      key.valid?
      expect(key.expires_at).to be_within(1.second).of(24.hours.from_now)
    end

    it "does not override manually set expires_at" do
      custom_time = 48.hours.from_now
      key = described_class.new(
        credential: credential,
        idempotency_key: "test",
        expires_at: custom_time
      )
      key.valid?
      expect(key.expires_at).to be_within(1.second).of(custom_time)
    end
  end
end
