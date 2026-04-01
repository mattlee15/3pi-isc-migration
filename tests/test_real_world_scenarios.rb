# frozen_string_literal: true

require_relative "test_helper"

# Tests for real-world migration scenarios based on actual 3PI configs
class TestRealWorldScenarios < Minitest::Test
  # Scenario: Loyalty card config with simple password
  def test_loyalty_card_simple_auth
    parsed = {
      "lms" => {
        "api_url" => "https://loyalty.partner.com/api",
        "authenticate_password" => "partner_secret_key_2024"
      }
    }

    # Single-value template: password only
    template = build_single_value_template(parsed, "lms.authenticate_password")
    assert_match(/authenticate_password: \$\$secret\$\$/, template)
    assert_match(/api_url: https:\/\/loyalty\.partner\.com/, template)

    # Verify substitution works
    result = template.gsub("$$secret$$", "partner_secret_key_2024")
    final = YAML.safe_load(result)
    assert_equal parsed, final
  end

  # Scenario: Offers config with multiple API credentials
  def test_offers_multi_credential
    parsed = {
      "lms" => {
        "api_url" => "https://offers.partner.com",
        "api_version" => "v2",
        "client_id" => "client_abc123",
        "client_secret" => "secret_xyz789",
        "api_key" => "key_def456"
      }
    }

    # Multi-value template: client_secret and api_key
    paths = ["lms.client_secret", "lms.api_key"]
    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    # Template should keep non-secrets
    assert_match(/api_url:/, template)
    assert_match(/client_id:/, template)

    # Template should remove secrets
    refute_match(/client_secret:/, template)
    refute_match(/api_key:/, template)

    # Verify substitution
    result = template.gsub("$$secret$$", secret_block)
    final = YAML.safe_load(result)
    assert_equal parsed, final
  end

  # Scenario: Loyalty points with SSH key authentication
  def test_loyalty_points_ssh_auth
    ssh_key = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA123\n-----END RSA PRIVATE KEY-----"

    parsed = {
      "sftp" => {
        "host" => "sftp.partner.com",
        "port" => 22,
        "username" => "partner_user",
        "private_key" => ssh_key
      }
    }

    # For multiline values, should use multi-value template
    # Single-value template wouldn't handle multiline properly
    paths = ["sftp.private_key"]
    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    # SSH key should use literal block scalar
    assert_match(/private_key: \|[-]?/, secret_block)

    # Verify substitution preserves SSH key format
    result = template.gsub("$$secret$$", secret_block)
    final = YAML.safe_load(result)
    assert_equal ssh_key, final["sftp"]["private_key"]
    assert_match(/BEGIN RSA PRIVATE KEY/, final["sftp"]["private_key"])
  end

  # Scenario: Multi-value with SSH key (should use multi-value pattern)
  def test_multi_value_with_ssh_key
    ssh_key = "-----BEGIN RSA PRIVATE KEY-----\nKEY_DATA\n-----END RSA PRIVATE KEY-----"

    parsed = {
      "sftp" => {
        "host" => "sftp.partner.com",
        "username" => "user",
        "password" => "pass123",
        "private_key" => ssh_key
      }
    }

    paths = ["sftp.password", "sftp.private_key"]
    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    # Secret block should use literal block scalar for SSH key
    assert_match(/private_key: \|/, secret_block)
    assert_match(/password: pass123/, secret_block)

    # Verify full substitution
    result = template.gsub("$$secret$$", secret_block)
    final = YAML.safe_load(result)
    assert_equal parsed, final
  end

  # Scenario: App Card SFX nested config (depth 2)
  def test_app_card_sfx_nested
    parsed = {
      "app_card_sfx" => {
        "api" => {
          "base_url" => "https://api.appcard.com",
          "version" => "1.0",
          "auth_token" => "Bearer_token_xyz",
          "signature_key" => "signature_abc123"
        }
      }
    }

    paths = ["app_card_sfx.api.auth_token", "app_card_sfx.api.signature_key"]
    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    # Check proper indentation for depth 2
    secret_lines = secret_block.split("\n")
    assert_equal "auth_token: Bearer_token_xyz", secret_lines[0]
    assert secret_lines[1].start_with?("    "), "Line 2 should have 4-space indent (depth 2)"

    # Verify substitution
    result = template.gsub("$$secret$$", secret_block)
    final = YAML.safe_load(result)
    assert_equal parsed, final
  end

  # Scenario: Config with certificate chain (multiple certs)
  def test_config_with_certificate_chain
    cert_chain = <<~CERTS.chomp
      -----BEGIN CERTIFICATE-----
      MIID1TCCAr2gAwIBAgIUXxxxxxxxxxxxxxxxxxxxxxxxxxxxxxEwDQYJ
      KoZIhvcNAQELBQAwejELMAkGA1UEBhMCVVMxEzARBgNVBAgMCkNhbGlmb3JuaWEx
      -----END CERTIFICATE-----
      -----BEGIN CERTIFICATE-----
      MIID2TCCAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx2wDQYJ
      KoZIhvcNAQELBQAwejELMAkGA1UEBhMCVVMxEzARBgNVBAgMCkNhbGlmb3JuaWEx
      -----END CERTIFICATE-----
    CERTS

    parsed = {
      "ssl" => {
        "enabled" => true,
        "certificate_chain" => cert_chain,
        "private_key_password" => "key_password_123"
      }
    }

    paths = ["ssl.certificate_chain", "ssl.private_key_password"]
    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    # Certificate chain should use literal block scalar
    assert_match(/certificate_chain: \|[-]?/, secret_block)

    # Verify full content preserved via substitution
    result = template.gsub("$$secret$$", secret_block)
    parsed_back = YAML.safe_load(result)
    assert_equal cert_chain, parsed_back["ssl"]["certificate_chain"]
    assert_includes parsed_back["ssl"]["certificate_chain"], "BEGIN CERTIFICATE"
    assert_equal 2, parsed_back["ssl"]["certificate_chain"].scan(/BEGIN CERTIFICATE/).count
  end

  # Scenario: OAuth2 credentials (common pattern)
  def test_oauth2_credentials
    parsed = {
      "oauth2" => {
        "provider" => "auth0",
        "client_id" => "client_abc123",
        "client_secret" => "secret_xyz789_very_long_base64_encoded_string",
        "token_url" => "https://auth.partner.com/oauth/token",
        "scope" => "read write"
      }
    }

    paths = ["oauth2.client_secret"]
    template = build_single_value_template(parsed, paths[0])

    # All non-secrets preserved
    assert_match(/provider: auth0/, template)
    assert_match(/client_id: client_abc123/, template)
    assert_match(/client_secret: \$\$secret\$\$/, template)

    # Verify substitution
    result = template.gsub("$$secret$$", parsed["oauth2"]["client_secret"])
    final = YAML.safe_load(result)
    assert_equal parsed, final
  end

  # Scenario: AWS credentials with special characters
  def test_aws_credentials_special_chars
    parsed = {
      "aws" => {
        "region" => "us-west-2",
        "access_key_id" => "AKIAIOSFODNN7EXAMPLE",
        "secret_access_key" => "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
      }
    }

    paths = ["aws.access_key_id", "aws.secret_access_key"]
    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    # Special characters (/) should be preserved
    assert_includes secret_block, "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

    # Verify substitution
    result = template.gsub("$$secret$$", secret_block)
    final = YAML.safe_load(result)
    assert_equal parsed, final
  end

  # Scenario: Webhook signature verification
  def test_webhook_signature_config
    parsed = {
      "webhook" => {
        "url" => "https://partner.com/webhooks",
        "enabled" => true,
        "signature_algorithm" => "HMAC-SHA256",
        "signature_secret" => "whsec_abcdef1234567890",
        "timeout_seconds" => 30
      }
    }

    template = build_single_value_template(parsed, "webhook.signature_secret")

    # Verify all fields preserved
    assert_match(/signature_algorithm: HMAC-SHA256/, template)
    assert_match(/timeout_seconds: 30/, template)
    assert_match(/signature_secret: \$\$secret\$\$/, template)
  end

  # Scenario: Database credentials
  def test_database_credentials
    parsed = {
      "database" => {
        "host" => "db.partner.com",
        "port" => 5432,
        "database" => "partner_db",
        "username" => "db_user",
        "password" => 'db_p@ssw0rd!#$',
        "ssl_mode" => "require",
        "connection_timeout" => 10
      }
    }

    template = build_single_value_template(parsed, "database.password")

    # Special characters in password
    result = template.gsub("$$secret$$", 'db_p@ssw0rd!#$')
    final = YAML.safe_load(result)
    assert_equal 'db_p@ssw0rd!#$', final["database"]["password"]
  end

  # Scenario: JWT signing with multiline private key
  def test_jwt_signing_config
    private_key = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgk\n-----END PRIVATE KEY-----"

    parsed = {
      "jwt" => {
        "algorithm" => "RS256",
        "private_key" => private_key,
        "issuer" => "partner.com",
        "expiration_seconds" => 3600
      }
    }

    # For multiline private keys, use multi-value template
    paths = ["jwt.private_key"]
    template = build_multi_value_template(parsed, paths)
    secret_block = build_secret_block(parsed, paths)

    # Verify multiline preserved
    result = template.gsub("$$secret$$", secret_block)
    final = YAML.safe_load(result)
    assert_equal private_key, final["jwt"]["private_key"]
    assert_includes final["jwt"]["private_key"], "BEGIN PRIVATE KEY"
  end

  # Scenario: API rate limiting config (no secrets, should use no_secret pattern)
  def test_config_without_secrets
    parsed = {
      "rate_limiting" => {
        "enabled" => true,
        "requests_per_minute" => 60,
        "burst_size" => 10,
        "retry_after_seconds" => 60
      }
    }

    # This would use no_secret pattern in main.rb
    # Verify YAML generation works
    yaml_output = to_yaml_with_literal_blocks(parsed)

    refute_match(/\$\$secret\$\$/, yaml_output)
    assert_match(/enabled: true/, yaml_output)
    assert_match(/requests_per_minute: 60/, yaml_output)
  end

  # Scenario: Mixed array and hash config with secrets
  def test_complex_nested_structure
    parsed = {
      "integration" => {
        "name" => "partner_integration",
        "endpoints" => [
          {
            "type" => "auth",
            "url" => "https://auth.partner.com",
            "credentials" => {
              "username" => "user",
              "password" => "pass123"
            }
          },
          {
            "type" => "api",
            "url" => "https://api.partner.com",
            "credentials" => {
              "api_key" => "key456"
            }
          }
        ]
      }
    }

    # This would be no_template pattern due to cross-structure secrets
    # But we can verify YAML generation preserves structure
    yaml_output = to_yaml_with_literal_blocks(parsed)
    reparsed = YAML.safe_load(yaml_output)

    assert_equal parsed, reparsed
    assert_equal 2, reparsed["integration"]["endpoints"].length
    assert_equal "pass123", reparsed["integration"]["endpoints"][0]["credentials"]["password"]
  end

  # Scenario: Config with environment-specific overrides
  def test_environment_specific_config
    parsed = {
      "api" => {
        "base_url" => "https://staging.partner.com",
        "timeout" => 30,
        "api_key" => "staging_key_abc123",
        "debug_mode" => true
      }
    }

    template = build_single_value_template(parsed, "api.api_key")

    # Environment-specific values preserved
    assert_match(/base_url: https:\/\/staging\.partner\.com/, template)
    assert_match(/debug_mode: true/, template)
    assert_match(/api_key: \$\$secret\$\$/, template)
  end

  # Scenario: Legacy config with inline YAML as string
  def test_legacy_inline_yaml_string
    # Some legacy configs store YAML as a string value
    yaml_string = "username: admin\npassword: secret123\nenabled: true"

    parsed = {
      "legacy_config" => yaml_string
    }

    # This would typically be a no_template scenario
    yaml_output = to_yaml_with_literal_blocks(parsed)
    reparsed = YAML.safe_load(yaml_output)

    # The YAML string should be preserved as a string (not parsed)
    assert_equal yaml_string, reparsed["legacy_config"]
  end
end
