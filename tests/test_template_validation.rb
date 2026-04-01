# frozen_string_literal: true

require_relative "test_helper"

# Tests to validate that templates and secret blocks produce valid YAML when substituted
class TestTemplateValidation < Minitest::Test
  # Simulates ISC template substitution: replaces $$secret$$ with the actual secret value
  def simulate_substitution(template, secret_value)
    template.gsub("$$secret$$", secret_value)
  end

  def test_single_value_substitution_simple
    parsed = {
      "lms" => {
        "api_url" => "https://example.com",
        "password" => "secret123"
      }
    }

    template = build_single_value_template(parsed, "lms.password")
    secret_value = "secret123"

    result = simulate_substitution(template, secret_value)

    # Result should be valid YAML
    final_parsed = YAML.safe_load(result)
    assert_equal "https://example.com", final_parsed["lms"]["api_url"]
    assert_equal "secret123", final_parsed["lms"]["password"]
  end

  def test_multi_value_substitution_depth_1
    parsed = {
      "lms" => {
        "api_url" => "https://example.com",
        "password" => "pass123",
        "api_key" => "key456"
      }
    }
    paths = ["lms.password", "lms.api_key"]

    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    result = simulate_substitution(template, secret_block)

    # Result should be valid YAML with all original values
    final_parsed = YAML.safe_load(result)
    assert_equal "https://example.com", final_parsed["lms"]["api_url"]
    assert_equal "pass123", final_parsed["lms"]["password"]
    assert_equal "key456", final_parsed["lms"]["api_key"]
  end

  def test_multi_value_substitution_depth_2
    parsed = {
      "provider" => {
        "api" => {
          "url" => "https://example.com",
          "password" => "pass123",
          "token" => "token456"
        }
      }
    }
    paths = ["provider.api.password", "provider.api.token"]

    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    result = simulate_substitution(template, secret_block)

    # Result should be valid YAML
    final_parsed = YAML.safe_load(result)
    assert_equal "https://example.com", final_parsed["provider"]["api"]["url"]
    assert_equal "pass123", final_parsed["provider"]["api"]["password"]
    assert_equal "token456", final_parsed["provider"]["api"]["token"]
  end

  def test_multi_value_substitution_with_multiline
    ssh_key = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA123\n-----END RSA PRIVATE KEY-----"
    parsed = {
      "lms" => {
        "api_url" => "https://example.com",
        "ssh_key" => ssh_key,
        "password" => "pass123"
      }
    }
    paths = ["lms.ssh_key", "lms.password"]

    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    result = simulate_substitution(template, secret_block)

    # Result should be valid YAML with multiline preserved
    final_parsed = YAML.safe_load(result)
    assert_equal "https://example.com", final_parsed["lms"]["api_url"]
    assert_equal ssh_key, final_parsed["lms"]["ssh_key"]
    assert_equal "pass123", final_parsed["lms"]["password"]
  end

  def test_multi_value_substitution_depth_0
    parsed = {
      "password" => "pass123",
      "api_key" => "key456",
      "url" => "https://example.com"
    }
    paths = ["password", "api_key"]

    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    result = simulate_substitution(template, secret_block)

    # Result should be valid YAML
    final_parsed = YAML.safe_load(result)
    assert_equal "pass123", final_parsed["password"]
    assert_equal "key456", final_parsed["api_key"]
    assert_equal "https://example.com", final_parsed["url"]
  end

  def test_substitution_preserves_yaml_structure
    parsed = {
      "app" => {
        "servers" => [
          { "host" => "server1", "port" => 8080 },
          { "host" => "server2", "port" => 8081 }
        ],
        "credentials" => {
          "password" => "pass123",
          "api_key" => "key456"
        },
        "settings" => {
          "timeout" => 30,
          "retries" => 3
        }
      }
    }
    paths = ["app.credentials.password", "app.credentials.api_key"]

    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    result = simulate_substitution(template, secret_block)

    # All structure should be preserved
    final_parsed = YAML.safe_load(result)
    assert_equal 2, final_parsed["app"]["servers"].length
    assert_equal "server1", final_parsed["app"]["servers"][0]["host"]
    assert_equal 30, final_parsed["app"]["settings"]["timeout"]
    assert_equal "pass123", final_parsed["app"]["credentials"]["password"]
    assert_equal "key456", final_parsed["app"]["credentials"]["api_key"]
  end

  def test_substitution_with_multiple_multiline_values
    key1 = "-----BEGIN RSA PRIVATE KEY-----\nKEY1\n-----END RSA PRIVATE KEY-----"
    cert = "-----BEGIN CERTIFICATE-----\nCERT\n-----END CERTIFICATE-----"

    parsed = {
      "config" => {
        "url" => "https://example.com",
        "private_key" => key1,
        "certificate" => cert
      }
    }
    paths = ["config.private_key", "config.certificate"]

    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    result = simulate_substitution(template, secret_block)

    # Both multiline values should be preserved
    final_parsed = YAML.safe_load(result)
    assert_equal key1, final_parsed["config"]["private_key"]
    assert_equal cert, final_parsed["config"]["certificate"]
  end

  def test_substitution_with_special_characters
    parsed = {
      "config" => {
        "url" => "https://example.com",
        "password" => "p@ss:w0rd!#$%",
        "api_key" => "key-with-$$$-symbols"
      }
    }
    paths = ["config.password", "config.api_key"]

    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    result = simulate_substitution(template, secret_block)

    # Special characters should be preserved
    final_parsed = YAML.safe_load(result)
    assert_equal "p@ss:w0rd!#$%", final_parsed["config"]["password"]
    assert_equal "key-with-$$$-symbols", final_parsed["config"]["api_key"]
  end

  def test_indentation_correctness_depth_1
    parsed = {
      "lms" => {
        "url" => "https://example.com",
        "password" => "pass",
        "key" => "key"
      }
    }
    paths = ["lms.password", "lms.key"]

    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    # Check that template has $$secret$$ at correct indent (2 spaces for depth 1)
    template_lines = template.split("\n")
    secret_line = template_lines.find { |l| l.include?("$$secret$$") }
    assert secret_line.start_with?("  "), "$$secret$$ should be indented 2 spaces"

    # Check that secret block first line has no indent
    secret_lines = secret_block.split("\n")
    refute secret_lines.first.start_with?(" "), "First line of secret block should not be indented"

    # Substitution should produce valid YAML
    result = simulate_substitution(template, secret_block)
    final_parsed = YAML.safe_load(result)
    assert_equal "pass", final_parsed["lms"]["password"]
  end

  def test_indentation_correctness_depth_2
    parsed = {
      "provider" => {
        "api" => {
          "url" => "https://example.com",
          "password" => "pass",
          "key" => "key"
        }
      }
    }
    paths = ["provider.api.password", "provider.api.key"]

    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    # Check that template has $$secret$$ at correct indent (4 spaces for depth 2)
    template_lines = template.split("\n")
    secret_line = template_lines.find { |l| l.include?("$$secret$$") }
    assert secret_line.start_with?("    "), "$$secret$$ should be indented 4 spaces"

    # Substitution should produce valid YAML
    result = simulate_substitution(template, secret_block)
    final_parsed = YAML.safe_load(result)
    assert_equal "pass", final_parsed["provider"]["api"]["password"]
  end

  def test_substitution_roundtrip_equals_original
    # Test that template + secret_block substitution produces identical YAML to original
    test_cases = [
      {
        "lms" => {
          "url" => "https://example.com",
          "password" => "secret",
          "api_key" => "key123"
        }
      },
      {
        "provider" => {
          "api" => {
            "url" => "https://api.example.com",
            "token" => "token123",
            "secret" => "secret456"
          }
        }
      },
      {
        "config" => {
          "servers" => ["s1", "s2"],
          "password" => "pass",
          "timeout" => 30
        }
      }
    ]

    test_cases.each do |original|
      # Find secret keys (keys named password, token, secret, api_key)
      secret_paths = []
      original.each do |parent_key, parent_val|
        if parent_val.is_a?(Hash)
          parent_val.each do |child_key, _child_val|
            if child_key.match?(/password|token|secret|key/i)
              secret_paths << "#{parent_key}.#{child_key}"
            end
          end
        end
      end

      next if secret_paths.empty?

      template = build_multi_value_template(original, secret_paths)
      secret_block = build_secret_block(original, secret_paths)
      result = simulate_substitution(template, secret_block)

      final_parsed = YAML.safe_load(result)

      # Deep equality check
      assert_equal original, final_parsed,
                   "Roundtrip should produce identical result for: #{original.inspect}"
    end
  end
end
