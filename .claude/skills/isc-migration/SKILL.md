# ISC Migration Setup Skill

## Description

Automated ISC configuration migration setup assistant. Scans ISC configs across patterns and environments, generates migration tracking CSV, and provides summary statistics.

**Core Capability:** Batch scan and prepare migrations from any ISC service pattern to another.

## When to Invoke

User says:
- "use the isc-migration skill to setup migration..."
- "scan ISC configs from X to Y"
- "generate migration CSV for configs..."

## Parameters

User provides:
- `old_pattern`: Source ISC service pattern (e.g., `rpc.integrations.integrations`)
- `new_pattern`: Destination ISC service pattern (e.g., `*.integrations.integrations`)
- `environments`: List of environments (e.g., `production`, `staging`, `development`)
- `config_prefixes`: List of config name prefixes to scan (e.g., `OFFERS_V1`, `LOYALTY_CARD_V1`)

**Example invocation:**
```
Use the isc-migration skill to setup migration for all ISC configs from
rpc.integrations.integrations to *.integrations.integrations.
I want it done for these environments: production, staging, development.
I want it done for configs that start with OFFERS_V1, LOYALTY_CARD_V1.
```

## Execution Steps

### 1. Fetch All Configs from Old Pattern

Use the fetch script to scan configs in parallel:
```bash
ruby scripts/fetch_configs_parallel.rb \
  --old-pattern "rpc.integrations.integrations" \
  --new-pattern "*.integrations.integrations" \
  --environments production,staging,development \
  --prefixes OFFERS_V1,LOYALTY_CARD_V1 \
  --output automated-migration-configs/migration_<timestamp>.csv
```

**What the script does:**
- For each config prefix + environment combination, fetch all matching configs from old pattern
- Check if each config exists in new pattern for specified environments
- Run all fetches in parallel for speed
- Write results to CSV with columns:
  - `Config Name`
  - `<Env> Old Pattern` (Yes/No for each environment)
  - `<Env> New Pattern` (Yes/No for each environment)
  - `<Env> Migrated` (auto-calculated: Yes if in new pattern, No if only in old, N/A if not in old)

**Example CSV output:**
```csv
Config Name,Production Old Pattern,Production New Pattern,Production Migrated,Staging Old Pattern,Staging New Pattern,Staging Migrated
env/OFFERS_V1_CONFIG_1,Yes,No,No,Yes,No,No
env/OFFERS_V1_CONFIG_2,Yes,Yes,Yes,Yes,Yes,Yes
env/LOYALTY_CARD_V1_CONFIG_1,No,No,N/A,Yes,No,No
```

### 2. Generate Summary Statistics

After CSV is created, output:
```
Migration Scan Complete
======================

Source Pattern: rpc.integrations.integrations
Destination Pattern: *.integrations.integrations
Environments Scanned: production, staging, development
Config Prefixes: OFFERS_V1, LOYALTY_CARD_V1

Summary by Environment:
  Production:
    - Total configs in old pattern: 45
    - Already in new pattern: 12
    - Pending migration: 33

  Staging:
    - Total configs in old pattern: 45
    - Already in new pattern: 8
    - Pending migration: 37

  Development:
    - Total configs in old pattern: 30
    - Already in new pattern: 5
    - Pending migration: 25

Overall:
  - Total unique configs: 45
  - Fully migrated (all envs): 3
  - Partially migrated: 9
  - Not started: 33

CSV saved to: automated-migration-configs/migration_20260331115530.csv

Next Steps:
Run the migration tool and select "Migrate from Generated Config" option:
  ruby tmp/3pi_isc_migration/scripts/main.rb
```

### 3. User Runs Main Script

User executes migration tool and selects new mode:
```
Mode:
‣ Migrate Manually by Name
  Migrate by Service
  Migrate from Generated Config    ← NEW
  Delete Secret Ref
  Exit
```

The tool then:
1. Lists all CSVs in `automated-migration-configs/` sorted by last updated (descending)
2. Shows: filename, created date, last updated date
3. User selects one CSV
4. Functions like "Migrate by Service" mode but uses patterns from CSV metadata

## Script Requirements

### Fetch Script: `scripts/fetch_configs_parallel.rb`

**Arguments:**
- `--old-pattern`: Source service pattern
- `--new-pattern`: Destination service pattern
- `--environments`: Comma-separated list
- `--prefixes`: Comma-separated config name prefixes
- `--output`: Output CSV path

