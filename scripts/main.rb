# frozen_string_literal: true

# Interactive ISC migration terminal UI.
#
# Mode 1 — Migrate Manually by Name:
#   Enter a conf name, all 3 environments are checked, pick which to migrate.
#
# Mode 2 — Migrate from Generated Config:
#   Pick a generated CSV from the Claude Skill, iterate through each row.
#
# Run with:  ruby tmp/3pi_isc_migration/scripts/main.rb

require_relative "common"
require_relative "migrate_single_value_template"
require_relative "migrate_multi_value_template"
require_relative "migrate_no_template"
require_relative "migrate_no_secret"
require "csv"

begin
  require "tty-prompt"
  require "tty-spinner"
  require "tty-table"
rescue LoadError
  abort "Missing gems: run `gem install tty-prompt tty-spinner tty-table` then retry."
end

$tty = TTY::Prompt.new(interrupt: :exit)

REPORT_PATH  = File.expand_path("../report.txt", __dir__)
ALL_ENVIRONMENTS = %w[production staging development].freeze

# Feature flag: enable permission checking for shared secret refs
# When enabled, prompts user if they lack 'link' permission to reuse existing secret ref
# DISABLED until ISC CLI bug is fixed (--show-my-perms currently returns null for principal_permissions)
# TODO: Enable this once ISC team fixes CLI to return ["link"] in principal_permissions array
ENABLE_PERMISSION_CHECK = false

# Session flag: if true, always skip deduplication when creating secret refs
$skip_dedup_for_session = false

# ── Helpers ────────────────────────────────────────────────────────────────────

def flatten_keys(obj, prefix = nil)
  return [] unless obj.is_a?(Hash)

  obj.flat_map do |k, v|
    full = prefix ? "#{prefix}.#{k}" : k.to_s
    v.is_a?(Hash) ? flatten_keys(v, full) : [full]
  end
end

def prompt(msg)
  print msg
  $stdout.flush
  gets&.chomp&.strip
end

# Run a block with a spinner, then print the result on success.
# Usage: loading("Looking up secret ref") { some_operation() }
def loading(label, &block)
  spinner = TTY::Spinner.new("[:spinner] #{label}...", format: :dots)
  spinner.auto_spin
  result = block.call
  spinner.success("(done)")
  result
end

def separator
  puts "-" * 70
end

# Fetch source + dest conf status for environments in parallel threads.
# Shows a single animated spinner while the threads run.
# Returns { env => { raw:, dest_raw:, dest_exists:, detail: } }
def parallel_env_fetch(conf_name, environments: ALL_ENVIRONMENTS)
  results = {}
  mutex   = Mutex.new

  spinner = TTY::Spinner.new("[:spinner] Checking all environments...", format: :dots)
  spinner.auto_spin

  threads = environments.map do |env|
    Thread.new do
      source_raw  = try_read_conf(conf_name, service: SOURCE_SERVICE, environment: env)
      dest_raw    = try_read_conf(conf_name, service: DEFAULT_SERVICE, environment: env)
      dest_exists = !dest_raw.nil?
      detail      = dest_raw ? migration_detail_label(conf_name, dest_raw: dest_raw, environment: env) : ""
      mutex.synchronize do
        results[env] = { raw: source_raw, dest_raw: dest_raw, dest_exists: dest_exists, detail: detail }
      end
    end
  end

  threads.each(&:join)
  spinner.success("(done)")

  results
end

def suggest_plan(secret_key_paths)
  return :no_secret if secret_key_paths.empty?
  return :single_value_template if secret_key_paths.length == 1

  parents = secret_key_paths.map { |p| p.split(".")[0..-2].join(".") }.uniq
  parents.length == 1 ? :multi_value_template : :no_template
end

def derive_new_conf_name(source_conf)
  base = source_conf.sub(%r{\Aenv/}, "")
  "env/#{base}"
end

def derive_secret_ref_name(source_conf, plan, secret_key: nil)
  base = source_conf.sub(%r{\Aenv/}, "")
  suffix =
    if plan == :single_value_template && secret_key
      secret_key.split(".").last.upcase
    elsif plan == :single_value_template
      "SECRET"
    else
      "SECRETS"
    end
  "#{base}_#{suffix}"
end

# Returns a detail label describing how an already-migrated dest conf is set up.
#
# Detection order:
#   1. Check find_conf metadata for a linked secretref field (tries several field names
#      since the ISC CLI JSON schema isn't guaranteed).
#   2. Fall back to looking up secret refs by our naming convention (_SECRET / _SECRETS).
#   3. If nothing found, inspect the conf content for secret-looking keys to judge
#      whether a template migration could still be applied.
def truncate_ref_name(ref_name, max_length: 10)
  return ref_name if ref_name.nil? || ref_name.length <= max_length
  "#{ref_name[0...max_length]}..."
end

def migration_detail_label(conf_name, dest_raw:, environment:)
  # Check if the config uses $$secret$$ template pattern
  # dest_raw can be a String, nil, or Symbol (:no_access)
  uses_template = dest_raw.is_a?(String) && dest_raw.include?("$$secret$$")

  dest_meta = find_conf(conf_name, service: DEFAULT_SERVICE, environment: environment)
  if dest_meta
    ref_name = dest_meta["secretref"] || dest_meta["secret_ref"] ||
               dest_meta["secretRefName"] || dest_meta["secret_ref_name"] ||
               dest_meta["secretref_name"]
    ref_name = nil if ref_name.to_s.strip.empty?

    if ref_name && uses_template
      return " [✅ MIGRATED: template with #{truncate_ref_name(ref_name)}]"
    elsif ref_name && !uses_template
      return " [⚠️  MONOLITHIC: linked to #{truncate_ref_name(ref_name)}]"
    end
  end

  # Naming-convention fallback: look for _SECRET / _SECRETS refs we would have created
  base = conf_name.sub(%r{\Aenv/}, "")
  named_ref = ["#{base}_SECRET", "#{base}_SECRETS"].find do |n|
    find_secret_ref(n, environment: environment)
  end

  if named_ref && uses_template
    return " [✅ MIGRATED: template with #{truncate_ref_name(named_ref)}]"
  elsif named_ref && !uses_template
    return " [⚠️  MONOLITHIC: linked to #{truncate_ref_name(named_ref)}]"
  end

  # No secret ref found — check content
  if uses_template
    return " [⚠️  TEMPLATE FOUND but no secret-ref link detected]"
  end

  # Plain YAML config (no template, no secret ref)
  dest_parsed = YAML.safe_load(dest_raw) rescue nil
  dest_keys   = dest_parsed ? flatten_keys(dest_parsed) : []
  secret_like = dest_keys.select { |k| k.split(".").last.downcase.match?(/secret|password|key|token|signature/) }
  secret_like.any? ? " [PLAIN YAML with secret-like keys]" : " [PLAIN YAML - no secrets]"
