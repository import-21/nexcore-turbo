# Small assertion helpers shared by the shell test suites.
# shellcheck shell=sh

T_PASS=0
T_FAIL=0
T_FAILED=""

pass() { T_PASS=$((T_PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { T_FAIL=$((T_FAIL + 1)); T_FAILED="$T_FAILED
  - $1"; printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }

# expect_eq <name> <expected> <actual>
expect_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}

# expect_match <name> <grep -E pattern> <text>
expect_match() {
    if printf '%s' "$3" | grep -Eq -- "$2"; then pass "$1"; else fail "$1" "no match for /$2/ in [$(printf '%s' "$3" | head -c 300)]"; fi
}

expect_no_match() {
    if printf '%s' "$3" | grep -Eq -- "$2"; then fail "$1" "unexpected /$2/ in [$(printf '%s' "$3" | head -c 300)]"; else pass "$1"; fi
}

summary() {
    printf '\n%s: %d passed, %d failed\n' "${1:-result}" "$T_PASS" "$T_FAIL"
    [ "$T_FAIL" -eq 0 ] || { printf 'failed:%s\n' "$T_FAILED"; return 1; }
}

# cache_status <curl args...>  -> value of X-Turbo-Cache ("" when absent)
cache_status() {
    curl -s -o /dev/null -D - "$@" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-turbo-cache"{print $2}'
}

http_code() {
    curl -s -o /dev/null -w '%{http_code}' "$@"
}
