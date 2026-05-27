#!/bin/bash
# MEMPALACE CURSOR PRE-COMPACT HOOK — Snapshot transcript before compaction
#
# Cursor "preCompact" hook. Cursor's preCompact is documented as
# OBSERVATIONAL ONLY (cursor.com/docs/hooks.md fetched 2026-05-27):
#
#   * It cannot block compaction.
#   * Its only output field is `user_message` (no `followup_message`,
#     no `decision: block`).
#
# So unlike the Claude Code PreCompact hook (which can block the AI
# and force a save before compaction proceeds), the Cursor preCompact
# hook can only do two useful things at this moment:
#
#   1. Run `mempalace mine` SYNCHRONOUSLY against the transcript file.
#      The verbatim drawers land in the palace BEFORE Cursor
#      summarises the conversation. This is the actual data-loss
#      protection — zero LLM cost, no agent interaction needed.
#
#   2. Drop a `.pending` marker file keyed on conversation_id. The
#      next `stop` hook reads that marker and forces a save followup
#      regardless of its counter, so the AI still gets a "write a
#      diary entry now" nudge on the very next turn.
#
# === INSTALL ===
#
# Add to ~/.cursor/hooks.json (or .cursor/hooks.json for project
# scope) under "preCompact":
#
#   {
#     "version": 1,
#     "hooks": {
#       "preCompact": [
#         { "command": "/absolute/path/to/mempal_precompact_hook_cursor.sh" }
#       ]
#     }
#   }
#
# No loop_limit is needed; preCompact is not a looping hook.

_mempal_self="${BASH_SOURCE[0]:-$0}"
_mempal_dir="$(cd "$(dirname "$_mempal_self")" 2>/dev/null && pwd)"
# shellcheck source=lib/common.sh
. "$_mempal_dir/lib/common.sh"

# Optional additional project directory to mine before compaction
# (parity with the Claude Code hook's MEMPAL_DIR knob).
MEMPAL_DIR="${MEMPAL_DIR:-}"

if mempal_is_disabled; then
    mempal_emit '{}'
    exit 0
fi

INPUT="$(cat)"
mempal_parse_stdin "$INPUT"

if [ "$MEMPAL_PARSE_OK" != "1" ]; then
    mempal_dump_bad_input "$INPUT" "preCompact"
    mempal_emit '{}'
    exit 0
fi

mempal_log "preCompact" "$MEMPAL_CONV_ID" \
    "trigger=${MEMPAL_TRIGGER:-?} transcript=$MEMPAL_TRANSCRIPT"

# ── Synchronous mine ──────────────────────────────────────────────
#
# This intentionally blocks the hook (within Cursor's per-hook
# timeout). Compaction is irreversible — once Cursor summarises the
# conversation we cannot get the verbatim text back. Background-mining
# would race the compaction.
if command -v mempalace >/dev/null 2>&1; then
    if mempal_is_valid_transcript "$MEMPAL_TRANSCRIPT" \
        && [ -f "$MEMPAL_TRANSCRIPT" ]; then
        mempalace mine "$(dirname "$MEMPAL_TRANSCRIPT")" --mode convos \
            >> "$MEMPAL_CURSOR_LOG" 2>&1 || \
            mempal_log "preCompact" "$MEMPAL_CONV_ID" \
                "WARN: mempalace mine convos returned non-zero"
    elif [ -n "$MEMPAL_TRANSCRIPT" ]; then
        mempal_log "preCompact" "$MEMPAL_CONV_ID" \
            "skipping invalid transcript path: $MEMPAL_TRANSCRIPT"
    fi
    if [ -n "$MEMPAL_DIR" ] && [ -d "$MEMPAL_DIR" ]; then
        mempalace mine "$MEMPAL_DIR" --mode projects \
            >> "$MEMPAL_CURSOR_LOG" 2>&1 || \
            mempal_log "preCompact" "$MEMPAL_CONV_ID" \
                "WARN: mempalace mine projects returned non-zero"
    fi
else
    mempal_log "preCompact" "$MEMPAL_CONV_ID" \
        "mempalace CLI not on PATH; skipping synchronous mine"
fi

# ── Drop the pending-save marker ──────────────────────────────────
mempal_set_pending "$MEMPAL_CONV_ID" || \
    mempal_log "preCompact" "$MEMPAL_CONV_ID" \
        "WARN: could not write pending-save marker"

# Surface a short user-visible note that compaction is about to
# happen and we've already captured the verbatim text. user_message
# is the only output field Cursor's preCompact accepts.
"$MEMPAL_PYTHON_BIN" -c '
import json
print(json.dumps({
    "user_message": (
        "MemPalace: transcript snapshotted before compaction. "
        "A diary nudge is queued for the next agent turn."
    )
}))
'
