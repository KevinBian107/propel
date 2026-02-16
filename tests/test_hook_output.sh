#!/usr/bin/env bash
# Test that session-start.sh produces valid JSON output.
#
# Usage: bash tests/test_hook_output.sh
#
# This test verifies:
# 1. The hook script runs without error
# 2. Output is valid JSON
# 3. Required fields are present (plugin, version, context)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
HOOK_SCRIPT="$PLUGIN_DIR/hooks/session-start.sh"

# Store output in a temp file to avoid shell escaping issues with large JSON
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

echo "Testing: hooks/session-start.sh"
echo "================================"

# Test 1: Script exists and is executable
if [ ! -x "$HOOK_SCRIPT" ]; then
    echo "FAIL: $HOOK_SCRIPT is not executable"
    exit 1
fi
echo "PASS: Script is executable"

# Test 2: Script runs without error
bash "$HOOK_SCRIPT" > "$TMPFILE" 2>&1 || {
    echo "FAIL: Script exited with error"
    cat "$TMPFILE"
    exit 1
}
echo "PASS: Script runs without error"

# Test 3: Output is valid JSON
python3 -m json.tool < "$TMPFILE" > /dev/null 2>&1 || {
    echo "FAIL: Output is not valid JSON"
    cat "$TMPFILE"
    exit 1
}
echo "PASS: Output is valid JSON"

# Test 4: Required fields are present
python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
required_fields = ['plugin', 'version', 'context']
missing = [f for f in required_fields if f not in data]
if missing:
    print(f'FAIL: Missing required fields: {missing}')
    sys.exit(1)
if data['plugin'] != 'propel':
    print(f'FAIL: plugin should be \"propel\", got \"{data[\"plugin\"]}\"')
    sys.exit(1)
if data['version'] != '0.1.0':
    print(f'FAIL: version should be \"0.1.0\", got \"{data[\"version\"]}\"')
    sys.exit(1)
print('PASS: All required fields present and correct')
" "$TMPFILE" || exit 1

# Test 5: Context contains skill content
python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
context = data['context']
if 'using-propel' not in context.lower() and 'Using Propel' not in context:
    print('FAIL: Context does not contain using-propel skill content')
    sys.exit(1)
if 'Gate 0' not in context:
    print('FAIL: Context does not mention Gate 0')
    sys.exit(1)
print('PASS: Context contains expected skill content')
" "$TMPFILE" || exit 1

# Test 6: active_investigations is a list
python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
if not isinstance(data.get('active_investigations', None), list):
    print('FAIL: active_investigations should be a list')
    sys.exit(1)
print('PASS: active_investigations is a list')
" "$TMPFILE" || exit 1

# Test 7: registry_entries is a list
python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
if not isinstance(data.get('registry_entries', None), list):
    print('FAIL: registry_entries should be a list')
    sys.exit(1)
print('PASS: registry_entries is a list')
" "$TMPFILE" || exit 1

echo ""
echo "================================"
echo "All tests passed!"
