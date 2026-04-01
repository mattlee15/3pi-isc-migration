# frozen_string_literal: true

# Migration module: no-secret pattern.
#
# Use when the config contains NO sensitive fields and should be stored as plain YAML
# (not as a secret ref). This migrates configs that were incorrectly stored as secrets
# in the source service.
#
# Standalone usage:
#   ruby tmp/3pi_isc_migration/scripts/migrate_no_secret.rb \
#     --source-conf env/OFFERS_V1_... \
#     --new-conf env/OFFERS_V1_..._NEW \
#     --environment staging

require_relative "common"
require "optparse"

module MigrateNoSecret
  # Run the migration.
  #
  # @param parsed [Hash]        YAML-parsed content of the source conf
  # @param source_conf [String] name of the source conf (for logging/reporting)
  # @param new_conf_name [String]   name for the new conf
  # @param environment [String]
  # @param dest_service [String]    ISC service glob for the new conf
  # @param report_path [String, nil] path to append report entry; nil = skip
  # @return [Hash] { new_conf_name:, secret_ref_used: nil }
  def self.run(parsed:, source_conf:, new_conf_name:,
               environment: DEFAULT_ENVIRONMENT, dest_service: DEFAULT_SERVICE, report_path: nil)
    puts "--- No-secret migration ---"
    puts "  Source conf:    #{source_conf}"
    puts "  New conf:       #{new_conf_name}"
    puts "  Environment:    #{environment}"
    puts "  Note:           Config will be stored as plain YAML (no secret ref)"
    puts

    # Convert to YAML with proper formatting
    yaml_content = to_yaml_with_literal_blocks(parsed)
    puts "  Config content:"
    puts yaml_content.lines.first(10).map { |l| "    #{l}" }.join
    puts "    ..." if yaml_content.lines.count > 10
    puts

    # Create the conf as plain YAML (no secret ref)
    puts "  Creating conf: #{new_conf_name}"
    create_plain_conf(new_conf_name, yaml_content, service: dest_service, environment: environment)
    puts "  Conf created."
    puts

    # Verify round-trip
    puts "  Verifying new conf..."
    new_raw = read_conf(new_conf_name, service: dest_service, environment: environment)
    new_parsed = YAML.safe_load(new_raw)

    # Deep comparison
    all_pass = verify(
      "Config structure matches" => new_parsed == parsed,
    )
    raise IscError, "Verification failed for #{new_conf_name}" unless all_pass

    report_path && append_report(
      report_path: report_path,
      source_conf: source_conf,
      environment: environment,
      plan: "no_secret",
      secret_keys: "(none - plain YAML)",
      new_conf_name: new_conf_name,
      secret_ref_used: nil,
      orig_conf_status: "(pending)",
      orig_secret_status: "(pending)",
    )

    { new_conf_name: new_conf_name, secret_ref_used: nil }
  end
end

# ── Standalone execution ───────────────────────────────────────────────────────

if __FILE__ == $PROGRAM_NAME
  options = {
    environment: DEFAULT_ENVIRONMENT,
    dest_service: DEFAULT_SERVICE,
  }

  OptionParser.new do |opts|
    opts.banner = "Usage: ruby migrate_no_secret.rb [options]"
    opts.on("--source-conf NAME", "Source conf name") { |v| options[:source_conf] = v }
    opts.on("--new-conf NAME", "New conf name") { |v| options[:new_conf] = v }
    opts.on("--environment ENV", "Environment (default: #{DEFAULT_ENVIRONMENT})") { |v| options[:environment] = v }
    opts.on("--dest-service SVC", "Destination service (default: #{DEFAULT_SERVICE})") { |v| options[:dest_service] = v }
  end.parse!

  %i[source_conf new_conf].each do |key|
    abort "Missing required option: --#{key.to_s.tr('_', '-')}" unless options[key]
  end

  raw = read_conf(options[:source_conf], service: SOURCE_SERVICE, environment: options[:environment])
  parsed = YAML.safe_load(raw)

  result = MigrateNoSecret.run(
    parsed: parsed,
    source_conf: options[:source_conf],
    new_conf_name: options[:new_conf],
    environment: options[:environment],
    dest_service: options[:dest_service],
    report_path: File.expand_path("../../report.txt", __dir__),
  )

  puts "Migration complete."
  puts "  New conf: #{result[:new_conf_name]}"
  puts "  Secret ref: (none - plain YAML)"
end
