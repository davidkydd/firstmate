# shellcheck shell=bash
# HTML/description/comment budgeting and spill composition for the ADO backlog
# backend. Split out of fm-ado-lib.sh (which sources this file) so the
# composition and follow-up-accumulation mechanics live in one cohesive unit;
# every function name and signature is unchanged, so callers that source
# fm-ado-lib.sh keep working with no change. See docs/ado-task-backend.md for the
# full field-mapping and overflow contract.
#
# Depends on fm_ado_az and the FM_ADO_* config globals (defined/populated in the
# core fm-ado-lib.sh, resolved at call time). This file defines the
# fm_ado_html_escape / fm_ado_*_len / fm_ado_emit_* / fm_ado_compose_description /
# fm_ado_*_spill_* / fm_ado_*followup* helpers.

# --- description composition -----------------------------------------------
# The Description is the durable full record of a work item, and it is NEVER
# truncated. System.Description is an HTML long-text field and the az CLI exposes
# no markdown-format flag, so the backend composes semantic HTML directly: an
# <h3>-delimited section per part, with the verbatim prompt and brief in <pre>
# blocks so their exact text (indentation, blank lines) is preserved. Every
# interpolated value is HTML-escaped so a prompt or brief containing <, >, or &
# cannot corrupt the markup.
#
# Sections:
#   initial-prompt : the captain's verbatim request (what the captain said)
#   brief          : the full generated brief handed to the crew (what firstmate
#                    turned the prompt into)
#   context        : delivery mode, kind, repo, and any extra context line
#
# FULL-PRESERVATION overflow (no truncation):
#   The Description holds as much of the composed content (initial-prompt first,
#   then brief) as fits FM_ADO_DESC_MAX_CHARS bytes; the context section (small)
#   is always included. Any prompt/brief bytes that do not fit spill to ordered
#   work-item COMMENTS (fm_ado_write_spill_comments -> posted by cmd_add after the
#   WI exists), FM_ADO_COMMENT_MAX_CHARS bytes each, so the Description's section
#   text concatenated with its spillover comments reconstructs the full prompt and
#   full brief exactly. Spillover is split at sensible break points (paragraph
#   blank lines, then line boundaries; a hard byte cut only when a single line
#   alone exceeds the budget), UTF-8-safe (iconv -c), so no word or multibyte char
#   is ever split. The data/<id>/brief.md pointer is a convenience note only, not
#   the recovery mechanism.

# fm_ado_html_escape  -> read stdin, escape &, <, > for safe HTML interpolation.
fm_ado_html_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# fm_ado_file_bytes <file>  -> echo the file's byte length (0 if absent).
fm_ado_file_bytes() {
  local n
  [ -f "$1" ] || { printf '0\n'; return 0; }
  n=$(wc -c < "$1" | tr -d ' ')
  printf '%s\n' "${n:-0}"
}

