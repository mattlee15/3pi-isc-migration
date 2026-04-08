# frozen_string_literal: true

# Shared helpers for 3pi ISC migration scripts.
#
# Usage:  require_relative "common"

require "yaml"
require "open3"
require "json"
require "digest"
require "tempfile"

DEFAULT_SERVICE     = "*.integrations.integrations"
SOURCE_SERVICE      = "rpc.integrations.integrations"
DEFAULT_ENVIRONMENT = "staging"

DEFAULT_PRINCIPALS = [
  ["Eng Enterprise Solutions - Architecture & Engineering (3-2816)", "owner"],
  ["ps-automation", "update"],
].freeze

# ── Error ──────────────────────────────────────────────────────────────────────

class IscError < StandardError; end

# ── Low-level ISC runners ──────────────────────────────────────────────────────

# Run ISC command. Returns stdout. Raises IscError on failure.
def isc!(*args)
  stdout, stderr, status = Open3.capture3(*args)
  unless status.success?
    raise IscError, "ISC command failed:\n  CMD:    #{args.join(' ')}\n  STDERR: #{stderr.strip}\n  STDOUT: #{stdout.strip}"
  end
  stdout
end

# Run ISC command. Returns [stdout, success?]. Never raises.
def isc(*args)
  stdout, _stderr, status = Open3.capture3(*args)
  [stdout, status.success?]
end

# ── Conf operations ────────────────────────────────────────────────────────────

def read_conf(name, service: DEFAULT_SERVICE, environment: DEFAULT_ENVIRONMENT)
  isc!("isc", "conf", "-e", environment, service, "get", "--no-env", name)
end

def find_conf(name, service: DEFAULT_SERVICE, environment: DEFAULT_ENVIRONMENT)
  stdout, success = isc("isc", "conf", "-e", environment, service, "search", "-k", name, "--as-json")
  return nil unless success
  results = JSON.parse(stdout)
  # ISC conf search --as-json uses "key" for the conf name (not "file")
  results.is_a?(Array) ? results.find { |c| c["key"] == name || c["file"] == name } : nil
rescue JSON::ParserError
  nil
end

# Create a conf with a $$secret$$ template linked to a secret ref.
# If the conf already exists, it will be deleted first to avoid ISC's interactive confirmation prompt.
def create_conf_with_template(conf_name, template, secretref_name, service: DEFAULT_SERVICE, environment: DEFAULT_ENVIRONMENT)
  # Check if conf already exists and delete it first to avoid confirmation prompt
  existing = find_conf(conf_name, service: service, environment: environment)
  if existing
    puts "    (Deleting existing conf to avoid confirmation prompt)"
    delete_conf(conf_name, service: service, environment: environment, ignore_secretref: true)
  end

  isc!("isc", "conf", "-e", environment, service, "set", conf_name, "--no-env", "-t", template, "-sn", secretref_name)
end

# Create a conf linked directly to an existing secret ref (no template).
# If the conf already exists, it will be deleted first to avoid ISC's interactive confirmation prompt.
def link_conf_to_secret_ref(conf_name, secretref_name, service: DEFAULT_SERVICE, environment: DEFAULT_ENVIRONMENT)
  # Check if conf already exists and delete it first to avoid confirmation prompt
  existing = find_conf(conf_name, service: service, environment: environment)
  if existing
    puts "    (Deleting existing conf to avoid confirmation prompt)"
    delete_conf(conf_name, service: service, environment: environment, ignore_secretref: true)
  end

  isc!("isc", "conf", "-e", environment, service, "set", conf_name, "--no-env", "-sn", secretref_name)
end

# Create a plain conf (no secret ref) with YAML content.
# If the conf already exists, it will be deleted first to avoid ISC's interactive confirmation prompt.
def create_plain_conf(conf_name, yaml_content, service: DEFAULT_SERVICE, environment: DEFAULT_ENVIRONMENT)
  # Check if conf already exists and delete it first to avoid confirmation prompt
  existing = find_conf(conf_name, service: service, environment: environment)
  if existing
    puts "    (Deleting existing conf to avoid confirmation prompt)"
    delete_conf(conf_name, service: service, environment: environment, ignore_secretref: true)
  end

  # Use --file for multiline YAML to avoid shell escaping issues
  Tempfile.create("isc_conf") do |f|
    f.write(yaml_content)
    f.flush
    isc!("isc", "conf", "-e", environment, service, "set", conf_name, "--no-env", "--file", f.path)
  end
