#!/usr/bin/env bash
# =============================================================================
#  pr-cross-check.sh -- second-opinion PR review via ppq.ai (GPT + DeepSeek)
#
#  Purpose:
#    Diff the current branch against a base branch and send it to two extra
#    models (OpenAI GPT and DeepSeek, via the ppq.ai proxy) for an independent
#    review, as a cross-check alongside Claude's own review.
#
#  Setup:
#    cp ops/pr-review/.review.env_example ops/pr-review/.review.env
#    # then fill in PPQ_API_KEY
#
#  Usage:
#    ops/pr-review/pr-cross-check.sh [base-ref] [head-ref]
#    ops/pr-review/pr-cross-check.sh --list-models
#
#    base-ref defaults to "master". If head-ref is omitted, the working tree
#    (staged + unstaged changes, on top of any commits already made on this
#    branch) is reviewed instead of requiring a commit first. Pass an explicit
#    head-ref (e.g. HEAD) to review only committed changes.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.review.env"
API_BASE="https://api.ppq.ai"

MODEL_GPT="${PPQ_MODEL_GPT:-openai/gpt-5.6-luna}"
MODEL_DEEPSEEK="${PPQ_MODEL_DEEPSEEK:-deepseek/deepseek-v4-pro}"

require_tools() {
  for tool in curl jq git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Missing required tool: $tool" >&2
      exit 1
    fi
  done
}

load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Missing $ENV_FILE -- copy .review.env_example and set PPQ_API_KEY." >&2
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  if [[ -z "${PPQ_API_KEY:-}" ]]; then
    echo "PPQ_API_KEY is not set in $ENV_FILE" >&2
    exit 1
  fi
  MODEL_GPT="${PPQ_MODEL_GPT:-$MODEL_GPT}"
  MODEL_DEEPSEEK="${PPQ_MODEL_DEEPSEEK:-$MODEL_DEEPSEEK}"
}

list_models() {
  curl -sS "$API_BASE/v1/models" \
    -H "Authorization: Bearer $PPQ_API_KEY" \
    | jq -r '.data[]?.id // .[]?.id // .'
}

review_with_model() {
  local model="$1" diff="$2"
  local prompt payload response content

  prompt=$(cat <<EOF
You are an independent code reviewer cross-checking a pull request diff for
an infrastructure/deployment repo (Docker Swarm, shell scripts, docker-compose
stacks, monitoring configs). Review the diff below for correctness bugs,
security issues, and risky/destructive changes. Be concise: list findings as
a short bullet list with file/line references where possible. If nothing is
wrong, say so briefly.

DIFF:
$diff
EOF
)

  # Pass the prompt via a temp file: large diffs exceed the argv size limit.
  local pfile
  pfile=$(mktemp)
  printf '%s' "$prompt" > "$pfile"
  payload=$(jq -n --arg model "$model" --rawfile content "$pfile" \
    '{model: $model, messages: [{role: "user", content: $content}]}')
  rm -f "$pfile"

  response=$(curl -sS "$API_BASE/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $PPQ_API_KEY" \
    --data-binary @- <<<"$payload")

  content=$(echo "$response" | jq -r '.choices[0].message.content // empty')

  echo "=============================================================="
  echo "Reviewer: $model"
  echo "=============================================================="
  if [[ -z "$content" ]]; then
    echo "No content returned. Raw response:"
    echo "$response"
  else
    echo "$content"
  fi
  echo
}

main() {
  require_tools
  load_env

  if [[ "${1:-}" == "--list-models" ]]; then
    list_models
    exit 0
  fi

  local base="${1:-master}"
  local head="${2:-}"

  local diff label
  if [[ -n "$head" ]]; then
    diff=$(git diff "${base}...${head}")
    label="$base...$head"
  else
    # No head-ref given: review the working tree (staged + unstaged) on top
    # of the base, so uncommitted work-in-progress can be reviewed too.
    diff=$(git diff "${base}")
    label="$base...(working tree)"
  fi

  if [[ -z "$diff" ]]; then
    echo "No diff between $base and $label." >&2
    exit 0
  fi

  echo "Cross-checking diff $label with $MODEL_GPT and $MODEL_DEEPSEEK"
  echo

  review_with_model "$MODEL_GPT" "$diff"
  review_with_model "$MODEL_DEEPSEEK" "$diff"
}

main "$@"