# fm_ado_head_len <file> <budget>  -> echo the byte length of the largest leading
# segment of <file> that is <= <budget> bytes, ends at a SENSIBLE break point
# (last paragraph blank line, else last line boundary, else a UTF-8-safe hard cut
# when a single line alone exceeds the budget), and never splits a word or a
# multibyte char. The remainder is bytes [len, end): head-len + tail concatenate
# back to the exact original.
fm_ado_head_len() {
  local file=$1 budget=$2 total win safe len
  total=$(fm_ado_file_bytes "$file")
  if [ "$budget" -le 0 ]; then printf '0\n'; return 0; fi
  if [ "$total" -le "$budget" ]; then printf '%s\n' "$total"; return 0; fi
  win=$(mktemp "${TMPDIR:-/tmp}/fm-ado-win.XXXXXX") || { printf '%s\n' "$budget"; return 0; }
  # UTF-8-safe window: drop any trailing partial multibyte char at the cut. iconv
  # -c exits non-zero when the final char is incomplete but still emits the valid
  # prefix, so keep its output and only fall back to raw bytes if it emitted none.
  head -c "$budget" "$file" | iconv -f UTF-8 -t UTF-8 -c > "$win" 2>/dev/null || true
  [ -s "$win" ] || head -c "$budget" "$file" > "$win"
  safe=$(fm_ado_file_bytes "$win")
  # Byte-accurate boundary scan (LC_ALL=C so length() is bytes, default RS=\n).
  # Prefer the last paragraph break (a blank line) within the window, else the
  # last line boundary, else a hard cut at the UTF-8-safe window when a single
  # line alone exceeds the budget. Every complete line in the window is
  # newline-terminated; the final partial line has no newline and its +1 overcount
  # pushes it past `safe`, so it is naturally excluded from a boundary cut.
  len=$(LC_ALL=C awk -v safe="$safe" '
    BEGIN { off = 0; best = 0; para = 0 }
    {
      newoff = off + length($0) + 1
      if (newoff <= safe) {
        best = newoff
        if ($0 == "") para = newoff
      }
      off = newoff
    }
    END {
      if (para > 0) print para
      else if (best > 0) print best
      else print safe
    }
  ' "$win")
  rm -f "$win" 2>/dev/null || true
  printf '%s\n' "${len:-$safe}"
}

# fm_ado_desc_budget  -> the Description byte budget.
fm_ado_desc_budget() {
  printf '%s\n' "${FM_ADO_DESC_MAX_CHARS:-$FM_ADO_DEFAULT_DESC_MAX_CHARS}"
}

# fm_ado_comment_budget  -> the per-spillover-comment byte budget.
fm_ado_comment_budget() {
  printf '%s\n' "${FM_ADO_COMMENT_MAX_CHARS:-$FM_ADO_DEFAULT_COMMENT_MAX_CHARS}"
}

# fm_ado_prompt_head_len <prompt-file>  -> bytes of the prompt that fit the
# Description (the prompt gets first claim on the whole Description budget).
fm_ado_prompt_head_len() {
  fm_ado_head_len "$1" "$(fm_ado_desc_budget)"
}

# fm_ado_brief_head_len <prompt-file> <brief-file>  -> bytes of the brief that fit
# the Description AFTER the prompt's share; 0 when the prompt already filled it.
fm_ado_brief_head_len() {
  local prompt_file=$1 brief_file=$2 budget p_total p_head rem
  budget=$(fm_ado_desc_budget)
  p_total=$(fm_ado_file_bytes "$prompt_file")
  p_head=$(fm_ado_prompt_head_len "$prompt_file")
  if [ "$p_head" -lt "$p_total" ]; then
    printf '0\n'; return 0        # prompt filled the Description; whole brief spills
  fi
  rem=$((budget - p_total))
  [ "$rem" -gt 0 ] || { printf '0\n'; return 0; }
  fm_ado_head_len "$brief_file" "$rem"
}

# fm_ado_emit_pre <file> <start-offset> <len>  -> HTML-escaped <pre> block for the
# byte range [start-offset, start-offset+len) of <file>. Empty len emits nothing.
# Used for spillover and follow-up COMMENT payloads, where a byte-exact <pre>
# round-trip is the reconstruction contract; the Description head uses the
# human-readable fm_ado_emit_rich instead.
fm_ado_emit_pre() {
  local file=$1 start=$2 len=$3
  [ "$len" -gt 0 ] || return 0
  printf '<pre>'
  tail -c +"$((start + 1))" "$file" | head -c "$len" | fm_ado_html_escape
  printf '</pre>\n'
}

# fm_ado_emit_rich <file> <start-offset> <len>  -> human-readable HTML for the byte
# range [start-offset, start-offset+len) of <file>. Empty len emits nothing.
# The text is HTML-escaped ONCE up front (so &, <, > can never corrupt the markup),
# then the common markdown that briefs and prompts actually contain is converted to
# clean HTML: blank-line-separated paragraphs become <p>, markdown list runs
# (`- `/`* ` or `N. `) become <ul>/<ol>, markdown headings (#/##/###) become
# <h4>/<h5>, and fenced code blocks (```) stay in <pre> so code/commands keep their
# formatting. This is pragmatic, not a full markdown parser. HTML-escaping runs
# before the awk pass, so awk only wraps already-escaped text in tags and never
# needs to escape; the markdown markers (- * # digits . `) are not escape targets,
# so they survive escaping intact. A fenced block left open by a byte-budget cut is
# closed at END so the emitted HTML is always well-formed.
fm_ado_emit_rich() {
  local file=$1 start=$2 len=$3
  [ "$len" -gt 0 ] || return 0
  tail -c +"$((start + 1))" "$file" | head -c "$len" | fm_ado_html_escape | awk '
    function flush_para() { if (para != "") { printf "<p>%s</p>\n", para; para = "" } }
    function flush_list() { if (in_list) { printf "</%s>\n", list_tag; in_list = 0 } }
    function flush_all() { flush_para(); flush_list() }
    BEGIN { para = ""; in_list = 0; in_code = 0; list_tag = "ul" }
    {
      line = $0
      if (in_code) {
        if (line ~ /^```/) { print "</pre>"; in_code = 0 }
        else { print line }
        next
      }
      if (line ~ /^```/) { flush_all(); print "<pre>"; in_code = 1; next }
      if (line ~ /^#+[ \t]/) {
        flush_all()
        n = 0; while (substr(line, n + 1, 1) == "#") n++
        tag = (n <= 2) ? "h4" : "h5"
        sub(/^#+[ \t]+/, "", line)
        printf "<%s>%s</%s>\n", tag, line, tag
        next
      }
      if (line ~ /^[-*][ \t]/) {
        flush_para()
        if (in_list && list_tag != "ul") flush_list()
        if (!in_list) { list_tag = "ul"; print "<ul>"; in_list = 1 }
        sub(/^[-*][ \t]+/, "", line)
        printf "<li>%s</li>\n", line
        next
      }
      if (line ~ /^[0-9]+\.[ \t]/) {
        flush_para()
        if (in_list && list_tag != "ol") flush_list()
        if (!in_list) { list_tag = "ol"; print "<ol>"; in_list = 1 }
        sub(/^[0-9]+\.[ \t]+/, "", line)
        printf "<li>%s</li>\n", line
        next
      }
      if (line ~ /^[ \t]*$/) { flush_all(); next }
      flush_list()
      if (para == "") para = line
      else para = para "<br>" line
    }
    END { if (in_code) print "</pre>"; flush_all() }
  '
}

# fm_ado_compose_description <id> <kind> <repo> [--prompt-file <p>] [--brief-file <p>]
#                            [--mode <m>] [--context <text>]
# Echo the composed HTML Description to stdout: the leading (budget-fitting) part
# of the prompt and brief plus the full context section. Content that does not fit
# is NOT dropped - fm_ado_write_spill_comments emits the remainder as ordered
# comments. Reads FM_ADO_DESC_MAX_CHARS (set by fm_ado_load_config).
fm_ado_compose_description() {
  local id=$1 kind=$2 repo=$3; shift 3
  local prompt_file="" brief_file="" mode="" context=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt-file) prompt_file=$2; shift 2 ;;
      --brief-file) brief_file=$2; shift 2 ;;
      --mode) mode=$2; shift 2 ;;
      --context) context=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  printf '<h3>initial-prompt</h3>\n'
  if [ -n "$prompt_file" ] && [ -f "$prompt_file" ]; then
    local p_total p_head
    p_total=$(fm_ado_file_bytes "$prompt_file")
    p_head=$(fm_ado_prompt_head_len "$prompt_file")
    fm_ado_emit_rich "$prompt_file" 0 "$p_head"
    if [ "$p_head" -lt "$p_total" ]; then
      printf '<p><em>(prompt continues in the work-item comments below)</em></p>\n'
    fi
  else
    printf '<p><em>(no prompt recorded)</em></p>\n'
  fi
  if [ -n "$brief_file" ] && [ -f "$brief_file" ]; then
    printf '<h3>brief</h3>\n'
    local b_total b_head
    b_total=$(fm_ado_file_bytes "$brief_file")
    b_head=$(fm_ado_brief_head_len "$prompt_file" "$brief_file")
    fm_ado_emit_rich "$brief_file" 0 "$b_head"
    if [ "$b_head" -lt "$b_total" ]; then
      printf '<p><em>(brief continues in the work-item comments below; full brief also at data/%s/brief.md)</em></p>\n' \
        "$(printf '%s' "$id" | fm_ado_html_escape)"
    fi
  fi
  printf '<h3>context</h3>\n<ul>\n'
  printf '<li>kind: %s</li>\n' "$(printf '%s' "$kind" | fm_ado_html_escape)"
  printf '<li>repo: %s</li>\n' "$(printf '%s' "$repo" | fm_ado_html_escape)"
  [ -n "$mode" ] && printf '<li>delivery-mode: %s</li>\n' "$(printf '%s' "$mode" | fm_ado_html_escape)"
  [ -n "$context" ] && printf '<li>%s</li>\n' "$(printf '%s' "$context" | fm_ado_html_escape)"
  printf '</ul>\n'
}

