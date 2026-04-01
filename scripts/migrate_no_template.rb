# frozen_string_literal: true

# Migration module: no-template (direct secret ref link) pattern.
#
# Use when sensitive fields span different parent keys (cross-subkey secrets),
# making the $$secret$$ substitution approach impossible without restructuring
# the YAML. The entire conf value comes from the existing secret ref — no
# template substitution occurs.
#
# This simply creates a new conf in *.integrations.integrations linked to the
# same existing secret ref as the source conf. It does NOT create a new secret
# ref; it reuses the one already linked to the source conf.
#
# Standalone usage:
#   ruby tmp/3pi_isc_migration/scripts/migrate_no_template.rb \
#     --source-conf env/LOYALTY_V1_... \
#     --source-secret-ref env/LOYALTY_V1_... \
#     --new-conf env/LOYALTY_V1_..._NEW \
#     --environment staging

require_relative "common"
require "optparse"

module MigrateNoTemplate
  # Run the migration.
  #
  # @param source_conf [String]           name of the source conf (read to verify)
  # @param source_secret_ref_name [String] name of the existing secret ref to link to
  # @param new_conf_name [String]          name for the new conf
  # @param environment [String]
  # @param dest_service [String]           ISC service glob for the new conf
  # @param already_migrated [Boolean] true when the dest conf already exists (updating, not creating)
  # @param report_path [String, nil]       path to append report entry; nil = skip
  # @return [Hash] { new_conf_name:, secret_ref_used: }
  def self.run(source_conf:, source_secret_ref_name:, new_conf_name:,
               environment: DEFAULT_ENVIRONMENT, dest_service: DEFAULT_SERVICE,
               already_migrated: false, report_path: nil)
    puts "--- No-template migration (direct secret ref link) ---"
    puts "  Source conf:       #{source_conf}"
    puts "  Existing secret ref: #{source_secret_ref_name}"
    puts "  New conf:          #{new_conf_name}"
    puts "  Environment:       #{environment}"
    puts

    # Read original conf so we can verify the new one matches
    puts "  Reading source conf..."
    orig_raw = read_conf(source_conf, service: SOURCE_SERVICE, environment: environment)
    orig_parsed = YAML.safe_load(orig_raw)

    # Verify the secret ref exists
    ref = find_secret_ref(source_secret_ref_name, environment: environment)
    raise IscError, "Secret ref not found: #{source_secret_ref_name}" unless ref

    puts "  Found secret ref: #{source_secret_ref_name}"
    puts

    # Create or update the conf link (no template — entire value comes from secret ref)
    action = already_migrated ? "Updating conf link" : "Creating new conf"
    puts "  #{action}: #{new_conf_name}"
    link_conf_to_secret_ref(new_conf_name, source_secret_ref_name,
                            service: dest_service, environment: environment)
    puts "  Conf #{already_migrated ? 'updated' : 'created'}."
    puts

    # Verify the new conf returns the same value as the original
    puts "  Verifying new conf..."
    new_raw = read_conf(new_conf_name, service: dest_service, environment: environment)
    new_parsed = YAML.safe_load(new_raw)

    all_pass = verify(
      "new conf matches original" => new_parsed == orig_parsed,
    )
    raise IscError, "Verification failed for #{new_conf_name}" unless all_pass

    report_path && append_report(
      report_path: report_path,
      source_conf: source_conf,
      environment: environment,
      plan: "no_template",
      secret_keys: "(all — monolithic)",
      new_conf_name: new_conf_name,
      secret_ref_used: source_secret_ref_name,
      orig_conf_status: "(pending)",
      orig_secret_status: "(pending)",
    )

    { new_conf_name: new_conf_name, secret_ref_used: source_secret_ref_name }
  end
end

# ── Standalone execution ───────────────────────────────────────────────────────

if __FILE__ == $PROGRAM_NAME
  options = {
    environment: DEFAULT_ENVIRONMENT,
    dest_service: DEFAULT_SERVICE,
  }

  OptionParser.new do |opts|
    opts.banner = "Usage: ruby migrate_no_template.rb [options]"
    opts.on("--source-conf NAME", "Source conf name") { |v| options[:source_conf] = v }
    opts.on("--source-secret-ref NAME", "Existing secret ref name to link to") { |v| options[:source_secret_ref] = v }
    opts.on("--new-conf NAME", "New conf name") { |v| options[:new_conf] = v }
    opts.on("--environment ENV", "Environment (default: #{DEFAULT_ENVIRONMENT})") { |v| options[:environment] = v }
    opts.on("--dest-service SVC", "Destination service (default: #{DEFAULT_SERVICE})") { |v| options[:dest_service] = v }
  end.parse!

  %i[source_conf source_secret_ref new_conf].each do |key|
    abort "Missing required option: --#{key.to_s.tr('_', '-')}" unless options[key]
  end

  result = MigrateNoTemplate.run(
    source_conf: options[:source_conf],
    source_secret_ref_name: options[:source_secret_ref],
    new_conf_name: options[:new_conf],
    environment: options[:environment],
    dest_service: options[:dest_service],
    report_path: File.expand_path("../../report.txt", __dir__),
  )

  puts "Migration complete."
  puts "  New conf:   #{result[:new_conf_name]}"
  puts "  Secret ref: #{result[:secret_ref_used]}"
end
