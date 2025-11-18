# frozen_string_literal: true

module WithIdempotency
  extend ActiveSupport::Concern

  IDEMPOTENCY_HEADER = "HTTP_IDEMPOTENCY_KEY"

  included do
    # Helper to execute an action with idempotency support
    def with_idempotency(&block)
      idempotency_key = request.headers[IDEMPOTENCY_HEADER]

      # If no idempotency key provided, process normally
      if idempotency_key.blank?
        yield
        return
      end

      # Validate key format
      unless valid_idempotency_key?(idempotency_key)
        render_error "InvalidIdempotencyKey",
                     message: "The provided idempotency key is invalid. Must be 1-255 characters."
        return
      end

      # Find or initialize the idempotency key record
      record, status = IdempotencyKey.find_or_initialize_for_request(
        @current_credential,
        idempotency_key,
        request.method,
        request.path,
        api_params
      )

      case status
      when :cached
        # Return cached response
        render json: record.response_body, status: record.response_code
        return

      when :locked
        # Another request is in progress
        render_error "IdempotencyKeyInUse",
                     message: "A request with this idempotency key is currently being processed"
        return

      when :mismatch
        # Same key, different params
        render_error "IdempotencyKeyMismatch",
                     message: "This idempotency key was previously used with different parameters"
        return

      when :new
        # Save the new record and process
        if record.save
          begin
            # Capture the response by temporarily storing it
            @idempotency_response_capture = StringIO.new

            # Execute the actual action
            yield

            # Capture the response that was rendered
            if response.body.present?
              record.store_response(response.status, response.body)
            end
          rescue StandardError => e
            # If there's an error, unlock the key so it can be retried
            record.unlock! if record.persisted?
            raise e
          end
        else
          render_error "IdempotencyKeyError",
                       message: "Failed to create idempotency key record"
        end
      end
    end

    private

    def valid_idempotency_key?(key)
      key.present? && key.length.between?(1, 255)
    end
  end

end
