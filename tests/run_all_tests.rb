#!/usr/bin/env ruby
# frozen_string_literal: true

# Run all tests in the tests directory
#
# Usage:
#   ruby tests/run_all_tests.rb
#   ruby tests/run_all_tests.rb --verbose
#   ruby tests/run_all_tests.rb --name test_specific_test_name

require "minitest/autorun"

# Load all test files
test_files = Dir[File.join(__dir__, "test_*.rb")]
test_files.each { |file| require file }

puts "\n" + "=" * 80
puts "Running #{test_files.length} test files"
puts "=" * 80 + "\n"
