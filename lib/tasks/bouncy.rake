# frozen_string_literal: true

namespace :bouncy do
  desc "Require a fresh verified mirror before starting a host's mail workers"
  task bootstrap: :environment do
    puts JSON.pretty_generate(Bouncy.bootstrap!.details)
  end

  desc "Import and reconcile the configured provider scope"
  task sync: :environment do
    puts JSON.pretty_generate(Bouncy.sync!.details)
  end

  desc "Check provider scope and local freshness without changing AWS"
  task doctor: :environment do
    checks = Bouncy.adapter.doctor
    checks["last_attempt"] = Bouncy.last_sync&.created_at
    checks["last_success"] = Bouncy.last_successful_sync&.created_at
    puts JSON.pretty_generate(checks)
  end

  namespace :ses do
    desc "Print a read-only SES setup plan; never provisions resources"
    task setup: :environment do
      raise Bouncy::ConfigurationError, "Write mode is not supported; omit APPLY" if ENV.key?("APPLY")

      puts JSON.pretty_generate(Bouncy.adapter.doctor)
      puts "1. Deploy POST <engine mount>/webhooks/ses with the exact topic allowlist (the mount is usually /bouncy)."
      puts "2. Review the SNS publisher policy: SES service principal plus SourceAccount and SourceArn conditions."
      puts "3. Subscribe that HTTPS URL; preserve existing feedback destinations. Disable raw message delivery."
      puts "4. Confirm subscription status in SNS and test receiver delivery/retries."
      puts "5. Run bouncy:sync; schedule Bouncy::SyncJob hourly and Bouncy::PruneJob daily."
      puts "6. Review imported restrictions and perform a staging delivery test before enabling :drop."
    end
  end
end