end

# Delete a conf. Returns [success, stderr].
# Pass ignore_secretref: true when the linked secret ref is shared with other confs.
def delete_conf(name, service: DEFAULT_SERVICE, environment: DEFAULT_ENVIRONMENT, ignore_secretref: false)
  args = ["isc", "conf", "-e", environment, service, "clear", "--no-env"]
  args << "--ignore-secretref" if ignore_secretref
  args << name
  _stdout, stderr, status = Open3.capture3(*args)
  [status.success?, stderr]
end

# ── Secret ref operations ──────────────────────────────────────────────────────

def find_secret_ref(name, environment: DEFAULT_ENVIRONMENT)
  stdout, success = isc("isc", "secretref", "-e", environment, "list", "-n", name, "--as-json")
  return nil unless success
  results = JSON.parse(stdout)
  results.is_a?(Array) ? results.find { |r| r["name"] == name } : nil
rescue JSON::ParserError
  nil
end

# Find a secret ref whose value matches by SHA256 hash. Returns the ref hash or nil.
# When show_my_perms is true, includes principal_permissions field in the response.
# Returns nil if secret ref not found OR if you don't have access to view it.
def find_secret_ref_by_value(value, environment: DEFAULT_ENVIRONMENT, show_my_perms: false)
  hash = Digest::SHA256.hexdigest(value)
  args = ["isc", "secretref", "-e", environment, "list", "-d", hash, "--as-json"]
  args << "--show-my-perms" if show_my_perms
  stdout, success = isc(*args)
  return nil unless success
  results = JSON.parse(stdout)
  results.is_a?(Array) ? results.first : nil
rescue JSON::ParserError
  nil
end

# Check if we have link permissions for a secret ref.
# Returns: :can_link, :no_link_access, or :not_found
#
# Expected behavior (once ISC CLI is fixed):
# - principal_permissions: ["link"] or array containing "link" → :can_link
# - principal_permissions: null or [] → :no_link_access (no permission)
def check_secret_ref_link_permission(secret_ref, environment: DEFAULT_ENVIRONMENT)
  return :not_found if secret_ref.nil?

  permissions = secret_ref["principal_permissions"]

  # If permissions is null or empty array, we don't have link permission
  if permissions.nil? || (permissions.is_a?(Array) && permissions.empty?)
    return :no_link_access
  end

  # Check if array includes "link"
  return :can_link if permissions.is_a?(Array) && permissions.include?("link")

  # Permissions array exists but doesn't include "link"
  :no_link_access
end

# Returns array of confs linked to the given secret ref (uses -c flag).
# The -c flag returns the configs directly as an array, not nested in a secret ref object.
# Each config has: {"file": "env/...", "pattern": "service.name", "environment": "production"}
def find_linked_confs_for_secret_ref(name, environment: DEFAULT_ENVIRONMENT)
  stdout, success = isc("isc", "secretref", "-e", environment, "list", "-n", name, "-c", "--as-json")
  return [] unless success
  results = JSON.parse(stdout)
  # With -c flag, ISC returns an array of config objects directly (not nested in a ref object)
  return [] unless results.is_a?(Array)
  # Map to consistent format with "key" field for compatibility
  results.map do |conf|
    {
      "key" => conf["file"],
      "file" => conf["file"],
      "service" => conf["pattern"],
      "environment" => conf["environment"]
    }
  end
rescue JSON::ParserError
  []
end

