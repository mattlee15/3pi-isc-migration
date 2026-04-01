# frozen_string_literal: true

# Test helper for 3pi ISC migration tests
#
# Provides utilities for mocking ISC commands and shared test fixtures.

require "minitest/autorun"
require "yaml"
require "stringio"
require_relative "../scripts/common"

module TestHelper
  # Capture stdout during a block
  def capture_stdout
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end

  # Mock ISC command responses
  class IscMock
    attr_reader :calls

    def initialize
      @calls = []
      @responses = {}
    end

    def add_response(command_pattern, stdout: "", stderr: "", success: true)
      @responses[command_pattern] = { stdout: stdout, stderr: stderr, success: success }
    end

    def call(*args)
      @calls << args
      key = args.join(" ")

      # Match against patterns
      response = @responses.find { |pattern, _| key.include?(pattern) }&.last
      response ||= { stdout: "", stderr: "Command not mocked: #{key}", success: false }

      [response[:stdout], response[:stderr], double_status(response[:success])]
    end

    def clear
      @calls.clear
      @responses.clear
    end

    private

    def double_status(success)
      status = Minitest::Mock.new
      status.expect(:success?, success)
      status
    end
  end

  # Sample test fixtures
  module Fixtures
    # Simple config with one secret field
    SIMPLE_PASSWORD = {
      "lms" => {
        "api_url" => "https://example.com",
        "authenticate_password" => "super_secret_123"
      }
    }

    # Config with multiple secret fields under same parent
    MULTI_SECRETS = {
      "lms" => {
        "api_url" => "https://example.com",
        "authenticate_password" => "password_123",
        "api_key" => "key_456",
        "token" => "token_789"
      }
    }

    # Config with SSH private key (multiline)
    SSH_KEY_CONFIG = {
      "lms" => {
        "api_url" => "https://example.com",
        "ssh_key" => "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA1234567890abcdef\nABCDEF1234567890abcdef1234567890\n-----END RSA PRIVATE KEY-----"
      }
    }

    # Config with multiple fields including multiline
    MULTI_WITH_MULTILINE = {
      "lms" => {
        "api_url" => "https://example.com",
        "password" => "simple_password",
        "certificate" => "-----BEGIN CERTIFICATE-----\nMIIDXTCCAkWgAwIBAgIJAKZ\n-----END CERTIFICATE-----"
      }
    }

    # Config with secrets at different parent levels (no template scenario)
    CROSS_PARENT_SECRETS = {
      "lms" => {
        "authenticate_password" => "password_123"
      },
      "api" => {
        "api_key" => "key_456"
      }
    }

    # Nested config (depth 2)
    NESTED_SECRETS = {
      "provider" => {
        "api" => {
          "password" => "nested_password",
          "token" => "nested_token"
        }
      }
    }

    # Config with array values
    ARRAY_CONFIG = {
      "settings" => {
        "servers" => ["server1", "server2"],
        "api_key" => "secret_key"
      }
    }

    # Edge case: value starts with hyphen
    HYPHEN_VALUE = {
      "config" => {
        "password" => "-starts-with-hyphen"
      }
    }

    # Edge case: empty string value
    EMPTY_VALUE = {
      "config" => {
        "password" => ""
      }
    }

    # Edge case: numeric value
    NUMERIC_SECRET = {
      "config" => {
        "pin" => 123456
      }
    }
  end

  # Helper to create a temporary test environment
  def with_test_env
    old_env = ENV.to_h
    yield
  ensure
    ENV.replace(old_env)
  end
end

# Minitest configuration
class Minitest::Test
  include TestHelper
end