# fm_ado_section_spill_parts <file> <consumed>  -> echo one "start<TAB>len" line
# per spillover segment of <file> after the first <consumed> bytes, each <=
# FM_ADO_COMMENT_MAX_CHARS and split at a sensible boundary. Nothing echoed when
# the whole file already fit the Description.
fm_ado_section_spill_parts() {
  local file=$1 consumed=$2 total budget pos sub seglen
  total=$(fm_ado_file_bytes "$file")
  [ "$consumed" -lt "$total" ] || return 0
  budget=$(fm_ado_comment_budget)
  pos=$consumed
  while [ "$pos" -lt "$total" ]; do
    sub=$(mktemp "${TMPDIR:-/tmp}/fm-ado-spill.XXXXXX") || return 1
    # Only the first <budget> bytes of the remaining tail can affect the cut, so
    # slice at most budget+1 bytes (the +1 keeps this segment above budget when the
    # true tail is, so fm_ado_head_len does the boundary scan instead of returning
    # a full-tail hard cut). This makes the whole split O(n), not O(n^2).
    tail -c +"$((pos + 1))" "$file" | head -c "$((budget + 1))" > "$sub"
    seglen=$(fm_ado_head_len "$sub" "$budget")
    rm -f "$sub" 2>/dev/null || true
    [ "$seglen" -gt 0 ] || seglen=$((total - pos))   # never stall
    printf '%s\t%s\n' "$pos" "$seglen"
    pos=$((pos + seglen))
  done
}

