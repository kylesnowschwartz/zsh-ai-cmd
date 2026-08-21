# providers/bedrock.zsh - Amazon Bedrock provider (bedrock-mantle and bedrock-runtime)
#
# Opt-in via ZSH_AI_CMD_PROVIDER='bedrock'. The chosen model must be enabled in the Region --
# model access is granted per account and per Region, so a model reachable in one may need
# requesting in another. Credentials are an Amazon Bedrock API key on the plugin's standard chain
# (BEDROCK_API_KEY -> ZSH_AI_CMD_API_KEY_COMMAND -> Keychain), so this provider adds no credential
# machinery of its own. External dependencies are the plugin's own: curl and jq.
#
# AWS profile / SigV4 credentials are unsupported for now: nothing on the service side blocks
# them, but the single-string credential chain cannot express multi-valued, expiring ones.
# Planned for once that chain gains a credential-process contract.
#
# Endpoints: https://docs.aws.amazon.com/bedrock/latest/userguide/models-endpoint-availability.html

typeset -g ZSH_AI_CMD_BEDROCK_MODEL=${ZSH_AI_CMD_BEDROCK_MODEL:-'openai.gpt-5.6-luna'}

# A fixed default rather than $AWS_REGION: bedrock-mantle is offered in a subset of Regions, so an
# ambient value could point at one without it, and inference would silently move Region whenever
# an unrelated AWS session changed. us-west-2 is where the routing table below was measured.
typeset -g ZSH_AI_CMD_BEDROCK_REGION=${ZSH_AI_CMD_BEDROCK_REGION:-'us-west-2'}

# Tunable because Bedrock compiles a JSON schema it has not seen into a grammar on first use --
# documented as possibly taking minutes, then cached for 24h -- so the first call after a long
# idle period can legitimately outlast a fixed default.
# https://docs.aws.amazon.com/bedrock/latest/userguide/structured-output.html
typeset -g ZSH_AI_CMD_BEDROCK_TIMEOUT=${ZSH_AI_CMD_BEDROCK_TIMEOUT:-30}

# Pinned rather than inherited, because turning one sentence into one command is pattern
# completion: reasoning tokens are charged to the budget below before any output is emitted, so
# higher settings spend it on deliberation the task does not need. 'low' suits this well and is
# adaptive -- zero reasoning tokens on ordinary prompts, more where a request earns it -- while
# 'none' keeps to the most literal reading. Supported: none|low|medium|high|xhigh|max.
typeset -g ZSH_AI_CMD_BEDROCK_EFFORT=${ZSH_AI_CMD_BEDROCK_EFFORT:-'low'}

# Reasoning is charged to this budget before any output is emitted, so the two track each other:
# raise this if ZSH_AI_CMD_BEDROCK_EFFORT is raised.
typeset -g ZSH_AI_CMD_BEDROCK_MAX_TOKENS=${ZSH_AI_CMD_BEDROCK_MAX_TOKENS:-2048}

# No retry here, deliberately: the trigger key is the better-placed one. A failed suggestion
# leaves BUFFER intact, so re-querying costs a single keystroke, any keypress already cancels an
# in-flight call, and no sibling provider retries.

# responses | chat_completions | auto
#
# Only modes that enforce the JSON schema are offered, since the destructive flag is trustworthy
# exactly when the schema is applied -- which is why the Anthropic Messages API sits outside this
# set (see the anthropic.* branch in _zsh_ai_cmd_bedrock_route). 'auto' derives the mode from the
# model ID, measured against the whole bedrock-mantle catalogue rather than inferred, so changing
# ZSH_AI_CMD_BEDROCK_MODEL is normally enough.
typeset -g ZSH_AI_CMD_BEDROCK_API=${ZSH_AI_CMD_BEDROCK_API:-'auto'}

# Models that accept a schema field and return the JSON wrapped in prose, which the wire parser
# cannot extract. Listed so the reason is visible up front rather than surfacing as an empty
# suggestion. gemma-3-12b-it complies on roughly half of prompts, so measure a candidate across
# ./test-api.sh rather than a single prompt -- schema compliance is best read as a rate.
#
# Edit here rather than overriding: zsh cannot `export` an array, so the natural `export
# ZSH_AI_CMD_*` override yields a scalar, and the (Ie) subscript below would match substrings
# instead of whole entries.
typeset -ga ZSH_AI_CMD_BEDROCK_UNSUPPORTED_MODELS=(
  openai.gpt-oss-120b
  openai.gpt-oss-20b
  openai.gpt-oss-safeguard-20b
  mistral.magistral-small-2509
  moonshotai.kimi-k2-thinking
  google.gemma-3-12b-it
)

