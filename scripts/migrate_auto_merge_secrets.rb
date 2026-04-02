# frozen_string_literal: true

# Migration module: auto_merge_secrets pattern.
#
# This pattern stores non-secret config in the main ISC config and secrets in a
# separate SecretRef, then uses the `secrets:` key with auto-flattening at runtime.
#
# How it works:
# 1. Base config contains ALL fields (including secrets)
# 2. Add `secrets: $$secret$$` at root level
# 3. Secret ref contains ONLY secret fields with full parent structure preserved
# 4. At runtime, configurations/base.rb:
#    - Extracts the `secrets:` key
#    - Deep merges it into base settings
#    - Secrets override base values where they exist
#
# Example:
#   Template:
#     ncr:
#       lms:
#         base_url: https://example.com
#         username: public_user
#         password: placeholder_will_be_overridden
#     secrets: $$secret$$
#
#   Secret ref:
#     ncr:
#       lms:
#         password: actual_secret
#
#   Result (at runtime after merge):
#     ncr:
#       lms:
#         base_url: https://example.com
#         username: public_user
#         password: actual_secret  # ← overridden from secrets:
#
# Benefits:
#   - Clean separation: non-secrets in template, secrets in separate ref
#   - Single ISC config per retailer (not two like Option 3)
#   - Uses ISC template pattern (self-documenting with $$secret$$)
#   - Zero plugin code changes needed
#   - Non-secret values can be updated without touching secrets
#
# Standalone usage:
#   ruby tmp/3pi_isc_migration/scripts/migrate_auto_merge_secrets.rb \
#     --source-conf env/LOYALTY_V1_... \
#     --secret-keys lms.password,lms.api_key \
#     --new-conf env/LOYALTY_V1_... \
#     --secret-ref LOYALTY_V1_..._SECRETS \
#     --environment staging

require_relative "common"
require "optparse"

