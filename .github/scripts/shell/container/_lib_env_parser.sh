#!/usr/bin/env bash
# ============================================================
# Domain: Env Parser — safe .env file reading for docker --build-arg
#         injection. No shell execution, no variable expansion.
# ============================================================

# ------------------------------------------------------------
# @description  Parses a single KEY=VALUE line from a .env file and
#               writes the validated key and stripped value into the
#               caller's named variables via namerefs.
#
#               Contract:
#               - Skips blank lines and comment lines (# prefix).
#               - Strips optional 'export ' prefix, CRLF, and UTF-8 BOM.
#               - Strips matching surrounding single or double quotes.
#               - Rejects keys that violate [A-Za-z_][A-Za-z0-9_]*.
#               - Never executes shell substitutions or expands variables.
#
# @param $1     raw_line  - Raw line read from the .env file.
# @param $2     key_ref   - Nameref: receives the parsed key string.
# @param $3     value_ref - Nameref: receives the parsed value string.
# @return       0 on a valid KEY=VALUE line; 1 on blank, comment, or invalid.
# ------------------------------------------------------------
_env_parse_line() {
  local raw_line="${1-}"
  local -n _epl_key="$2"
  local -n _epl_value="$3"

  _epl_key=""
  _epl_value=""

  raw_line="${raw_line%$'\r'}"
  raw_line="${raw_line#$'\xEF\xBB\xBF'}"
  raw_line="${raw_line#"${raw_line%%[![:space:]]*}"}"
  raw_line="${raw_line%"${raw_line##*[![:space:]]}"}"

  [[ -z "${raw_line}" ]]     && return 1
  [[ "${raw_line}" == \#* ]] && return 1

  if [[ "${raw_line}" == export[[:space:]]* ]]; then
    raw_line="${raw_line#export }"
    raw_line="${raw_line#"${raw_line%%[![:space:]]*}"}"
  fi

  [[ "${raw_line}" == *"="* ]] || return 1

  local parsed_key="${raw_line%%=*}"
  local parsed_value="${raw_line#*=}"

  parsed_key="${parsed_key#"${parsed_key%%[![:space:]]*}"}"
  parsed_key="${parsed_key%"${parsed_key##*[![:space:]]}"}"
  parsed_value="${parsed_value#"${parsed_value%%[![:space:]]*}"}"
  parsed_value="${parsed_value%"${parsed_value##*[![:space:]]}"}"

  [[ -n "${parsed_key}" ]] || return 1
  [[ "${parsed_key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || { log_error "Invalid env var name in .env: '${parsed_key}'"; return 1; }

  if [[ ${#parsed_value} -ge 2 ]]; then
    if   [[ "${parsed_value:0:1}" == '"'  && "${parsed_value: -1}" == '"'  ]]; then
      parsed_value="${parsed_value:1:${#parsed_value}-2}"
    elif [[ "${parsed_value:0:1}" == "'"  && "${parsed_value: -1}" == "'"  ]]; then
      parsed_value="${parsed_value:1:${#parsed_value}-2}"
    fi
  fi

  _epl_key="${parsed_key}"
  _epl_value="${parsed_value}"
}

# ------------------------------------------------------------
# @description  Reads a .env file line-by-line and appends a --build-arg
#               flag per valid KEY=VALUE pair to the caller's array.
#               Silently skips files that do not exist.
#               Never sources the file or executes its content.
# @param $1     env_file  - Path to the .env file (absolute or relative).
# @param $2     args_ref  - Nameref: indexed array to append --build-arg entries.
# ------------------------------------------------------------
env_build_args() {
  local env_file="$1"
  local -n _eba_args="$2"

  if [[ ! -f "${env_file}" ]]; then
    log_info "No .env file at '${env_file}'. Continuing without build args."
    return 0
  fi

  log_info "Loading build args from '${env_file}'"

  local line="" key="" value="" count=0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    if _env_parse_line "${line}" key value; then
      _eba_args+=(--build-arg "${key}=${value}")
      (( count += 1 ))
      log_info "  build-arg: ${key}"
    fi
  done < "${env_file}"

  log_info "Loaded ${count} build arg(s)."
}