# mantle | runtime. Only the OpenAI-compatible APIs are implemented; they carry the model in the
# request body, so no model ID ever reaches the URL. bedrock-runtime's native /model/{id}/converse
# and /invoke paths are unimplemented here rather than unreachable.
typeset -g ZSH_AI_CMD_BEDROCK_ENDPOINT=${ZSH_AI_CMD_BEDROCK_ENDPOINT:-'mantle'}

# Resolve (model, api, endpoint) -> (api mode, URL path), setting _mode and _path in the caller.
# Compatibility is per-model rather than per-vendor -- gemma-4 serves Responses while gemma-3
# serves Chat Completions -- so the table cannot key on the vendor prefix alone. $endpoint is
# already validated by the caller, which has to resolve it to a host anyway.
_zsh_ai_cmd_bedrock_route() {
  local model=$1 api=$2 endpoint=${3:-mantle}
  _mode=$api

  if [[ $api == auto ]]; then
    case $model in
      openai.gpt-[0-9]*|google.gemma-4*|xai.grok-*) _mode=responses ;;
      *)                                            _mode=chat_completions ;;
    esac
  fi

  if (( ${ZSH_AI_CMD_BEDROCK_UNSUPPORTED_MODELS[(Ie)$model]} )); then
    print -u2 "zsh-ai-cmd [bedrock]: '$model' returns the JSON wrapped in prose, so no suggestion"
    print -u2 "  can be parsed from its output. Choose another model."
    return 1
  fi

  # Claude on mantle is served by /anthropic/v1/messages, which offers advisory tool schemas rather
  # than the enforced kind the destructive flag relies on. Enforced structured output for Claude is
  # available on Bedrock through bedrock-runtime's native InvokeModel/Converse, so supporting these
  # models is a matter of implementing that path.
  if [[ $model == anthropic.* ]]; then
    print -u2 "zsh-ai-cmd [bedrock]: '$model' is served by the Messages API on bedrock-mantle, which"
    print -u2 "  offers advisory rather than enforced schemas. Choose a model on the Responses or Chat Completions API."
    return 1
  fi

  case $_mode in
    responses|chat_completions) ;;
    messages)
      print -u2 "zsh-ai-cmd [bedrock]: the Anthropic Messages API is not supported (no structured output)"
      return 1 ;;
    *) print -u2 "zsh-ai-cmd [bedrock]: unknown ZSH_AI_CMD_BEDROCK_API '$_mode'"
       print -u2 "  expected: auto | responses | chat_completions  (values are case-sensitive)"
       return 1 ;;
  esac

  # Chat Completions lives under an /openai prefix on runtime; bare /v1/chat/completions answers
  # with a Coral UnknownOperationException. Responses is available on runtime too, but runtime
  # resolves models through Region-prefixed inference profiles (us., eu.) rather than the plain IDs
  # the auto table uses, and that prefix varies by Region -- so this pairing asks for an explicit
  # choice rather than guessing an ID.
  if [[ $endpoint == runtime ]]; then
    [[ $_mode == chat_completions ]] || {
      print -u2 "zsh-ai-cmd [bedrock]: '$_mode' is not available on the bedrock-runtime endpoint"
      return 1
    }
    _path='/openai/v1/chat/completions'
    return 0
  fi

  case $_mode in
    # No catalogue model serves bare /v1/responses, so that path is not attempted.
    responses)        _path='/openai/v1/responses' ;;
    chat_completions) _path='/v1/chat/completions' ;;
  esac
  return 0
}

