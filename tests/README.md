# Test Suite for 3PI ISC Migration Tool

Comprehensive test coverage for all migration patterns and edge cases.

## Running Tests

### Run all tests
```bash
ruby tests/run_all_tests.rb
```

### Run specific test file
```bash
ruby tests/test_build_secret_block.rb
ruby tests/test_common_helpers.rb
ruby tests/test_edge_cases.rb
ruby tests/test_template_validation.rb
```

### Run specific test by name
```bash
ruby tests/run_all_tests.rb --name test_multiline_value_with_literal_block_scalar
```

### Run with verbose output
```bash
ruby tests/run_all_tests.rb --verbose
```

## Test Coverage

### `test_build_secret_block.rb`
Tests for the `build_secret_block` function - the core logic for multi-value templates:
- ✅ Single-line values at different depths (0, 1, 2)
- ✅ Multiline values (SSH keys, certificates) with literal block scalars (`|`)
- ✅ Mixed single-line and multiline values
- ✅ Proper indentation for different parent depths
- ✅ Preservation of YAML types (strings, numbers, booleans, null)
- ✅ Special characters and edge cases
- ✅ Multiple multiline values in same config

### `test_common_helpers.rb`
Tests for helper functions in `common.rb`:
- ✅ `deep_dup` - deep duplication of hashes and arrays
- ✅ `looks_like_private_key?` - SSH key detection (RSA, OpenSSH, certificates)
- ✅ `fix_private_key_format` - fixing escaped newlines
- ✅ `to_yaml_with_literal_blocks` - YAML generation with literal scalars
- ✅ `build_single_value_template` - single-value template generation
- ✅ `build_multi_value_template` - multi-value template generation
- ✅ `check_for_ssh_keys` - recursive SSH key discovery
- ✅ `fix_ssh_keys_in_hash!` - in-place SSH key formatting

### `test_edge_cases.rb`
Tests for edge cases and special scenarios:
- ✅ Empty configs and null values
- ✅ Boolean and numeric values
- ✅ Array and nested hash values
- ✅ Special YAML characters (`:`, `@`, `#`, `$`, etc.)
- ✅ Unicode characters and emojis
- ✅ Very long values (10,000+ characters)
- ✅ Multiline values with blank lines and indentation
- ✅ Values that look like YAML
- ✅ Keys with special characters
- ✅ Deeply nested configs (4+ levels)
- ✅ Leading/trailing whitespace preservation
- ✅ Multiple SSH keys in same config
- ✅ SSH keys with metadata (Proc-Type, DEK-Info)
- ✅ Values with dollar signs, quotes, backslashes
- ✅ Mix of all data types in one secret block

### `test_template_validation.rb`
Integration tests that validate template substitution:
- ✅ Single-value template substitution
- ✅ Multi-value template substitution at different depths
- ✅ Substitution with multiline values
- ✅ Preservation of YAML structure (arrays, nested hashes)
- ✅ Multiple multiline values
- ✅ Special characters in substituted values
- ✅ Indentation correctness verification
- ✅ Roundtrip equality (template + secret = original)

## Test Scenarios

### Migration Patterns

#### Single-Value Template
- Simple password field
- Nested password field (2+ levels deep)
- With surrounding non-secret fields
- Edge cases: empty, numeric, special chars

#### Multi-Value Template
- Multiple secrets under same parent (depth 1, 2, 0)
- Mixed single-line and multiline secrets
- All secrets multiline
- With surrounding non-secret fields
- Edge cases: different data types, special characters

#### No Template (Monolithic)
- Cross-parent secrets (covered in edge cases)
- Entire config as secret ref

### Multiline Value Handling
- SSH private keys (RSA, OpenSSH, encrypted)
- Certificates (X.509, PEM format)
- Multi-line text with:
  - Blank lines
  - Internal indentation
  - Special characters
  - Unicode
- Multiple multiline values in same block

### YAML Edge Cases
- All primitive types: string, number, boolean, null
- Complex types: arrays, nested hashes
- Special characters: `:`, `@`, `#`, `$`, `-`, quotes, backslashes
- Unicode and emojis
- Very long strings
- Values that look like YAML syntax
- Keys with special characters
- Empty values and whitespace

### Indentation Correctness
- Depth 0 (top-level): no indent
- Depth 1: 2-space indent on lines 2+
- Depth 2: 4-space indent on lines 2+
- Depth 3+: (depth × 2) space indent

### Roundtrip Validation
Tests verify that:
```
Original YAML → Template + Secret Block → ISC Substitution → Final YAML
```
Produces identical results to the original.

## Test Fixtures

Common test fixtures are available in `TestHelper::Fixtures`:
- `SIMPLE_PASSWORD` - one secret field
- `MULTI_SECRETS` - multiple secrets, same parent
- `SSH_KEY_CONFIG` - config with SSH key
- `MULTI_WITH_MULTILINE` - mixed single/multiline
- `CROSS_PARENT_SECRETS` - different parents
- `NESTED_SECRETS` - depth 2 secrets
- `ARRAY_CONFIG` - with array values
- `HYPHEN_VALUE` - starts with hyphen
- `EMPTY_VALUE` - empty string
- `NUMERIC_SECRET` - numeric pin

## Adding New Tests

1. Create test file: `test_feature_name.rb`
2. Require test helper: `require_relative "test_helper"`
3. Create test class inheriting from `Minitest::Test`
4. Write test methods starting with `test_`
5. Use assertions: `assert`, `assert_equal`, `assert_match`, `refute`, etc.

Example:
```ruby
require_relative "test_helper"

class TestNewFeature < Minitest::Test
  def test_my_new_feature
    # Arrange
    input = { "key" => "value" }

    # Act
    result = my_function(input)

    # Assert
    assert_equal "expected", result
  end
end
```

## CI Integration

To run tests in CI:
```bash
# Add to your CI pipeline
bundle install
ruby tests/run_all_tests.rb
```

## Troubleshooting

### Tests fail with "undefined method"
Make sure you're in the project root and common.rb is loaded:
```bash
cd /path/to/3pi_isc_migration
ruby tests/run_all_tests.rb
```

### Tests timeout
Some tests with very long strings may be slow. Use `--verbose` to see progress:
```bash
ruby tests/run_all_tests.rb --verbose
```

### YAML parsing errors
If tests fail with YAML parsing errors, check:
1. Indentation is correct (use spaces, not tabs)
2. Special characters are properly quoted
3. Multiline values use literal block scalar (`|`)

## Coverage Summary

| Category | Tests | Coverage |
|----------|-------|----------|
| build_secret_block | 14 | All depths, single/multi-line, types |
| Common helpers | 14 | All utility functions |
| Edge cases | 26 | Special chars, types, edge values |
| Template validation | 12 | Roundtrip, substitution, indentation |
| **Total** | **66+** | **Comprehensive** |

## Future Test Additions

Potential areas for additional coverage:
- [ ] Integration tests with mocked ISC commands
- [ ] Migration module tests (single/multi/no template)
- [ ] CSV update tests
- [ ] Report generation tests
- [ ] Permission checking tests
- [ ] Parallel environment fetching tests
- [ ] Error handling and recovery tests
