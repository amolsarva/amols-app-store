#!/bin/bash
# ============================================================
#  Drive Dedup — Quick-start runner (with resume support)
#  Just run: bash run.sh
#  It will detect where you left off and continue automatically.
# ============================================================

DRIVE="/Volumes/Sunflowers"
SCAN_OUTPUT="./scan_results"
CLAUDE_API_KEY="${ANTHROPIC_API_KEY:-}"

# ── Detect prior progress ──────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║       Drive Dedup — Quick Runner         ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Check drive
if [ ! -d "$DRIVE" ]; then
  echo "❌ Drive not found: $DRIVE"
  echo "   Make sure Sunflowers is plugged in and mounted."
  exit 1
fi
echo "✅ Drive found: $DRIVE"

# Python (and the anthropic package when an API key is set) via python-guard's private venv.
GUARD="$(cd "$(dirname "$0")" && pwd)/../python-guard/pyenv.sh"
if [ -n "$CLAUDE_API_KEY" ]; then PY="$(/bin/bash "$GUARD" venv drive-dedup --pkg anthropic)"
else PY="$(/bin/bash "$GUARD" find)"; fi
if [ -z "$PY" ]; then
  echo "❌ no usable python3 (run ../python-guard/run.sh doctor)"
  exit 1
fi

# ── Figure out where we are ────────────────────────────────────────────────────

HAS_DUPES=false
HAS_INVENTORY=false
HAS_SCAN_CKPT=false
HAS_HASH_CKPT=false

[ -f "$SCAN_OUTPUT/duplicates.json" ]      && HAS_DUPES=true
[ -f "$SCAN_OUTPUT/inventory.csv" ]        && HAS_INVENTORY=true
[ -f "$SCAN_OUTPUT/checkpoint_scan.json" ] && HAS_SCAN_CKPT=true
[ -f "$SCAN_OUTPUT/checkpoint_hash.json" ] && HAS_HASH_CKPT=true

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Status check:"
echo "  scan checkpoint : $HAS_SCAN_CKPT"
echo "  inventory.csv   : $HAS_INVENTORY"
echo "  hash checkpoint : $HAS_HASH_CKPT"
echo "  duplicates.json : $HAS_DUPES"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if $HAS_DUPES; then
  echo "✅ Phase 1 already complete — skipping to Phase 2"
else
  echo "STEP 1: Scanning drive and finding duplicates (resumes if interrupted)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  "$PY" phase1_scan.py "$DRIVE" --output "$SCAN_OUTPUT"
  echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 2: Building consolidation plan (dry run)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -n "$CLAUDE_API_KEY" ]; then
  "$PY" phase2_reorganize.py "$DRIVE" \
    --scan-dir "$SCAN_OUTPUT" \
    --claude-api-key "$CLAUDE_API_KEY"
else
  "$PY" phase2_reorganize.py "$DRIVE" \
    --scan-dir "$SCAN_OUTPUT"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ DONE — Review these files before moving anything:"
echo ""
echo "   $SCAN_OUTPUT/summary.txt          ← overview + duplicate report"
echo "   $SCAN_OUTPUT/consolidate.sh       ← the full copy plan"
echo ""
echo "When you're happy, run:"
echo "   bash $SCAN_OUTPUT/consolidate.sh"
echo ""
echo "Or to execute with built-in resume support (recommended for large drives):"
echo "   python3 phase2_reorganize.py $DRIVE --scan-dir $SCAN_OUTPUT --execute"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