# fm_ado_write_spill_comments <id> <spill-dir> [--prompt-file <p>] [--brief-file <p>]
#   -> write one ordered payload file per spillover comment into <spill-dir>
#      (NNNN, zero-padded, globally ordered: prompt parts then brief parts), and
#      echo the number of comment files written. Each payload is a labelled,
#      HTML-escaped <pre> block whose text continues the Description's section, so
#      the caller can post them with `az ... update --discussion "$(cat file)"`
#      after the WI exists. Prompt/brief head lengths match
#      fm_ado_compose_description exactly, so no byte is duplicated or lost.
#      Every payload carries a machine-findable marker
#      `<!-- fm-spill:<id>:<section>:<part>/<m> -->`. This is the CREATE-path
#      overflow only: a re-add never re-posts it (the create's prompt/brief are
#      durable); a follow-up prompt on a re-add accumulates separately via
#      fm_ado_write_followup_comments / fm_ado_append_followup.
fm_ado_write_spill_comments() {
  local id=$1 spill_dir=$2; shift 2
  local prompt_file="" brief_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt-file) prompt_file=$2; shift 2 ;;
      --brief-file) brief_file=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  mkdir -p "$spill_dir" 2>/dev/null || return 1
  # Collect (label, file, start, len) for every spillover part, in global order.
  local -a labels=() files=() starts=() lens=()
  local start len p_head b_head
  if [ -n "$prompt_file" ] && [ -f "$prompt_file" ]; then
    p_head=$(fm_ado_prompt_head_len "$prompt_file")
    while IFS=$'\t' read -r start len; do
      [ -n "$len" ] || continue
      labels+=("initial-prompt"); files+=("$prompt_file"); starts+=("$start"); lens+=("$len")
    done < <(fm_ado_section_spill_parts "$prompt_file" "$p_head")
  fi
  if [ -n "$brief_file" ] && [ -f "$brief_file" ]; then
    b_head=$(fm_ado_brief_head_len "$prompt_file" "$brief_file")
    while IFS=$'\t' read -r start len; do
      [ -n "$len" ] || continue
      labels+=("brief"); files+=("$brief_file"); starts+=("$start"); lens+=("$len")
    done < <(fm_ado_section_spill_parts "$brief_file" "$b_head")
  fi
  local total=${#labels[@]} i seq=0 label
  # Per-section part counts for N/M labels.
  local prompt_m=0 brief_m=0
  for ((i = 0; i < total; i++)); do
    case "${labels[$i]}" in
      initial-prompt) prompt_m=$((prompt_m + 1)) ;;
      brief) brief_m=$((brief_m + 1)) ;;
    esac
  done
  local prompt_n=0 brief_n=0 n m fname section
  for ((i = 0; i < total; i++)); do
    label=${labels[$i]}
    case "$label" in
      initial-prompt) prompt_n=$((prompt_n + 1)); n=$prompt_n; m=$prompt_m; section=initial-prompt ;;
      brief) brief_n=$((brief_n + 1)); n=$brief_n; m=$brief_m; section=brief ;;
      *) n=1; m=1; section=other ;;
    esac
    seq=$((seq + 1))
    fname=$(printf '%s/%04d' "$spill_dir" "$seq")
    {
      printf '<!-- fm-spill:%s:%s:%s/%s -->\n' "$id" "$section" "$n" "$m"
      printf '<h3>%s (continued, part %s/%s)</h3>\n' "$label" "$n" "$m"
      fm_ado_emit_pre "${files[$i]}" "${starts[$i]}" "${lens[$i]}"
    } > "$fname"
  done
  printf '%s\n' "$total"
}

