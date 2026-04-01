# frozen_string_literal: true

# Parallel ISC config scanner for migration planning.
#
# Fetches all configs matching prefixes from old pattern, checks if they exist
# in new pattern, and generates a CSV for migration tracking.
#
# Usage:
#   ruby scripts/fetch_configs_parallel.rb \
#     --old-pattern "rpc.integrations.integrations" \
#     --new-pattern "*.integrations.integrations" \
#     --environments production,staging,development \
#     --prefixes OFFERS_V1,LOYALTY_CARD_V1 \
#     --output automated-migration-configs/migration_20260331115530.csv

require_relative "common"
require "csv"
require "optparse"
require "set"

options = {
  environments: [],
  prefixes: [],
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby fetch_configs_parallel.rb [options]"
  opts.on("--old-pattern PATTERN", "Source ISC service pattern") { |v| options[:old_pattern] = v }
  opts.on("--new-pattern PATTERN", "Destination ISC service pattern") { |v| options[:new_pattern] = v }
  opts.on("--environments ENV1,ENV2", Array, "Environments (comma-separated)") { |v| options[:environments] = v }
  opts.on("--prefixes PREFIX1,PREFIX2", Array, "Config name prefixes (comma-separated)") { |v| options[:prefixes] = v }
  opts.on("--output PATH", "Output CSV path") { |v| options[:output] = v }
end.parse!

%i[old_pattern new_pattern environments prefixes output].each do |key|
  abort "Missing required option: --#{key.to_s.tr('_', '-')}" unless options[key] && !options[key].empty?
end

OLD_PATTERN = options[:old_pattern]
NEW_PATTERN = options[:new_pattern]
ENVIRONMENTS = options[:environments]
PREFIXES = options[:prefixes]
OUTPUT_PATH = options[:output]

puts "=" * 70
puts "ISC Config Migration Scanner"
puts "=" * 70
puts "Source Pattern:      #{OLD_PATTERN}"
puts "Destination Pattern: #{NEW_PATTERN}"
puts "Environments:        #{ENVIRONMENTS.join(', ')}"
puts "Config Prefixes:     #{PREFIXES.join(', ')}"
puts "Output:              #{OUTPUT_PATH}"
puts "=" * 70
puts

# ── Helper Functions ────────────────────────────────────────────────────────

# Fetch all configs matching prefix in a given pattern + environment
def fetch_configs_for_prefix(prefix, pattern, environment)
  # Special case: "ALL" means search for any config starting with "env/"
  search_key = prefix.upcase == "ALL" ? "env/" : "env/#{prefix}"
  stdout, success = isc("isc", "conf", "-e", environment, pattern, "search", "-k", search_key, "--as-json")
  return [] unless success

  begin
    results = JSON.parse(stdout)
    return [] unless results.is_a?(Array)
    results.map { |c| c["key"] || c["file"] }.compact.uniq
  rescue JSON::ParserError
    []
  end
end

# Check if a specific config exists in a pattern + environment
def config_exists?(config_name, pattern, environment)
  stdout, success = isc("isc", "conf", "-e", environment, pattern, "search", "-k", config_name, "--as-json")
  return false unless success

  begin
    results = JSON.parse(stdout)
    return false unless results.is_a?(Array)
    results.any? { |c| (c["key"] || c["file"]) == config_name }
  rescue JSON::ParserError
    false
  end
end

# ── Main Execution ──────────────────────────────────────────────────────────

puts "Phase 1: Discovering configs from source pattern..."
puts

# Discover all unique configs from old pattern
all_configs = Set.new
results = {}
mutex = Mutex.new
stats = { total_fetches: 0, total_found: 0 }

threads = []
PREFIXES.each do |prefix|
  ENVIRONMENTS.each do |env|
    threads << Thread.new do
      print "  Fetching #{prefix} in #{env}..."
      $stdout.flush
      configs = fetch_configs_for_prefix(prefix, OLD_PATTERN, env)
      mutex.synchronize do
        configs.each do |config_name|
          all_configs.add(config_name)
          results[config_name] ||= {}
          results[config_name][env] ||= { old: false, new: false }
          results[config_name][env][:old] = true
        end
        stats[:total_fetches] += 1
        stats[:total_found] += configs.length
      end
      puts " found #{configs.length}"
    end
  end
end

threads.each(&:join)
puts
puts "  Total unique configs found: #{all_configs.size}"
puts

if all_configs.empty?
  puts "No configs found. Exiting."
  exit 0
end

puts "Phase 2: Checking configs in destination pattern..."
puts

# Check each config in new pattern for each environment
check_threads = []
all_configs.each do |config_name|
  ENVIRONMENTS.each do |env|
    check_threads << Thread.new do
      exists = config_exists?(config_name, NEW_PATTERN, env)
      mutex.synchronize do
        results[config_name][env] ||= { old: false, new: false }
        results[config_name][env][:new] = exists
      end
      print "."
      $stdout.flush
    end
  end
end

check_threads.each(&:join)
puts
puts "  Destination pattern check complete."
puts

# ── CSV Generation ──────────────────────────────────────────────────────────

puts "Phase 3: Generating CSV..."
puts

# Ensure output directory exists
require "fileutils"
FileUtils.mkdir_p(File.dirname(OUTPUT_PATH))

# Write metadata comment lines directly (not as CSV rows to avoid quote escaping)
File.open(OUTPUT_PATH, "w") do |file|
  file.puts "# OLD_PATTERN: #{OLD_PATTERN}"
  file.puts "# NEW_PATTERN: #{NEW_PATTERN}"
  file.puts "# GENERATED: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
  file.puts "# PREFIXES: #{PREFIXES.join(', ')}"
end

# Append CSV data
CSV.open(OUTPUT_PATH, "a") do |csv|
  # Build header
  header = ["Config Name"]
  ENVIRONMENTS.each do |env|
    header << "#{env.capitalize} Old Pattern"
    header << "#{env.capitalize} New Pattern"
    header << "#{env.capitalize} Migrated"
  end
  csv << header

  # Write rows (sorted by config name)
  all_configs.sort.each do |config_name|
    row = [config_name]
    ENVIRONMENTS.each do |env|
      old_exists = results.dig(config_name, env, :old) || false
      new_exists = results.dig(config_name, env, :new) || false

      row << (old_exists ? "Yes" : "No")
      row << (new_exists ? "Yes" : "No")

      # Migrated status: Yes if in new, No if only in old, N/A if not in old
      if !old_exists
        row << "N/A"
      elsif new_exists
        row << "Yes"
      else
        row << "No"
      end
    end
    csv << row
  end
end

puts "  CSV written to: #{OUTPUT_PATH}"
puts

# ── Summary Statistics ──────────────────────────────────────────────────────

puts "=" * 70
puts "Migration Scan Complete"
puts "=" * 70
puts
puts "Source Pattern:      #{OLD_PATTERN}"
puts "Destination Pattern: #{NEW_PATTERN}"
puts "Environments:        #{ENVIRONMENTS.join(', ')}"
puts "Config Prefixes:     #{PREFIXES.join(', ')}"
puts
puts "Summary by Environment:"
ENVIRONMENTS.each do |env|
  old_count = results.values.count { |r| r.dig(env, :old) }
  new_count = results.values.count { |r| r.dig(env, :new) }
  pending_count = results.values.count { |r| r.dig(env, :old) && !r.dig(env, :new) }

  puts "  #{env.capitalize}:"
  puts "    - Total configs in old pattern: #{old_count}"
  puts "    - Already in new pattern: #{new_count}"
  puts "    - Pending migration: #{pending_count}"
  puts
end

# Overall stats
fully_migrated = all_configs.count do |config_name|
  ENVIRONMENTS.all? { |env| results.dig(config_name, env, :new) }
end
partially_migrated = all_configs.count do |config_name|
  ENVIRONMENTS.any? { |env| results.dig(config_name, env, :new) } &&
    ENVIRONMENTS.any? { |env| results.dig(config_name, env, :old) && !results.dig(config_name, env, :new) }
end
not_started = all_configs.count do |config_name|
  ENVIRONMENTS.all? { |env| !results.dig(config_name, env, :new) } &&
    ENVIRONMENTS.any? { |env| results.dig(config_name, env, :old) }
end

puts "Overall:"
puts "  - Total unique configs: #{all_configs.size}"
puts "  - Fully migrated (all envs): #{fully_migrated}"
puts "  - Partially migrated: #{partially_migrated}"
puts "  - Not started: #{not_started}"
puts
puts "CSV saved to: #{OUTPUT_PATH}"
puts
puts "=" * 70
puts "Next Steps"
puts "=" * 70
puts "Run the migration tool and select 'Migrate from Generated Config':"
puts "  ruby tmp/3pi_isc_migration/scripts/main.rb"
puts "=" * 70