module MigrateAutoMergeSecrets
  # Deep merge helper (simulates Rails' Hash#deep_merge)
  def self.deep_merge_hash(base, overrides)
    base.merge(overrides) do |_key, base_val, override_val|
      if base_val.is_a?(Hash) && override_val.is_a?(Hash)
        deep_merge_hash(base_val, override_val)
      else
        override_val
      end
    end
  end

  # Show differences between two hashes
  def self.show_hash_diff(expected, actual, indent = "")
    all_keys = (expected.keys + actual.keys).uniq

    all_keys.each do |key|
      exp_val = expected[key]
      act_val = actual[key]

      if !expected.key?(key)
        puts "#{indent}  + '#{key}': #{act_val.inspect} (extra in actual)"
      elsif !actual.key?(key)
        puts "#{indent}  - '#{key}': #{exp_val.inspect} (missing in actual)"
      elsif exp_val != act_val
        if exp_val.is_a?(Hash) && act_val.is_a?(Hash)
          puts "#{indent}  ~ '#{key}': (nested differences)"
          show_hash_diff(exp_val, act_val, indent + "    ")
        else
          puts "#{indent}  ~ '#{key}':"
          puts "#{indent}      expected: #{exp_val.inspect}"
          puts "#{indent}      got:      #{act_val.inspect}"
        end
      end
    end
  end

  # Build template: keeps ALL non-secret fields + adds secrets: $$secret$$
  def self.build_template(parsed, secret_key_paths)
    # Clone the full config
    template_hash = deep_dup(parsed)

    # Remove secret fields from template and clean up empty parents
    secret_key_paths.each do |path|
      parts = path.split(".")

      if parts.length == 1
        # Top-level secret
        template_hash.delete(parts[0])
      else
        # Navigate to parent and delete the leaf key
        parent = template_hash.dig(*parts[0..-2])
        parent&.delete(parts[-1])

        # Walk back up the tree and remove any parents that are now empty
        # (only parents that became empty from removing this secret)
        (parts.length - 2).downto(0) do |i|
          current_path = parts[0..i]
          current_node = template_hash.dig(*current_path)

          # If this node is now empty, remove it from its parent
          if current_node.is_a?(Hash) && current_node.empty?
            if i == 0
              # Top-level key
              template_hash.delete(current_path[0])
            else
              # Nested key
              parent_node = template_hash.dig(*current_path[0..-2])
              parent_node&.delete(current_path[-1])
            end
          else
            # Node is not empty, stop walking up
            break
          end
        end
      end
    end

    yaml_str = template_hash.to_yaml.sub(/\A---\n/, "")

    # Add secrets: with $$secret$$ on next line with 2-space indent
    # This ensures proper YAML structure after ISC substitution
    yaml_str += "secrets:\n  $$secret$$\n"

    yaml_str
  end

  # Build secret ref: ONLY secret fields with full parent structure preserved
  #
  # Example input:
  #   parsed: { "ncr" => { "lms" => { "base_url" => "...", "password" => "secret" } } }
  #   secret_key_paths: ["ncr.lms.password"]
  #
  # Output (2-space indentation to match $$secret$$ position):
  #   ncr:
  #     lms:
  #       password: secret
  def self.build_secret_value(parsed, secret_key_paths)
    secrets_hash = {}

    secret_key_paths.each do |path|
      parts = path.split(".")
      value = parsed.dig(*parts)

      # Build nested structure: traverse from root to leaf
      current = secrets_hash
      parts[0..-2].each do |part|
        current[part] ||= {}
        current = current[part]
      end
      current[parts.last] = value
    end

    # Convert to YAML with literal block scalars for multiline strings (SSH keys, certs)
    yaml_fragment = to_yaml_with_literal_blocks(secrets_hash)

    # ISC replaces "  $$secret$$" in template by:
    #   - Line 0: gets template's 2-space indent
    #   - Lines 1+: inserted as-is
    # So we need lines 1+ to have +2 indent to align under secrets:
    lines = yaml_fragment.split("\n")
    return lines.first if lines.length == 1

    # Add 2 spaces to all lines EXCEPT first (which gets template's indent)
    ([lines.first] + lines[1..].map { |l| "  #{l}" }).join("\n")
  end

  # Run the migration.
  #
  # @param parsed [Hash]              the full parsed config
  # @param source_conf [String]       name of the source conf (for reporting)
  # @param secret_key_paths [Array<String>] dot-separated paths to secret keys
  # @param new_conf_name [String]     name for the new conf
  # @param secret_ref_name [String]   name for the new secret ref
  # @param environment [String]
  # @param dest_service [String]      ISC service glob for the new conf
  # @param report_path [String, nil]  path to append report entry; nil = skip
  # @param update_secret_ref_name [String, nil]  if set, update this secret ref instead of creating new
  # @param skip_dedup [Boolean]       if true, create new secret ref even if matching value exists
  # @return [Hash] { new_conf_name:, secret_ref_used: }
  def self.run(parsed:, source_conf:, secret_key_paths:, new_conf_name:, secret_ref_name:,
               environment: DEFAULT_ENVIRONMENT, dest_service: DEFAULT_SERVICE,
               report_path: nil, update_secret_ref_name: nil, skip_dedup: false)
    puts "--- Auto-merge secrets migration (Option 2.5: secrets: key) ---"
    puts "  Source conf:       #{source_conf}"
    puts "  New conf:          #{new_conf_name}"
    puts "  Secret ref:        #{secret_ref_name}"
    puts "  Secret keys:       #{secret_key_paths.join(', ')}"
    puts "  Environment:       #{environment}"
    puts

    # Build template with secrets: $$secret$$ at root (excluding secret fields)
    template = build_template(parsed, secret_key_paths)
    puts "  Template:"
    puts template.gsub(/^/, "    ")
    puts

    # Build secret value with only secret fields (preserving parent structure)
    secret_value = build_secret_value(parsed, secret_key_paths)
    puts "  Secret ref value (with parent structure):"
    secret_key_paths.each do |path|
      # Show the full path to illustrate the parent structure
      puts "    #{path}: [REDACTED]"
    end
    puts

    # Create or update the secret ref
    if update_secret_ref_name
      puts "  Updating existing secret ref: #{update_secret_ref_name}"
      update_secret_ref(update_secret_ref_name, secret_value, environment: environment)
      actual_secret_ref = update_secret_ref_name
    else
      puts "  Creating secret ref..."
      actual_secret_ref = create_or_find_secret_ref(secret_ref_name, secret_value,
                                                     environment: environment, skip_dedup: skip_dedup)
    end
    puts

    # Create the conf with template
    puts "  Creating conf with template..."
    create_conf_with_template(new_conf_name, template, actual_secret_ref,
                               service: dest_service, environment: environment)
    puts "  Conf created."
    puts

    # Verify the new conf by reading it back
    puts "  Verifying new conf..."
    new_raw = read_conf(new_conf_name, service: dest_service, environment: environment)

    # The returned config should have the secrets: key populated with the secret ref value
    # After ISC substitution, it should match the original when deep_merge is applied
    new_parsed = YAML.safe_load(new_raw)

    # Show what we got after ISC substitution
    puts "  After ISC substitution:"
    puts "    Has 'secrets:' key: #{new_parsed.key?("secrets") || new_parsed.key?(:secrets)}"

    # Extract secrets: key (if present after substitution)
    if new_parsed.key?("secrets") || new_parsed.key?(:secrets)
      secrets_block = new_parsed.delete("secrets") || new_parsed.delete(:secrets)
      puts "    Secrets block type: #{secrets_block.class}"
      # Deep merge secrets into base
      if secrets_block.is_a?(Hash)
        new_parsed = deep_merge_hash(new_parsed, secrets_block)
        puts "    Deep merged secrets into base"
      end
    end

    # Check if they match
    matches = new_parsed == parsed

    unless matches
      puts
      puts "  ❌ VERIFICATION FAILED - Configs don't match after merge:"
      puts
      puts "  Expected (original):"
      puts "    " + parsed.inspect.lines.join("    ")
      puts
      puts "  Got (after merge):"
      puts "    " + new_parsed.inspect.lines.join("    ")
      puts
      puts "  Differences:"
      show_hash_diff(parsed, new_parsed, "  ")
      puts
    end

    all_pass = verify(
      "new conf matches original after merge" => matches,
    )
    raise IscError, "Verification failed for #{new_conf_name}" unless all_pass

    report_path && append_report(
      report_path: report_path,
      source_conf: source_conf,
      environment: environment,
      plan: "auto_merge_secrets",
      secret_keys: secret_key_paths,
      new_conf_name: new_conf_name,
      secret_ref_used: actual_secret_ref,
      orig_conf_status: "(pending)",
      orig_secret_status: "(pending)",
    )

    { new_conf_name: new_conf_name, secret_ref_used: actual_secret_ref }
  end
