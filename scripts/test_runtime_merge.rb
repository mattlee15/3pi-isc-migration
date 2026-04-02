#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script to simulate configurations/base.rb settings method behavior.
# This mimics the auto-merge logic from the PR to verify configs work at runtime.
#
# Usage:
#   ruby scripts/test_runtime_merge.rb

require_relative "common"
require "yaml"

# Try to load Rails for exact deep_merge/deep_symbolize_keys behavior
CARROT_PATH = File.expand_path("~/carrot")
if File.exist?("#{CARROT_PATH}/config/environment.rb")
  puts "Loading Rails environment from #{CARROT_PATH}..."
  ENV["RAILS_ENV"] ||= "development"
  require "#{CARROT_PATH}/config/environment"
  puts "✓ Rails loaded (using ActiveSupport methods)"
  puts
else
  puts "Rails not found at #{CARROT_PATH}, using minimal Hash extensions"
  puts
end

def prompt(msg)
  print msg
  $stdout.flush
  gets&.chomp&.strip
end

# Simulate the settings method from configurations/base.rb (lines 39-66)
# Matches the exact logic from the PR: https://github.com/instacart/carrot/pull/763917
def simulate_settings(raw_yaml)
  settings = YAML.safe_load(raw_yaml)

  unless settings.is_a?(Hash)
    puts "ERROR: Config is not a hash"
    return nil
  end

  # Extract and validate secrets key if present (lines 52-57)
  if settings.key?("secrets") || settings.key?(:secrets)
    secrets = settings.delete("secrets") || settings.delete(:secrets)

    unless secrets.is_a?(Hash)
      puts "ERROR: secrets: key is not a hash"
      return nil
    end

    puts "  Found secrets: key with #{secrets.keys.length} top-level key(s)"
    settings = settings.deep_merge(secrets) if secrets.present?
    puts "  Deep merged secrets into base config"
  else
    puts "  No secrets: key found (plain config)"
  end

  # Deep symbolize keys (line 59)
  settings.deep_symbolize_keys
rescue Psych::Exception => e
  puts "ERROR: YAML parsing failed: #{e.message}"
  nil
end

# Minimal Hash extensions if Rails isn't loaded
unless {}.respond_to?(:deep_merge)
  class Hash
    def deep_merge(other_hash)
      merge(other_hash) do |_key, this_val, other_val|
        if this_val.is_a?(Hash) && other_val.is_a?(Hash)
          this_val.deep_merge(other_val)
        else
          other_val
        end
      end
    end

    def deep_symbolize_keys
      each_with_object({}) do |(k, v), h|
        h[k.to_sym] = v.is_a?(Hash) ? v.deep_symbolize_keys : v
      end
    end

    def present?
      !empty?
    end
  end
end

# Show the nested structure of a hash
def show_structure(hash, indent = 0)
  return unless hash.is_a?(Hash)

  hash.each do |key, value|
    if value.is_a?(Hash)
      puts "#{"  " * indent}#{key}:"
      show_structure(value, indent + 1)
    else
      value_preview = value.to_s.length > 50 ? "#{value.to_s[0..47]}..." : value.to_s
      puts "#{"  " * indent}#{key}: #{value_preview}"
    end
  end
end

puts "=" * 70
puts "  Runtime Merge Test (simulates configurations/base.rb)"
puts "=" * 70
puts

loop do
  puts
  conf_name = prompt("Config name (or 'quit'): ")
  break if conf_name.nil? || conf_name.downcase == "quit"
  next if conf_name.empty?

  conf_name = "env/#{conf_name}" unless conf_name.start_with?("env/")

  service = prompt("Service pattern (default: *.integrations.integrations): ")
  service = "*.integrations.integrations" if service.empty?

  environment = prompt("Environment (default: staging): ")
  environment = "staging" if environment.empty?

  puts
  puts "Fetching #{conf_name} from #{service} (#{environment})..."

  begin
    raw_yaml = read_conf(conf_name, service: service, environment: environment)
    puts "✓ Fetched successfully"
    puts

    # Show raw config
    puts "Raw config (after ISC substitution):"
    puts "-" * 70
    puts raw_yaml
    puts "-" * 70
    puts

    # Simulate runtime processing
    puts "Simulating runtime merge..."
    settings = simulate_settings(raw_yaml)

    if settings
      puts
      puts "Final settings structure (symbolized keys):"
      puts "-" * 70
      show_structure(settings)
      puts "-" * 70
      puts

      # Interactive dig testing
      loop do
        puts
        path = prompt("Test dig path (e.g., 'ncr.lms.password', or 'back'): ")
        break if path.nil? || path.downcase == "back"
        next if path.empty?

        keys = path.split(".").map(&:to_sym)
        result = settings.dig(*keys)

        if result.nil?
          puts "  Result: nil (path not found)"
        else
          result_preview = result.to_s.length > 100 ? "#{result.to_s[0..97]}..." : result.to_s
          puts "  Result: #{result_preview}"
          puts "  Type: #{result.class}"
        end
      end
    end
  rescue IscError => e
    puts "✗ Failed to fetch: #{e.message}"
  rescue Psych::SyntaxError => e
    puts "✗ YAML parsing failed: #{e.message}"
  end
end

puts
puts "Exiting."
