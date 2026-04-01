# frozen_string_literal: true

require_relative "test_helper"

# Tests for YAML sanitization helper
class TestYamlSanitization < Minitest::Test
  def test_sanitize_value_starting_with_comma
    yaml = <<~YAML
      brdata:
        base_url: https://webservices.brdata.com
        app_id: 150
        client_id: instacartSandboxUser
        secret_key: ,xci89xcznDia1WkjsxUQIi2k23
        currency: USD
    YAML

    result = sanitize_yaml(yaml)

    # Should quote the value starting with comma
    assert_match(/secret_key: ",xci89xcznDia1WkjsxUQIi2k23"/, result)

    # Should be parseable
    parsed = YAML.safe_load(result)
    assert_equal ",xci89xcznDia1WkjsxUQIi2k23", parsed["brdata"]["secret_key"]
  end

  def test_sanitize_value_starting_with_bracket
    yaml = <<~YAML
      config:
        array_like: [test]value
        normal: value
    YAML

    result = sanitize_yaml(yaml)

    # Should quote the value starting with bracket
    assert_match(/array_like: "\[test\]value"/, result)

    # Should not quote normal value
    assert_match(/normal: value/, result)
  end

  def test_sanitize_already_quoted_values
    yaml = <<~YAML
      config:
        quoted_comma: ",value"
        quoted_bracket: "[value]"
    YAML

    result = sanitize_yaml(yaml)

    # Should not double-quote
    assert_equal yaml, result
  end

  def test_sanitize_preserves_valid_yaml
    yaml = <<~YAML
      config:
        normal_value: abc123
        url: https://example.com
        number: 42
    YAML

    result = sanitize_yaml(yaml)

    # Should not modify valid YAML
    assert_equal yaml, result
  end

  def test_sanitize_multiple_problematic_values
    yaml = <<~YAML
      config:
        comma_val: ,abc
        bracket_val: [test
        brace_val: {data
        normal: value
    YAML

    result = sanitize_yaml(yaml)

    # Should quote all problematic values
    assert_match(/comma_val: ",abc"/, result)
    assert_match(/bracket_val: "\[test"/, result)
    assert_match(/brace_val: "\{data"/, result)
    assert_match(/normal: value/, result)

    # Should be parseable
    parsed = YAML.safe_load(result)
    assert_equal ",abc", parsed["config"]["comma_val"]
    assert_equal "[test", parsed["config"]["bracket_val"]
    assert_equal "{data", parsed["config"]["brace_val"]
  end

  def test_sanitize_preserves_indentation
    yaml = <<~YAML
      level1:
        level2:
          problematic: ,value
          normal: value
    YAML

    result = sanitize_yaml(yaml)

    # Should preserve indentation structure
    assert_match(/^  level2:/, result)
    assert_match(/^    problematic: ",value"/, result)
    assert_match(/^    normal: value/, result)
  end

  def test_sanitize_empty_string
    assert_equal "", sanitize_yaml("")
  end

  def test_sanitize_yaml_with_no_issues
    yaml = "key: value\n"
    assert_equal yaml, sanitize_yaml(yaml)
  end
end