# fm_ado_post_spill_comments <wi> <spill-dir>  -> post every ordered spillover
# payload file in <spill-dir> as a work-item comment, in filename order. Returns
# non-zero if any post failed (the caller surfaces a diagnostic).
fm_ado_post_spill_comments() {
  local wi=$1 spill_dir=$2 f rc=0
  [ -d "$spill_dir" ] || return 0
  for f in "$spill_dir"/[0-9]*; do
    [ -f "$f" ] || continue
    fm_ado_az boards work-item update --id "$wi" \
      --discussion "$(cat "$f")" --org "$FM_ADO_ORG" -o json >/dev/null 2>&1 || rc=1
  done
  return "$rc"
}

# --- follow-up prompt accumulation -----------------------------------------
# A re-add of an already-created work item with a NEW prompt ACCUMULATES that
# prompt rather than overwriting anything: the original prompt stays in the
# Description untouched, and each follow-up prompt is appended to the Description
# under a dated `<h3>Follow-up prompt (<ISO-date>)</h3>` header when it fits
# FM_ADO_DESC_MAX_CHARS, or posted as ordered work-item comment(s) (the same
# FM_ADO_COMMENT_MAX_CHARS split machinery as create-path overflow) when the
# append would exceed the Description budget. Either way no prior prompt is ever
# moved, overwritten, or dropped, and a failed write leaves the stored
# Description intact.

# fm_ado_followup_section <prompt-file> <iso-date>  -> echo the HTML follow-up
# section for the WHOLE prompt: a dated header plus the human-readable prompt.
# This is the in-Description append form (used when it fits the Description
# budget), so it renders with fm_ado_emit_rich to match the Description head; the
# overflow-to-comment form keeps <pre> for its byte-exact reconstruction contract.
fm_ado_followup_section() {
  local prompt_file=$1 date=$2 total
  printf '<h3>Follow-up prompt (%s)</h3>\n' "$(printf '%s' "$date" | fm_ado_html_escape)"
  total=$(fm_ado_file_bytes "$prompt_file")
  fm_ado_emit_rich "$prompt_file" 0 "$total"
}