# Create a new secret ref, or reuse one with the same value (SHA256 dedup).
# Returns the name of the secret ref to use.
# Set skip_dedup: true to force creation even if a matching value exists.
def create_or_find_secret_ref(name, value, principals: DEFAULT_PRINCIPALS, environment: DEFAULT_ENVIRONMENT, skip_dedup: false)
  unless skip_dedup
    existing = find_secret_ref_by_value(value, environment: environment, show_my_perms: true)
    if existing
      puts "  Found existing secret ref with same value: #{existing['name']} — reusing."
      return existing["name"]
    end
  end

  # Use --file for multiline values (e.g., SSH keys, certificates)
  # This avoids issues with newlines and special characters
  if value.include?("\n")
    Tempfile.create("isc_secret") do |f|
      f.write(value)
      f.flush
      args = ["isc", "secretref", "-e", environment, "create", "-n", name, "--file", f.path, "-d", name]
      args << "--shared-value-detection=false" if skip_dedup
      principals.each { |principal, perms| args += ["-p", "#{principal}:#{perms}"] }
      isc!(*args)
    end
  else
    # For single-line values, use --value= to handle values starting with hyphens
    args = ["isc", "secretref", "-e", environment, "create", "-n", name, "--value=#{value}", "-d", name]
    args << "--shared-value-detection=false" if skip_dedup
    principals.each { |principal, perms| args += ["-p", "#{principal}:#{perms}"] }
    isc!(*args)
  end

  if skip_dedup
    puts "  Created new secret ref: #{name} (shared_value_detection: false)"
  else
    puts "  Created new secret ref: #{name}"
  end
  name
end

def update_secret_ref(name, value, environment: DEFAULT_ENVIRONMENT)
  # Use --file for multiline values (e.g., SSH keys, certificates)
  if value.include?("\n")
    Tempfile.create("isc_secret") do |f|
      f.write(value)
      f.flush
      isc!("isc", "secretref", "-e", environment, "update", "-n", name, "--file", f.path)
    end
  else
    # For single-line values, use --value= to handle values starting with hyphens
    isc!("isc", "secretref", "-e", environment, "update", "-n", name, "--value=#{value}")
  end
end

# List all secret refs in an environment. Returns array of secret ref hashes.
def list_all_secret_refs(environment: DEFAULT_ENVIRONMENT)
  stdout, success = isc("isc", "secretref", "-e", environment, "list", "--as-json")
  return [] unless success
  results = JSON.parse(stdout)
  results.is_a?(Array) ? results : []
rescue JSON::ParserError
  []
end

# Delete a secret ref. Returns [success, stderr].
def delete_secret_ref(name, environment: DEFAULT_ENVIRONMENT)
  _stdout, stderr, status = Open3.capture3("isc", "secretref", "-e", environment, "clear", name)
  [status.success?, stderr]
end

# Try to clean up a secret ref after migration. Returns a human-readable status string.
# Deletes only if the ref exists and has no remaining linked confs.
def try_cleanup_secret_ref(name, environment: DEFAULT_ENVIRONMENT)
  ref = find_secret_ref(name, environment: environment)
  return "not found — nothing to clean up" unless ref

  linked = find_linked_confs_for_secret_ref(name, environment: environment)
  if linked.any?
    linked_names = linked.map { |c| c["key"] || c["file"] || c.to_s }.join(", ")
    return "preserved — #{linked.length} conf(s) still linked: #{linked_names}"
  end

  success, stderr = delete_secret_ref(name, environment: environment)
  if success
    "deleted"
  else
    "could not delete (permission denied) — requires delete access to: #{name}\n    #{stderr.strip}"
  end
end

# ── YAML Sanitization ─────────────────────────────────────────────────────────