_zsh_ai_cmd_bedrock_call() {
  local input=$1
  local base_prompt=$2
  local model=$ZSH_AI_CMD_BEDROCK_MODEL
  local region=$ZSH_AI_CMD_BEDROCK_REGION

  # Only reachable if the user blanks the variable after the default was applied; without this the
  # request would go to a host built from an empty Region.
  [[ -z $region ]] && {
    print -u2 "zsh-ai-cmd [bedrock]: ZSH_AI_CMD_BEDROCK_REGION is empty (default: us-west-2)"
    return 1
  }

  # Reaches jq via --argjson, where a non-numeric value fails as an opaque parse error instead.
  [[ $ZSH_AI_CMD_BEDROCK_MAX_TOKENS == <-> ]] || {
    print -u2 "zsh-ai-cmd [bedrock]: ZSH_AI_CMD_BEDROCK_MAX_TOKENS must be an integer (got '$ZSH_AI_CMD_BEDROCK_MAX_TOKENS')"
    return 1
  }

  # Validated once, here: rejecting an unknown endpoint and resolving it to a host are the same
  # decision, so _route can trust the value.
  local host
  case $ZSH_AI_CMD_BEDROCK_ENDPOINT in
    mantle)  host="https://bedrock-mantle.${region}.api.aws" ;;
    runtime) host="https://bedrock-runtime.${region}.amazonaws.com" ;;
    *) print -u2 "zsh-ai-cmd [bedrock]: unknown ZSH_AI_CMD_BEDROCK_ENDPOINT '$ZSH_AI_CMD_BEDROCK_ENDPOINT'"
       print -u2 "  expected: mantle | runtime  (values are case-sensitive)"
       return 1 ;;
  esac

  local _mode _path
  _zsh_ai_cmd_bedrock_route "$model" "$ZSH_AI_CMD_BEDROCK_API" "$ZSH_AI_CMD_BEDROCK_ENDPOINT" || return 1

  # Bedrock accepts only a subset of JSON Schema Draft 2020-12 -- no recursion, no external $ref,
  # no numeric or length constraints -- and returns 400 outside it. The shared schema complies
  # today; an edit there adding one of those would break Bedrock alone.
  local prompt="${base_prompt}${_ZSH_AI_CMD_PROMPT_STRUCTURED}"

  local payload
  case $_mode in
    responses)
      # store:false is mandatory, not an optimization: the API defaults to store:true, which
      # retains the prompt -- including $PWD and the typed intent -- for 30 days.
      # https://docs.aws.amazon.com/bedrock/latest/userguide/bedrock-mantle.html
      payload=$(command jq -nc \
        --arg model "$model" \
        --arg system "$prompt" \
        --arg content "$input" \
        --argjson schema "$_ZSH_AI_CMD_SCHEMA" \
        --argjson max_tokens "$ZSH_AI_CMD_BEDROCK_MAX_TOKENS" \
        --arg effort "$ZSH_AI_CMD_BEDROCK_EFFORT" \
        '{
          model: $model,
          instructions: $system,
          input: $content,
          store: false,
          max_output_tokens: $max_tokens,
          reasoning: {effort: $effort},
          text: {format: {type: "json_schema", name: "shell_command", schema: $schema, strict: true}}
        }')
      ;;
    chat_completions)
      payload=$(command jq -nc \
        --arg model "$model" \
        --arg system "$prompt" \
        --arg content "$input" \
        --argjson schema "$_ZSH_AI_CMD_SCHEMA" \
        --argjson max_tokens "$ZSH_AI_CMD_BEDROCK_MAX_TOKENS" \
        --arg effort "$ZSH_AI_CMD_BEDROCK_EFFORT" \
        '{
          model: $model,
          max_completion_tokens: $max_tokens,
          reasoning_effort: $effort,
          messages: [
            {role: "system", content: $system},
            {role: "user", content: $content}
          ],
          response_format: {type: "json_schema", json_schema: {name: "shell_command", schema: $schema, strict: true}}
        }')
      ;;
  esac

  # Populated by _zsh_ai_cmd_get_key's chain before the provider runs.
  local -a auth=()
  if [[ -n ${BEDROCK_API_KEY:-} ]]; then
    auth=(-H "Authorization: Bearer ${BEDROCK_API_KEY}")
  else
    print -u2 "zsh-ai-cmd [bedrock]: BEDROCK_API_KEY is not set"
    return 1
  fi

  # -w appends the status on its own line, so an HTTP error carrying an empty body stays
  # distinguishable from no response at all (curl reports 000 when it never received one).
  local response http_code
  response=$(command curl -sS --max-time "$ZSH_AI_CMD_BEDROCK_TIMEOUT" -w '\n%{http_code}' "${host}${_path}" \
    -H "Content-Type: application/json" \
    "${auth[@]}" \
    -d "$payload" 2>/dev/null)
  http_code=${response##*$'\n'}
  response=${response%$'\n'*}

  # jq stderr is dropped here: on a non-JSON body it would print a parse error to the prompt, since
  # the widget redirects only stdout to its tmpfile. The raw body is logged regardless.
  if [[ $ZSH_AI_CMD_DEBUG == true ]]; then
    {
      print -- "=== $(date '+%Y-%m-%d %H:%M:%S') [bedrock] ==="
      print -- "endpoint: ${host}${_path} (api_mode=$_mode, http=$http_code)"
      print -- "--- REQUEST ---"
      command jq . <<< "$payload" 2>/dev/null || print -r -- "$payload"
      print -- "--- RESPONSE ---"
      command jq . <<< "$response" 2>/dev/null || print -r -- "$response"
      print ""
    } >>$ZSH_AI_CMD_LOG
  fi

  # 000 is a transport failure (timeout, DNS, TLS); any other status means an HTTP error that
  # carried no body, such as a proxy 502.
  [[ -z $response ]] && {
    if [[ $http_code == 000 ]]; then
      print -u2 "zsh-ai-cmd [bedrock]: no response from ${host} (timed out or unreachable)"
    else
      print -u2 "zsh-ai-cmd [bedrock]: HTTP $http_code from ${host} with no error body"
    fi
    return 1
  }

  # Four error shapes across these endpoints: mantle uses .error.message, bedrock-runtime a
  # capitalized .Message, and runtime can answer HTTP 200 with a Coral fault envelope carrying no
  # message at all. tostring keeps an object-valued .error from reaching the prompt as raw JSON.
  local error_msg
  error_msg=$(print -r -- "$response" | command jq -re \
    '(.error.message // .error // .message // .Message // .Output.__type // empty) | tostring' 2>/dev/null)
  if [[ -n $error_msg ]]; then
    print -u2 "zsh-ai-cmd [bedrock]: $error_msg"
    return 1
  fi

  # A non-2xx matching none of those shapes would otherwise reach the widget as "no suggestion".
  if [[ $http_code != 2* ]]; then
    print -u2 "zsh-ai-cmd [bedrock]: HTTP $http_code from ${host}"
    return 1
  fi

  # A truncated, filtered or refused completion is a *successful* response carrying no parseable
  # command, so it passes every check above and would surface as a bare "no suggestion". Pinning
  # ZSH_AI_CMD_BEDROCK_EFFORT is the primary defence; this is the backstop, and it stays regardless
  # of budget because reasoning spend is a rate and a model may under-honour the effort hint. It is
  # intermittent, which is why the message offers re-triggering first.
  local stop
  case $_mode in
    responses)
      stop=$(print -r -- "$response" | command jq -re \
        '[.incomplete_details.reason // (.output[]? | select(.type == "message") | .content[]? | select(.type == "refusal") | .refusal)] | .[0] // empty' 2>/dev/null) ;;
    chat_completions)
      stop=$(print -r -- "$response" | command jq -re \
        '[(.choices[0].finish_reason | select(. == "length" or . == "content_filter")) // .choices[0].message.refusal] | .[0] // empty' 2>/dev/null) ;;
  esac
  if [[ -n $stop ]]; then
    case $stop in
      max_output_tokens|length)
        print -u2 "zsh-ai-cmd [bedrock]: response truncated at ${ZSH_AI_CMD_BEDROCK_MAX_TOKENS} tokens ($stop)"
        print -u2 "  Reasoning is charged to that budget before any output -- press ${ZSH_AI_CMD_KEY:-^z} to retry, or raise ZSH_AI_CMD_BEDROCK_MAX_TOKENS." ;;
      *)
        print -u2 "zsh-ai-cmd [bedrock]: model returned no usable answer ($stop)" ;;
    esac
    return 1
  fi

  case $_mode in
    responses)
      _zsh_ai_cmd_extract "$response" \
        '(.output[] | select(.type == "message") | .content[] | select(.type == "output_text") | .text)'
      ;;
    chat_completions)
      _zsh_ai_cmd_extract "$response" '.choices[0].message.content'
      ;;
  esac
}

