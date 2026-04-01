# frozen_string_literal: true

require_relative "test_helper"

# Tests for common.rb helper functions
class TestCommonHelpers < Minitest::Test
  def test_deep_dup_hash
    original = { "a" => { "b" => "c" } }
    duped = deep_dup(original)

    duped["a"]["b"] = "modified"

    assert_equal "c", original["a"]["b"]
    assert_equal "modified", duped["a"]["b"]
  end

  def test_deep_dup_array
    original = [1, [2, 3], { "a" => "b" }]
    duped = deep_dup(original)

    duped[1][0] = 99
    duped[2]["a"] = "modified"

    assert_equal 2, original[1][0]
    assert_equal "b", original[2]["a"]
  end

  def test_looks_like_private_key_rsa
    key = "-----BEGIN RSA PRIVATE KEY-----\ndata\n-----END RSA PRIVATE KEY-----"
    assert looks_like_private_key?(key)
  end

  def test_looks_like_private_key_openssh
    key = "-----BEGIN OPENSSH PRIVATE KEY-----\ndata\n-----END OPENSSH PRIVATE KEY-----"
    assert looks_like_private_key?(key)
  end

  def test_looks_like_private_key_certificate
    cert = "-----BEGIN CERTIFICATE-----\ndata\n-----END CERTIFICATE-----"
    assert looks_like_private_key?(cert)
  end

  def test_looks_like_private_key_false_cases
    refute looks_like_private_key?("regular password")
    refute looks_like_private_key?("-----BEGIN PUBLIC KEY-----")
    refute looks_like_private_key?("")
    refute looks_like_private_key?(nil)
    refute looks_like_private_key?(12345)
  end

  def test_fix_private_key_format_already_correct
    key = "-----BEGIN RSA PRIVATE KEY-----\nline1\nline2\n-----END RSA PRIVATE KEY-----"
    result = fix_private_key_format(key)
    assert_equal key, result
  end

  def test_fix_private_key_format_escaped_newlines
    key = "-----BEGIN RSA PRIVATE KEY-----\\nline1\\nline2\\n-----END RSA PRIVATE KEY-----"
    result = fix_private_key_format(key)
    assert_match(/\n/, result)
    refute_match(/\\n/, result)
  end

  def test_to_yaml_with_literal_blocks_multiline
    hash = {
      "key" => "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA\n-----END RSA PRIVATE KEY-----"
    }
    result = to_yaml_with_literal_blocks(hash)

    # Should use literal block scalar (|)
    assert_match(/key: \|/, result)
    refute_match(/^---/, result) # Document marker should be removed
  end

  def test_to_yaml_with_literal_blocks_single_line
    hash = { "key" => "simple value" }
    result = to_yaml_with_literal_blocks(hash)

    assert_match(/key: simple value/, result)
    refute_match(/^---/, result)
  end

  def test_build_single_value_template
    parsed = {
      "lms" => {
        "api_url" => "https://example.com",
        "password" => "secret123"
      }
    }

    result = build_single_value_template(parsed, "lms.password")

    # Should replace only the password value with $$secret$$
    assert_match(/password: \$\$secret\$\$/, result)
    assert_match(/api_url: https:\/\/example\.com/, result)
    refute_match(/secret123/, result)
  end

  def test_build_single_value_template_nested
    parsed = {
      "provider" => {
        "api" => {
          "password" => "secret"
        }
      }
    }

    result = build_single_value_template(parsed, "provider.api.password")

    assert_match(/password: \$\$secret\$\$/, result)
    assert_match(/provider:/, result)
    assert_match(/api:/, result)
  end

  def test_build_multi_value_template
    parsed = {
      "lms" => {
        "api_url" => "https://example.com",
        "password" => "pass123",
        "api_key" => "key456"
      }
    }
    paths = ["lms.password", "lms.api_key"]

    result = build_multi_value_template(parsed, paths)

    # Secret keys should be removed
    refute_match(/password:/, result)
    refute_match(/api_key:/, result)

    # $$secret$$ placeholder should be present
    assert_match(/\$\$secret\$\$/, result)

    # Non-secret keys should remain
    assert_match(/api_url: https:\/\/example\.com/, result)
  end

  def test_build_multi_value_template_depth_0
    parsed = {
      "password" => "pass123",
      "api_key" => "key456",
      "url" => "https://example.com"
    }
    paths = ["password", "api_key"]

    result = build_multi_value_template(parsed, paths)

    # Top-level secrets removed
    refute_match(/^password:/, result)
    refute_match(/^api_key:/, result)

    # $$secret$$ at top level
    assert_match(/^\$\$secret\$\$/, result)

    # Non-secret remains
    assert_match(/url:/, result)
  end

  def test_check_for_ssh_keys_finds_keys
    value = {
      "normal" => "value",
      "ssh_key" => "-----BEGIN RSA PRIVATE KEY-----\ndata\n-----END RSA PRIVATE KEY-----",
      "nested" => {
        "cert" => "-----BEGIN CERTIFICATE-----\ndata\n-----END CERTIFICATE-----"
      }
    }

    found_keys = []
    check_for_ssh_keys(value, "", found_keys)

    assert_equal 2, found_keys.length
    assert_includes found_keys, ".ssh_key"
    assert_includes found_keys, ".nested.cert"
  end

  def test_check_for_ssh_keys_empty
    value = { "normal" => "value", "other" => "data" }
    found_keys = []
    check_for_ssh_keys(value, "", found_keys)

    assert_empty found_keys
  end

  def test_fix_ssh_keys_in_hash_modifies_in_place
    hash = {
      "ssh_key" => "-----BEGIN RSA PRIVATE KEY-----\\nline1\\nline2\\n-----END RSA PRIVATE KEY-----",
      "normal" => "value"
    }

    fix_ssh_keys_in_hash!(hash)

    # SSH key should be fixed (escaped \n replaced)
    refute_match(/\\n/, hash["ssh_key"])
    assert_match(/\n/, hash["ssh_key"])

    # Normal value unchanged
    assert_equal "value", hash["normal"]
  end
end