end

def try_read_conf(conf_name, service:, environment:)
  # First check if config exists in this specific service (search doesn't do cross-service fallback)
  conf_meta = find_conf(conf_name, service: service, environment: environment)
  return nil unless conf_meta

  # If it exists, read the full content
  raw = read_conf(conf_name, service: service, environment: environment)
  raw.strip.empty? ? nil : raw
rescue IscError => e
  # Distinguish between permission errors and actual errors
  if e.message.match?(/permission|You don't have the permission/i)
    :no_access
  else
    nil
  end
end

def find_source_secret_ref(source_conf, raw_conf_value:, environment:)
  ref = find_secret_ref(source_conf, environment: environment)
  return ref["name"] if ref

  bare = source_conf.sub(%r{\Aenv/}, "")
  ref = find_secret_ref(bare, environment: environment)
  return ref["name"] if ref

  ref = find_secret_ref_by_value(raw_conf_value, environment: environment)
  ref ? ref["name"] : nil
end

def write_report(source_conf:, environment:, status:, plan: nil, secret_keys: nil,
                 new_conf_name: nil, secret_ref_used: nil,
                 orig_conf_status: nil, orig_secret_status: nil, error: nil)
  File.open(REPORT_PATH, "a") do |f|
    f.puts "=== #{Time.now.strftime('%Y-%m-%d %H:%M:%S')} ==="
    f.puts "Status:                  #{status}"
    f.puts "Source conf:             #{source_conf}"
    f.puts "Environment:             #{environment}"
    f.puts "Migration plan:          #{plan || 'N/A'}"
    f.puts "Secret keys:             #{Array(secret_keys).join(', ')}" if secret_keys
    f.puts "New conf:                #{new_conf_name}" if new_conf_name
    f.puts "Secret ref used:         #{secret_ref_used}" if secret_ref_used
    f.puts "Original conf:           #{orig_conf_status}" if orig_conf_status
    f.puts "Original secret ref:     #{orig_secret_status}" if orig_secret_status
    f.puts "Error:                   #{error}" if error
    f.puts ""
  end
end


# ── Core migration for one conf in one environment ─────────────────────────────

# Returns :success, :skipped, or :failed
def migrate_one(conf_name, environment:, raw:, already_migrated:)
  # Safety check: ensure raw is a valid string (not :no_access or nil)
  if raw == :no_access
    puts "  ERROR: Cannot migrate - no access to config"
    return :failed
  end

  unless raw.is_a?(String)
    puts "  ERROR: Invalid config data (expected String, got #{raw.class})"
    return :failed
  end

  # Parse YAML with error handling
  begin
    parsed = YAML.safe_load(raw)
  rescue Psych::SyntaxError => e
    puts "  ERROR: Malformed YAML in config - #{e.message}"
    puts
    puts "  Raw YAML content:"
    puts "  " + ("-" * 70)
    raw.lines.each_with_index do |line, idx|
      puts "  #{(idx + 1).to_s.rjust(3)}: #{line}"
    end
    puts "  " + ("-" * 70)
    puts
    puts "  This config needs manual inspection/repair before migration."
    return :failed
  end

  # Fix SSH private key formatting (ensure proper newlines and structure)
  ssh_keys_found = []
  parsed.each do |k, v|
    check_for_ssh_keys(v, k, ssh_keys_found)
  end
  fix_ssh_keys_in_hash!(parsed)

  if ssh_keys_found.any?
    puts "  [SSH KEY] Detected and formatted private keys: #{ssh_keys_found.join(', ')}"
  end

  all_keys = flatten_keys(parsed)

  if all_keys.empty?
    puts "  Could not parse conf or no keys found. Skipping."
    return :skipped
  end

  puts
  if already_migrated
    puts "  NOTE: This conf already exists in #{DEFAULT_SERVICE} — you may be re-migrating."
  end

  # Pre-select likely secret keys for the multi-select defaults
  likely_secret_keys = all_keys.select { |k| k.split(".").last.downcase.match?(/secret|password|key|token|signature/) }
  suggested_plan     = likely_secret_keys.any? ? suggest_plan(likely_secret_keys) : :no_secret

  # Key choices for manual selection (no :full mixed in — kept as a separate strategy)
  key_choices  = []
  default_idxs = []
  all_keys.each_with_index do |k, i|
    is_likely = likely_secret_keys.include?(k)
    key_choices << { name: "#{k}#{is_likely ? '  *' : ''}", value: k }
    default_idxs << (i + 1) if is_likely  # 1-based
  end
  key_choices << { name: "← Back", value: :back }

  plan_label = ->(p) { p.to_s.tr("_", " ") }

  secret_key_paths, plan = loop do
    # ── Step 1: Strategy picker — shows suggested plan upfront ────────────
    strategy_choices = []
    if suggested_plan
      if suggested_plan == :no_secret
        strategy_choices << {
          name:  "No secret (plain YAML)  (suggested)",
          value: :suggested,
        }
      else
        keys_str = likely_secret_keys.join(", ")
        strategy_choices << {
          name:  "#{plan_label[suggested_plan]}  ←  #{keys_str}  (suggested)",
          value: :suggested,
        }
      end
    end
    strategy_choices << { name: "Select keys manually",                          value: :manual   }
    strategy_choices << { name: "Full no-template  (entire conf as secret ref)", value: :full     }
    strategy_choices << { name: "No secret (plain YAML)",                        value: :no_secret }
    strategy_choices << { name: "Skip this environment",                         value: :skip     }

    strategy = $tty.select("Plan:", strategy_choices, cycle: true)

    return :skipped                       if strategy == :skip
    break [all_keys, :no_template]        if strategy == :full
    break [[], :no_secret]                if strategy == :no_secret
    break [likely_secret_keys, suggested_plan] if strategy == :suggested

    # ── Step 2: Manual key selection ─────────────────────────────────────
    selected = $tty.multi_select(
      "Which keys contain secrets? (* = likely,  space = toggle,  enter = confirm)",
      key_choices,
      default: default_idxs,
      per_page: key_choices.length,
      echo: false,
    )

    next if selected.include?(:back)

    inner_paths = selected.reject { |v| v == :back }
    if inner_paths.empty?
      puts "  No keys selected — treating as no-secret migration."
      break [[], :no_secret]
    end

    break [inner_paths, suggest_plan(inner_paths)]
  end

  puts "  Plan: #{plan_label[plan]}"

  # Check if any selected secret values contain newlines (multiline secrets like SSH keys)
  # Single-value templates can't handle multiline values, so upgrade to multi-value template
  unless plan == :no_template || plan == :no_secret
    multiline_keys = secret_key_paths.select do |key_path|
      value = parsed.dig(*key_path.split("."))
      value.is_a?(String) && value.include?("\n")
    end

    if multiline_keys.any? && plan == :single_value_template
      puts
      puts "  ⚠ WARNING: Detected multiline secret values (e.g., SSH private keys):"
      multiline_keys.each { |k| puts "    - #{k}" }
      puts "  Single-value templates cannot handle multiline values properly."
      puts "  Upgrading to multi-value template for proper YAML formatting."
      puts
      plan = :multi_value_template
    end
  end

  new_conf_name = derive_new_conf_name(conf_name)
  puts "  New conf name: #{new_conf_name}"

  # For no_secret plan, skip all secret-related lookups
  if plan == :no_secret
    puts "  Note: Config will be stored as plain YAML (no secret ref)"
    puts
  else
    secret_value_to_store =
      case plan
      when :single_value_template then parsed.dig(*secret_key_paths.first.split(".")).to_s
      when :multi_value_template  then build_secret_block(parsed, secret_key_paths)
      when :no_template           then to_yaml_with_literal_blocks(parsed)
      end

    # reuse_secret_ref: an existing secret ref whose value exactly matches what we
    # want to store (safe to link the new conf to it directly).
    reuse_secret_ref = nil
    skip_dedup_this_config = $skip_dedup_for_session

    existing_ref_obj = nil
    loading("Looking up existing secret ref by value") do
      # Only fetch permissions if the feature is enabled
      existing_ref_obj = find_secret_ref_by_value(secret_value_to_store, environment: environment, show_my_perms: ENABLE_PERMISSION_CHECK)
    end

    if existing_ref_obj && !skip_dedup_this_config
      if ENABLE_PERMISSION_CHECK
        # Check if we have link permissions
        permission_status = check_secret_ref_link_permission(existing_ref_obj, environment: environment)

        case permission_status
        when :can_link
          reuse_secret_ref = existing_ref_obj["name"]
          puts "  Found existing secret ref: #{reuse_secret_ref} — will reuse"
        when :no_link_access
          # User lacks link permission - prompt for action
          puts
          puts "  ⚠️  Found existing secret ref with matching value: #{existing_ref_obj['name']}"
          puts "      However, you do not have 'link' permissions to use it."
          puts

          choice = $tty.select("What would you like to do?", cycle: true) do |menu|
            menu.choice "Skip this config (request access and re-migrate later)", :skip
            menu.choice "Override shared value detection (create new secret ref with same value)", :override_once
            menu.choice "Override for rest of session (auto-create for all future conflicts)", :override_all
          end

          case choice
          when :skip
            puts
            puts "  Skipping migration for #{conf_name} in #{environment}"
            puts "  Action needed: Request 'link' permission for #{existing_ref_obj['name']}"
            puts
            write_report(
              source_conf: conf_name, environment: environment, status: "PENDING",
              plan: plan, secret_keys: secret_key_paths,
              error: "No link permission for existing secret ref: #{existing_ref_obj['name']}. Request access and retry."
            )
            puts "  Status recorded in report: #{REPORT_PATH}"
            return :skipped
          when :override_once
            skip_dedup_this_config = true
            puts
            puts "  Will create new secret ref with shared_value_detection: false"
          when :override_all
            $skip_dedup_for_session = true
            skip_dedup_this_config = true
            puts
            puts "  Will create new secret ref with shared_value_detection: false"
            puts "  (This will apply to all future configs in this session)"
          end
        when :not_found
          # Shouldn't happen, but handle gracefully
          puts "  No existing secret ref found — will create new"
        end
      else
        # Permission checking disabled - use original behavior
        reuse_secret_ref = existing_ref_obj["name"]
        puts "  Found existing secret ref: #{reuse_secret_ref} — will reuse"
      end
    elsif $skip_dedup_for_session && existing_ref_obj
      # Session flag is set - skip dedup automatically
      puts "  Found existing secret ref but user has disabled shared value detection for session"
      puts "  Will create new secret ref with shared_value_detection: false"
    elsif !existing_ref_obj
      puts "  No existing secret ref found — will create new"
    end
    puts

    # cleanup_secret_ref: the old monolithic secret ref to potentially delete after
    # migration. Uses name-based lookup + full-YAML hash as fallbacks.
    cleanup_secret_ref = nil
    loading("Looking up original secret ref for cleanup") do
      cleanup_secret_ref = find_source_secret_ref(conf_name, raw_conf_value: raw,
                                                  environment: environment)
    end
    if cleanup_secret_ref
      puts "  Found original secret ref: #{cleanup_secret_ref}"
    else
      puts "  No original secret ref found"
    end
    puts
  end

  # When re-migrating an already-migrated conf, find the existing secret ref linked to
  # the dest conf and decide whether to update it in place (single-linked) or create a new one.
  update_secret_ref_name = nil
  if already_migrated && plan != :no_template
    loading("Checking existing dest secret ref") do
      derived_ref = derive_secret_ref_name(conf_name, plan, secret_key: secret_key_paths.first)
      existing_ref = find_secret_ref(derived_ref, environment: environment)
      if existing_ref
        linked = find_linked_confs_for_secret_ref(derived_ref, environment: environment)
        if linked.length <= 1
          update_secret_ref_name = derived_ref
          puts "  Found secret ref: #{derived_ref} (#{linked.length} linked — will update in place)"
        else
          puts "  Found secret ref: #{derived_ref} (#{linked.length} linked confs — will create new ref)"
        end
      else
        puts "  No existing secret ref found — will create new ref"
      end
    end
    puts
  end

  migration_result =
    begin
      case plan
      when :single_value_template
        secret_ref_name = reuse_secret_ref || derive_secret_ref_name(conf_name, plan, secret_key: secret_key_paths.first)
        MigrateSingleValueTemplate.run(
          parsed: parsed, source_conf: conf_name, secret_key_path: secret_key_paths.first,
          new_conf_name: new_conf_name, secret_ref_name: secret_ref_name,
          environment: environment, dest_service: DEFAULT_SERVICE, report_path: nil,
          update_secret_ref_name: update_secret_ref_name, skip_dedup: skip_dedup_this_config,
        )

      when :multi_value_template
        secret_ref_name = reuse_secret_ref || derive_secret_ref_name(conf_name, plan)
        MigrateMultiValueTemplate.run(
          parsed: parsed, source_conf: conf_name, secret_key_paths: secret_key_paths,
          new_conf_name: new_conf_name, secret_ref_name: secret_ref_name,
          environment: environment, dest_service: DEFAULT_SERVICE, report_path: nil,
          update_secret_ref_name: update_secret_ref_name, skip_dedup: skip_dedup_this_config,
        )

      when :no_template
        no_template_ref = reuse_secret_ref || cleanup_secret_ref
        unless no_template_ref
          # Conf has no existing secret ref (was stored as plain YAML) — create one
          # holding the full YAML so the new conf can be linked to it.
          # Use the parsed (and SSH-key-fixed) version converted back to YAML
          new_ref_name = derive_secret_ref_name(conf_name, :multi_value_template)
          puts "  No existing secret ref — creating: #{new_ref_name}"
          no_template_ref = create_or_find_secret_ref(new_ref_name, secret_value_to_store, environment: environment, skip_dedup: skip_dedup_this_config)
        end
        MigrateNoTemplate.run(
          source_conf: conf_name, source_secret_ref_name: no_template_ref,
          new_conf_name: new_conf_name, environment: environment,
          dest_service: DEFAULT_SERVICE, already_migrated: already_migrated, report_path: nil,
        )

      when :no_secret
        MigrateNoSecret.run(
          parsed: parsed, source_conf: conf_name,
          new_conf_name: new_conf_name, environment: environment,
          dest_service: DEFAULT_SERVICE, report_path: nil,
        )
      end
    rescue IscError => e
      puts
      puts "  MIGRATION FAILED: #{e.message}"
      write_report(
        source_conf: conf_name, environment: environment, status: "FAILED",
        plan: plan, secret_keys: secret_key_paths, error: e.message,
      )
      puts "  Failure recorded in report: #{REPORT_PATH}"
      return :failed
    end

  puts
  puts "  Migration succeeded."
  puts "    New conf:   #{migration_result[:new_conf_name]}"
  if plan == :no_secret
    puts "    Secret ref: (none - plain YAML)"
  else
    puts "    Secret ref: #{migration_result[:secret_ref_used]}"
  end
  puts

  source_still_exists = !try_read_conf(conf_name, service: SOURCE_SERVICE, environment: environment).nil?
  orig_conf_status =
    if source_still_exists
      puts "  Removing source conf from #{SOURCE_SERVICE}..."
      del_success, del_stderr = delete_conf(conf_name, service: SOURCE_SERVICE,
                                            environment: environment, ignore_secretref: true)
      if del_success
        puts "    Deleted: #{conf_name}"
        "deleted"
      else
        puts "    WARNING: Could not delete #{conf_name} — #{del_stderr.strip}"
        puts "             Delete manually when you have permission."
        "could not delete (permission denied)"
      end
    else
      puts "  Source conf already removed from #{SOURCE_SERVICE}."
      "already removed"
    end
  puts

  orig_secret_status =
    if plan == :no_secret
      # For no_secret migrations, look up the old secret ref now and try to clean it up
      loading("Looking up original secret ref for cleanup") do
        cleanup_secret_ref = find_source_secret_ref(conf_name, raw_conf_value: raw,
                                                    environment: environment)
      end
      if cleanup_secret_ref
        puts "  Found original secret ref: #{cleanup_secret_ref}"
        puts "  Attempting to clean up original secret ref: #{cleanup_secret_ref}..."
        status = try_cleanup_secret_ref(cleanup_secret_ref, environment: environment)
        puts "    Secret ref: #{status}"
        status
      else
        puts "  No original secret ref to clean up."
        "no existing secret ref found"
      end
    elsif cleanup_secret_ref && cleanup_secret_ref == migration_result[:secret_ref_used]
      # no_template reuses the original secret ref for the new conf — must not delete it
      puts "  Secret ref #{cleanup_secret_ref} preserved — now linked to new conf."
      "preserved (reused by new conf)"
    elsif cleanup_secret_ref
      puts "  Attempting to clean up original secret ref: #{cleanup_secret_ref}..."
      status = try_cleanup_secret_ref(cleanup_secret_ref, environment: environment)
      puts "    Secret ref: #{status}"
      status
    else
      puts "  No original secret ref to clean up."
      "no existing secret ref found"
    end
  puts

  write_report(
    source_conf: conf_name, environment: environment, status: "SUCCESS",
    plan: plan, secret_keys: secret_key_paths,
    new_conf_name: migration_result[:new_conf_name],
    secret_ref_used: migration_result[:secret_ref_used],
    orig_conf_status: orig_conf_status, orig_secret_status: orig_secret_status,
  )
  puts "  Report appended to: #{REPORT_PATH}"

  :success
end

# ── Mode 1: Manual by name ─────────────────────────────────────────────────────

def mode_manual
  loop do
    separator
    conf_name = prompt("Conf name (or 'back'): ")
    break if conf_name.nil? || conf_name.downcase == "back"
    next if conf_name.empty?

    conf_name = "env/#{conf_name}" unless conf_name.start_with?("env/")

    # Inner loop for refresh functionality
    selected_envs = loop do
      fetched = parallel_env_fetch(conf_name)
      puts

      env_status = {}
      available  = []
      table_rows = []

      ALL_ENVIRONMENTS.each_with_index do |env, i|
        d = fetched[env]
        has_access = d[:raw] && d[:raw] != :no_access

        # Build clearer source status label based on source and dest state
        if d[:raw] == :no_access
          source_status = "NO ACCESS"
        elsif has_access && d[:dest_exists]
          # Check dest detail to see if it's truly migrated or needs work
          if d[:detail].include?("✅ MIGRATED")
            source_status = "EXISTS (✅ already migrated)"
          elsif d[:detail].include?("⚠️  MONOLITHIC")
            source_status = "EXISTS (⚠️ needs re-migration)"
          elsif d[:detail].include?("PLAIN YAML")
            source_status = "EXISTS (migrated as plain YAML)"
          else
            source_status = "EXISTS (migration status unclear)"
          end
        elsif has_access && !d[:dest_exists]
          source_status = "EXISTS (ready to migrate)"
        elsif !d[:raw] && d[:dest_exists]
          source_status = "DELETED (complete)"
        else
          source_status = "NOT FOUND"
        end

        dest_status = d[:dest_exists] ? "EXISTS#{d[:detail]}" : "-"

        table_rows << [env.upcase, source_status, dest_status]
        env_status[env] = { raw: d[:raw], dest_exists: d[:dest_exists], dest_raw: d[:dest_raw] }
        # Allow selection if source exists OR dest exists (for re-migration/updates)
        # Note: :no_access does NOT count as available (can't migrate without access)
        has_readable_source = d[:raw] && d[:raw] != :no_access
        available << (i + 1).to_s if has_readable_source || d[:dest_exists]
      end

      table = TTY::Table.new(
        header: ["Environment", "Source Status", "Dest Status"],
        rows: table_rows
      )
      puts table.render(:unicode, padding: [0, 1], alignments: [:left, :left, :left])
      puts

      # Check if all environments have no access
      all_no_access = ALL_ENVIRONMENTS.all? { |env| env_status[env][:raw] == :no_access }
      if all_no_access
        puts "  Cannot migrate: no permission to read source config in any environment."
        puts "  Please request access via the ISC web UI at: https://isc.fernet.io"
        break nil
      end

      if available.empty?
        puts "  Conf not found in any environment (neither source nor dest)."
        break nil
      end

      available_envs = available.map { |n| ALL_ENVIRONMENTS[n.to_i - 1] }

      env_choices = available_envs.map { |e| { name: e, value: e } }
      env_choices << { name: "Refresh", value: :refresh }
      env_choices << { name: "Skip", value: :skip }

      picks = $tty.multi_select("  Which environments to migrate?", env_choices,
                                 default: (1..available_envs.length).to_a, cycle: true)

      # Skip takes precedence over Refresh
      if picks.include?(:skip)
        break nil
      end

      if picks.include?(:refresh)
        puts
        puts "  Refreshing..."
        puts
        next  # Re-fetch and redisplay
      end

      envs = picks.reject { |v| v == :skip || v == :refresh }
      break nil if envs.empty?

      # Store env_status for later use
      @env_status_cache = env_status
      break envs
    end

    next unless selected_envs
    env_status = @env_status_cache

    selected_envs.each do |environment|
      puts
      separator
      puts ">>> #{conf_name} — #{environment.upcase} <<<"
      separator
      s = env_status[environment]

      # Check for permission issues first
      if s[:raw] == :no_access
        puts "  ERROR: Cannot migrate - no permission to read source config in #{environment}"
        puts "  Please request access via the ISC web UI at: https://isc.fernet.io"
        next
      end

      # Use source raw if available, otherwise use dest raw for re-migration
      # Note: :no_access is truthy, so we need to explicitly check for it
      raw_to_use = (s[:raw] && s[:raw] != :no_access) ? s[:raw] : s[:dest_raw]

      unless raw_to_use && raw_to_use != :no_access
        puts "  ERROR: Cannot migrate - no source or dest config found for #{environment}"
        next
      end

      migrate_one(conf_name, environment: environment, raw: raw_to_use,
                  already_migrated: s[:dest_exists])
    end
  end
end

# ── Mode 2: Delete Secret Ref ──────────────────────────────────────────────────

def mode_delete_secret_ref
  loop do
    separator
    secret_ref_name = prompt("Secret ref name (or 'back'): ")
    break if secret_ref_name.nil? || secret_ref_name.downcase == "back"
    next if secret_ref_name.empty?

    spinner = TTY::Spinner.new("[:spinner] Checking secret ref in all environments...", format: :dots)
    spinner.auto_spin

    found_in = []
    env_details = {}

    ALL_ENVIRONMENTS.each do |env|
      ref = find_secret_ref(secret_ref_name, environment: env)
      if ref
        # SAFETY: Verify exact name match (not substring)
        if ref["name"] == secret_ref_name
          found_in << env
          linked_confs = find_linked_confs_for_secret_ref(secret_ref_name, environment: env)
          env_details[env] = { ref: ref, linked_confs: linked_confs }
        else
          puts "  ⚠️  WARNING: ISC returned '#{ref['name']}' but expected exact match '#{secret_ref_name}'"
        end
      end
    end

    spinner.success("(done)")
    puts

    if found_in.empty?
      puts "  Secret ref '#{secret_ref_name}' not found in any environment (exact match)."
      puts
      next
    end

    # Display findings and check for issues
    puts "✓ Found secret ref: '#{secret_ref_name}'"
    puts

    safe_to_delete = []
    blocked_by_links = {}
    table_rows = []

    found_in.each do |env|
      details = env_details[env]
      ref_name = details[:ref]["name"]
      linked_count = details[:linked_confs].length

      # Check for linked configs
      if linked_count > 0
        status = "🚫 BLOCKED"
        linked_info = "#{linked_count} configs"
        linked_list = details[:linked_confs].map { |c| "#{c['key'] || c['file']} (#{c['service']})" }.join(", ")
        blocked_by_links[env] = linked_list

        table_rows << [env.upcase, "EXISTS", status, linked_info]

        # Show detailed linked configs below table
      else
        status = "✅ Safe"
        linked_info = "none"
        safe_to_delete << env
        table_rows << [env.upcase, "EXISTS", status, linked_info]
      end
    end

    table = TTY::Table.new(
      header: ["Environment", "Secret Ref", "Status", "Linked Configs"],
      rows: table_rows
    )
    puts table.render(:unicode, padding: [0, 1], alignments: [:left, :left, :left, :left])
    puts

    # Show detailed linked configs for blocked environments
    blocked_by_links.each do |env, _|
      details = env_details[env]
      if details[:linked_confs].any?
        puts "  #{env.upcase} linked configs:"
        details[:linked_confs].each do |conf|
          conf_name = conf["key"] || conf["file"] || conf.to_s
          service = conf["service"] || "unknown service"
          puts "    • #{conf_name} (#{service})"
        end
        puts
      end
    end

    # If nothing is safe to delete, exit
    if safe_to_delete.empty?
      if blocked_by_links.any?
        puts "  ⚠️  Cannot delete: All environments have linked configs."
        puts "  Please unlink or migrate the configs first."
      else
        puts "  ⚠️  No environments are available for deletion."
      end
      puts
      next
    end

    # Environment selection - only allow safe environments
    env_choices = safe_to_delete.map { |e| { name: e, value: e } }
    env_choices << { name: "Cancel", value: :cancel }

    selected_envs = $tty.multi_select(
      "Which environments to delete from? (only safe environments shown)",
      env_choices,
      cycle: true
    )

    next if selected_envs.include?(:cancel) || selected_envs.empty?

    # Confirmation
    puts
    puts "  ⚠️  You are about to delete secret ref: #{secret_ref_name}"
    puts "  Environments: #{selected_envs.join(', ')}"
    puts

    confirm = $tty.select("Are you sure?", cycle: true) do |menu|
      menu.choice "Yes, delete it", true
      menu.choice "No, cancel", false
    end

    next unless confirm

    # Delete from each environment
    puts
    deletion_results = []

    selected_envs.each do |env|
      # SAFETY: Final verification that we're deleting the exact name
      ref_to_delete = find_secret_ref(secret_ref_name, environment: env)
      if !ref_to_delete || ref_to_delete["name"] != secret_ref_name
        deletion_results << {
          env: env,
          status: "❌ SAFETY CHECK FAILED",
          message: "Name mismatch: expected '#{secret_ref_name}', found '#{ref_to_delete ? ref_to_delete['name'] : 'nil'}'"
        }

        # Log safety check failure
        File.open(REPORT_PATH, "a") do |f|
          f.puts "=== Secret Ref Deletion: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')} ==="
          f.puts "Status:                  SAFETY CHECK FAILED"
          f.puts "Secret ref name:         #{secret_ref_name}"
          f.puts "Environment:             #{env}"
          f.puts "Action:                  Blocked - name mismatch"
          f.puts "Expected:                #{secret_ref_name}"
          f.puts "Found:                   #{ref_to_delete ? ref_to_delete['name'] : 'nil'}"
          f.puts ""
        end
        next
      end

      spinner = TTY::Spinner.new("[:spinner] Deleting from #{env}...", format: :dots)
      spinner.auto_spin
      success, stderr = delete_secret_ref(secret_ref_name, environment: env)

      if success
        spinner.success("(deleted)")
        deletion_results << {
          env: env,
          status: "✅ Success",
          message: "Deleted"
        }

        # Log success to report
        File.open(REPORT_PATH, "a") do |f|
          f.puts "=== Secret Ref Deletion: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')} ==="
          f.puts "Status:                  SUCCESS"
          f.puts "Secret ref name:         #{secret_ref_name}"
          f.puts "Environment:             #{env}"
          f.puts "Action:                  Deleted"
          f.puts ""
        end
      else
        spinner.error("(failed)")
        deletion_results << {
          env: env,
          status: "❌ Failed",
          message: stderr.strip
        }

        # Log failure to report
        File.open(REPORT_PATH, "a") do |f|
          f.puts "=== Secret Ref Deletion: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')} ==="
          f.puts "Status:                  FAILED"
          f.puts "Secret ref name:         #{secret_ref_name}"
          f.puts "Environment:             #{env}"
          f.puts "Action:                  Attempted deletion"
          f.puts "Error:                   #{stderr.strip}"
          f.puts ""
        end
      end
    end

    puts
    puts "Deletion Summary:"
    puts

    result_table_rows = deletion_results.map { |r| [r[:env].upcase, r[:status], r[:message]] }
    result_table = TTY::Table.new(
      header: ["Environment", "Result", "Details"],
      rows: result_table_rows
    )
    puts result_table.render(:unicode, padding: [0, 1], alignments: [:left, :left, :left])
    puts
  end
end

# ── Mode 3: Migrate from Generated Config ──────────────────────────────────

AUTOMATED_CONFIGS_DIR = File.expand_path("../automated-migration-configs", __dir__)

def mode_by_generated_config
  loop do
    separator
    # Find all CSV files
    csv_files = Dir[File.join(AUTOMATED_CONFIGS_DIR, "*.csv")].sort_by { |f| File.mtime(f) }.reverse

    if csv_files.empty?
      puts "No generated config files found in #{AUTOMATED_CONFIGS_DIR}/"
      puts "Use the isc-migration skill to generate a config CSV first."
      puts
      break
    end

    # Build menu choices with metadata
    choices = csv_files.map do |path|
      filename = File.basename(path)
      created = File.birthtime(path).strftime('%Y-%m-%d %H:%M')
      updated = File.mtime(path).strftime('%Y-%m-%d %H:%M')
      {
        name: "#{filename} (Created: #{created}, Updated: #{updated})",
        value: path,
      }
    end
    choices << { name: "Back", value: :back }

    selected_csv = $tty.select("Select migration config:", choices, cycle: true)
    break if selected_csv == :back

    puts
    puts "=" * 70
    puts "  Migrating from: #{File.basename(selected_csv)}"

    # Extract patterns from CSV metadata (header comments)
    source_pattern, dest_pattern = extract_patterns_from_csv(selected_csv)

    if source_pattern.nil? || dest_pattern.nil?
      puts "ERROR: Could not extract patterns from CSV metadata."
      puts "Expected header comments:"
      puts "  # OLD_PATTERN: ..."
      puts "  # NEW_PATTERN: ..."
      puts
      next
    end

    puts "  Source:  #{source_pattern}"
    puts "  Dest:    #{dest_pattern}"
    puts "=" * 70
    puts

    # Temporarily override patterns for this migration session
    original_source = SOURCE_SERVICE
    original_dest = DEFAULT_SERVICE

    begin
      silence_warnings do
        Object.const_set(:SOURCE_SERVICE, source_pattern)
        Object.const_set(:DEFAULT_SERVICE, dest_pattern)
      end

      # Run migration flow (same as mode_by_service but with this CSV)
      migrate_from_generated_csv(selected_csv, source_pattern, dest_pattern)

    ensure
      # Restore original patterns
      silence_warnings do
        Object.const_set(:SOURCE_SERVICE, original_source)
        Object.const_set(:DEFAULT_SERVICE, original_dest)
      end
    end

    puts
    puts "=" * 70
    puts "  Configuration Migration has been completed!"
    puts "=" * 70
    puts
  end
end

def silence_warnings
  original_verbosity = $VERBOSE
  $VERBOSE = nil
  yield
ensure
  $VERBOSE = original_verbosity
end

def extract_patterns_from_csv(csv_path)
  source_pattern = nil
  dest_pattern = nil

  File.open(csv_path, "r") do |file|
    file.each_line do |line|
      break unless line.start_with?("#")

      if line.match(/^# OLD_PATTERN: (.+)$/)
        source_pattern = $1.strip
      elsif line.match(/^# NEW_PATTERN: (.+)$/)
        dest_pattern = $1.strip
      end
    end
  end

  [source_pattern, dest_pattern]
end

def migrate_from_generated_csv(csv_path, source_pattern, dest_pattern)
  table = CSV.read(csv_path, headers: true, skip_lines: /^#/)

  # Extract environments from CSV headers (e.g., "Production Old Pattern" -> "production")
  csv_environments = table.headers
    .select { |h| h&.end_with?(" Old Pattern") }
    .map { |h| h.sub(" Old Pattern", "").downcase }

  if csv_environments.empty?
    puts "ERROR: Could not detect environments from CSV headers."
    puts "Expected columns like: 'Production Old Pattern', 'Staging Old Pattern', etc."
    return
  end

  # Filter out comment lines (extra safety in case CSV row has # in Config Name field)
  conf_rows = table.select { |row| row["Config Name"]&.strip&.then { |n| !n.empty? && !n.start_with?("#") } }
  total = conf_rows.length

  # ── Start position prompt ──────────────────────────────────────────────
  start_idx = 0
  start_from = $tty.select("  Start from:", cycle: true) do |menu|
    menu.choice "Beginning", :beginning
    menu.choice "Specific config", :specific
  end

  if start_from == :specific
    if conf_rows.empty?
      puts "  No configs found in CSV. Starting from beginning."
      start_idx = 0
    else
      config_choices = conf_rows.each_with_index.map do |row, i|
        { name: "#{i + 1}. #{row['Config Name']&.strip}", value: i }
      end
      start_idx = $tty.select("  Start from config:", config_choices, per_page: 15, cycle: true, filter: true)
      puts "  Starting from: #{conf_rows[start_idx]['Config Name']&.strip}"
    end
  end
  puts

  conf_rows.each_with_index do |row, row_idx|
    next if row_idx < start_idx
    conf_name = row["Config Name"]&.strip
    next unless conf_name && !conf_name.empty?

    separator
    puts "Config #{row_idx + 1}/#{total}: #{conf_name}"
    puts "[#{row_idx + 1 - start_idx} of #{total - start_idx} remaining]"
    puts

    # Live-check environments in parallel — CSV can be stale
    # Inner loop for refresh functionality
    selected_envs = loop do
      env_data = {}
      fetched  = parallel_env_fetch(conf_name, environments: csv_environments)
      puts

      table_rows = []

      csv_environments.each do |env|
        d          = fetched[env]
        raw        = d[:raw]
        dest_exists = d[:dest_exists]
        has_access = raw && raw != :no_access

        # Build clearer source status label
        if raw == :no_access
          source_status = "NO ACCESS"
        elsif has_access && dest_exists
          source_status = "EXISTS (migrated)"
        elsif has_access && !dest_exists
          source_status = "EXISTS (ready)"
        elsif !raw && dest_exists
          source_status = "DELETED (complete)"
        else
          source_status = "NOT FOUND"
        end

        dest_status = dest_exists ? "EXISTS" : "-"

        # Determine status from CSV
        csv_old = row["#{env.capitalize} Old Pattern"]&.strip
        csv_new = row["#{env.capitalize} New Pattern"]&.strip
        csv_migrated = row["#{env.capitalize} Migrated"]&.strip

        status_note = ""
        if raw == :no_access
          status_note = " [NO PERM]"
        elsif !raw
          status_note = ""
        elsif csv_migrated == "Yes" && dest_exists
          status_note = d[:detail]
        elsif csv_migrated == "Yes" && !dest_exists
          status_note = " [CSV ≠ actual]"
        elsif csv_migrated == "No"
          status_note = " [PENDING]"
        end

        table_rows << [env.upcase, source_status, dest_status, status_note]
        env_data[env] = { raw: raw, dest_raw: d[:dest_raw], dest_exists: dest_exists }
      end

      table = TTY::Table.new(
        header: ["Environment", "Source", "Dest", "Status"],
        rows: table_rows
      )
      puts table.render(:unicode, padding: [0, 1], alignments: [:left, :left, :left, :left])
      puts

      # Check if all environments have no access
      all_no_access = csv_environments.all? { |env| env_data[env][:raw] == :no_access }
      if all_no_access
        puts "  Cannot migrate: no permission to read source config in any environment."
        puts "  Please request access via the ISC web UI at: https://isc.fernet.io"
        break nil
      end

      # Filter to environments where we have readable source OR dest exists (allows re-migration)
      # Note: :no_access does NOT count as migratable (can't migrate without access)
      migratable = csv_environments.select do |env|
        has_readable_source = env_data[env][:raw] && env_data[env][:raw] != :no_access
        has_readable_source || env_data[env][:dest_exists]
      end

      if migratable.empty?
        puts "  No environments reachable (neither source nor dest). Skipping."
        break nil
      end

      # ── Environment selection for this config ──────────────────────────
      env_choices = migratable.map { |env| { name: env, value: env } }
      env_choices << { name: "Refresh", value: :refresh }
      env_choices << { name: "Skip this config", value: :skip }

      picks = $tty.multi_select("  Which environments to migrate?", env_choices,
                                 default: (1..migratable.length).to_a, cycle: true)

      # Skip takes precedence over Refresh
      if picks.include?(:skip)
        puts "  Skipping #{conf_name}."
        break nil
      end

      if picks.include?(:refresh)
        puts
        puts "  Refreshing..."
        puts
        next  # Re-fetch and redisplay
      end

      envs = picks.reject { |v| v == :skip || v == :refresh }
      break nil if envs.empty?

      # Store env_data for later use
      @env_data_cache = env_data
      break envs
    end

    next unless selected_envs
    env_data = @env_data_cache

    # ── Migrate each selected environment ───────────────────────────────
    selected_envs.each do |environment|
      puts
      separator
      puts ">>> #{conf_name} — #{environment.upcase} <<<"
      separator

      d = env_data[environment]

      # Check for permission issues first
      if d[:raw] == :no_access
        puts "  ERROR: Cannot migrate - no permission to read source config in #{environment}"
        puts "  Please request access via the ISC web UI at: https://isc.fernet.io"
        next
      end

      # Use source raw if available, otherwise use dest raw for re-migration
      # Note: :no_access is truthy, so we need to explicitly check for it
      raw_to_use = (d[:raw] && d[:raw] != :no_access) ? d[:raw] : d[:dest_raw]

      unless raw_to_use && raw_to_use != :no_access
        puts "  ERROR: Cannot migrate - no source or dest config found for #{environment}"
        next
      end

      result = migrate_one(conf_name, environment: environment, raw: raw_to_use,
                           already_migrated: d[:dest_exists])

      if result == :success
        # Update the generated CSV
        update_generated_csv!(csv_path, conf_name, environment)
        puts "  CSV updated: #{conf_name} — #{environment} → Yes"
      end
    end
  end
end

def update_generated_csv!(csv_path, conf_name, environment)
  table = CSV.read(csv_path, headers: true, skip_lines: /^#/)

  # Find the row and update the Migrated column for this environment
  table.each do |row|
    if row["Config Name"]&.strip == conf_name
      migrated_col = "#{environment.capitalize} Migrated"
      row[migrated_col] = "Yes" if table.headers.include?(migrated_col)
    end
  end

  # Write back preserving header comments
  comments = []
  File.open(csv_path, "r") do |file|
    file.each_line do |line|
      break unless line.start_with?("#")
      comments << line.chomp
    end
  end

  CSV.open(csv_path, "w") do |csv|
    comments.each { |comment| csv << [comment] }
    csv << table.headers
    table.each { |row| csv << row }
  end
end

# ── Entry point ────────────────────────────────────────────────────────────────

puts "=" * 70
puts "  ISC 3PI Migration Tool"
puts "  Source:  #{SOURCE_SERVICE}"
puts "  Dest:    #{DEFAULT_SERVICE}"
puts "  Report:  #{REPORT_PATH}"
puts "=" * 70
puts

loop do
  choice = $tty.select("Mode:", cycle: true) do |menu|
    menu.choice "Migrate Manually by Name",           :manual
    menu.choice "Migrate from Generated Config",      :generated
    menu.choice "Delete Secret Ref",                  :delete_secret_ref
    menu.choice "Exit",                               :exit
  end

  break if choice == :exit
  puts

  case choice
  when :manual            then mode_manual
  when :generated         then mode_by_generated_config
  when :delete_secret_ref then mode_delete_secret_ref
  end

  puts
end

puts
puts "Done. Goodbye."
