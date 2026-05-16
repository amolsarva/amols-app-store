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

# Check Python
if ! command -v python3 &>/dev/null; then
  echo "❌ python3 not found. Install from https://www.python.org"
  exit 1
fi

# Install anthropic if needed
if [ -n "$CLAUDE_API_KEY" ]; then
  if ! python3 -c "import anthropic" 2>/dev/null; then
    echo "📦 Installing anthropic Python package..."
    pip3 install anthropic --quiet 2>/dev/null || pip3 install anthropic --break-system-packages --quiet
  fi
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
  python3 phase1_scan.py "$DRIVE" --output "$SCAN_OUTPUT"
  echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 2: Building consolidation plan (dry run)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -n "$CLAUDE_API_KEY" ]; then
  python3 phase2_reorganize.py "$DRIVE" \
    --scan-dir "$SCAN_OUTPUT" \
    --claude-api-key "$CLAUDE_API_KEY"
else
  python3 phase2_reorganize.py "$DRIVE" \
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