_zsh_ai_cmd_bedrock_key_error() {
  print -u2 ""
  if [[ -z $ZSH_AI_CMD_BEDROCK_REGION ]]; then
    print -u2 "zsh-ai-cmd: ZSH_AI_CMD_BEDROCK_REGION is empty"
    print -u2 ""
    print -u2 "It defaults to us-west-2 (AWS_REGION is deliberately ignored, and"
    print -u2 "bedrock-mantle is not offered in every Region):"
    print -u2 "  export ZSH_AI_CMD_BEDROCK_REGION='us-west-2'"
    return
  fi

  print -u2 "zsh-ai-cmd: BEDROCK_API_KEY not found"
  print -u2 ""
  print -u2 "Generate an Amazon Bedrock API key in the Bedrock console, then set it via"
  print -u2 "environment variable:"
  print -u2 "  export BEDROCK_API_KEY='ABSK...'"
  print -u2 ""
  print -u2 "Or store in macOS Keychain:"
  print -u2 "  security add-generic-password -s 'bedrock-api-key' -a \"\$USER\" -w 'ABSK...'"
  print -u2 ""
  print -u2 "Or retrieve it with a command:"
  print -u2 "  export ZSH_AI_CMD_API_KEY_COMMAND='pass \${provider}-api-key'"
  print -u2 ""
  print -u2 "AWS profile / SigV4 credentials are not supported yet."
}
