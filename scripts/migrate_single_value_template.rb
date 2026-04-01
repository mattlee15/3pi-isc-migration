# frozen_string_literal: true

# Migration module: single-value secret-ref template pattern.
#
# Use when there is exactly ONE sensitive field under a single parent key.
# The key stays in the template; $$secret$$ replaces only the value.
#
# Standalone usage:
#   ruby tmp/3pi_isc_migration/scripts/migrate_single_value_template.rb \
#     --source-conf env/OFFERS_V1_... \
#     --secret-key lms.authenticate_password \
#     --new-conf env/OFFERS_V1_..._NEW \
#     --secret-ref OFFERS_V1_..._NEW_SECRET \
#     --environment staging

require_relative "common"
require "optparse"

module MigrateSingleValueTemplate
  # Run the migration.
  #
  # @param parsed [Hash]        YAML-parsed content of the source conf
  # @param source_conf [String] name of the source conf (for logging/reporting)
  # @param secret_key_path [String] dot-separated path to the secret field, e.g. "lms.authenticate_password"
  # @param new_conf_name [String]   name for the new conf
  # @param secret_ref_name [String] name for the secret ref to create/reuse
  # @param environment [String]
  # @param dest_service [String]    ISC service glob for the new conf
  # @param report_path [String, nil] path to append report entry; nil = skip
  # @param update_secret_ref_name [String, nil] when re-migrating an already-migrated conf,
  #   the name of the secret ref currently linked to the dest conf. If set and single-linked,
  #   the ref is updated in place. If multi-linked, a new ref is created instead.
  # @param skip_dedup [Boolean] if true, create secret ref with shared_value_detection: false
  # @return [Hash] { new_conf_name:, secret_ref_used: }
  def self.run(parsed:, source_conf:, secret_key_path:, new_conf_name:, secret_ref_name:,
               environment: DEFAULT_ENVIRONMENT, dest_service: DEFAULT_SERVICE, report_path: nil,
               update_secret_ref_name: nil, skip_dedup: false)
    parts = secret_key_path.split(".")
    secret_value = parsed.dig(*parts)
    raise IscError, "Secret key not found in conf: #{secret_key_path}" if secret_value.nil?

    puts "--- Single-value template migration ---"
    puts "  Source conf:    #{source_conf}"
    puts "  Secret key:     #{secret_key_path}"
    puts "  New conf:       #{new_conf_name}"
    puts "  Environment:    #{environment}"
    puts

    # Build template: key stays, $$secret$$ is the value
    template = build_single_value_template(parsed, secret_key_path)
    puts "  Template:"
    puts template.gsub(/^/, "    ")

    # Create, update, or reuse secret ref
    used_secretref =
      if update_secret_ref_name
        linked = find_linked_confs_for_secret_ref(update_secret_ref_name, environment: environment)
        if linked.length <= 1
          puts "  Updating existing secret ref: #{update_secret_ref_name}"
          update_secret_ref(update_secret_ref_name, secret_value.to_s, environment: environment)
          update_secret_ref_name
        else
          puts "  Existing secret ref linked to #{linked.length} confs — creating new one"
          create_or_find_secret_ref(secret_ref_name, secret_value.to_s, environment: environment, skip_dedup: skip_dedup)
        end
      else
        puts "  Creating/finding secret ref: #{secret_ref_name}"
        create_or_find_secret_ref(secret_ref_name, secret_value.to_s, environment: environment, skip_dedup: skip_dedup)
      end
    puts

    # Create or update the conf
    action = update_secret_ref_name ? "Updating" : "Creating"
    puts "  #{action} conf: #{new_conf_name}"
    create_conf_with_template(new_conf_name, template, used_secretref,
                              service: dest_service, environment: environment)
    puts "  Conf #{update_secret_ref_name ? 'updated' : 'created'}."
    puts

    # Verify round-trip
    puts "  Verifying new conf..."
    new_raw = read_conf(new_conf_name, service: dest_service, environment: environment)
    new_parsed = YAML.safe_load(new_raw)
    new_value = new_parsed.dig(*parts)

    all_pass = verify(
      "#{secret_key_path} matches original" => new_value.to_s == secret_value.to_s,
    )
    raise IscError, "Verification failed for #{new_conf_name}" unless all_pass

    report_path && append_report(
      report_path: report_path,
      source_conf: source_conf,
      environment: environment,
      plan: "single_value_template",
      secret_keys: secret_key_path,
      new_conf_name: new_conf_name,
      secret_ref_used: used_secretref,
      orig_conf_status: "(pending)",
      orig_secret_status: "(pending)",
    )

    { new_conf_name: new_conf_name, secret_ref_used: used_secretref }
  end
end

# ── Standalone execution ───────────────────────────────────────────────────────

if __FILE__ == $PROGRAM_NAME
  options = {
    environment: DEFAULT_ENVIRONMENT,
    dest_service: DEFAULT_SERVICE,
  }

  OptionParser.new do |opts|
    opts.banner = "Usage: ruby migrate_single_value_template.rb [options]"
    opts.on("--source-conf NAME", "Source conf name") { |v| options[:source_conf] = v }
    opts.on("--secret-key PATH", "Dot-separated secret key path (e.g. lms.authenticate_password)") { |v| options[:secret_key] = v }
    opts.on("--new-conf NAME", "New conf name") { |v| options[:new_conf] = v }
    opts.on("--secret-ref NAME", "Secret ref name") { |v| options[:secret_ref] = v }
    opts.on("--environment ENV", "Environment (default: #{DEFAULT_ENVIRONMENT})") { |v| options[:environment] = v }
    opts.on("--dest-service SVC", "Destination service (default: #{DEFAULT_SERVICE})") { |v| options[:dest_service] = v }
  end.parse!

  %i[source_conf secret_key new_conf secret_ref].each do |key|
    abort "Missing required option: --#{key.to_s.tr('_', '-')}" unless options[key]
  end

  raw = read_conf(options[:source_conf], service: SOURCE_SERVICE, environment: options[:environment])
  parsed = YAML.safe_load(raw)

  result = MigrateSingleValueTemplate.run(
    parsed: parsed,
    source_conf: options[:source_conf],
    secret_key_path: options[:secret_key],
    new_conf_name: options[:new_conf],
    secret_ref_name: options[:secret_ref],
    environment: options[:environment],
    dest_service: options[:dest_service],
    report_path: File.expand_path("../../report.txt", __dir__),
  )

  puts "Migration complete."
  puts "  New conf:   #{result[:new_conf_name]}"
  puts "  Secret ref: #{result[:secret_ref_used]}"
end
