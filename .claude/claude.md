# Claude Code Assistant Guide - ISC 3PI Migration Tool

## Project Overview

**Purpose**: Migrate third-party loyalty integration configs from monolithic secrets to templated secrets using ISC (Instacart Service Control).

**Key Problem**: Old configs store entire YAML blocks with embedded secrets. New approach uses `$$secret$$` template substitution with separate secret refs.

**Services**: Loyalty Card, Offers, Loyalty Points

---

## Critical Rules

### Auto-Merge Secrets Pattern - RECOMMENDED
✅ **Now using auto-merge secrets pattern** - see [PR #763917](https://github.com/instacart/carrot/pull/763917) and [wiki](https://instacart.atlassian.net/wiki/spaces/ENTSO/pages/6481412238)
- Replaces legacy `no_template` pattern for cross-parent secrets
- **Template**: ALL fields + `secrets: $$secret$$` at root
- **Secret ref**: ONLY secret fields with parent structure preserved
- **Runtime**: `configurations/base.rb` auto-merges `secrets:` into base config
- **Benefits**: Clean separation, single ISC config, zero plugin changes

### ISC CLI Restrictions
⚠️ **NEVER run `isc secretref create/update` or `isc conf set` commands via bash/shell execution in AI agent mode.**
- These commands detect AI contexts and WILL fail
- All migration scripts MUST be run by user directly in terminal
- Only read-only ISC commands work in agent mode

### Safety Checks
- ✅ Always verify exact name matching (not substring) before deleting secret refs
- ✅ Check for linked configs before deletion
- ✅ Use `find_conf` (not `read_conf`) to check if config exists in specific service (prevents false positives from cross-service fallback)
- ✅ All destructive operations must log to `report.txt`

---

## ISC Limitations

### Permission-Related
1. **Limited list access**: `isc secretref list` only returns ~25 refs (those you have list perms for), even though hundreds exist
   - ✅ Solution: Query by exact name: `isc secretref list -n "EXACT_NAME"`
2. **Permission denied = Not found**: ISC returns "not found" when you lack permissions (indistinguishable from truly missing)
3. **No self-service perms**: Must use ISC web UI to request/view/manage permissions
4. **Delete requires special perm**: Success doesn't mean cleanup will work — need separate delete permission

### CLI Behavior
5. **Cross-service fallback**: `isc conf get` searches other services if not found → false positives
   - ✅ Solution: Use `find_conf` (which uses `isc conf search`) first to verify specific service
6. **AI agent blocking**: Write operations (`create`, `update`, `set`) blocked in AI mode
7. **In-use refs protected**: Cannot delete secret refs with linked configs (safety feature)

---

## File Structure

```
3pi_isc_migration/
├── README.md                    # User documentation
├── claude.md                    # This file - AI assistant guide
├── Gemfile                      # Ruby dependencies
├── report.txt                   # Migration log (auto-appended)
├── request_permissions_status.csv  # Permission tracking
├── configs/                     # CSV files tracking migration status
│   ├── loyalty_card.csv
│   ├── loyalty_points.csv
│   └── offers.csv
└── scripts/
    ├── main.rb                  # Interactive UI - entry point
    ├── common.rb                # Shared ISC helpers
    ├── migrate_single_value_template.rb
    ├── migrate_multi_value_template.rb
    ├── migrate_auto_merge_secrets.rb   # RECOMMENDED for cross-parent secrets
    ├── migrate_no_secret.rb
    └── test_*.rb                # Test scripts
```

---

## Key Concepts

### ISC Components
- **Conf**: Configuration YAML stored in ISC, linked to a service pattern (e.g., `rpc.integrations.integrations`)
- **Secret Ref**: Secret value stored separately, referenced by name
- **Template**: Conf with `$$secret$$` placeholder that gets substituted at runtime
- **Service Pattern**: Controls which services can access a conf (e.g., `*.integrations.integrations` = all integration services)

### Migration Patterns

| Pattern | Use Case | Example |
|---------|----------|---------|
| **single_value_template** | 1 secret field (non-multiline) | `password: $$secret$$` |
| **multi_value_template** | 2+ fields under same parent, OR 1 multiline field | Standalone `$$secret$$` block with YAML literal scalar (`\|`) for multiline |
| **auto_merge_secrets** | **Fields under different parents (RECOMMENDED)** | Template: ALL fields + `secrets: $$secret$$`; Secret ref: only secrets with parent structure |
| **no_secret** | No secrets detected | Plain YAML config (no secret ref) |

### Multiline Values (SSH Keys, Certs)
- ⚠️ Single-value templates CANNOT handle multiline → auto-upgrade to multi-value
- Uses YAML literal block scalar syntax: `key: \|\n  -----BEGIN...`
- Must use `--file` flag (not `--value`) for `isc secretref create`

---

## Common Operations

### Read a Config
```ruby
# WRONG - uses cross-service fallback, can give false positives
raw = read_conf(name, service: service, environment: env)

# RIGHT - checks specific service first
conf_meta = find_conf(name, service: service, environment: env)
return nil unless conf_meta
raw = read_conf(name, service: service, environment: env)
```

### Check for Linked Configs
```ruby
linked_confs = find_linked_confs_for_secret_ref(secret_ref_name, environment: env)
# Returns array with: [{"key" => "env/...", "file" => "env/...", "service" => "rpc..."}]
```

### Secret Ref Deduplication
```ruby
# Finds existing ref with same SHA256 value hash
existing = find_secret_ref_by_value(value, environment: environment)
# Reuse if found, otherwise create new
```

### Secret Ref Naming and Versioning
When re-migrating a config and the existing secret ref has multiple linked configs:
- Script generates unique name by appending `_V2`, `_V3`, etc.
- Tries incrementing versions until finding an unused name
- Fallback to timestamp if all versions exist (unlikely)
```ruby
# Example: HERITAGE_GROCERS_GROUP_SECRETS exists with 3 linked configs
# → Creates: HERITAGE_GROCERS_GROUP_SECRETS_V2
```

---

## Code Patterns

### Parallel Environment Fetching
```ruby
fetched = parallel_env_fetch(conf_name)
# Returns: { "production" => {raw:, dest_exists:, dest_raw:, detail:}, ... }
```

### Spinner for Long Operations
```ruby
spinner = TTY::Spinner.new("[:spinner] Message...", format: :dots)
spinner.auto_spin
result = do_work()
spinner.success("(done)")  # or spinner.error("(failed)")
```

### Table Display
```ruby
table = TTY::Table.new(
  header: ["Col1", "Col2"],
  rows: [["val1", "val2"], ...]
)
puts table.render(:unicode, padding: [0, 1], alignments: [:left, :left])
```

---

## CSV Structure

### Columns
- `Config Name` - Full config name with `env/` prefix
- `RPC Production/Staging/Development` - "Yes" if exists in source service
- `Migrated to Production/Staging/Development` - "Yes"/"No"/"N/A"

### Update After Migration
```ruby
mark_migrated_in_csv!(csv_path, conf_name, environment)
```

---

## Helper Functions (common.rb)

### Most Used
- `find_conf(name, service:, environment:)` - Check if conf exists in service
- `read_conf(name, service:, environment:)` - Get conf YAML
- `find_secret_ref(name, environment:)` - Find secret ref by name
- `find_secret_ref_by_value(value, environment:)` - Find by SHA256 hash
- `find_linked_confs_for_secret_ref(name, environment:)` - Get linked configs
- `create_or_find_secret_ref(name, value, principals:, environment:)` - Create or reuse
- `delete_secret_ref(name, environment:)` - Delete (returns [success, stderr])
- `list_all_secret_refs(environment:)` - Get all refs in environment

### Template Building
- `build_single_value_template(parsed, secret_key_path)`
- `build_multi_value_template(parsed, secret_key_paths)`
- `build_secret_block(parsed, secret_key_paths)` - Pre-indented YAML block

### SSH Key Detection
- `looks_like_private_key?(value)` - Detects `-----BEGIN ... PRIVATE KEY-----`
- `to_yaml_with_literal_blocks(hash)` - Formats with `|` for multiline, auto-quotes URLs

### URL Quoting (Automatic)
Both when reading and generating configs:
- `sanitize_yaml()` - Quotes URLs when reading existing configs from ISC
- `to_yaml_with_literal_blocks()` - Quotes URLs when generating new configs
- Prevents YAML parsing errors from unquoted `https://` or `http://` values
- Example: `base_url: 'https://api.example.com'` (single-quoted)
- Also quotes malformed special chars (e.g., `,abc` or `[test`) but leaves valid arrays intact

---

## Common Tasks

### Add New Service Type
1. Add CSV to `configs/` directory

### Debug Migration Failures
1. Check `report.txt` for error details
2. Look for "Permission denied" → add to `request_permissions_status.csv`
3. Check source vs dest exists → use correct labels in status display

### Add New Secret Keyword
Update line ~95 in `main.rb`:
```ruby
likely_secret = key.match?(/secret|password|key|token|signature/i)
```

---

## Testing

### Automated Test Suite
```bash
# Run full test suite (all patterns)
ruby tests/run_all_tests.rb
# Current: 100 runs, 489 assertions, 0 failures

# Run specific pattern tests
ruby tests/test_migrate_auto_merge_secrets.rb     # 15 comprehensive tests
ruby tests/test_migrate_single_value_template.rb
ruby tests/test_migrate_multi_value_template.rb
```

### Auto-Merge Secrets Test Coverage
The `test_migrate_auto_merge_secrets.rb` suite includes 15 comprehensive tests:

**Basic scenarios:**
- Cross-parent secrets (2+ parents with secrets)
- Deep nesting (3-level structures)
- SSH keys and certificate chains
- Special characters in values
- Mixed same and cross-parent secrets
- Top-level and nested secrets

**4-level nesting scenarios:**
- Secret at bottom with non-secret siblings
- Secret as only child (parent removal)
- Secrets at multiple levels in same branch
- Multiple secrets across different branches

**Edge cases:**
- Empty parent hash cleanup when secret is only child
- Arrays in config
- Empty parent keys that existed in original

All tests verify:
- Template excludes secret fields
- Secret value preserves parent structure with correct indentation
- Runtime merge (simulating configurations/base.rb) reconstructs original config

### Quick Validation
```bash
# Test each migration pattern on staging
ruby tmp/3pi_isc_migration/scripts/test_migrate_single_value_template.rb
ruby tmp/3pi_isc_migration/scripts/test_migrate_multi_value_template.rb
```

### Runtime Merge Testing
```bash
# Interactive script to test configs after migration
ruby scripts/test_runtime_merge.rb
# Simulates configurations/base.rb deep merge behavior
# Loads Rails if available for exact ActiveSupport methods
```

### Manual Testing Flow
1. Use Mode 1 (Manual by Name) for one-off testing
2. Check staging first, then production
3. Verify with: `isc conf -e staging '*.integrations.integrations' get env/...`
4. Use `test_runtime_merge.rb` to verify runtime behavior

---

## UI Enhancement Tips

- Use `TTY::Spinner` for all fetch/delete operations
- Use `TTY::Table` for multi-row status displays
- Show progress: `"Config 5/20 [15 remaining]"`
- Emoji indicators: ✅ ❌ 🚫 🔄 ⚠️
- Keep source/dest status labels clear and consistent

---

## Performance

- **Parallel fetching**: Use threads for checking multiple environments
- **Batch operations**: Mode 4 scans all refs in parallel
- **Deduplication**: SHA256 hash lookup before creating new secret refs
- **CSV caching**: Read once per operation, update immediately

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Permission denied" on secret ref | Add to `request_permissions_status.csv`, request via ISC UI |
| "Source exists" but actually deleted | Using `read_conf` instead of `find_conf` → cross-service fallback |
| SSH key creation fails | Using `--value` instead of `--file` with tempfile |
| Multiline secret broken YAML | Not using `to_yaml_with_literal_blocks` or not upgrading to multi-value |
| Secret ref says "linked" but can't find | Check ALL services, use `isc secretref -c` |

---

## Quick Reference

### Secret Keywords (auto-detected)
`secret`, `password`, `key`, `token`, `signature`

### Service Prefixes
- Loyalty Card: `LOYALTY_V1_LOYALTY_CARD_SERVICE_CONFIGURATIONS_`
- Offers: `OFFERS_V1_OFFER_SERVICE_CONFIGURATIONS_`
- Loyalty Points: `LOYALTY_POINTS_V1_LOYALTY_POINTS_SERVICE_CONFIGURATIONS_`

### ISC Services
- Source: `rpc.integrations.integrations`
- Dest: `*.integrations.integrations`

### Environments
`production`, `staging`, `development`
