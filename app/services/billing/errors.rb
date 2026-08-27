# frozen_string_literal: true

module Billing
  Error = Class.new(StandardError)

  # A peer consumed the capacity between our locked read and our write.
  # Expected under concurrency — not a bug.
  CapacityRaced = Class.new(Error)

  # The allocator lost or created engagements. ALWAYS a bug; rolls the batch back.
  ConservationViolation = Class.new(Error)

  # The batch's staging data is unusable (e.g. negative counts survived ingest).
  MalformedBatch = Class.new(Error)

  # The fencing check failed: our lease expired and someone else owns this batch now.
  # Expected under a paused worker.
  LeaseLost = Class.new(Error)
end
