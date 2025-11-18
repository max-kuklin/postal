# frozen_string_literal: true

module ScheduledTasks
  class CleanupIdempotencyKeysTask

    def self.call
      new.run
    end

    def run
      deleted_count = IdempotencyKey.expired.delete_all

      if deleted_count > 0
        Rails.logger.info "[IdempotencyKey Cleanup] Deleted #{deleted_count} expired idempotency key(s)"
      end

      deleted_count
    end

  end
end
