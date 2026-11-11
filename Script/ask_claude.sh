#!/usr/bin/env bash
#
# ask_claude.sh - ask Claude one or more questions non-interactively.
#
# Claude may search the web (WebSearch / WebFetch) to answer. All other tools
# (shell, file editing) are disabled, so the run cannot change anything on the
# machine. Intended for a normal machine or VM with open internet access; the
# repository's .devcontainer firewall would block web search.
#
# Usage:
#   Script/ask_claude.sh -q "question"            ask one question
#   Script/ask_claude.sh -f questions.txt         one question per line
#                                                 (empty lines and lines starting with # are skipped)
#   Script/ask_claude.sh -q "..." -o answer.md    also save the answer to a file
#   Script/ask_claude.sh -q "..." -m MODEL        choose a model
#
# Authentication (one of):
#   - run `claude` once and log in, or
#   - export ANTHROPIC_API_KEY=...
#
# Environment:
#   ASK_SYSTEM_PROMPT   replaces the default instructions given to Claude

set -euo pipefail

DEFAULT_PROMPT='Answer the question using web search where it helps. Reply in the language of the question. Start with a short conclusion, then give the reasoning. Separate facts, assumptions and conclusions. Cite sources with URLs, and state your level of confidence when information may be outdated or incomplete.'
SYSTEM_PROMPT="${ASK_SYSTEM_PROMPT:-$DEFAULT_PROMPT}"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

question="" file="" out="" model=""
while getopts ":q:f:o:m:h" opt; do
    case "$opt" in
        q) question="$OPTARG" ;;
        f) file="$OPTARG" ;;
        o) out="$OPTARG" ;;
        m) model="$OPTARG" ;;
        h) usage; exit 0 ;;
        :) echo "Option -$OPTARG needs a value." >&2; usage >&2; exit 2 ;;
        *) echo "Unknown option -$OPTARG." >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -n "$question" && -n "$file" ]] || [[ -z "$question" && -z "$file" ]]; then
    echo "Give exactly one of -q or -f." >&2
    usage >&2
    exit 2
fi
if ! command -v claude >/dev/null 2>&1; then
    echo "'claude' not found. Install it: npm install -g @anthropic-ai/claude-code" >&2
    exit 1
fi

questions=()
if [[ -n "$question" ]]; then
    questions+=("$question")
else
    [[ -r "$file" ]] || { echo "Cannot read '$file'." >&2; exit 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "${line//[[:space:]]/}" || "$line" == \#* ]] && continue
        questions+=("$line")
    done < "$file"
    [[ ${#questions[@]} -gt 0 ]] || { echo "No questions found in '$file'." >&2; exit 1; }
fi

[[ -n "$out" ]] && : > "$out"

args=(-p --allowedTools WebSearch WebFetch --disallowedTools Bash Edit Write NotebookEdit
      --append-system-prompt "$SYSTEM_PROMPT")
[[ -n "$model" ]] && args+=(--model "$model")

status=0
for i in "${!questions[@]}"; do
    q="${questions[$i]}"
    header="## Q$((i + 1)): $q"
    answer=""
    # The question goes through stdin so that a leading '-' is never read as an option.
    if ! answer="$(printf '%s' "$q" | claude "${args[@]}")"; then
        echo "Claude failed on question $((i + 1)); check login or ANTHROPIC_API_KEY." >&2
        status=1
        continue
    fi
    if [[ ${#questions[@]} -gt 1 ]]; then
        printf '%s\n\n%s\n\n' "$header" "$answer"
    else
        printf '%s\n' "$answer"
    fi
    if [[ -n "$out" ]]; then
        if [[ ${#questions[@]} -gt 1 ]]; then
            printf '%s\n\n%s\n\n' "$header" "$answer" >> "$out"
        else
            printf '%s\n' "$answer" >> "$out"
        fi
    fi
done

exit "$status"
