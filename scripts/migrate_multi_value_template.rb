# frozen_string_literal: true

# Migration module: multi-value secret-ref template pattern.
#
# Use when there are 2+ sensitive fields that all live under the same immediate
# parent key. A standalone $$secret$$ block placeholder is inserted at the end
# of the parent key block and expands to a pre-indented multi-line YAML block.
#
# Pre-indent rules (critical):
#   Line 1: no leading spaces — $$secret$$ position in the template provides the indent
#   Line 2+: (parent_depth × 2) spaces — depth 1 parent → 2 spaces, depth 2 → 4 spaces, etc.
#
# Standalone usage:
#   ruby tmp/3pi_isc_migration/scripts/migrate_multi_value_template.rb \
#     --source-conf env/OFFERS_V1_... \
#     --secret-keys lms.authenticate_password,lms.api_key \
#     --new-conf env/OFFERS_V1_..._NEW \
#     --secret-ref OFFERS_V1_..._NEW_SECRET \
#     --environment staging

require_relative "common"
require "optparse"

module MigrateMultiValueTemplate
  # Run the migration.
  #
  # @param parsed [Hash]          YAML-parsed content of the source conf
  # @param source_conf [String]   name of the source conf (for logging/reporting)
  # @param secret_key_paths [Array<String>] dot-separated paths to all secret fields,
  #   must share the same immediate parent (e.g. ["lms.authenticate_password", "lms.api_key"])
  # @param new_conf_name [String]    name for the new conf
  # @param secret_ref_name [String]  name for the secret ref to create/reuse
  # @param environment [String]
  # @param dest_service [String]     ISC service glob for the new conf
  # @param report_path [String, nil] path to append report entry; nil = skip
  # @param update_secret_ref_name [String, nil] when re-migrating an already-migrated conf,
  #   the name of the secret ref currently linked to the dest conf. If set and single-linked,
  #   the ref is updated in place. If multi-linked, a new ref is created instead.
  # @param skip_dedup [Boolean] if true, create secret ref with shared_value_detection: false
  # @return [Hash] { new_conf_name:, secret_ref_used: }
  def self.run(parsed:, source_conf:, secret_key_paths:, new_conf_name:, secret_ref_name:,
               environment: DEFAULT_ENVIRONMENT, dest_service: DEFAULT_SERVICE, report_path: nil,
               update_secret_ref_name: nil, skip_dedup: false)
    # Validate all keys share the same parent
    parents = secret_key_paths.map { |p| p.split(".")[0..-2].join(".") }.uniq
    if parents.length > 1
      raise IscError, "All secret keys must share the same parent. Got parents: #{parents.join(', ')}"
    end

    # Validate all keys exist in the parsed conf
    secret_key_paths.each do |path|
      parts = path.split(".")
      val = parsed.dig(*parts)
      raise IscError, "Secret key not found in conf: #{path}" if val.nil?
    end

    puts "--- Multi-value template migration ---"
    puts "  Source conf:    #{source_conf}"
    puts "  Secret keys:    #{secret_key_paths.join(', ')}"
    puts "  New conf:       #{new_conf_name}"
    puts "  Environment:    #{environment}"
    puts

    # Build template: secret keys removed, standalone $$secret$$ block added
    template = build_multi_value_template(parsed, secret_key_paths)
    puts "  Template:"
    puts template.gsub(/^/, "    ")

    # Build the pre-indented secret value block
    secret_value = build_secret_block(parsed, secret_key_paths)
    puts "  Secret ref value:"
    secret_key_paths.each do |path|
      puts "    #{path.split('.').last}: [REDACTED]"
    end
    puts

    # Create, update, or reuse secret ref
    used_secretref =
      if update_secret_ref_name
        linked = find_linked_confs_for_secret_ref(update_secret_ref_name, environment: environment)
        if linked.length <= 1
          puts "  Updating existing secret ref: #{update_secret_ref_name}"
          update_secret_ref(update_secret_ref_name, secret_value, environment: environment)
          update_secret_ref_name
        else
          puts "  Existing secret ref linked to #{linked.length} confs — creating new one"
          create_or_find_secret_ref(secret_ref_name, secret_value, environment: environment, skip_dedup: skip_dedup)
        end
      else
        puts "  Creating/finding secret ref: #{secret_ref_name}"
        create_or_find_secret_ref(secret_ref_name, secret_value, environment: environment, skip_dedup: skip_dedup)
      end
    puts

    # Create or update the conf
    action = update_secret_ref_name ? "Updating" : "Creating"
    puts "  #{action} conf: #{new_conf_name}"
    create_conf_with_template(new_conf_name, template, used_secretref,
                              service: dest_service, environment: environment)
    puts "  Conf #{update_secret_ref_name ? 'updated' : 'created'}."
    puts

    # Verify round-trip: all secret fields should match
    puts "  Verifying new conf..."
    new_raw = read_conf(new_conf_name, service: dest_service, environment: environment)
    new_parsed = YAML.safe_load(new_raw)

    checks = secret_key_paths.each_with_object({}) do |path, h|
      parts = path.split(".")
      h["#{path} matches original"] = new_parsed.dig(*parts).to_s == parsed.dig(*parts).to_s
    end

    all_pass = verify(checks)
    raise IscError, "Verification failed for #{new_conf_name}" unless all_pass

    report_path && append_report(
      report_path: report_path,
      source_conf: source_conf,
      environment: environment,
      plan: "multi_value_template",
      secret_keys: secret_key_paths,
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
    opts.banner = "Usage: ruby migrate_multi_value_template.rb [options]"
    opts.on("--source-conf NAME", "Source conf name") { |v| options[:source_conf] = v }
    opts.on("--secret-keys PATHS", "Comma-separated dot-separated secret key paths") { |v| options[:secret_keys] = v.split(",").map(&:strip) }
    opts.on("--new-conf NAME", "New conf name") { |v| options[:new_conf] = v }
    opts.on("--secret-ref NAME", "Secret ref name") { |v| options[:secret_ref] = v }
    opts.on("--environment ENV", "Environment (default: #{DEFAULT_ENVIRONMENT})") { |v| options[:environment] = v }
    opts.on("--dest-service SVC", "Destination service (default: #{DEFAULT_SERVICE})") { |v| options[:dest_service] = v }
  end.parse!

  %i[source_conf secret_keys new_conf secret_ref].each do |key|
    abort "Missing required option: --#{key.to_s.tr('_', '-')}" unless options[key]
  end

  raw = read_conf(options[:source_conf], service: SOURCE_SERVICE, environment: options[:environment])
  parsed = YAML.safe_load(raw)

  result = MigrateMultiValueTemplate.run(
    parsed: parsed,
    source_conf: options[:source_conf],
    secret_key_paths: options[:secret_keys],
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
