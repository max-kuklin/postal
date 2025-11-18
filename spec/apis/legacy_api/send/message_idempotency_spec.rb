# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Legacy Send API - Message Idempotency", type: :request do
  let(:server) { create(:server) }
  let(:credential) { create(:credential, server: server) }
  let(:domain) { create(:domain, owner: server) }
  let(:default_params) do
    {
      to: ["test@example.com"],
      from: "test@#{domain.name}",
      subject: "Test Subject",
      plain_body: "Test body"
    }
  end

  describe "with Idempotency-Key header" do
    let(:idempotency_key) { "test-key-#{SecureRandom.hex(8)}" }

    context "when sending the same request twice" do
      it "returns the cached response on second request" do
        # First request
        post "/api/v1/send/message",
             headers: { "x-server-api-key" => credential.key,
                        "idempotency-key" => idempotency_key,
                        "content-type" => "application/json" },
             params: default_params.to_json

        expect(response.status).to eq 200
        first_body = JSON.parse(response.body)
        expect(first_body["status"]).to eq "success"
        message_id_1 = first_body["data"]["messages"]["test@example.com"]["id"]

        # Second request with same key
        post "/api/v1/send/message",
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
            post "/api/v1/send/message",
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
        post "/api/v1/send/message",
             headers: { "x-server-api-key" => credential.key,
                        "idempotency-key" => idempotency_key,
                        "content-type" => "application/json" },
             params: default_params.to_json

        expect(response.status).to eq 200

        # Second request with different params
        different_params = default_params.merge(subject: "Different Subject")
        post "/api/v1/send/message",
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

    context "when idempotency key is invalid" do
      it "returns an error for empty key" do
        post "/api/v1/send/message",
             headers: { "x-server-api-key" => credential.key,
                        "idempotency-key" => "",
                        "content-type" => "application/json" },
             params: default_params.to_json

        # Should process normally without idempotency when key is blank
        expect(response.status).to eq 200
        body = JSON.parse(response.body)
        expect(body["status"]).to eq "success"
      end

      it "returns an error for too long key" do
        long_key = "a" * 256
        post "/api/v1/send/message",
             headers: { "x-server-api-key" => credential.key,
                        "idempotency-key" => long_key,
                        "content-type" => "application/json" },
             params: default_params.to_json

        expect(response.status).to eq 200
        body = JSON.parse(response.body)
        expect(body["status"]).to eq "error"
        expect(body["data"]["code"]).to eq "InvalidIdempotencyKey"
      end
    end

    context "when the first request fails" do
      it "allows retry with the same key" do
        invalid_params = default_params.except(:from)

        # First request fails
        post "/api/v1/send/message",
             headers: { "x-server-api-key" => credential.key,
                        "idempotency-key" => idempotency_key,
                        "content-type" => "application/json" },
             params: invalid_params.to_json

        expect(response.status).to eq 200
        body = JSON.parse(response.body)
        expect(body["status"]).to eq "error"
        expect(body["data"]["code"]).to eq "FromAddressMissing"

        # Second request with valid params should succeed
        post "/api/v1/send/message",
             headers: { "x-server-api-key" => credential.key,
                        "idempotency-key" => idempotency_key,
                        "content-type" => "application/json" },
             params: default_params.to_json

        expect(response.status).to eq 200
        body = JSON.parse(response.body)
        expect(body["status"]).to eq "success"
      end
    end

    context "when different credentials use the same key" do
      let(:other_server) { create(:server) }
      let(:other_credential) { create(:credential, server: other_server) }
      let(:other_domain) { create(:domain, owner: other_server) }

      it "treats them as separate requests" do
        # First credential
        post "/api/v1/send/message",
             headers: { "x-server-api-key" => credential.key,
                        "idempotency-key" => idempotency_key,
                        "content-type" => "application/json" },
             params: default_params.to_json

        expect(response.status).to eq 200
        first_body = JSON.parse(response.body)

        # Second credential with same key
        other_params = default_params.merge(from: "test@#{other_domain.name}")
        post "/api/v1/send/message",
             headers: { "x-server-api-key" => other_credential.key,
                        "idempotency-key" => idempotency_key,
                        "content-type" => "application/json" },
             params: other_params.to_json

        expect(response.status).to eq 200
        second_body = JSON.parse(response.body)
        expect(second_body["status"]).to eq "success"

        # Verify different messages were created
        message_id_1 = first_body["data"]["messages"]["test@example.com"]["id"]
        message_id_2 = second_body["data"]["messages"]["test@example.com"]["id"]
        expect(message_id_2).not_to eq(message_id_1)
      end
    end

    context "when caching error responses" do
      it "caches validation errors" do
        invalid_params = default_params.merge(from: "invalid@unauthorized.com")

        # First request
        post "/api/v1/send/message",
             headers: { "x-server-api-key" => credential.key,
                        "idempotency-key" => idempotency_key,
                        "content-type" => "application/json" },
             params: invalid_params.to_json

        expect(response.status).to eq 200
        first_body = JSON.parse(response.body)
        expect(first_body["status"]).to eq "error"

        # Second request should return cached error
        post "/api/v1/send/message",
             headers: { "x-server-api-key" => credential.key,
                        "idempotency-key" => idempotency_key,
                        "content-type" => "application/json" },
             params: invalid_params.to_json

        expect(response.status).to eq 200
        second_body = JSON.parse(response.body)
        expect(second_body).to eq(first_body)
      end
    end
  end

  describe "without Idempotency-Key header" do
    it "processes requests normally" do
      expect do
        2.times do
          post "/api/v1/send/message",
               headers: { "x-server-api-key" => credential.key,
                          "content-type" => "application/json" },
               params: default_params.to_json

          expect(response.status).to eq 200
          body = JSON.parse(response.body)
          expect(body["status"]).to eq "success"
        end
      end.to change { server.message_db.messages.count }.by(2)
    end

    it "creates separate messages for each request" do
      post "/api/v1/send/message",
           headers: { "x-server-api-key" => credential.key,
                      "content-type" => "application/json" },
           params: default_params.to_json

      first_id = JSON.parse(response.body)["data"]["messages"]["test@example.com"]["id"]

      post "/api/v1/send/message",
           headers: { "x-server-api-key" => credential.key,
                      "content-type" => "application/json" },
           params: default_params.to_json

      second_id = JSON.parse(response.body)["data"]["messages"]["test@example.com"]["id"]

      expect(second_id).not_to eq(first_id)
    end
  end
end
