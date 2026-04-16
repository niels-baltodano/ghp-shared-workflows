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
# @example
#   key="" value=""
#   _env_parse_line 'API_KEY=my-secret' key value
#   # key="API_KEY"  value="my-secret"
#
#   _env_parse_line 'export DB_URL="postgresql://localhost"' key value
#   # key="DB_URL"  value="postgresql://localhost"  (export prefix + quotes stripped)
#
#   _env_parse_line "PORT='8080'" key value
#   # key="PORT"  value="8080"  (single quotes stripped)
#
#   _env_parse_line '# this is a comment' key value
#   # return 1  (comment line — skipped)
#
#   _env_parse_line '' key value
#   # return 1  (blank line — skipped)
#
#   _env_parse_line '1INVALID=value' key value
#   # return 1  — ❌ Invalid env var name in .env: '1INVALID'
# ------------------------------------------------------------
_env_parse_line() {
	local raw_line="${1-}"
	local -n _epl_key="$2"
	local -n _epl_value="$3"

	# Reset output namerefs so callers never see stale values from a prior call.
	_epl_key=""
	_epl_value=""

	# ── Normalize raw bytes ──────────────────────────────────────

	# Strip Windows-style carriage return (\r) from line endings (CRLF files).
	raw_line="${raw_line%$'\r'}"

	# Strip UTF-8 BOM (0xEF 0xBB 0xBF) that some editors prepend to the first line.
	raw_line="${raw_line#$'\xEF\xBB\xBF'}"

	# Strip leading whitespace.
	# Pattern: remove the prefix that consists solely of spaces/tabs.
	# "${raw_line%%[![:space:]]*}" matches everything up to the first non-space char;
	# removing it as a prefix leaves only the non-space content onward.
	raw_line="${raw_line#"${raw_line%%[![:space:]]*}"}"

	# Strip trailing whitespace using the mirror of the same trick:
	# "${raw_line##*[![:space:]]}" matches everything after the last non-space char;
	# removing it as a suffix leaves only up to (and including) the last non-space char.
	raw_line="${raw_line%"${raw_line##*[![:space:]]}"}"

	# ── Skip non-data lines ──────────────────────────────────────

	# Skip blank lines (empty after trimming).
	[[ -z "${raw_line}" ]] && return 1

	# Skip comment lines (first non-space character is '#').
	[[ "${raw_line}" == \#* ]] && return 1

	# ── Strip optional 'export ' prefix ─────────────────────────

	# Some .env files use 'export KEY=VALUE' so the file can also be sourced
	# directly in a shell. Strip the keyword and any trailing spaces after it.
	if [[ "${raw_line}" == export[[:space:]]* ]]; then
		raw_line="${raw_line#export }"
		# Strip any extra spaces between 'export' and the key name.
		raw_line="${raw_line#"${raw_line%%[![:space:]]*}"}"
	fi

	# ── Require KEY=VALUE structure ──────────────────────────────

	# Lines without '=' are not valid KEY=VALUE pairs — skip them.
	[[ "${raw_line}" == *"="* ]] || return 1

	# ── Split into key and value ─────────────────────────────────

	# "%%=*"  — remove the longest suffix starting with '=', leaving only the key.
	# "#*="   — remove everything up to and including the first '=', leaving the value.
	# This correctly handles values that contain '=' (e.g. BASE64=abc=def).
	local parsed_key="${raw_line%%=*}"
	local parsed_value="${raw_line#*=}"

	# Trim whitespace around both sides (handles 'KEY = VALUE' with spaces).
	parsed_key="${parsed_key#"${parsed_key%%[![:space:]]*}"}"
	parsed_key="${parsed_key%"${parsed_key##*[![:space:]]}"}"
	parsed_value="${parsed_value#"${parsed_value%%[![:space:]]*}"}"
	parsed_value="${parsed_value%"${parsed_value##*[![:space:]]}"}"

	# ── Validate key name ────────────────────────────────────────

	# Reject empty keys (e.g. a line starting with '=').
	[[ -n "${parsed_key}" ]] || return 1

	# Enforce POSIX variable name rules: must start with a letter or underscore,
	# followed by letters, digits, or underscores only.
	# Rejecting invalid names prevents injecting arbitrary strings into docker build args.
	[[ "${parsed_key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
		{
			log_error "Invalid env var name in .env: '${parsed_key}'"
			return 1
		}

	# ── Strip surrounding quotes from the value ──────────────────

	# Only strip quotes when the value is at least 2 characters long AND both
	# the opening and closing character are the same quote type.
	# This handles:  KEY="value"  and  KEY='value'
	# But leaves:    KEY="unclosed  and  KEY=it's  unchanged.
	if [[ ${#parsed_value} -ge 2 ]]; then
		if [[ "${parsed_value:0:1}" == '"' && "${parsed_value: -1}" == '"' ]]; then
			parsed_value="${parsed_value:1:${#parsed_value}-2}"
		elif [[ "${parsed_value:0:1}" == "'" && "${parsed_value: -1}" == "'" ]]; then
			parsed_value="${parsed_value:1:${#parsed_value}-2}"
		fi
	fi

	# ── Write results to caller's namerefs ───────────────────────
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
# @example
#   # .env file contains:
#   #   API_KEY=secret
#   #   PORT=8080
#   #   # ignored comment
#   local args=()
#   env_build_args "/workspace/.env" args
#   # args=(--build-arg "API_KEY=secret" --build-arg "PORT=8080")
#   # Logs: "Loaded 2 build arg(s)."
#
#   # .env file does not exist:
#   env_build_args "/workspace/.env" args
#   # args unchanged
#   # Logs: "No .env file at '/workspace/.env'. Continuing without build args."
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
			((count += 1))
			log_info "  build-arg: ${key}"
		fi
	done <"${env_file}"

	log_info "Loaded ${count} build arg(s)."
}
