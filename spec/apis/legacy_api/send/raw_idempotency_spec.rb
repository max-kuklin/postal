# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Legacy Send API - Raw Idempotency", type: :request do
  let(:server) { create(:server) }
  let(:credential) { create(:credential, server: server) }
  let(:domain) { create(:domain, owner: server) }
  let(:mail_data) do
    mail = Mail.new
    mail.to = "test@example.com"
    mail.from = "test@#{domain.name}"
    mail.subject = "Test Subject"
    mail.body = "Test body"
    mail
  end
  let(:default_params) do
    {
      mail_from: "test@#{domain.name}",
      rcpt_to: ["test@example.com"],
      data: Base64.encode64(mail_data.to_s)
    }
  end

  describe "with Idempotency-Key header" do
    let(:idempotency_key) { "test-raw-key-#{SecureRandom.hex(8)}" }

    context "when sending the same request twice" do
      it "returns the cached response on second request" do
        # First request
        post "/api/v1/send/raw",
             headers: { "x-server-api-key" => credential.key,
                        "idempotency-key" => idempotency_key,
                        "content-type" => "application/json" },
             params: default_params.to_json

        expect(response.status).to eq 200
        first_body = JSON.parse(response.body)
        expect(first_body["status"]).to eq "success"
        message_id_1 = first_body["data"]["messages"]["test@example.com"]["id"]

        # Second request with same key
        post "/api/v1/send/raw",
             headers: { "x-server-api-key" => credential.key,
                        "idempotency-key" => idempotency_key,
                        "content-type" => "application/json" },
             params: default_params.to_json

        expect(response.status).to eq 200
        second_body = JSON.parse(response.body)
        expect(second_body).to eq(first_body)

        # Verify no new message was created
        message_id_2 = second_body["data"]["messages"]["test@example.com"]["id"]
        expect(message_id_2).to eq(message_id_1)
      end

      it "does not create duplicate messages" do
        expect do
          2.times do
            post "/api/v1/send/raw",
                 headers: { "x-server-api-key" => credential.key,
                            "idempotency-key" => idempotency_key,
                            "content-type" => "application/json" },
                 params: default_params.to_json
          end
        end.to change { server.message_db.messages.count }.by(1)
      end
    end

    context "when sending with same key but different params" do
      it "returns an error" do
        # First request
        post "/api/v1/send/raw",
             headers: { "x-server-api-key" => credential.key,
                        "idempotency-key" => idempotency_key,
                        "content-type" => "application/json" },
             params: default_params.to_json

        expect(response.status).to eq 200

        # Second request with different recipient
        different_params = default_params.merge(rcpt_to: ["different@example.com"])
        post "/api/v1/send/raw",
             headers: { "x-server-api-key" => credential.key,
                        "idempotency-key" => idempotency_key,
                        "content-type" => "application/json" },
             params: different_params.to_json

        expect(response.status).to eq 200
        body = JSON.parse(response.body)
        expect(body["status"]).to eq "error"
        expect(body["data"]["code"]).to eq "IdempotencyKeyMismatch"
      end
    end

    context "when the first request fails" do
      it "allows retry with the same key" do
        invalid_params = default_params.except(:mail_from)

        # First request fails
        post "/api/v1/send/raw",
             headers: { "x-server-api-key" => credential.key,
                        "idempotency-key" => idempotency_key,
                        "content-type" => "application/json" },
             params: invalid_params.to_json

        expect(response.status).to eq 200
        body = JSON.parse(response.body)
        expect(body["status"]).to eq "parameter-error"

        # Second request with valid params should succeed
        post "/api/v1/send/raw",
             headers: { "x-server-api-key" => credential.key,
                        "idempotency-key" => idempotency_key,
                        "content-type" => "application/json" },
             params: default_params.to_json

        expect(response.status).to eq 200
        body = JSON.parse(response.body)
        expect(body["status"]).to eq "success"
      end
    end

    context "when handling multiple recipients" do
      let(:multi_recipient_params) do
        default_params.merge(rcpt_to: ["test1@example.com", "test2@example.com"])
      end

      it "returns the same message IDs on retry" do
        # First request
        post "/api/v1/send/raw",
             headers: { "x-server-api-key" => credential.key,
                        "idempotency-key" => idempotency_key,
                        "content-type" => "application/json" },
             params: multi_recipient_params.to_json

        expect(response.status).to eq 200
        first_body = JSON.parse(response.body)
        expect(first_body["data"]["messages"].keys).to contain_exactly("test1@example.com", "test2@example.com")

        # Second request
        post "/api/v1/send/raw",
             headers: { "x-server-api-key" => credential.key,
                        "idempotency-key" => idempotency_key,
                        "content-type" => "application/json" },
             params: multi_recipient_params.to_json

        expect(response.status).to eq 200
        second_body = JSON.parse(response.body)
        expect(second_body).to eq(first_body)
      end

      it "does not create duplicate messages for any recipient" do
        expect do
          2.times do
            post "/api/v1/send/raw",
                 headers: { "x-server-api-key" => credential.key,
                            "idempotency-key" => idempotency_key,
                            "content-type" => "application/json" },
                 params: multi_recipient_params.to_json
          end
        end.to change { server.message_db.messages.count }.by(2) # One per recipient, not 4
      end
    end
  end

  describe "without Idempotency-Key header" do
    it "processes requests normally and creates duplicate messages" do
      expect do
        2.times do
          post "/api/v1/send/raw",
               headers: { "x-server-api-key" => credential.key,
                          "content-type" => "application/json" },
               params: default_params.to_json

          expect(response.status).to eq 200
          body = JSON.parse(response.body)
          expect(body["status"]).to eq "success"
        end
      end.to change { server.message_db.messages.count }.by(2)
    end
  end
end