# fm_ado_write_followup_comments <fm-id> <spill-dir> <prompt-file> <iso-date>
#   -> write one ordered payload file per comment into <spill-dir> (NNNN,
#      zero-padded), each a dated, HTML-escaped <pre> block whose parts
#      concatenate back to the exact prompt, and echo the number of files written.
#      Used when appending the follow-up to the Description would exceed the
#      Description budget: the follow-up prompt lands in comment(s) instead, split
#      at sensible boundaries at most FM_ADO_COMMENT_MAX_CHARS bytes each. Every
#      payload carries a machine-findable marker
#      `<!-- fm-followup:<id>:<date>:<part>/<m> -->`, so a follow-up comment set is
#      distinguishable from create-path fm-spill comments.
fm_ado_write_followup_comments() {
  local id=$1 spill_dir=$2 prompt_file=$3 date=$4
  [ -f "$prompt_file" ] || { printf '0\n'; return 0; }
  mkdir -p "$spill_dir" 2>/dev/null || return 1
  local -a starts=() lens=()
  local start len
  while IFS=$'\t' read -r start len; do
    [ -n "$len" ] || continue
    starts+=("$start"); lens+=("$len")
  done < <(fm_ado_section_spill_parts "$prompt_file" 0)
  local total=${#starts[@]} i seq=0 fname
  [ "$total" -ge 1 ] || { printf '0\n'; return 0; }
  for ((i = 0; i < total; i++)); do
    seq=$((seq + 1))
    fname=$(printf '%s/%04d' "$spill_dir" "$seq")
    {
      printf '<!-- fm-followup:%s:%s:%s/%s -->\n' "$id" "$date" "$((i + 1))" "$total"
      printf '<h3>Follow-up prompt (%s), part %s/%s</h3>\n' \
        "$(printf '%s' "$date" | fm_ado_html_escape)" "$((i + 1))" "$total"
      fm_ado_emit_pre "$prompt_file" "${starts[$i]}" "${lens[$i]}"
    } > "$fname"
  done
  printf '%s\n' "$total"
}

# fm_ado_append_followup <wi> <existing-desc-file> <prompt-file> <iso-date>
#   Append the dated follow-up section to the WI's Description. The caller has
#   already read the existing Description into <existing-desc-file> and verified
#   the combined result fits the Description budget. Writes the full new
#   Description in ONE az update so a failed write leaves the original intact
#   (never a partial or dropped Description). Returns non-zero on write failure.
fm_ado_append_followup() {
  local wi=$1 existing_file=$2 prompt_file=$3 date=$4 new_file
  new_file=$(mktemp "${TMPDIR:-/tmp}/fm-ado-desc-new.XXXXXX") || return 1
  cat "$existing_file" > "$new_file"
  fm_ado_followup_section "$prompt_file" "$date" >> "$new_file"
  fm_ado_az boards work-item update --id "$wi" --description "$(cat "$new_file")" \
    --org "$FM_ADO_ORG" -o json >/dev/null 2>&1
  local rc=$?
  rm -f "$new_file" 2>/dev/null || true
  return "$rc"
}

# fm_ado_followup_fits <existing-desc-file> <prompt-file> <iso-date>  -> 0 iff
# appending the dated follow-up section to the existing Description stays within
# the Description byte budget (FM_ADO_DESC_MAX_CHARS). Composes the section into a
# temp file and compares existing + section bytes against the budget.
fm_ado_followup_fits() {
  local existing_file=$1 prompt_file=$2 date=$3 budget existing section sec_file
  budget=$(fm_ado_desc_budget)
  existing=$(fm_ado_file_bytes "$existing_file")
  sec_file=$(mktemp "${TMPDIR:-/tmp}/fm-ado-followup-sec.XXXXXX") || return 1
  fm_ado_followup_section "$prompt_file" "$date" > "$sec_file"
  section=$(fm_ado_file_bytes "$sec_file")
  rm -f "$sec_file" 2>/dev/null || true
  [ "$((existing + section))" -le "$budget" ]
}