**Behavior:**
- Use threads to parallelize API calls
- For each (prefix, environment) combo:
  - `isc conf -e <env> <old_pattern> search -k "env/<prefix>" --as-json`
  - Parse results for matching configs
  - For each config, check if exists in new pattern
- Consolidate results into CSV
- Include metadata comment in CSV header with patterns

### Main Script Updates: `scripts/main.rb`

**New Mode: "Migrate from Generated Config"**

Add after Mode 2 (Migrate by Service):
```ruby
when :generated then mode_by_generated_config(services)
```

**Function: `mode_by_generated_config(services)`**

1. List CSVs in `automated-migration-configs/`:
   ```ruby
   Dir["automated-migration-configs/*.csv"].sort_by { |f| File.mtime(f) }.reverse
   ```

2. Display selection menu:
   ```
   Select migration config:
   ‣ migration_20260331115530.csv (Created: 2026-03-31 11:55, Updated: 2026-03-31 12:30)
     migration_20260330093045.csv (Created: 2026-03-30 09:30, Updated: 2026-03-30 10:15)
     Back
   ```

3. Read CSV and extract metadata from header comments:
   ```ruby
   # CSV Header (first 4 lines are raw text comments, not CSV rows):
   # OLD_PATTERN: rpc.integrations.integrations
   # NEW_PATTERN: *.integrations.integrations
   # GENERATED: 2026-03-31 11:55:30
   # PREFIXES: OFFERS_V1, LOYALTY_CARD_V1
   ```

4. Use extracted patterns instead of hardcoded `SOURCE_SERVICE` and `DEFAULT_SERVICE`

5. Function identically to Mode 2 (Migrate by Service):
   - Iterate through CSV rows
   - Fetch all 3 environments in parallel
   - Display status table
   - Multi-select environments
   - Refresh option
   - Choose migration strategy
   - Execute migration
   - Update CSV after success

**Key Difference from Mode 2:**
- Patterns are dynamic (read from CSV metadata) instead of hardcoded constants
- Must parameterize all ISC commands:
  ```ruby
  # Before (hardcoded):
  isc conf -e staging rpc.integrations.integrations get ...

  # After (parameterized):
  isc conf -e staging #{source_pattern} get ...
  ```

## CSV Format

**IMPORTANT:** The first 4 lines are comment lines written as raw text (NOT CSV rows) to avoid quote escaping:
- Line 1: `# OLD_PATTERN: <old_pattern>`
- Line 2: `# NEW_PATTERN: <new_pattern>`
- Line 3: `# GENERATED: <date_time>`
- Line 4: `# PREFIXES: <prefix values>`

Line 5 contains the CSV column headers, and remaining lines are data rows.

```csv
# OLD_PATTERN: rpc.integrations.integrations
# NEW_PATTERN: *.integrations.integrations
# GENERATED: 2026-03-31 11:55:30
# PREFIXES: OFFERS_V1, LOYALTY_CARD_V1
Config Name,Production Old Pattern,Production New Pattern,Production Migrated,Staging Old Pattern,Staging New Pattern,Staging Migrated
env/OFFERS_V1_CONFIG_1,Yes,No,No,Yes,No,No
env/OFFERS_V1_CONFIG_2,Yes,Yes,Yes,Yes,Yes,Yes
```

**Column Structure:**
- `Config Name`: Full config name (with `env/` prefix)
- For each environment:
  - `<Env> Old Pattern`: Yes/No (config exists in source)
  - `<Env> New Pattern`: Yes/No (config exists in destination)
  - `<Env> Migrated`: Yes (migrated), No (pending), N/A (not in old pattern)

## Important Notes

1. **Parallel Execution**: The fetch script MUST run in parallel to handle large config sets efficiently
2. **Pattern Agnostic**: All code must support ANY pattern, not just `rpc.*` → `*.`
3. **CSV Metadata**: Patterns stored in CSV header comments for traceability
4. **Timestamp Format**: `YYYYMMDDHHMMSS` for filenames (sortable)
5. **Environment Filtering**: Only include columns for requested environments

## Success Criteria

Skill completes successfully when:
- ✅ CSV file created in `automated-migration-configs/`
- ✅ All requested configs scanned
- ✅ Summary statistics displayed
- ✅ User instructed to run migration tool
- ✅ CSV contains accurate status for all environments

## Error Handling

- **Permission denied**: Skip config, log in summary
- **Pattern not found**: Show warning, continue
- **ISC timeout**: Retry with exponential backoff
- **CSV write failure**: Abort with clear error message
