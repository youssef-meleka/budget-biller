# frozen_string_literal: true

module Billing
  class ClaimBatch
    SQL = <<~SQL.squish
      UPDATE billing_batches
         SET state             = 'claimed',
             claimed_by        = ?,
             claimed_at        = NOW(),
             lease_expires_at  = NOW() + (? || ' seconds')::interval,
             attempts          = attempts + 1
       WHERE id = (
         SELECT id
           FROM billing_batches
          WHERE state != 'failed'
            AND (
              state = 'pending'
              OR (state = 'claimed' AND lease_expires_at < NOW())
              OR (state = 'billed'  AND staging_digest != billed_digest)
            )
          ORDER BY date ASC, merchant_id ASC
          LIMIT 1
          FOR UPDATE SKIP LOCKED
         )
      RETURNING *
    SQL

    def self.call(worker_id:)
      BillingBatch.find_by_sql([ SQL, worker_id, Billing::LEASE_TTL ]).first
    end
  end
end
