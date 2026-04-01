# frozen_string_literal: true

require_relative "test_helper"

# Tests for edge cases and special scenarios
class TestEdgeCases < Minitest::Test
  def test_empty_config
    parsed = {}
    paths = []

    # Should not crash
    assert_raises(StandardError) do
      build_secret_block(parsed, paths)
    end
  end

  def test_config_with_null_values
    parsed = {
      "config" => {
        "password" => nil,
        "api_key" => "key123"
      }
    }

    # Single value template with nil
    result = build_single_value_template(parsed, "config.password")
    assert_match(/password:/, result)

    # Multi value template with nil
    result2 = build_secret_block(parsed, ["config.password", "config.api_key"])
    assert_match(/password:/, result2)
  end

  def test_config_with_boolean_values
    parsed = {
      "config" => {
        "enabled" => true,
        "disabled" => false,
        "api_key" => "key123"
      }
    }

    paths = ["config.enabled", "config.disabled"]
    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    # Booleans should be preserved via substitution
    result = template.gsub("$$secret$$", secret_block)
    parsed_back = YAML.safe_load(result)
    assert_equal true, parsed_back["config"]["enabled"]
    assert_equal false, parsed_back["config"]["disabled"]
  end

  def test_config_with_numeric_values
    parsed = {
      "config" => {
        "port" => 8080,
        "timeout" => 30.5,
        "api_key" => "key123"
      }
    }

    paths = ["config.port", "config.timeout"]
    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    # Numbers should be preserved via substitution
    result = template.gsub("$$secret$$", secret_block)
    parsed_back = YAML.safe_load(result)
    assert_equal 8080, parsed_back["config"]["port"]
    assert_equal 30.5, parsed_back["config"]["timeout"]
  end

  def test_config_with_array_values
    parsed = {
      "config" => {
        "servers" => ["server1", "server2", "server3"],
        "api_key" => "key123"
      }
    }

    # Arrays should be preserved in templates
    result = build_single_value_template(parsed, "config.api_key")
    assert_match(/servers:/, result)
    assert_match(/- server1/, result)
  end

  def test_config_with_nested_arrays_and_hashes
    parsed = {
      "config" => {
        "servers" => [
          { "host" => "server1", "port" => 8080 },
          { "host" => "server2", "port" => 8081 }
        ],
        "password" => "secret"
      }
    }

    result = build_single_value_template(parsed, "config.password")

    # Nested structures should be preserved
    assert_match(/servers:/, result)
    assert_match(/host: server1/, result)
    assert_match(/port: 8080/, result)
  end

  def test_special_yaml_characters_in_values
    parsed = {
      "config" => {
        "password" => 'pass_word@with#special_chars%',
        "key" => "key-with-hyphens",
        "quoted" => "value with spaces"
      }
    }

    paths = ["config.password", "config.key", "config.quoted"]
    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    # Should produce valid YAML via substitution
    result = template.gsub("$$secret$$", secret_block)
    parsed_back = YAML.safe_load(result)
    assert_equal 'pass_word@with#special_chars%', parsed_back["config"]["password"]
    assert_equal "key-with-hyphens", parsed_back["config"]["key"]
    assert_equal "value with spaces", parsed_back["config"]["quoted"]
  end

  def test_unicode_characters_in_values
    parsed = {
      "config" => {
        "message" => "Hello 世界 🌍",
        "password" => "pâsswörd"
      }
    }

    paths = ["config.message", "config.password"]
    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    # Unicode should be preserved via substitution
    result = template.gsub("$$secret$$", secret_block)
    parsed_back = YAML.safe_load(result)
    assert_equal "Hello 世界 🌍", parsed_back["config"]["message"]
    assert_equal "pâsswörd", parsed_back["config"]["password"]
  end

  def test_very_long_values
    long_value = "a" * 10000
    parsed = {
      "config" => {
        "long_password" => long_value
      }
    }

    result = build_secret_block(parsed, ["config.long_password"])

    # Should handle long values without truncation
    parsed_back = YAML.safe_load(result)
    assert_equal long_value, parsed_back["long_password"]
  end

  def test_multiline_value_with_blank_lines
    value = "line1\n\nline3\n\nline5"
    parsed = {
      "config" => {
        "content" => value
      }
    }

    paths = ["config.content"]
    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    # Blank lines should be preserved via substitution
    result = template.gsub("$$secret$$", secret_block)
    parsed_back = YAML.safe_load(result)
    assert_equal value, parsed_back["config"]["content"]
    assert_equal 5, parsed_back["config"]["content"].lines.count
  end

  def test_multiline_value_with_indentation
    value = "line1\n  indented line\n    more indented\nback to normal"
    parsed = {
      "config" => {
        "content" => value
      }
    }

    paths = ["config.content"]
    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    # Internal indentation should be preserved via substitution
    result = template.gsub("$$secret$$", secret_block)
    parsed_back = YAML.safe_load(result)
    assert_equal value, parsed_back["config"]["content"]
  end

  def test_value_that_looks_like_yaml
    # Value that could be confused as YAML structure
    value = "key: value\nanother_key: another_value"
    parsed = {
      "config" => {
        "yaml_string" => value
      }
    }

    result = build_secret_block(parsed, ["config.yaml_string"])

    # Should be treated as a string, not parsed as YAML
    parsed_back = YAML.safe_load(result)
    assert_equal value, parsed_back["yaml_string"]
  end

  def test_keys_with_special_characters
    parsed = {
      "config-with-hyphens" => {
        "pass_word" => "secret",
        "API.KEY" => "key123"
      }
    }

    # Keys with special chars should work
    result = build_secret_block(parsed, ["config-with-hyphens.pass_word"])
    assert_match(/pass_word:/, result)
  end

  def test_deeply_nested_config
    parsed = {
      "level1" => {
        "level2" => {
          "level3" => {
            "level4" => {
              "password" => "deep_secret"
            }
          }
        }
      }
    }

    result = build_single_value_template(parsed, "level1.level2.level3.level4.password")

    # Should handle deep nesting
    assert_match(/password: \$\$secret\$\$/, result)
    assert_match(/level1:/, result)
    assert_match(/level4:/, result)
  end

  def test_config_with_leading_trailing_whitespace
    parsed = {
      "config" => {
        "password" => "  secret with spaces  ",
        "key" => "\ttab-prefixed\t"
      }
    }

    paths = ["config.password", "config.key"]
    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    # Whitespace should be preserved via substitution
    result = template.gsub("$$secret$$", secret_block)
    parsed_back = YAML.safe_load(result)
    assert_equal "  secret with spaces  ", parsed_back["config"]["password"]
    assert_equal "\ttab-prefixed\t", parsed_back["config"]["key"]
  end

  def test_multiple_ssh_keys_in_same_config
    key1 = "-----BEGIN RSA PRIVATE KEY-----\nKEY1_DATA\n-----END RSA PRIVATE KEY-----"
    key2 = "-----BEGIN RSA PRIVATE KEY-----\nKEY2_DATA\n-----END RSA PRIVATE KEY-----"

    parsed = {
      "config" => {
        "primary_key" => key1,
        "backup_key" => key2
      }
    }

    result = build_secret_block(parsed, ["config.primary_key", "config.backup_key"])

    # Both keys should use literal block scalars
    assert_match(/primary_key: \|/, result)
    assert_match(/backup_key: \|/, result)
    assert_match(/KEY1_DATA/, result)
    assert_match(/KEY2_DATA/, result)
  end

  def test_ssh_key_with_comment_lines
    key = "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-256-CBC,ABC123\n\nMIIEpAIBAAKCAQEA\n-----END RSA PRIVATE KEY-----"

    parsed = {
      "config" => {
        "ssh_key" => key
      }
    }

    result = build_secret_block(parsed, ["config.ssh_key"])

    # All lines including metadata should be preserved
    parsed_back = YAML.safe_load(result)
    assert_match(/Proc-Type/, parsed_back["ssh_key"])
    assert_match(/DEK-Info/, parsed_back["ssh_key"])
  end

  def test_value_with_dollar_signs
    # Dollar signs (not $$secret$$) should be escaped properly
    parsed = {
      "config" => {
        "password" => "$pecial$pa$$word"
      }
    }

    result = build_secret_block(parsed, ["config.password"])

    parsed_back = YAML.safe_load(result)
    assert_equal "$pecial$pa$$word", parsed_back["password"]
  end

  def test_value_with_quotes
    parsed = {
      "config" => {
        "password" => 'password with "quotes" inside',
        "key" => "password with 'single quotes'"
      }
    }

    paths = ["config.password", "config.key"]
    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    # Quotes should be preserved via substitution
    result = template.gsub("$$secret$$", secret_block)
    parsed_back = YAML.safe_load(result)
    assert_equal 'password with "quotes" inside', parsed_back["config"]["password"]
    assert_equal "password with 'single quotes'", parsed_back["config"]["key"]
  end

  def test_value_with_backslashes
    parsed = {
      "config" => {
        "windows_path" => 'C:\\Users\\Admin\\file.txt',
        "regex" => '\\d+\\w+'
      }
    }

    paths = ["config.windows_path", "config.regex"]
    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    # Backslashes should be preserved via substitution
    # Use block form of gsub to avoid backslash interpretation
    result = template.gsub("$$secret$$") { secret_block }
    parsed_back = YAML.safe_load(result)
    assert_equal 'C:\\Users\\Admin\\file.txt', parsed_back["config"]["windows_path"]
    assert_equal '\\d+\\w+', parsed_back["config"]["regex"]
  end

  def test_empty_parent_after_secret_removal
    parsed = {
      "config" => {
        "password" => "secret"
      }
    }

    # After removing the only key, parent should still exist with $$secret$$
    result = build_multi_value_template(parsed, ["config.password"])

    assert_match(/config:/, result)
    assert_match(/\$\$secret\$\$/, result)
  end

  def test_mix_of_data_types_in_secret_block
    parsed = {
      "config" => {
        "string_val" => "text",
        "int_val" => 123,
        "float_val" => 45.67,
        "bool_val" => true,
        "null_val" => nil,
        "multiline_val" => "line1\nline2",
        "array_val" => [1, 2, 3],
        "hash_val" => { "nested" => "value" }
      }
    }

    paths = [
      "config.string_val",
      "config.int_val",
      "config.float_val",
      "config.bool_val",
      "config.null_val",
      "config.multiline_val",
      "config.array_val",
      "config.hash_val"
    ]

    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    # All types should be preserved correctly via substitution
    result = template.gsub("$$secret$$", secret_block)
    parsed_back = YAML.safe_load(result)
    assert_equal "text", parsed_back["config"]["string_val"]
    assert_equal 123, parsed_back["config"]["int_val"]
    assert_equal 45.67, parsed_back["config"]["float_val"]
    assert_equal true, parsed_back["config"]["bool_val"]
    assert_nil parsed_back["config"]["null_val"]
    assert_equal "line1\nline2", parsed_back["config"]["multiline_val"]
    assert_equal [1, 2, 3], parsed_back["config"]["array_val"]
    assert_equal({ "nested" => "value" }, parsed_back["config"]["hash_val"])
  end
end
