# frozen_string_literal: true

namespace :billing do
  desc "Ingest a CSV engagements file into pending_engagements: billing:ingest[path]"
  task :ingest, [ :path ] => :environment do |_task, args|
    result = Ingest::LoadFile.call(args[:path])
    puts "ingested #{result.rows_read} rows from #{result.file}, touched #{result.batches_touched} batch(es)"
  end

  desc "Run the billing worker loop (claim -> allocate -> persist). Scale with --scale worker=N"
  task work: :environment do
    worker_id = "#{Socket.gethostname}-#{Process.pid}"
    shutdown = false

    # Graceful shutdown: stop claiming new batches, finish the one in
    # flight, exit. Without it every deploy and every `compose down` leaves
    # batches claimed until their leases expire.
    Signal.trap("TERM") { shutdown = true }
    Signal.trap("INT")  { shutdown = true }

    Rails.logger.info({ event: "worker.started", worker_id: }.to_json)

    until shutdown
      result = Billing::BillBatch.call_next(worker_id:)
      sleep(Billing::POLL_INTERVAL) if result == :no_work && !shutdown
    end

    Rails.logger.info({ event: "worker.stopped", worker_id: }.to_json)
  end

  desc "Run the billing worker until no work remains, then exit (used for batch runs and specs)"
  task drain: :environment do
    worker_id = "#{Socket.gethostname}-#{Process.pid}"
    loop { break if Billing::BillBatch.call_next(worker_id:) == :no_work }
    puts "drained"
  end

  desc "Check the three conservation invariants against the current database state"
  task verify: :environment do
    violations = Billing::ConservationCheck.call

    if violations.empty?
      puts "conservation OK: engagements and premium ledgers balance per date, no budget over quota"
    else
      violations.each do |v|
        puts "VIOLATION #{v.kind} key=#{v.key} expected=#{v.expected} actual=#{v.actual}"
      end
      abort "#{violations.size} conservation violation(s)"
    end
  end
end
