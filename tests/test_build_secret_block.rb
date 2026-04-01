# frozen_string_literal: true

require_relative "test_helper"

# Tests for build_secret_block function - handles multi-value templates with multiline values
class TestBuildSecretBlock < Minitest::Test
  def test_single_line_values_depth_1
    parsed = {
      "lms" => {
        "password" => "pass123",
        "api_key" => "key456"
      }
    }
    paths = ["lms.password", "lms.api_key"]

    result = build_secret_block(parsed, paths)

    # Should produce YAML fragment without document marker
    assert_match(/password:/, result)
    assert_match(/api_key:/, result)
    refute_match(/^---/, result)

    # Lines 2+ should have 2-space indent (parent depth = 1)
    lines = result.split("\n")
    assert_equal "password: pass123", lines[0]
    assert_match(/^\s+api_key: key456/, lines[1]) # Line 2 should be indented
  end

  def test_multiline_value_with_literal_block_scalar
    parsed = {
      "lms" => {
        "ssh_key" => "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA123\n-----END RSA PRIVATE KEY-----"
      }
    }
    paths = ["lms.ssh_key"]

    result = build_secret_block(parsed, paths)

    # Should use literal block scalar (| or |-) for multiline strings
    assert_match(/ssh_key: \|[-]?/, result)
    assert_match(/BEGIN RSA PRIVATE KEY/, result)
    assert_match(/END RSA PRIVATE KEY/, result)

    # Lines should be properly indented for parent depth 1
    lines = result.split("\n")
    assert_match(/ssh_key: \|[-]?/, lines[0]) # May have chomping indicator
    # Subsequent lines should have 2-space base indent
    assert_match(/^\s+-----BEGIN/, lines[1])
  end

  def test_multiple_values_including_multiline_depth_1
    parsed = {
      "lms" => {
        "password" => "simple_pass",
        "certificate" => "-----BEGIN CERTIFICATE-----\nMIIDXTCCAkWgAwIBAgIJAKZ\n-----END CERTIFICATE-----"
      }
    }
    paths = ["lms.password", "lms.certificate"]

    result = build_secret_block(parsed, paths)

    # Should handle both single-line and multiline values correctly
    assert_match(/password: simple_pass/, result)
    assert_match(/certificate: \|[-]?/, result)
    assert_match(/BEGIN CERTIFICATE/, result)

    # Check indentation
    lines = result.split("\n")
    assert lines[1].start_with?("  "), "Line 2+ should have 2-space indent (depth 1)"
  end

  def test_depth_0_no_indent
    parsed = {
      "password" => "pass123",
      "api_key" => "key456"
    }
    paths = ["password", "api_key"]

    result = build_secret_block(parsed, paths)

    # No parent, so no indentation on any lines
    lines = result.split("\n")
    lines.each do |line|
      refute line.start_with?("  "), "Depth 0 should have no indent: #{line}"
    end
  end

  def test_depth_2_four_space_indent
    parsed = {
      "provider" => {
        "api" => {
          "password" => "nested_pass",
          "token" => "nested_token"
        }
      }
    }
    paths = ["provider.api.password", "provider.api.token"]

    result = build_secret_block(parsed, paths)

    # Parent depth = 2, so lines 2+ should have 4-space indent
    lines = result.split("\n")
    assert_equal "password: nested_pass", lines[0]
    assert_equal "    token: nested_token", lines[1]
  end

  def test_preserves_yaml_types
    parsed = {
      "config" => {
        "string_val" => "text",
        "number_val" => 12345,
        "bool_val" => true,
        "null_val" => nil
      }
    }
    paths = ["config.string_val", "config.number_val", "config.bool_val", "config.null_val"]

    result = build_secret_block(parsed, paths)

    # Verify types are preserved in YAML output
    assert_match(/string_val: text/, result)
    assert_match(/number_val: 12345/, result)
    assert_match(/bool_val: true/, result)
    assert_match(/null_val:/, result) # nil becomes empty value
  end

  def test_handles_special_characters
    parsed = {
      "lms" => {
        "password" => "p@ssw0rd_no_colon",
        "key" => "key-with-hyphens"
      }
    }
    paths = ["lms.password", "lms.key"]

    result = build_secret_block(parsed, paths)

    # Special characters should be properly quoted if needed
    assert_match(/password:/, result)
    assert_match(/key:/, result)

    # To verify it's valid YAML, we need to parse it in context (as if substituted in template)
    # Add parent context for parsing since this is a fragment
    template = build_multi_value_template(parsed, paths)
    full_yaml = template.gsub("$$secret$$", result)
    parsed_back = YAML.safe_load(full_yaml)

    assert_equal "p@ssw0rd_no_colon", parsed_back["lms"]["password"]
    assert_equal "key-with-hyphens", parsed_back["lms"]["key"]
  end

  def test_multiline_certificate_with_pipes
    # Real-world certificate with multiple lines and proper formatting
    cert = <<~CERT.chomp
      -----BEGIN CERTIFICATE-----
      MIIDXTCCAkWgAwIBAgIJAKZ5m0pcXv3uMA0GCSqGSIb3DQEBCwUAMEUxCzAJBgNV
      BAYTAkFVMRMwEQYDVQQIDApTb21lLVN0YXRlMSEwHwYDVQQKDBhJbnRlcm5ldCBX
      aWRnaXRzIFB0eSBMdGQwHhcNMTkwNzEwMTgyMjU5WhcNMjAwNzA5MTgyMjU5WjBF
      -----END CERTIFICATE-----
    CERT

    parsed = { "lms" => { "cert" => cert } }
    paths = ["lms.cert"]

    result = build_secret_block(parsed, paths)

    # Should use literal block scalar (with optional chomping indicator)
    assert_match(/cert: \|[-]?/, result)

    # Each line of the cert should be properly indented
    lines = result.split("\n")
    cert_lines = lines[1..] # Skip "cert: |" line
    cert_lines.each do |line|
      assert line.start_with?("  "), "Certificate lines should be indented: #{line}"
    end
  end

  def test_empty_string_value
    parsed = {
      "config" => {
        "password" => "",
        "api_key" => "key123"
      }
    }
    paths = ["config.password", "config.api_key"]

    result = build_secret_block(parsed, paths)

    # Empty string should be handled
    assert_match(/password: ['"]?['"]?/, result)
    assert_match(/api_key: key123/, result)
  end

  def test_value_starting_with_hyphen
    parsed = {
      "config" => {
        "password" => "-starts-with-hyphen"
      }
    }
    paths = ["config.password"]

    result = build_secret_block(parsed, paths)

    # Values starting with hyphen should be quoted by YAML
    parsed_back = YAML.safe_load(result)
    assert_equal "-starts-with-hyphen", parsed_back["password"]
  end

  def test_multiple_multiline_values
    ssh_key = "-----BEGIN RSA PRIVATE KEY-----\nKEY_DATA\n-----END RSA PRIVATE KEY-----"
    cert = "-----BEGIN CERTIFICATE-----\nCERT_DATA\n-----END CERTIFICATE-----"

    parsed = {
      "lms" => {
        "ssh_key" => ssh_key,
        "certificate" => cert
      }
    }
    paths = ["lms.ssh_key", "lms.certificate"]

    result = build_secret_block(parsed, paths)

    # Both should use literal block scalars (with optional chomping indicator)
    assert_match(/ssh_key: \|[-]?/, result)
    assert_match(/certificate: \|[-]?/, result)

    # Both should preserve content
    assert_match(/KEY_DATA/, result)
    assert_match(/CERT_DATA/, result)
  end

  def test_mixed_depth_values_same_parent
    # All values share immediate parent "api" (depth 2)
    parsed = {
      "provider" => {
        "api" => {
          "simple_key" => "value1",
          "multiline_key" => "line1\nline2\nline3"
        }
      }
    }
    paths = ["provider.api.simple_key", "provider.api.multiline_key"]

    result = build_secret_block(parsed, paths)

    # Line 1 should have no indent, lines 2+ should have 4 spaces (depth 2)
    lines = result.split("\n")
    refute lines[0].start_with?(" "), "First line should not be indented"

    # Find lines after first key-value pair
    multiline_start = lines.index { |l| l.include?("multiline_key") }
    if multiline_start
      lines[(multiline_start + 1)..].each do |line|
        next if line.strip.empty?
        assert line.start_with?("    "), "Lines after first should have 4-space indent (depth 2): #{line}"
      end
    end
  end
end
