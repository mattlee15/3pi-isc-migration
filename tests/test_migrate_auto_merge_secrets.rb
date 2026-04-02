# frozen_string_literal: true

require_relative "test_helper"
require_relative "../scripts/migrate_auto_merge_secrets"

# Tests for auto_merge_secrets migration pattern.
# This pattern handles cross-parent secrets by:
# 1. Template: ALL fields + secrets: $$secret$$ at root
# 2. Secret ref: ONLY secret fields with parent structure preserved
# 3. Runtime: configurations/base.rb auto-merges secrets: into base config
class TestMigrateAutoMergeSecrets < Minitest::Test
  # Helper: simulate ISC substitution + runtime merge (what configurations/base.rb does)
  def simulate_runtime_merge(template, secret_value)
    # ISC replaces "  $$secret$$" → "  " + secret_value
    # (Keeps template's 2-space indent, secret value inserted after it)
    substituted = template.gsub("  $$secret$$", "  #{secret_value}")
    template_parsed = YAML.safe_load(substituted)

    # Extract secrets: key
    secrets_block = template_parsed.delete("secrets")
    return template_parsed unless secrets_block.is_a?(Hash)

    # Deep merge secrets into base (simulating configurations/base.rb behavior)
    deep_merge_hash(template_parsed, secrets_block)
  end

  # Deep merge helper (simulates Rails' Hash#deep_merge)
  def deep_merge_hash(base, overrides)
    base.merge(overrides) do |_key, base_val, override_val|
      if base_val.is_a?(Hash) && override_val.is_a?(Hash)
        deep_merge_hash(base_val, override_val)
      else
        override_val
      end
    end
  end
  # Basic cross-parent secrets scenario
  def test_basic_cross_parent_secrets
    parsed = {
      "ncr" => {
        "lms" => {
          "base_url" => "https://api.example.com",
          "username" => "public_user",
          "password" => "secret123"
        }
      },
      "api" => {
        "endpoint" => "https://api2.example.com",
        "api_key" => "key456"
      }
    }

    secret_key_paths = ["ncr.lms.password", "api.api_key"]

    # Build template
    template = MigrateAutoMergeSecrets.build_template(parsed, secret_key_paths)

    # Template should contain non-secret fields only
    assert_match(/base_url: https:\/\/api\.example\.com/, template)
    assert_match(/username: public_user/, template)
    assert_match(/endpoint: https:\/\/api2\.example\.com/, template)

    # Template should NOT contain secret fields
    refute_match(/password:/, template)
    refute_match(/api_key:/, template)

    # Template should have secrets: with $$secret$$ on next line
    assert_match(/secrets:\n  \$\$secret\$\$/, template)

    # Build secret value
    secret_value = MigrateAutoMergeSecrets.build_secret_value(parsed, secret_key_paths)

    # Verify runtime behavior - secret value is only valid after ISC substitution
    merged = simulate_runtime_merge(template, secret_value)

    # Verify the merged result has all secret fields
    assert_equal "secret123", merged.dig("ncr", "lms", "password")
    assert_equal "key456", merged["api"]["api_key"]

    # Verify merged result does NOT contain extra fields in secret portion
    # (template has the non-secret fields)
    assert_equal "https://api.example.com", merged.dig("ncr", "lms", "base_url")
    assert_equal "public_user", merged.dig("ncr", "lms", "username")
    assert_equal "https://api2.example.com", merged.dig("api", "endpoint")

    # Verify runtime behavior (simulate what configurations/base.rb does)
    merged = simulate_runtime_merge(template, secret_value)

    # Final result should have all fields with secrets overriding placeholders
    assert_equal parsed, merged
  end

  # Three-level nesting with cross-parent secrets
  def test_deep_nested_cross_parent_secrets
    parsed = {
      "provider_a" => {
        "credentials" => {
          "auth" => {
            "username" => "user1",
            "password" => "secret1"
          }
        },
        "config" => {
          "timeout" => 30
        }
      },
      "provider_b" => {
        "api" => {
          "key" => "secret2",
          "url" => "https://example.com"
        }
      }
    }

    secret_key_paths = ["provider_a.credentials.auth.password", "provider_b.api.key"]

    template = MigrateAutoMergeSecrets.build_template(parsed, secret_key_paths)
    secret_value = MigrateAutoMergeSecrets.build_secret_value(parsed, secret_key_paths)

    # Verify template has non-secret fields only
    assert_match(/username: user1/, template)
    assert_match(/timeout: 30/, template)
    assert_match(/url: https:\/\/example\.com/, template)
    assert_match(/secrets:\n  \$\$secret\$\$/, template)

    # Verify template does NOT have secret fields
    refute_match(/password:/, template)
    refute_match(/key: secret2/, template)

    # Verify runtime merge
    merged = simulate_runtime_merge(template, secret_value)
    assert_equal parsed, merged
  end

  # SSH private key in one parent, password in another
  def test_ssh_key_cross_parent
    ssh_key = "-----BEGIN OPENSSH PRIVATE KEY-----\nMIIEpAIBAAKCAQEA123\n-----END OPENSSH PRIVATE KEY-----"

    parsed = {
      "sftp" => {
        "host" => "sftp.example.com",
        "port" => 22,
        "username" => "user",
        "private_key" => ssh_key
      },
      "api" => {
        "endpoint" => "https://api.example.com",
        "api_key" => "key123"
      }
    }

    secret_key_paths = ["sftp.private_key", "api.api_key"]

    template = MigrateAutoMergeSecrets.build_template(parsed, secret_key_paths)
    secret_value = MigrateAutoMergeSecrets.build_secret_value(parsed, secret_key_paths)

    # Template should preserve non-secret fields only
    assert_match(/host: sftp\.example\.com/, template)
    assert_match(/port: 22/, template)
    assert_match(/username: user/, template)
    assert_match(/endpoint: https:\/\/api\.example\.com/, template)

    # Template should NOT have secret fields
    refute_match(/private_key:/, template)
    refute_match(/api_key:/, template)

    # Secret value should use literal block scalar for SSH key
    assert_match(/private_key: \|/, secret_value)
    assert_match(/BEGIN OPENSSH PRIVATE KEY/, secret_value)

    # Verify runtime merge preserves SSH key format
    merged = simulate_runtime_merge(template, secret_value)
    assert_equal ssh_key, merged.dig("sftp", "private_key")
    assert_match(/BEGIN OPENSSH PRIVATE KEY/, merged.dig("sftp", "private_key"))
    assert_equal "key123", merged.dig("api", "api_key")
  end

  # Multiple secrets under same parent AND different parents
  def test_mixed_same_and_cross_parent_secrets
    parsed = {
      "auth" => {
        "username" => "admin",
        "password" => "secret1",
        "api_key" => "secret2"  # Two secrets under same parent
      },
      "database" => {
        "host" => "db.example.com",
        "db_password" => "secret3"  # Secret under different parent
      }
    }

    secret_key_paths = ["auth.password", "auth.api_key", "database.db_password"]

    template = MigrateAutoMergeSecrets.build_template(parsed, secret_key_paths)
    secret_value = MigrateAutoMergeSecrets.build_secret_value(parsed, secret_key_paths)

    # Template has non-secret fields only
    assert_match(/username: admin/, template)
    assert_match(/host: db\.example\.com/, template)
    assert_match(/secrets:\n  \$\$secret\$\$/, template)

    # Template does NOT have secret fields
    refute_match(/password:/, template)
    refute_match(/api_key:/, template)
    refute_match(/db_password:/, template)

    # Verify runtime merge
    merged = simulate_runtime_merge(template, secret_value)
    assert_equal parsed, merged
  end

  # Top-level secrets (no parent) with cross-parent secrets
  def test_top_level_and_nested_secrets
    parsed = {
      "global_api_key" => "secret1",  # Top-level secret
      "settings" => {
        "timeout" => 30
      },
      "credentials" => {
        "password" => "secret2"  # Nested secret
      }
    }

    secret_key_paths = ["global_api_key", "credentials.password"]

    template = MigrateAutoMergeSecrets.build_template(parsed, secret_key_paths)
    secret_value = MigrateAutoMergeSecrets.build_secret_value(parsed, secret_key_paths)

    # Template has non-secret fields only
    assert_match(/timeout: 30/, template)
    assert_match(/secrets:\n  \$\$secret\$\$/, template)

    # Template does NOT have secret fields
    refute_match(/global_api_key:/, template)
    refute_match(/password:/, template)

    # Verify runtime merge
    merged = simulate_runtime_merge(template, secret_value)
    assert_equal parsed, merged
  end

  # Special characters in secret values
  def test_special_characters_in_secrets
    parsed = {
      "api_a" => {
        "url" => "https://api.example.com",
        "key" => "abc!@#$%^&*()_+-=[]{}|;:',.<>?/~`"
      },
      "api_b" => {
        "endpoint" => "https://api2.example.com",
        "token" => "Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9"
      }
    }

    secret_key_paths = ["api_a.key", "api_b.token"]

    template = MigrateAutoMergeSecrets.build_template(parsed, secret_key_paths)
    secret_value = MigrateAutoMergeSecrets.build_secret_value(parsed, secret_key_paths)

    # Verify runtime merge preserves special characters
    merged = simulate_runtime_merge(template, secret_value)
    assert_equal parsed, merged
  end

  # Certificate chain (multiline) with cross-parent secrets
  def test_certificate_chain_cross_parent
    cert_chain = <<~CERTS.chomp
      -----BEGIN CERTIFICATE-----
      MIID1TCCAr2gAwIBAgIUXxxxxxxxxxxxxxxxxxxxxxxxxxxxxxEwDQYJ
      -----END CERTIFICATE-----
      -----BEGIN CERTIFICATE-----
      MIID2TCCAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx2wDQYJ
      -----END CERTIFICATE-----
    CERTS

    parsed = {
      "ssl" => {
        "enabled" => true,
        "certificate_chain" => cert_chain
      },
      "auth" => {
        "username" => "admin",
        "password" => "secret123"
      }
    }

    secret_key_paths = ["ssl.certificate_chain", "auth.password"]

    template = MigrateAutoMergeSecrets.build_template(parsed, secret_key_paths)
    secret_value = MigrateAutoMergeSecrets.build_secret_value(parsed, secret_key_paths)

    # Certificate chain should use literal block scalar
    assert_match(/certificate_chain: \|/, secret_value)
    assert_match(/BEGIN CERTIFICATE/, secret_value)

    # Verify runtime merge
    merged = simulate_runtime_merge(template, secret_value)
    assert_equal cert_chain, merged.dig("ssl", "certificate_chain")
    assert_equal 2, merged.dig("ssl", "certificate_chain").scan(/BEGIN CERTIFICATE/).count
    assert_equal "secret123", merged.dig("auth", "password")
  end

  # Array values in config (edge case)
  def test_config_with_arrays
    parsed = {
      "endpoints" => [
        "https://api1.example.com",
        "https://api2.example.com"
      ],
      "credentials" => {
        "api_key" => "secret123"
      }
    }

    secret_key_paths = ["credentials.api_key"]

    template = MigrateAutoMergeSecrets.build_template(parsed, secret_key_paths)
    secret_value = MigrateAutoMergeSecrets.build_secret_value(parsed, secret_key_paths)

    # Array should be preserved in template
    template_only = template.gsub("secrets:\n  $$secret$$\n", "")
    template_parsed = YAML.safe_load(template_only)
    assert_equal parsed["endpoints"], template_parsed["endpoints"]

    # Verify runtime merge
    merged = simulate_runtime_merge(template, secret_value)
    assert_equal parsed, merged
  end

  # Empty parent keys (edge case)
  def test_secret_with_empty_parent
    parsed = {
      "api" => {
        "credentials" => {}
      },
      "auth" => {
        "password" => "secret123"
      }
    }

    secret_key_paths = ["auth.password"]

    template = MigrateAutoMergeSecrets.build_template(parsed, secret_key_paths)
    secret_value = MigrateAutoMergeSecrets.build_secret_value(parsed, secret_key_paths)

    # Empty parent should be preserved
    template_only = template.gsub("secrets:\n  $$secret$$\n", "")
    template_parsed = YAML.safe_load(template_only)
    assert_equal({}, template_parsed.dig("api", "credentials"))

    # Verify runtime merge
    merged = simulate_runtime_merge(template, secret_value)
    assert_equal parsed, merged
  end

  # Four-level nesting: secret at deepest level
  def test_four_level_nesting_secret_at_bottom
    parsed = {
      "level1" => {
        "level2" => {
          "level3" => {
            "level4_secret" => "secret_value",
            "level4_public" => "public_value"
          },
          "level3_public" => "another_public"
        }
      }
    }

    secret_key_paths = ["level1.level2.level3.level4_secret"]

    template = MigrateAutoMergeSecrets.build_template(parsed, secret_key_paths)
    secret_value = MigrateAutoMergeSecrets.build_secret_value(parsed, secret_key_paths)

    # Template should preserve all non-secret fields
    assert_match(/level4_public: public_value/, template)
    assert_match(/level3_public: another_public/, template)
    assert_match(/secrets:\n  \$\$secret\$\$/, template)

    # Template should NOT have secret field
    refute_match(/level4_secret:/, template)

    # Verify runtime merge
    merged = simulate_runtime_merge(template, secret_value)
    assert_equal parsed, merged
  end

  # Four-level nesting: secret at level 4 is only child of level 3
  def test_four_level_nesting_secret_only_child
    parsed = {
      "level1" => {
        "level2" => {
          "level3_with_secret" => {
            "level4_secret" => "secret_value"
          },
          "level3_public" => {
            "level4_public" => "public_value"
          }
        }
      }
    }

    secret_key_paths = ["level1.level2.level3_with_secret.level4_secret"]

    template = MigrateAutoMergeSecrets.build_template(parsed, secret_key_paths)
    secret_value = MigrateAutoMergeSecrets.build_secret_value(parsed, secret_key_paths)

    # Template should have the public branch
    assert_match(/level4_public: public_value/, template)
    assert_match(/secrets:\n  \$\$secret\$\$/, template)

    # Template should NOT have level3_with_secret at all (empty after removing secret)
    refute_match(/level3_with_secret:/, template)
    refute_match(/level4_secret:/, template)

    # Verify runtime merge
    merged = simulate_runtime_merge(template, secret_value)
    assert_equal parsed, merged
  end

  # Four-level nesting: secrets at multiple levels in same branch
  def test_four_level_nesting_secrets_at_multiple_levels
    parsed = {
      "level1" => {
        "level2" => {
          "level2_secret" => "secret_at_2",
          "level3" => {
            "level3_secret" => "secret_at_3",
            "level4" => {
              "level4_secret" => "secret_at_4",
              "level4_public" => "public_value"
            }
          }
        }
      }
    }

    secret_key_paths = [
      "level1.level2.level2_secret",
      "level1.level2.level3.level3_secret",
      "level1.level2.level3.level4.level4_secret"
    ]

    template = MigrateAutoMergeSecrets.build_template(parsed, secret_key_paths)
    secret_value = MigrateAutoMergeSecrets.build_secret_value(parsed, secret_key_paths)

    # Template should only have public value
    assert_match(/level4_public: public_value/, template)
    assert_match(/secrets:\n  \$\$secret\$\$/, template)

    # Template should NOT have any secret fields
    refute_match(/level2_secret:/, template)
    refute_match(/level3_secret:/, template)
    refute_match(/level4_secret:/, template)

    # Verify runtime merge
    merged = simulate_runtime_merge(template, secret_value)
    assert_equal parsed, merged
  end

  # Four-level nesting: multiple secrets in different branches
  def test_four_level_nesting_multiple_branches
    parsed = {
      "provider_a" => {
        "region_us" => {
          "datacenter_east" => {
            "api_key" => "secret_east",
            "endpoint" => "https://east.example.com"
          },
          "datacenter_west" => {
            "api_key" => "secret_west",
            "endpoint" => "https://west.example.com"
          }
        }
      },
      "provider_b" => {
        "region_eu" => {
          "datacenter_london" => {
            "token" => "secret_london",
            "url" => "https://london.example.com"
          }
        }
      }
    }

    secret_key_paths = [
      "provider_a.region_us.datacenter_east.api_key",
      "provider_a.region_us.datacenter_west.api_key",
      "provider_b.region_eu.datacenter_london.token"
    ]

    template = MigrateAutoMergeSecrets.build_template(parsed, secret_key_paths)
    secret_value = MigrateAutoMergeSecrets.build_secret_value(parsed, secret_key_paths)

    # Template should preserve all non-secret fields
    assert_match(/endpoint: https:\/\/east\.example\.com/, template)
    assert_match(/endpoint: https:\/\/west\.example\.com/, template)
    assert_match(/url: https:\/\/london\.example\.com/, template)
    assert_match(/secrets:\n  \$\$secret\$\$/, template)

    # Template should NOT have secret fields
    refute_match(/api_key:/, template)
    refute_match(/token:/, template)

    # Verify runtime merge
    merged = simulate_runtime_merge(template, secret_value)
    assert_equal parsed, merged
  end

  # Edge case: secret is the only child of a parent
  def test_secret_only_child_of_parent
    parsed = {
      "regular" => "public_value",
      "nested" => {
        "timeout" => 1,
        "another_key" => "another_secret"
      },
      "second_nested" => {
        "signature" => "signature_value"  # Only child under second_nested
      },
      "test_key" => "secret_value"
    }

    secret_key_paths = ["nested.another_key", "second_nested.signature", "test_key"]

    template = MigrateAutoMergeSecrets.build_template(parsed, secret_key_paths)
    secret_value = MigrateAutoMergeSecrets.build_secret_value(parsed, secret_key_paths)

    # Template should have non-secret fields only
    assert_match(/regular: public_value/, template)
    assert_match(/timeout: 1/, template)
    assert_match(/secrets:\n  \$\$secret\$\$/, template)

    # Template should NOT have secret fields
    refute_match(/another_key:/, template)
    refute_match(/signature:/, template)
    refute_match(/test_key:/, template)

    # Template should NOT have empty parent hash for second_nested
    refute_match(/second_nested: \{\}/, template)
    refute_match(/second_nested:\s*$/, template)  # Also check for empty with newline

    # Verify runtime merge
    merged = simulate_runtime_merge(template, secret_value)
    assert_equal parsed, merged
  end

  # Real-world scenario: NCR LMS config with cross-parent secrets
  def test_real_world_ncr_lms
    parsed = {
      "retailer" => "test_retailer",
      "ncr" => {
        "lms" => {
          "base_url" => "https://webservices.example.com",
          "app_id" => 127,
          "client_id" => "TestUser",
          "secret_key" => "actual_secret_key_value",
          "uat" => {
            "base_url" => "https://webservices.example.com",
            "app_id" => 150,
            "client_id" => "TestUATUser",
            "secret_key" => "uat_secret_key_value"
          }
        }
      },
      "partner_ingestion" => {
        "partner_id" => 517,
        "api_key" => "partner_api_key"
      }
    }

    secret_key_paths = [
      "ncr.lms.secret_key",
      "ncr.lms.uat.secret_key",
      "partner_ingestion.api_key"
    ]

    template = MigrateAutoMergeSecrets.build_template(parsed, secret_key_paths)
    secret_value = MigrateAutoMergeSecrets.build_secret_value(parsed, secret_key_paths)

    # Template should preserve all non-secret fields
    assert_match(/retailer: test_retailer/, template)
    assert_match(/base_url: https:\/\/webservices\.example\.com/, template)
    assert_match(/app_id: 127/, template)
    assert_match(/client_id: TestUser/, template)
    assert_match(/partner_id: 517/, template)
    assert_match(/secrets:\n  \$\$secret\$\$/, template)

    # Template should NOT have secret fields
    refute_match(/secret_key:/, template)
    refute_match(/api_key:/, template)

    # Verify runtime merge produces correct result
    merged = simulate_runtime_merge(template, secret_value)
    assert_equal parsed, merged
  end
end