end

# ── Standalone execution ───────────────────────────────────────────────────────

if __FILE__ == $PROGRAM_NAME
  options = {
    environment: DEFAULT_ENVIRONMENT,
    dest_service: DEFAULT_SERVICE,
  }

  OptionParser.new do |opts|
    opts.banner = "Usage: ruby migrate_auto_merge_secrets.rb [options]"
    opts.on("--source-conf NAME", "Source conf name") { |v| options[:source_conf] = v }
    opts.on("--secret-keys KEYS", "Comma-separated secret key paths") { |v| options[:secret_keys] = v.split(",") }
    opts.on("--new-conf NAME", "New conf name") { |v| options[:new_conf] = v }
    opts.on("--secret-ref NAME", "Secret ref name") { |v| options[:secret_ref] = v }
    opts.on("--environment ENV", "Environment (default: #{DEFAULT_ENVIRONMENT})") { |v| options[:environment] = v }
    opts.on("--dest-service SVC", "Destination service (default: #{DEFAULT_SERVICE})") { |v| options[:dest_service] = v }
  end.parse!

  %i[source_conf secret_keys new_conf secret_ref].each do |key|
    abort "Missing required option: --#{key.to_s.tr('_', '-')}" unless options[key]
  end

  # Read and parse the source conf
  raw = read_conf(options[:source_conf], service: SOURCE_SERVICE, environment: options[:environment])
  parsed = YAML.safe_load(raw)

  result = MigrateAutoMergeSecrets.run(
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
