#!/usr/bin/env bash
#
# make_presentation.sh - research a topic on the web, analyse the material and build a
# PowerPoint (.pptx) presentation.
#
# Stages (each is a separate `claude -p` call, so every stage can be checked on its own):
#   1. research  - Claude searches the web (WebSearch / WebFetch only) and returns findings
#   2. analysis  - Claude separates facts, assumptions, interpretations, alternative views
#   3. build     - build_pptx.py (python-pptx) turns the analysis into slides
#
# Usage:
#   Script/make_presentation.sh -t "topic or condition" [-n 10] [-l Ukrainian] [-o deck.pptx]
#   Script/make_presentation.sh --from-analysis deck.analysis.json -o deck.pptx
#
# Options:
#   -t TOPIC            topic / condition the material is searched for (required unless --from-analysis)
#   -n N                target slide count, default 10 (a guide for the analysis, not a hard limit)
#   -l LANGUAGE         language of the content, default Ukrainian
#   -o FILE             output file, default presentation.pptx
#   -m MODEL            model for both Claude calls
#   --template FILE     .pptx whose layouts and theme are used for the slides
#   --from-analysis F   skip stages 1-2 and build from an existing analysis JSON
#   -h                  this help
#
# Kept next to the output: <name>.findings.json and <name>.analysis.json.
# Needs: claude (logged in or ANTHROPIC_API_KEY), python3, python-pptx, open internet access.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
topic="" slides=10 lang="Ukrainian" out="presentation.pptx" model="" template="" from_analysis=""

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "$1" >&2; exit "${2:-1}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t) topic="${2:?-t needs a value}"; shift 2 ;;
        -n) slides="${2:?-n needs a value}"; shift 2 ;;
        -l) lang="${2:?-l needs a value}"; shift 2 ;;
        -o) out="${2:?-o needs a value}"; shift 2 ;;
        -m) model="${2:?-m needs a value}"; shift 2 ;;
        --template) template="${2:?--template needs a value}"; shift 2 ;;
        --from-analysis) from_analysis="${2:?--from-analysis needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unknown option: $1" 2 ;;
    esac
done

[[ "$slides" =~ ^[0-9]+$ && "$slides" -ge 3 ]] || die "-n must be a whole number >= 3." 2
[[ -n "$topic" || -n "$from_analysis" ]] || { usage >&2; die "Give -t TOPIC or --from-analysis FILE." 2; }
command -v python3 >/dev/null 2>&1 || die "python3 not found."
python3 -c 'import pptx' 2>/dev/null || die "python-pptx is missing. Run: pip install python-pptx"
[[ -z "$template" || -r "$template" ]] || die "Cannot read template '$template'."

base="${out%.pptx}"
findings_file="$base.findings.json"
analysis_file="$base.analysis.json"

# Keep only the JSON object from Claude's reply (drops code fences and chatter); fails if invalid.
extract_json() {
    python3 -I -c '
import json, sys
t = sys.stdin.read()
a, b = t.find("{"), t.rfind("}")
if a < 0 or b < a:
    sys.exit(1)
print(json.dumps(json.loads(t[a:b + 1]), ensure_ascii=False, indent=2))
'
}

# claude_json STAGE_TAG SYSTEM_PROMPT INPUT_TEXT TOOLS(web|none)  -> valid JSON on stdout
claude_json() {
    local tag="$1" system="$2" input="$3" tools="$4" attempt reply json args
    command -v claude >/dev/null 2>&1 || die "'claude' not found. Install it: npm install -g @anthropic-ai/claude-code"
    for attempt in 1 2; do
        args=(-p --append-system-prompt "$system")
        if [[ "$tools" == web ]]; then
            args+=(--allowedTools WebSearch WebFetch --disallowedTools Bash Edit Write NotebookEdit)
        else
            args+=(--disallowedTools WebSearch WebFetch Bash Edit Write NotebookEdit)
        fi
        [[ -n "$model" ]] && args+=(--model "$model")
        if ! reply="$(printf '%s' "$input" | claude "${args[@]}")"; then
            die "Claude failed at stage '$tag'; check login or ANTHROPIC_API_KEY and internet access."
        fi
        if json="$(printf '%s' "$reply" | extract_json)"; then
            printf '%s\n' "$json"
            return 0
        fi
        echo "Stage '$tag': reply was not valid JSON (attempt $attempt of 2)." >&2
        system="$system REMINDER: your previous reply was not valid JSON. Return ONLY one JSON object, no text around it."
    done
    die "Stage '$tag' did not produce valid JSON."
}

if [[ -z "$from_analysis" ]]; then
    echo "[1/3] Researching: $topic" >&2
    research_system="STAGE:RESEARCH. Search the web for material on the topic given by the user and read the most relevant, \
authoritative sources (prefer primary and peer-reviewed sources; note dates). Write all text in $lang. \
Return ONLY one JSON object: {\"topic\": string, \"findings\": [{\"claim\": string, \"source_title\": string, \
\"source_url\": string, \"date\": string, \"type\": \"fact\" | \"estimate\" | \"opinion\"}]}. \
Collect 15-30 findings that cover the topic, including views that disagree with each other."
    claude_json research "$research_system" "$topic" web > "$findings_file"
    echo "      saved $findings_file" >&2

    echo "[2/3] Analysing the material" >&2
    analysis_system="STAGE:ANALYSIS. You receive research findings as JSON. Analyse them as a staff analyst preparing a briefing: \
keep facts, assumptions, interpretations and conclusions strictly separate; weigh source quality; flag contradictions and outdated data. \
Write all text in $lang. Keep every list item to one or two sentences and the lists short enough for a deck of about $slides slides. \
Return ONLY one JSON object: {\"title\": string, \"subtitle\": string, \"conclusion\": [string], \"facts\": [string], \
\"assumptions\": [string], \"interpretations\": [string], \"alternative_views\": [{\"position\": string, \"strength\": string}], \
\"confidence\": string, \"gaps\": [string], \"practical_takeaways\": [string], \"sources\": [{\"title\": string, \"url\": string}]}. \
Use only the findings you were given; do not add facts from memory."
    claude_json analysis "$analysis_system" "$(cat "$findings_file")" none > "$analysis_file"
    echo "      saved $analysis_file" >&2
else
    [[ -r "$from_analysis" ]] || die "Cannot read '$from_analysis'."
    analysis_file="$from_analysis"
    echo "[1-2/3] Skipped; using $analysis_file" >&2
fi

echo "[3/3] Building $out" >&2
build_args=("$analysis_file" -o "$out")
[[ -n "$template" ]] && build_args+=(--template "$template")
case "${lang,,}" in english*|en) build_args+=(--lang en) ;; *) build_args+=(--lang uk) ;; esac
python3 "$HERE/build_pptx.py" "${build_args[@]}"