# Fix YAML with unquoted values that start with YAML indicator characters.
# This handles cases where values like ",abc" or "[test]" cause parse errors.
# Also converts literal ↵ (Unicode U+21B5) symbols to actual newlines.
# Returns sanitized YAML string that can be safely parsed.
def sanitize_yaml(yaml_string)
  # First, replace literal ↵ symbols with actual newlines
  # This handles cases where ISC stores the return symbol instead of \n
  yaml_string = yaml_string.gsub('↵', "\n")

  lines = yaml_string.lines
  fixed_lines = lines.map do |line|
    # Match pattern: key: value (where value starts with special char)
    # Only fix if value is not already quoted and starts with YAML indicator
    if line.match?(/^(\s*)([a-zA-Z_][\w-]*):(\s+)([,\[\]\{\}])/)
      line.sub(/^(\s*)([a-zA-Z_][\w-]*):(\s+)(.+)$/) do
        indent = $1
        key = $2
        spacing = $3
        value = $4.chomp
        # Quote the value if it starts with YAML special chars and isn't already quoted
        if value.match?(/^[,\[\]\{\}]/) && !value.match?(/^["']/)
          "#{indent}#{key}:#{spacing}\"#{value}\"\n"
        else
          line
        end
      end
    else
      line
    end
  end
  fixed_lines.join
end

# ── SSH Key Formatting ────────────────────────────────────────────────────────

# Detect if a string looks like an SSH/RSA/other private key or certificate
def looks_like_private_key?(value)
  return false unless value.is_a?(String)
  value.match?(/-----BEGIN (?:RSA |DSA |EC |OPENSSH |ENCRYPTED )?(?:PRIVATE KEY|CERTIFICATE)-----/)
end

# Fix SSH private key formatting: ensure proper newlines and structure
# Handles cases where keys might be incorrectly formatted (missing newlines, etc.)
def fix_private_key_format(key_string)
  # If it already has newlines and proper structure, return as-is
  return key_string if key_string.include?("\n") && key_string.lines.length > 2

  # Handle cases where newlines might be escaped or missing
  # This is a basic fixer - most keys should already be correctly formatted
  key_string
    .gsub('\\n', "\n")           # Replace literal \n with actual newlines
    .gsub(/\r\n/, "\n")          # Normalize Windows line endings
    .gsub(/(?<=-----)\s+(?=\w)/, "\n")  # Add newline after BEGIN line if missing
    .gsub(/(?<=\w)\s+(?=-----)/, "\n")  # Add newline before END line if missing
end

# Helper to recursively check for SSH keys and collect their paths
def check_for_ssh_keys(value, path, found_keys)
  if looks_like_private_key?(value)
    found_keys << path
  elsif value.is_a?(Hash)
    value.each { |k, v| check_for_ssh_keys(v, "#{path}.#{k}", found_keys) }
  elsif value.is_a?(Array)
    value.each_with_index { |item, i| check_for_ssh_keys(item, "#{path}[#{i}]", found_keys) }
  end
end

# Recursively fix SSH private key formatting in a parsed YAML hash
# Modifies the hash in place
def fix_ssh_keys_in_hash!(hash)
  return unless hash.is_a?(Hash)

  hash.each do |key, value|
    if looks_like_private_key?(value)
      hash[key] = fix_private_key_format(value)
    elsif value.is_a?(Hash)
      fix_ssh_keys_in_hash!(value)
    elsif value.is_a?(Array)
      value.each { |item| fix_ssh_keys_in_hash!(item) if item.is_a?(Hash) }
    end
  end
  hash
end

# Convert hash to YAML with literal block scalars for multiline strings
# This ensures SSH keys are formatted with | syntax
def to_yaml_with_literal_blocks(hash)
  # Use Psych to generate YAML with specific options:
  # - line_width: -1 disables line wrapping
  # - indentation: 2 for consistent 2-space indents
  # Psych automatically uses literal block style (|) for multiline strings
  yaml_str = YAML.dump(hash, line_width: -1, indentation: 2)

  # Remove the document start marker (---) if present
  yaml_str = yaml_str.sub(/\A---\n/, "")

  # Post-process: ensure URLs with :// are quoted to prevent YAML parsing issues
  # Match lines like: "  key: http://example.com" (unquoted URL)
  # Replace with: "  key: 'http://example.com'" (quoted URL)
  yaml_str.gsub(/^(\s*\w+):\s+(https?:\/\/[^\s'"\n]+)$/, "\\1: '\\2'")
end

# ── Template building ──────────────────────────────────────────────────────────

def deep_dup(obj)
  case obj
  when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.dup] = deep_dup(v) }
  when Array then obj.map { |v| deep_dup(v) }
  when String then obj.dup
  else obj
  end
end

# Build a single-value template: key stays in the template, $$secret$$ is its value.
# secret_key_path is dot-separated, e.g. "lms.authenticate_password"
def build_single_value_template(parsed, secret_key_path)
  hash = deep_dup(parsed)
  parts = secret_key_path.split(".")
  parent = parts.length > 1 ? hash.dig(*parts[0..-2]) : hash
  parent[parts.last] = "$$secret$$"
  yaml_str = hash.to_yaml.sub(/\A---\n/, "")
  # Psych may double-quote $$secret$$ — strip the quotes so ISC sees the literal token
  yaml_str.gsub('"$$secret$$"', "$$secret$$")
end

MULTI_VALUE_SENTINEL = "__ISC_SECRET_BLOCK__"

# Build a multi-value template: secret keys are removed and replaced with a
# standalone $$secret$$ block placeholder at the end of their shared parent.
# All secret_key_paths must share the same immediate parent key.
def build_multi_value_template(parsed, secret_key_paths)
  hash = deep_dup(parsed)

  # Remove each secret key from the hash
  secret_key_paths.each do |path|
    parts = path.split(".")
    parent = parts.length > 1 ? hash.dig(*parts[0..-2]) : hash
    parent.delete(parts.last) if parent.is_a?(Hash)
  end

  # Append a sentinel as the last key in the shared parent block
  parent_parts = secret_key_paths.first.split(".")[0..-2]
  parent = parent_parts.empty? ? hash : hash.dig(*parent_parts)
  parent[MULTI_VALUE_SENTINEL] = nil

  yaml_str = hash.to_yaml.sub(/\A---\n/, "")
  # Replace "  __ISC_SECRET_BLOCK__:\n" (preserving leading indent) with "  $$secret$$\n"
  yaml_str.gsub(/^(\s*)#{MULTI_VALUE_SENTINEL}:.*\n/, "\\1$$secret$$\n")
end

# Build the pre-indented secret value block for multi-value substitution.
# Pre-indent rules:
#   Line 1: no leading spaces — $$secret$$ position in template provides the indent
#   Line 2+: (parent_depth × 2) spaces — must match the indent level of $$secret$$
#
# Examples:
#   depth 1 parent (lms.x)              → $$secret$$ at 2 spaces → line 2+: 2 spaces
#   depth 2 parent (app_card_sfx.api.x) → $$secret$$ at 4 spaces → line 2+: 4 spaces
#   depth 0 (top-level x)               → $$secret$$ at 0 spaces → no indent
#
# Serializes all secrets as a single hash so Psych emits correct YAML for every
# value type, including multiline strings (literal block scalars with `|`).
# Lines 2+ of the resulting fragment are pre-indented so that ISC's verbatim
# substitution of $$secret$$ yields correct YAML indentation.
def build_secret_block(parsed, secret_key_paths)
  parent_depth = secret_key_paths.first.split(".").length - 1
  indent = "  " * parent_depth

  # Build a hash with just the secret keys, preserving their values
  secrets_hash = secret_key_paths.each_with_object({}) do |path, h|
    parts = path.split(".")
    h[parts.last] = parsed.dig(*parts)
  end

  # Convert to YAML - Psych automatically uses literal block scalars (|) for multiline strings
  yaml_fragment = secrets_hash.to_yaml.delete_prefix("---\n").chomp

  # Apply indentation for lines 2+ when parent_depth > 0
  if parent_depth > 0
    yaml_lines = yaml_fragment.split("\n")
    ([yaml_lines.first] + yaml_lines[1..].map { |l| "#{indent}#{l}" }).join("\n")
  else
    yaml_fragment
  end
end

# ── Reporting ──────────────────────────────────────────────────────────────────

def append_report(report_path:, source_conf:, environment:, plan:, secret_keys:,
                  new_conf_name:, secret_ref_used:, orig_conf_status:, orig_secret_status:)
  File.open(report_path, "a") do |f|
    f.puts "=== Migration: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')} ==="
    f.puts "Source conf:             #{source_conf}"
    f.puts "Environment:             #{environment}"
    f.puts "Migration plan:          #{plan}"
    f.puts "Secret keys:             #{Array(secret_keys).join(', ')}"
    f.puts "New conf:                #{new_conf_name}"
    f.puts "Secret ref used:         #{secret_ref_used}"
    f.puts "Original conf:           #{orig_conf_status}"
    f.puts "Original secret ref:     #{orig_secret_status}"
    f.puts ""
  end
end

# ── Verification ───────────────────────────────────────────────────────────────

def verify(checks)
  all_pass = true
  checks.each do |label, result|
    puts "  [#{result ? 'PASS' : 'FAIL'}] #{label}"
    all_pass = false unless result
  end
  all_pass
end
