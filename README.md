# ISC Secret Template Migration: Findings & Tool Guide

**Ticket**: [PS-24396 — Update third-party loyalty automation to prevent future monolithic secrets](https://instacart.atlassian.net/browse/PS-24396)

**Epic**: [PS-24037 — Third-Party Loyalty ISC Config Migration](https://instacart.atlassian.net/browse/PS-24037)

**Wiki**: [3PI ISC Config Migration Tool - Confluence](https://instacart.atlassian.net/wiki/spaces/ENTSO/pages/6481412238/3PI+ISC+Config+Migration+Tool)

---

## Quick Start

```bash
# Install required gems (one-time)
gem install tty-prompt tty-spinner tty-table

# Or use bundler (if Gemfile is present)
bundle install

# Run from the repo root
ruby tmp/3pi_isc_migration/scripts/main.rb
```

> **Important**: `isc secretref create/update` and `isc conf set` are blocked in AI agent mode.
> Always run these scripts **directly in your terminal**, not via Claude Code's `!` prefix.

---

## Migration Statistics & Progress

### Current State (as of 2026-04-01)

#### Configs Already Migrated to `*.integrations.integrations`

| Service | Total Configs | Template Pattern | No-Template Pattern | Template Adoption |
|---------|--------------|------------------|---------------------|-------------------|
| **Loyalty Card** | 129 | 118 (91.5%) | 11 (8.5%) | 91.5% |
| **Loyalty Points** | 63 | 40 (63.5%) | 23 (36.5%) | 63.5% |
| **Offers** | 206 | 86 (41.7%) | 120 (58.3%) | 41.7% |
| **TOTAL** | **398** | **244 (61.3%)** | **154 (38.7%)** | **61.3%** |

#### Configs Remaining in `rpc.integrations.integrations` (Not Yet Migrated)

| Service | Configs to Migrate |
|---------|-------------------|
| **Loyalty Card** | 12 |
| **Loyalty Points** | 11 |
| **Offers** | ~25 |
| **TOTAL** | **~48** |

#### Overall Migration Progress

```
Total Configs: ~446 (398 migrated + 48 remaining)
Migration Completion: ~89% (398/446)
Remaining Work: ~11% (48/446)
```

**Progress Visualization:**

```
[████████████████████████████████████████░░░░] 89% Complete
```

### Pattern Distribution Insights

**Historical Context: No-Template Pattern (38.7% of migrated configs)**

The 154 configs initially migrated using **no-template** pattern (entire config as monolithic secret ref) were primarily configs with **cross-parent secrets** - secret fields under different parent keys.

**These configs can now be re-migrated using the `auto_merge_secrets` pattern** for better separation:

   ```yaml
   # Cross-parent secrets - NOW SUPPORTED with auto_merge_secrets
   birdzi:
     api_key: "secret1"     # ← Under birdzi
   lms:
     password: "secret2"    # ← Under lms
   # NEW Solution: Use auto_merge_secrets pattern (template + secrets: key)
   ```

2. **User Preference**: Operator chose "Full monolithic" during initial migration for simplicity
3. **Legacy Compatibility**: Minimal disruption for existing integrations

> **Note**: The `no_template` pattern has been deprecated in favor of `auto_merge_secrets`. Existing monolithic configs can be re-migrated to use the new pattern for better secret separation.

**Template Adoption by Service:**

* **Loyalty Card: 91.5%** - Highest adoption, cleanly structured secrets under single parent
* **Loyalty Points: 63.5%** - Moderate adoption, some cross-parent secrets
* **Offers: 41.7%** - Lower adoption (can now be improved with auto_merge_secrets)

**Security Benefits:**

All 398 migrated configs benefit from:
* ✅ Separation from monolithic storage in `rpc.integrations.integrations`
* ✅ Dedicated secret refs with proper ISC permissions
* ✅ Independent secret rotation capability

**Additional Template Benefits (244 configs):**
* ✅ Public config data separated from secrets (only 136 chars secrets vs 3,400+ chars)
* ✅ DynamoDB capacity savings (non-secret data in S3)
* ✅ Easier config updates without touching secrets
* ✅ Better GitOps compatibility

---

## Tool Guide

### Directory Layout

```
tmp/3pi_isc_migration/
  README.md                    ← this file
  report.txt                   ← migration log (appended automatically)
  automated-migration-configs/ ← generated CSVs from Claude Skill
    migration_20260331115530.csv
    migration_20260330093045.csv
    ...
  scripts/
    main.rb                    ← interactive terminal UI (entry point)
    common.rb                  ← shared ISC helpers used by all scripts
    fetch_configs_parallel.rb  ← parallel config scanner for Claude Skill
    migrate_single_value_template.rb
    migrate_multi_value_template.rb
    migrate_no_template.rb
    migrate_no_secret.rb
```

### Running the Tool

```bash
ruby tmp/3pi_isc_migration/scripts/main.rb
```

All navigation uses **arrow keys + Enter**. On startup you choose a mode:

```
Mode:
‣ Migrate Manually by Name
  Migrate from Generated Config
  Delete Secret Ref
  Exit
```

---

### Mode 1 — Migrate Manually by Name

Use this to migrate a single conf by name (ad-hoc, for testing or one-offs).

1. Enter the conf name (with or without the `env/` prefix — it's added automatically)
2. The tool fetches **all 3 environments in parallel** and shows a status table:

   ```
   1. production    : source: DELETED (migration complete) | dest: EXISTS [MIGRATED WITH SECRET-REF: ENV_..._SECRET]
   2. staging       : source: EXISTS (ready to migrate) | dest: -
   3. development   : source: not found | dest: -
   ```

   Source labels:
   - `source: EXISTS (ready to migrate)` — config exists in source, not yet migrated
   - `source: DELETED (migration complete)` — source already deleted, migration complete (can re-migrate from dest)
   - `source: not found` — config doesn't exist in source service

   Dest labels:
   - `[MIGRATED WITH SECRET-REF: <name>]` — already migrated, secret ref linked
   - `[MIGRATED - NO TEMPLATE BUT POSSIBLE!]` — already migrated but no secret ref (could be templated)
   - `[MIGRATED - NO TEMPLATE]` — already migrated, no secrets detected

3. **Multi-select** which environments to migrate (all pre-checked). Uncheck any to skip.
   - **Refresh**: Re-fetch configs from ISC (useful if you updated something externally)
   - **Skip**: Exit without migrating this config
   - **Re-migration**: You can select already-migrated configs to update them. When source is deleted, the tool uses the dest config as the source for re-migration.

4. For each selected environment, a **strategy selection** prompt appears:

   ```
   Plan:
   ‣ multi value template  ←  lms.authenticate_password, lms.api_key  (suggested)
     Select keys manually
     No secret (plain YAML)
     Skip this environment
   ```

   - **Suggested plan**: Auto-derived from detected secret-like keys (pre-selected for convenience)
   - **Select keys manually**: Choose specific keys, then plan is auto-derived
   - **No secret (plain YAML)**: Store config as plain YAML with no secret ref (for non-secret configs)
   - **Skip this environment**: Skip migration for this environment

   If you choose **Select keys manually**, a multi-select prompt appears:
   ```
   Which keys contain secrets? (* = likely,  space = toggle,  enter = confirm)
   ‣ ◉  lms.authenticate_password  *
     ◉  lms.api_key  *
     ○  lms.authenticate_username
     ○  ← Back
   ```

   - Likely secret keys are **pre-checked** (name contains `secret`, `password`, `key`, `token`, or `signature`)
   - Selecting **no keys** triggers the `no_secret` plan (plain YAML config)

5. After confirming, the plan is **auto-derived** from selected keys (see Plans below) and printed:
   ```
     Plan: multi value template
   ```

6. Migration runs: new conf created in `*.integrations.integrations`, source conf deleted, original secret ref cleaned up if safe.

7. Type `back` at the conf name prompt to return to the mode menu.

---

### Mode 2 — Migrate from Generated Config

Use this mode to migrate configs based on a CSV generated by the ISC migration skill.

**Prerequisites:** You must first generate a migration CSV using the ISC migration skill:
```
Use the isc-migration skill to setup migration for all ISC configs from
rpc.integrations.integrations to *.integrations.integrations.
I want it done for these environments: production, staging.
I want it done for configs that start with OFFERS_V1, LOYALTY_CARD_V1.
```

The skill will:
1. Scan all configs matching the prefixes from the old pattern
2. Check if they exist in the new pattern for specified environments
3. Generate a CSV in `automated-migration-configs/migration_<timestamp>.csv`
4. Display summary statistics

**Migration Workflow:**

1. Select "Migrate from Generated Config" from the main menu
2. Tool displays all generated CSVs sorted by last updated (descending):
   ```
   Select migration config:
   ‣ migration_20260331115530.csv (Created: 2026-03-31 11:55, Updated: 2026-03-31 12:30)
     migration_20260330093045.csv (Created: 2026-03-30 09:30, Updated: 2026-03-30 10:15)
     Back
   ```
3. Select one CSV file
4. Tool extracts old pattern and new pattern from CSV metadata
5. Migration workflow:
   - Iterates through CSV rows
   - Fetches all environments in parallel
   - Displays status table
   - Multi-select environments (with Refresh option)
   - Choose migration strategy
   - Execute migration
   - Update CSV after each success

**Key Features:**
- **Pattern Agnostic**: Supports ANY source → destination pattern (not just `rpc.*` → `*.*`)
- **Bulk Scanned**: CSV pre-populated with all configs matching criteria
- **Skill Generated**: CSV created by Claude skill, not manually maintained

**CSV Format:**
```csv
# OLD_PATTERN: rpc.integrations.integrations
# NEW_PATTERN: *.integrations.integrations
# GENERATED: 2026-03-31 11:55:30
# PREFIXES: OFFERS_V1, LOYALTY_CARD_V1
Config Name,Production Old Pattern,Production New Pattern,Production Migrated,Staging Old Pattern,Staging New Pattern,Staging Migrated
env/OFFERS_V1_CONFIG_1,Yes,No,No,Yes,No,No
env/OFFERS_V1_CONFIG_2,Yes,Yes,Yes,Yes,Yes,Yes
```

- **Metadata Comments**: Old/new patterns stored in CSV header for traceability
- **Dynamic Columns**: Only includes columns for scanned environments
- **Auto-Updated**: "Migrated" columns update to "Yes" after successful migration

---

### Mode 3 — Delete Secret Ref

Use this to delete a secret ref from one or more environments. Includes comprehensive safety checks.

1. Enter the secret ref name (exact name, no `env/` prefix)
2. The tool checks **all 3 environments in parallel** and shows which environments have the secret ref:

   ```
   production:
     Secret ref name: OFFERS_V1_..._SECRET
     Status: EXISTS
     Linked confs: 2
       - env/OFFERS_V1_..._CONFIG1 (rpc.integrations.integrations)
       - env/OFFERS_V1_..._CONFIG2 (*.integrations.integrations)
     🚫 BLOCKED: Cannot delete - still in use by configs

   staging:
     Secret ref name: OFFERS_V1_..._SECRET
     Status: EXISTS
     Linked confs: none
     ✅ Safe to delete
   ```

3. **Multi-select** which environments to delete from (only safe environments shown)
4. **Confirmation prompt** shows what will be deleted and requires explicit confirmation
5. Deletion runs for each selected environment
6. **Report logging**: Each deletion attempt (success or failure) is logged to `report.txt`
7. Type `back` at the secret ref name prompt to return to the mode menu

**Safety checks**:
- **Linked configs**: Checks for linked configs across ALL services (both `rpc.integrations.integrations` and `*.integrations.integrations`). Environments with any linked configs are automatically blocked from selection to prevent breaking active configs.
- **Exact name matching**: Multiple verification layers ensure only the exact secret ref name is deleted (not substrings)
- **Permission check**: ISC will block deletion if you lack delete permissions (failure is logged to report)
- **Report tracking**: All deletion attempts are logged with status, environment, and error details

---

### Migration Plans

The plan is **auto-derived** from the keys you select — no separate confirmation step.

**Simplified approach (2 patterns only):**

| Plan | When | How |
|------|------|-----|
| `single_value_template` | Exactly 1 key selected (single-line OR multiline) | Key stays in template, `$$secret$$` is the value: `password: $$secret$$`. Secret ref holds the value (multiline values automatically formatted with YAML literal block scalar `\|` syntax). |
| `auto_merge_secrets` | **2+ secret keys** (regardless of nesting) | Template contains ONLY non-secret fields + `$$secret$$` at end. Secret ref starts with `secrets:` root key containing ONLY secret fields with parent structure. At runtime, `configurations/base.rb` auto-merges `secrets:` into base config. |
| `no_secret` | No keys selected (0 secret-like keys detected), or explicitly chosen | Config stored as **plain YAML** (not a secret ref). No `$$secret$$` substitution. Used for configs that were incorrectly stored as secrets. |

**Note**: Single-value templates now support multiline values (SSH keys, certificates) via automatic YAML literal block scalar (`|`) formatting in the secret ref value.

#### Auto-Merge Secrets Pattern (Recommended for 2+ secrets)

**Use case**: Multiple secrets or secrets under different parent keys.

**Example original config:**
```yaml
retailer: brookshiregrocery
dpn:
  base_url: https://api.test.dpn.inmar.com
  retailer: brookshiregrocerydpn
  username: instacart_api_admin
  password: password_test_123           # ← Secret
  currency: USD
ice:
  retailer: brookshiregrocerydpn-instacart
  size: 300
  master_key_secret: masterkeysecret!!!  # ← Secret
```

**With auto_merge_secrets (NEW simplified format):**

**Template (stored in ISC config):**
```yaml
retailer: brookshiregrocery
dpn:
  base_url: https://api.test.dpn.inmar.com
  retailer: brookshiregrocerydpn
  username: instacart_api_admin
  currency: USD
ice:
  retailer: brookshiregrocerydpn-instacart
  size: 300
$$secret$$
```

**Secret ref (stored separately):**
```yaml
secrets:
  dpn:
    password: password_test_123
  ice:
    master_key_secret: masterkeysecret!!!
```

**At runtime** (in `configurations/base.rb`):
1. ISC substitutes `$$secret$$` with secret ref content (including the `secrets:` key)
2. `configurations/base.rb` extracts the `secrets:` key
3. Deep merges it into the base settings
4. Final result has all non-secret fields + actual secret values merged together

**Benefits:**
- ✅ **Clean separation**: Non-secret config in template, only secrets in secret ref
- ✅ **Valid standalone YAML**: Secret ref is valid YAML starting with `secrets:` root key
- ✅ **No confusing indentation**: Secret ref doesn't need special indentation rules
- ✅ **Easy to read and maintain**: Clear what's a secret vs. non-secret
- ✅ **Single ISC config**: Only one config per retailer
- ✅ **Zero plugin changes**: Existing `Current.settings.dig()` calls work unchanged

---

**Note on legacy auto-merge format:**

Several existing configs use an older auto-merge format where:
- Template had `secrets:` prefix: `secrets:\n  $$secret$$`
- Secret ref had indentation rules (first line no indent, subsequent lines +2 spaces)

**This legacy format still works** but is more complex and error-prone. The new format (shown above) is **recommended for all new configs and re-migrations**. Both formats are supported by `configurations/base.rb`.

#### Secret ref naming

| Plan | Secret ref name |
|------|----------------|
| `single_value_template` | `<CONF_BASE>_<KEY_UPCASE>` (e.g. `…_AUTHENTICATE_PASSWORD`) |
| `auto_merge_secrets` | `<CONF_BASE>_SECRETS` |
| `no_secret` | (none - plain YAML config) |

#### Re-migration (dest conf already exists)

If the conf already exists in `*.integrations.integrations`, the tool updates it instead of creating it fresh:
- Secret ref: updated in place if only linked to this one conf; a new ref is created if shared with others.
- Source conf deletion and cleanup are skipped if the source was already removed.

**ISC TTY limitation workaround**: When overwriting an existing config, ISC normally prompts for confirmation (`Overwrite? [y/N]`), but this fails in non-interactive contexts (Ruby scripts) with:
```
Error: attempted to confirm but input was not a TTY
```

ISC provides no `--force` or `--yes` flag to bypass this prompt. **Workaround**: The tool automatically deletes the existing config first, then creates the new one. This applies to all migration patterns when re-migrating. You'll see:
```
(Deleting existing conf to avoid confirmation prompt)
```

#### Migration status detection

When checking configs across environments, the tool now **detects whether configs are already migrated using templates** by checking for `$$secret$$` placeholders. This helps you identify which configs need work vs which are already complete.

**Status labels you'll see:**

**Destination status:**
- `✅ MIGRATED: template with secret-ref [name]` - Fully migrated with template pattern (no work needed!)
- `⚠️  MONOLITHIC: linked to [name] but no $$secret$$` - Has secret-ref but still monolithic (should re-migrate)
- `PLAIN YAML - no secrets` - Plain config without secrets (no migration needed)
- `PLAIN YAML with secret-like keys` - Has password/key fields but stored as plain YAML

**Source status:**
- `EXISTS (✅ already migrated)` - Source exists, dest fully migrated with template
- `EXISTS (⚠️ needs re-migration)` - Source exists, dest is monolithic without template
- `EXISTS (ready to migrate)` - Source exists, dest doesn't exist yet
- `EXISTS (migrated as plain YAML)` - Migrated without secrets

**Example output:**
```
Environment: production
  Source: EXISTS (✅ already migrated)
  Dest:   EXISTS [✅ MIGRATED: template with secret-ref LOYALTY_V1_..._SECRET]
```
Translation: "This config is done! It's using the template pattern. Skip it."

vs.

```
Environment: production
  Source: EXISTS (⚠️ needs re-migration)
  Dest:   EXISTS [⚠️ MONOLITHIC: linked to env/LOYALTY_V1_... but no $$secret$$]
```
Translation: "This config has a secret-ref but isn't using templates. Re-migrate to upgrade."

---

### Secret Ref Deduplication

Before creating a new secret ref, the tool searches for an existing one with the same SHA256 value hash (`isc secretref list -d <hash>`). If found, it reuses that ref instead of creating a duplicate. This is distinct from the cleanup lookup (which finds the old monolithic ref by name or by hashing the full YAML).

---

### Standalone Migration Scripts

Each migration module can also be run standalone from the command line:

```bash
# Single-value template
ruby tmp/3pi_isc_migration/scripts/migrate_single_value_template.rb \
  --source-conf env/OFFERS_V1_..._BOWMANS \
  --secret-key lms.authenticate_password \
  --new-conf env/OFFERS_V1_..._BOWMANS \
  --secret-ref OFFERS_V1_..._BOWMANS_SECRET \
  --environment staging

# Auto-merge secrets (recommended for 2+ secrets or multiline secrets)
ruby tmp/3pi_isc_migration/scripts/migrate_auto_merge_secrets.rb \
  --source-conf env/LOYALTY_V1_..._CONFIG \
  --secret-keys ncr.lms.password,ncr.api.api_key \
  --new-conf env/LOYALTY_V1_..._CONFIG \
  --secret-ref LOYALTY_V1_..._CONFIG_SECRETS \
  --environment staging

# No-secret (plain YAML)
ruby tmp/3pi_isc_migration/scripts/migrate_no_secret.rb \
  --source-conf env/CONFIG_WITH_NO_SECRETS \
  --new-conf env/CONFIG_WITH_NO_SECRETS \
  --environment staging
```

---

### Report

Every successful migration and every failure is appended to `report.txt`. Configs that are simply not found are not logged.

```
=== 2025-03-25 14:32:01 ===
Status:                  SUCCESS
Source conf:             env/OFFERS_V1_OFFER_SERVICE_CONFIGURATIONS_BOWMANS
Environment:             staging
Migration plan:          single_value_template
Secret keys:             lms.authenticate_password
New conf:                env/OFFERS_V1_OFFER_SERVICE_CONFIGURATIONS_BOWMANS
Secret ref used:         OFFERS_V1_OFFER_SERVICE_CONFIGURATIONS_BOWMANS_SECRET
Original conf:           deleted
Original secret ref:     deleted
```

---

## Key Findings

### 1. ISC supports only ONE `$$secret$$` placeholder per conf

All sensitive fields for a given conf must be bundled into a single `secret_ref` value and
substituted at a single `$$secret$$` position in the template.

### 2. `$$secret$$` does raw string substitution — multi-value blocks work

ISC replaces the `$$secret$$` token with the exact contents of `secret_ref.data` verbatim, so the
secret value can be a block of multiple YAML key/value pairs.

### 3. Pre-indent rule for multi-value secret blocks

Because `$$secret$$` is already indented in the template (e.g. 2 spaces inside `ice:`), ISC
substitutes it in-place:

- **First field**: NO leading spaces — `$$secret$$` position already provides the indent
- **All subsequent fields**: 2-space prefix — to align within the surrounding YAML block

Getting this wrong produces broken YAML (fields at the wrong nesting level).

### 4. Single-value template: key stays in template, `$$secret$$` is the value

```yaml
lms:
  authenticate_username: username
  authenticate_password: $$secret$$
```

Secret ref value: just the raw scalar. The `key: value` block format is only for 2+ fields.

### 5. Cross-subkey `$$secret$$` does NOT work

If sensitive fields belong to different top-level keys (e.g. `birdzi.password` AND `lms.api_key`),
a single `$$secret$$` block cannot cover them — this produces duplicate YAML keys. Use `no_template`
for these cases.

### 6. Top-level secret fields (no parent key) work with multi-value template

When secret fields have no parent (e.g. `client_secret`, `subscription_key` at the root level),
the tool handles this correctly — the sentinel is inserted at the root hash level and the
`$$secret$$` block expands inline.

### 7. `isc secretref create/update` are blocked in AI agent processes

The ISC CLI detects AI agent contexts and refuses write operations. All migration scripts must be
run by a human operator directly in the terminal.

### 8. `Open3.capture3` with an args array is required for multi-line secret values

Ruby's backtick operator uses `/bin/sh` and will corrupt multi-line strings. Use
`Open3.capture3("isc", "secretref", ..., "--value", value)` with an array of arguments.

### 9. Deduplication: ISC tracks secret values by SHA256 hash

Use `isc secretref list -d <sha256_hash> --as-json` to find an existing ref before creating.
The `create_or_find_secret_ref` helper in `common.rb` is the validated prototype for this pattern.

### 10. Secret ref reuse vs cleanup are separate lookups

- **Reuse lookup**: SHA256 of the specific secret value to store (used to link the new conf)
- **Cleanup lookup**: name match or SHA256 of the full raw YAML (used to find the old monolithic ref to delete)

These must not be conflated — reusing the monolithic ref as the new template's secret ref would
store the entire YAML as the secret value, defeating the purpose of the migration.

### 11. SSH private keys and multiline secrets require special handling

**ISC template substitution does NOT handle multiline values correctly** — `$$secret$$` performs simple string replacement without YAML formatting, causing malformed output for SSH private keys and certificates.

The tool automatically handles this:

#### Detection
- Scans for SSH/RSA private keys, certificates: `-----BEGIN OPENSSH PRIVATE KEY-----`, `-----BEGIN RSA PRIVATE KEY-----`, `-----BEGIN CERTIFICATE-----`, etc.
- Shows notification: `[SSH KEY] Detected and formatted private keys: app_card_sfx.offers_sftp.private_key`

#### Formatting Fix
- Ensures proper newline structure (handles escaped `\n`, normalizes line endings)
- Converts to YAML with literal block scalar syntax (`|`) for multiline strings:
  ```yaml
  private_key: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAA...
    -----END OPENSSH PRIVATE KEY-----
  ```

#### Auto-upgrade to multi-value template
- When a single-value template is selected but the value is multiline (SSH keys, certificates, etc.), the tool **automatically upgrades to multi-value template**
- Shows warning: `⚠ WARNING: Detected multiline secret values (e.g., SSH private keys)`
- Multi-value templates handle multiline values correctly using YAML literal block scalar (`|`) syntax with proper indentation
- Single-value templates cannot handle multiline values because ISC's `$$secret$$` does simple string replacement

#### Command-line argument handling for multiline secrets
- Uses `isc secretref create --file <tempfile>` for multiline values (recommended by ISC CLI)
- Uses `isc secretref create --value=<value>` for single-line values (handles values starting with `---` hyphens)
- Temporary files are automatically cleaned up after secret ref creation

---

## Limitations

### ISC CLI Restrictions

#### 1. Write Operations Blocked in AI Agent Mode
- **Issue**: `isc secretref create/update` and `isc conf set` detect AI agent contexts and refuse to run
- **Impact**: All migration scripts MUST be run directly by a human operator in their terminal
- **Workaround**: None — this is by design for security. Always run scripts manually, never via Claude Code's bash execution.

#### 2. Limited List Permissions
- **Issue**: `isc secretref list --as-json` only returns secret refs you have explicit list permissions for (typically ~25 refs)
- **Impact**: Cannot scan for all unused secret refs by prefix. Bulk cleanup operations are not possible.
- **Example**: You can see hundreds of secret refs on the ISC web UI, but `isc secretref list` only returns a small subset
- **Workaround**: Query individual secret refs by exact name using `isc secretref list -n "EXACT_NAME"` — this works even without list permissions

#### 3. Permission Denied = Does Not Exist
- **Issue**: When you lack read/view permissions on a conf or secret ref, ISC returns "not found" instead of "permission denied"
- **Impact**: Impossible to distinguish between truly missing resources and permission issues
- **Example**: A config may exist in production but show as "not found" if you lack read access
- **Workaround**: Cross-reference with ISC web UI or request permissions via ISC approval flow

#### 4. No Self-Service Permission Management
- **Issue**: Cannot view, modify, or request permissions via CLI
- **Impact**: Must use ISC web UI to:
  - Request access to secret refs or confs
  - View who has access to a resource
  - Change principals or permissions on existing secret refs
- **Workaround**: Use ISC web UI at https://isc.fernet.io/approvals/secretrefs for permission requests

#### 5. Cross-Service Fallback Behavior
- **Issue**: `isc conf get` searches across multiple services if the config isn't found in the specified service
- **Impact**: Can report "source: EXISTS" when config is actually in a different service (false positive)
- **Example**: Query `rpc.integrations.integrations` but get a result from `*.integrations.integrations`
- **Workaround**: Always use `isc conf search` (via `find_conf`) BEFORE `isc conf get` to verify the config exists in the specific service

#### 6. Delete Permissions Required
- **Issue**: Deleting a secret ref requires explicit "delete" permission (separate from read/update)
- **Impact**: Migration may succeed but cleanup fails with permission denied
- **Tracking**: All permission denied deletions are logged to `report.txt` and `request_permissions_status.csv`
- **Workaround**: Request delete permissions via ISC web UI, then retry cleanup using Mode 3

#### 7. Cannot Delete In-Use Secret Refs
- **Issue**: ISC blocks deletion of any secret ref that has linked configs
- **Impact**: Must unlink or delete all configs first before removing the secret ref
- **Detection**: Mode 3 automatically checks for linked configs and blocks deletion attempts
- **Workaround**: None — this is a safety feature. Must unlink configs first.

#### 8. No `--force` Flag for Overwriting Configs
- **Issue**: When overwriting an existing config, `isc conf set` prompts for interactive confirmation (`Overwrite? [y/N]`), but fails in non-TTY contexts (scripts) with: `Error: attempted to confirm but input was not a TTY`
- **Impact**: Cannot re-migrate configs from scripts without workaround
- **Root cause**: ISC has no `--force`, `--yes`, or similar flag to bypass confirmation prompts
- **Workaround**: The tool automatically deletes the existing config first (`isc conf clear`), then creates the new one. This applies to all migration patterns when re-migrating. You'll see: `(Deleting existing conf to avoid confirmation prompt)`
- **Affected functions**: `create_plain_conf`, `create_conf_with_template`, `link_conf_to_secret_ref`

---

## Current Provider Secret Profile

From `config/initializers/constants.rb` (attributes with `secret_config:` key):

| Provider | Service Type | Secret Fields | Count | Template Approach |
|----------|-------------|--------------|-------|-------------------|
| GiveX | offers, loyalty_card | `givex_admin_password` | 1 | Single-value |
| GiveX | loyalty_points | `givex_client_password` | 1 | Single-value |
| Birdzi | all | `birdzi_api_key` | 1 | Single-value |
| BRData | all | `brdata_app_id`, `brdata_client_id`, `brdata_secret_key` | 3 | Multi-value |
| Inmar | all (conditional) | `inmar_dpn_password` + optional `inmar_upcs_api_key` | 1–2 | Multi-value |
| Inmar | all (conditional) | `inmar_youtech_signature` + optional `inmar_upcs_api_key` | 1–2 | Multi-value |
| Inmar | all (conditional) | `inmar_ice_master_key_secret` + optional `inmar_upcs_api_key` | 1–2 | Multi-value |
| NCR LMS | all | `ncr_lms_authenticate_password` | 1 | Single-value |
| RSA America | all | `rsa_america_app_id`, `rsa_america_app_key` | 2 | Multi-value |

---

## Implementation Plan (Production Code Changes)

### `app/services/isc/conf_service.rb` — Add `add_secret_template`

```ruby
def add_secret_template(name:, service:, template_data:, secret_value:, environment:)
  create_or_update_conf(
    name: name, service: service, data: template_data,
    is_template: true, environment: environment,
  )
  create_or_update_secret_ref(name: name, value: secret_value, environment: environment)
end
```

`create_or_update_secret_ref` must implement SHA256 dedup: compute
`Digest::SHA256.hexdigest(secret_value)`, call `list_secret_refs` filtered by that hash, and reuse
if found. `create_or_find_secret_ref` in `common.rb` is the validated prototype.

### `app/services/whitelabel_sites/third_party_loyalty/isc_config_builders/base_builder.rb`

Add `sensitive_attributes(params)` (fields with `secret_config:` present) and
`public_attributes(params)` (everything else).

### `app/services/whitelabel_sites/third_party_loyalty/base_isc_config_service.rb`

Add `create_isc_conf_as_template` that calls `builder_class.build_isc_conf_template(public_params)`
and `build_secret_block(secret_params, builder_class)`, then calls `isc_conf_service.add_secret_template`.

### Builder classes — Add `build_isc_conf_template`

Variant of `build_isc_conf_value` that omits sensitive fields and appends `$$secret$$` at the
correct indent inside the provider hash.
