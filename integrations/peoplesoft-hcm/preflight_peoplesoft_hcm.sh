#!/usr/bin/env bash
# =============================================================================
# preflight_peoplesoft_hcm.sh
# Pre-deployment validation script for the PeopleSoft HCM → Veza OAA integration
#
# Derived from: peoplesoft_hcm.py — validates every prerequisite that the
# Python script requires before it can run successfully.
#
# Usage:
#   Interactive menu:  bash preflight_peoplesoft_hcm.sh
#   Non-interactive:   bash preflight_peoplesoft_hcm.sh --all
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Colors (cyan replaces dim blue for readability)
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_WARNING=0

# ---------------------------------------------------------------------------
# Print helpers
# ---------------------------------------------------------------------------
print_success() { echo -e "${GREEN}  ✓${NC}  $1"; ((TESTS_PASSED++)); }
print_fail()    { echo -e "${RED}  ✗${NC}  $1"; ((TESTS_FAILED++)); }
print_warning() { echo -e "${YELLOW}  ⚠${NC}  $1"; ((TESTS_WARNING++)); }
print_info()    { echo -e "${CYAN}  ℹ${NC}  $1"; }
print_header()  {
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Script directory (where the integration files live)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
LOG_FILE="${SCRIPT_DIR}/preflight_$(date +%Y%m%d_%H%M%S).log"

# Python — prefer venv
if [[ -f "${SCRIPT_DIR}/venv/bin/python3" ]]; then
    PYTHON="${SCRIPT_DIR}/venv/bin/python3"
else
    PYTHON="python3"
fi

# Mask sensitive values
mask_value() {
    local val="$1"
    local show="${2:-8}"
    if [[ ${#val} -le "${show}" ]]; then
        echo "***"
    else
        echo "${val:0:${show}}..."
    fi
}

# ---------------------------------------------------------------------------
# Tee all output to log file
# ---------------------------------------------------------------------------
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo -e "${BOLD}  PeopleSoft HCM → Veza OAA — Preflight Validation${NC}"
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "  Log: ${LOG_FILE}"
echo ""

# ===========================================================================
# SECTION 1 — System Requirements
# ===========================================================================
check_system_requirements() {
    print_header "1 — System Requirements"

    # OS detection
    OS_NAME="unknown"
    if [[ -f /etc/os-release ]]; then
        OS_NAME=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
    elif [[ "$(uname)" == "Darwin" ]]; then
        OS_NAME="macOS $(sw_vers -productVersion)"
    fi
    print_info "OS: ${OS_NAME}"

    # Python version (minimum 3.8)
    if command -v "${PYTHON}" &>/dev/null; then
        PY_VER=$(${PYTHON} -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')" 2>/dev/null)
        PY_MAJOR=$(echo "${PY_VER}" | cut -d. -f1)
        PY_MINOR=$(echo "${PY_VER}" | cut -d. -f2)
        if [[ "${PY_MAJOR}" -ge 3 && "${PY_MINOR}" -ge 8 ]]; then
            print_success "Python ${PY_VER} (via ${PYTHON})"
        else
            print_fail "Python ${PY_VER} — version 3.8+ required"
        fi
    else
        print_fail "Python not found at ${PYTHON}"
    fi

    # Check if running inside a venv
    if [[ -f "${SCRIPT_DIR}/venv/bin/python3" ]]; then
        print_success "Virtual environment found: ${SCRIPT_DIR}/venv"
    else
        print_warning "No virtual environment found at ${SCRIPT_DIR}/venv — run install_peoplesoft_hcm.sh first"
    fi

    # pip3
    if ${PYTHON} -m pip --version &>/dev/null; then
        PIP_VER=$(${PYTHON} -m pip --version | awk '{print $2}')
        print_success "pip ${PIP_VER}"
    else
        print_fail "pip not available for ${PYTHON}"
    fi

    # Java (required for jaydebeapi/JPype1)
    if command -v java &>/dev/null; then
        JAVA_VER=$(java -version 2>&1 | head -1)
        print_success "Java: ${JAVA_VER}"
    else
        print_fail "Java not found — required for JDBC connectivity (jaydebeapi/JPype1)"
        print_info  "  Install: sudo dnf install -y java-11-openjdk-headless"
        print_info  "           sudo apt-get install -y openjdk-11-jre-headless"
    fi

    # JAVA_HOME
    if [[ -n "${JAVA_HOME:-}" ]]; then
        print_success "JAVA_HOME=${JAVA_HOME}"
    else
        print_warning "JAVA_HOME not set — JPype1 may fail to locate JVM"
        print_info    "  Set in shell profile: export JAVA_HOME=\$(dirname \$(dirname \$(readlink -f \$(which java))))"
    fi

    # curl
    if command -v curl &>/dev/null; then
        print_success "curl: $(curl --version | head -1 | awk '{print $1,$2}')"
    else
        print_fail "curl not found — required for API connectivity tests"
    fi

    # jq (optional)
    if command -v jq &>/dev/null; then
        print_success "jq $(jq --version) (optional — for JSON inspection)"
    else
        print_warning "jq not found (optional — install for readable JSON output)"
    fi
}

# ===========================================================================
# SECTION 2 — Python Dependencies
# ===========================================================================
check_python_dependencies() {
    print_header "2 — Python Dependencies"

    REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements.txt"
    if [[ ! -f "${REQUIREMENTS_FILE}" ]]; then
        print_fail "requirements.txt not found at ${REQUIREMENTS_FILE}"
        return
    fi

    print_info "Using Python: ${PYTHON}"
    print_info "Checking packages from requirements.txt..."
    echo ""

    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "${line}" =~ ^[[:space:]]*# || -z "${line// /}" ]] && continue
        # Extract package name (strip version specifiers)
        pkg_name=$(echo "${line}" | sed 's/[>=<!].*//' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        # Handle install name vs import name differences
        import_name="${pkg_name}"
        case "${pkg_name}" in
            python-dotenv)  import_name="dotenv" ;;
            jaydebeapi)     import_name="jaydebeapi" ;;
            jpype1)         import_name="jpype" ;;
            oaaclient)      import_name="oaaclient" ;;
        esac

        if ${PYTHON} -c "import ${import_name}" 2>/dev/null; then
            pkg_ver=$(${PYTHON} -c "
try:
    import importlib.metadata as m
    print(m.version('${pkg_name}'))
except Exception:
    print('?')
" 2>/dev/null)
            print_success "${pkg_name} v${pkg_ver}"
        else
            print_fail "${pkg_name} — not installed"
            print_info  "  Fix: ${PYTHON} -m pip install -r ${REQUIREMENTS_FILE}"
        fi
    done < "${REQUIREMENTS_FILE}"
}

# ===========================================================================
# SECTION 3 — Configuration File
# ===========================================================================
check_configuration() {
    print_header "3 — Configuration File"

    if [[ ! -f "${ENV_FILE}" ]]; then
        print_fail ".env not found at ${ENV_FILE}"
        print_info "  Generate template: cp ${SCRIPT_DIR}/.env.example ${ENV_FILE} && chmod 600 ${ENV_FILE}"
        return
    fi

    print_success ".env found: ${ENV_FILE}"

    # Check permissions (must be 600)
    ENV_PERMS=$(stat -c '%a' "${ENV_FILE}" 2>/dev/null || stat -f '%A' "${ENV_FILE}" 2>/dev/null)
    if [[ "${ENV_PERMS}" == "600" ]]; then
        print_success ".env permissions: ${ENV_PERMS} (correct)"
    else
        print_fail ".env permissions: ${ENV_PERMS} (must be 600)"
        print_info  "  Fix: chmod 600 ${ENV_FILE}"
    fi

    # Source env file
    # shellcheck disable=SC1090
    set -a; source "${ENV_FILE}"; set +a

    echo ""
    print_info "Validating required variables:"

    # Required variables (from load_config() in peoplesoft_hcm.py)
    declare -A REQUIRED_VARS=(
        [VEZA_URL]="${VEZA_URL:-}"
        [VEZA_API_KEY]="${VEZA_API_KEY:-}"
        [PS_DB_HOST]="${PS_DB_HOST:-}"
        [PS_DB_SERVICE]="${PS_DB_SERVICE:-}"
        [PS_DB_USER]="${PS_DB_USER:-}"
        [PS_DB_PASSWORD]="${PS_DB_PASSWORD:-}"
        [JDBC_DRIVER_PATH]="${JDBC_DRIVER_PATH:-}"
    )

    for var_name in VEZA_URL VEZA_API_KEY PS_DB_HOST PS_DB_SERVICE PS_DB_USER PS_DB_PASSWORD JDBC_DRIVER_PATH; do
        val="${!var_name:-}"
        if [[ -z "${val}" ]]; then
            print_fail "${var_name} — not set"
        elif echo "${val}" | grep -qiE '^(your_|https://your-|REPLACE_)'; then
            print_fail "${var_name} — still has placeholder value"
        else
            # Mask sensitive values
            if echo "${var_name}" | grep -qiE 'PASSWORD|KEY|TOKEN|SECRET'; then
                print_success "${var_name}=$(mask_value "${val}" 8)"
            else
                print_success "${var_name}=${val}"
            fi
        fi
    done

    # Optional variables
    echo ""
    print_info "Optional variables:"
    for var_name in PS_DB_PORT PROVIDER_NAME DATASOURCE_NAME; do
        val="${!var_name:-}"
        if [[ -n "${val}" ]]; then
            print_info "  ${var_name}=${val}"
        else
            print_info "  ${var_name} (not set — default will be used)"
        fi
    done

    # JDBC driver file check
    echo ""
    JDBC_PATH="${JDBC_DRIVER_PATH:-}"
    if [[ -n "${JDBC_PATH}" ]]; then
        if [[ -f "${JDBC_PATH}" ]]; then
            JAR_SIZE=$(du -h "${JDBC_PATH}" | cut -f1)
            print_success "JDBC driver exists: ${JDBC_PATH} (${JAR_SIZE})"
        else
            print_fail "JDBC driver not found: ${JDBC_PATH}"
            print_info  "  Fix: download ojdbc11.jar and update JDBC_DRIVER_PATH in ${ENV_FILE}"
            print_info  "  Download: curl -fsSL https://repo1.maven.org/maven2/com/oracle/database/jdbc/ojdbc11/23.7.0.25.01/ojdbc11-23.7.0.25.01.jar -o ${JDBC_PATH}"
        fi
    else
        print_fail "JDBC_DRIVER_PATH not configured"
    fi
}

# ===========================================================================
# SECTION 4 — Network Connectivity
# ===========================================================================
check_network_connectivity() {
    print_header "4 — Network Connectivity"

    # Source env
    [[ -f "${ENV_FILE}" ]] && { set -a; source "${ENV_FILE}"; set +a; }

    # Oracle DB TCP check
    DB_HOST="${PS_DB_HOST:-}"
    DB_PORT="${PS_DB_PORT:-1521}"

    if [[ -n "${DB_HOST}" ]]; then
        print_info "Testing TCP connection to Oracle DB: ${DB_HOST}:${DB_PORT}"
        TCP_OK=false
        if command -v nc &>/dev/null; then
            if nc -zw 5 "${DB_HOST}" "${DB_PORT}" 2>/dev/null; then
                TCP_OK=true
            fi
        else
            if timeout 5 bash -c ">/dev/tcp/${DB_HOST}/${DB_PORT}" 2>/dev/null; then
                TCP_OK=true
            fi
        fi

        if "${TCP_OK}"; then
            print_success "TCP ${DB_HOST}:${DB_PORT} — reachable"
        else
            print_fail    "TCP ${DB_HOST}:${DB_PORT} — not reachable"
            print_info    "  Check: firewall rules, VPN, PS_DB_HOST, PS_DB_PORT"
        fi
    else
        print_warning "PS_DB_HOST not set — skipping Oracle DB connectivity check"
    fi

    # Veza HTTPS check
    VEZA_URL_VAL="${VEZA_URL:-}"
    if [[ -n "${VEZA_URL_VAL}" ]]; then
        # Ensure https:// prefix
        [[ "${VEZA_URL_VAL}" != https://* ]] && VEZA_URL_VAL="https://${VEZA_URL_VAL}"
        VEZA_HOST=$(echo "${VEZA_URL_VAL}" | sed 's|https://||' | cut -d/ -f1)
        print_info "Testing HTTPS to Veza: ${VEZA_URL_VAL}"
        if command -v curl &>/dev/null; then
            RESULT=$(curl -s -o /dev/null -w "%{http_code}|%{time_total}" \
                -m 10 "${VEZA_URL_VAL}" 2>/dev/null || echo "000|timeout")
            HTTP_CODE=$(echo "${RESULT}" | cut -d'|' -f1)
            LATENCY=$(echo "${RESULT}" | cut -d'|' -f2)
            if [[ "${HTTP_CODE}" =~ ^[23] ]]; then
                print_success "Veza HTTPS ${VEZA_URL_VAL} — HTTP ${HTTP_CODE} (${LATENCY}s)"
            elif [[ "${HTTP_CODE}" == "000" ]]; then
                print_fail    "Veza HTTPS ${VEZA_URL_VAL} — connection failed (timeout or DNS)"
            else
                print_warning "Veza HTTPS ${VEZA_URL_VAL} — HTTP ${HTTP_CODE} (expected 2xx/3xx)"
            fi
        else
            print_warning "curl not available — skipping HTTPS check"
        fi
    else
        print_warning "VEZA_URL not set — skipping Veza connectivity check"
    fi
}

# ===========================================================================
# SECTION 5 — API / Database Authentication
# ===========================================================================
check_authentication() {
    print_header "5 — API / Database Authentication"

    [[ -f "${ENV_FILE}" ]] && { set -a; source "${ENV_FILE}"; set +a; }

    DB_HOST="${PS_DB_HOST:-}"
    DB_PORT="${PS_DB_PORT:-1521}"
    DB_SERVICE="${PS_DB_SERVICE:-}"
    DB_USER="${PS_DB_USER:-}"
    DB_PASSWORD="${PS_DB_PASSWORD:-}"
    JDBC_DRIVER="${JDBC_DRIVER_PATH:-}"
    JAVA_HOME_VAL="${JAVA_HOME:-}"

    # Oracle DB auth test via jaydebeapi
    if [[ -n "${DB_HOST}" && -n "${DB_SERVICE}" && -n "${DB_USER}" && -n "${DB_PASSWORD}" && -f "${JDBC_DRIVER}" ]]; then
        print_info "[DEBUG] Connecting to jdbc:oracle:thin:@${DB_HOST}:${DB_PORT}/${DB_SERVICE} as ${DB_USER}"
        print_info "[DEBUG] JDBC driver: ${JDBC_DRIVER}"

        DB_TEST_RESULT=$(${PYTHON} - <<PYEOF 2>&1
import os, sys
if '${JAVA_HOME_VAL}':
    os.environ['JAVA_HOME'] = '${JAVA_HOME_VAL}'
try:
    import jaydebeapi
    conn = jaydebeapi.connect(
        'oracle.jdbc.driver.OracleDriver',
        'jdbc:oracle:thin:@${DB_HOST}:${DB_PORT}/${DB_SERVICE}',
        ['${DB_USER}', '${DB_PASSWORD}'],
        '${JDBC_DRIVER}'
    )
    curs = conn.cursor()
    curs.execute('SELECT BANNER FROM v\$version WHERE ROWNUM = 1')
    row = curs.fetchone()
    curs.close()
    conn.close()
    print('OK:' + str(row[0]) if row else 'OK:connected')
except Exception as e:
    print('FAIL:' + str(e))
PYEOF
)
        if echo "${DB_TEST_RESULT}" | grep -q "^OK:"; then
            DB_BANNER=$(echo "${DB_TEST_RESULT}" | sed 's/^OK://')
            print_success "Oracle DB authentication succeeded: ${DB_BANNER}"
        else
            DB_ERR=$(echo "${DB_TEST_RESULT}" | sed 's/^FAIL://')
            print_fail "Oracle DB authentication failed: ${DB_ERR}"
            print_info "  Check: PS_DB_USER, PS_DB_PASSWORD, PS_DB_HOST, PS_DB_PORT, PS_DB_SERVICE"
        fi
    else
        print_warning "Skipping Oracle DB auth test — missing config or JDBC driver file"
        [[ -z "${DB_HOST}" ]]       && print_info "  PS_DB_HOST not set"
        [[ -z "${DB_SERVICE}" ]]    && print_info "  PS_DB_SERVICE not set"
        [[ -z "${DB_USER}" ]]       && print_info "  PS_DB_USER not set"
        [[ -z "${DB_PASSWORD}" ]]   && print_info "  PS_DB_PASSWORD not set"
        [[ ! -f "${JDBC_DRIVER}" ]] && print_info "  JDBC_DRIVER_PATH file not found"
    fi

    # Veza API auth test
    VEZA_URL_VAL="${VEZA_URL:-}"
    VEZA_API_KEY_VAL="${VEZA_API_KEY:-}"

    if [[ -n "${VEZA_URL_VAL}" && -n "${VEZA_API_KEY_VAL}" ]]; then
        [[ "${VEZA_URL_VAL}" != https://* ]] && VEZA_URL_VAL="https://${VEZA_URL_VAL}"
        print_info "[DEBUG] Testing Veza API key against ${VEZA_URL_VAL}/api/v1/providers"
        print_info "[DEBUG] API key: $(mask_value "${VEZA_API_KEY_VAL}" 8)"
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -m 15 \
            -H "Authorization: Bearer ${VEZA_API_KEY_VAL}" \
            "${VEZA_URL_VAL}/api/v1/providers" 2>/dev/null || echo "000")
        if [[ "${HTTP_STATUS}" == "200" ]]; then
            print_success "Veza API authentication succeeded (HTTP ${HTTP_STATUS})"
        elif [[ "${HTTP_STATUS}" == "401" ]]; then
            print_fail    "Veza API authentication failed (HTTP 401 — invalid API key)"
            print_info    "  Regenerate: Veza UI → Admin → API Keys"
        elif [[ "${HTTP_STATUS}" == "000" ]]; then
            print_fail    "Veza API authentication — connection failed (timeout or DNS)"
        else
            print_warning "Veza API returned HTTP ${HTTP_STATUS} (expected 200)"
        fi
    else
        print_warning "Skipping Veza auth test — VEZA_URL or VEZA_API_KEY not set"
    fi
}

# ===========================================================================
# SECTION 6 — API Endpoint Accessibility
# ===========================================================================
check_endpoint_access() {
    print_header "6 — Veza Endpoint Access"

    [[ -f "${ENV_FILE}" ]] && { set -a; source "${ENV_FILE}"; set +a; }

    VEZA_URL_VAL="${VEZA_URL:-}"
    VEZA_API_KEY_VAL="${VEZA_API_KEY:-}"

    if [[ -z "${VEZA_URL_VAL}" || -z "${VEZA_API_KEY_VAL}" ]]; then
        print_warning "Skipping endpoint check — VEZA_URL or VEZA_API_KEY not set"
        return
    fi

    [[ "${VEZA_URL_VAL}" != https://* ]] && VEZA_URL_VAL="https://${VEZA_URL_VAL}"

    print_info "Testing Veza query endpoint (read permissions)..."

    QUERY_RESPONSE=$(curl -s -w "\n%{http_code}" -m 15 \
        -X POST \
        -H "Authorization: Bearer ${VEZA_API_KEY_VAL}" \
        -H "Content-Type: application/json" \
        -d '{"query":"nodes{InstanceId first:1}"}' \
        "${VEZA_URL_VAL}/api/v1/assessments/query_spec:nodes" 2>/dev/null || echo -e "\n000")

    HTTP_CODE=$(echo "${QUERY_RESPONSE}" | tail -1)
    BODY=$(echo "${QUERY_RESPONSE}" | head -n -1)

    if [[ "${HTTP_CODE}" == "200" ]]; then
        print_success "Veza query endpoint accessible (HTTP ${HTTP_CODE})"
    else
        print_fail    "Veza query endpoint returned HTTP ${HTTP_CODE}"
        print_info    "  Response: $(echo "${BODY}" | ${PYTHON} -c 'import sys,json; d=sys.stdin.read().strip(); print(json.dumps(json.loads(d), indent=2)[:500] if d else "(empty)")' 2>/dev/null)"
    fi
}

# ===========================================================================
# SECTION 7 — Deployment Structure
# ===========================================================================
check_deployment_structure() {
    print_header "7 — Deployment Structure"

    RECOMMENDED_BASE="/opt/VEZA/peoplesoft-hcm-veza/scripts"

    # Main script
    if [[ -f "${SCRIPT_DIR}/peoplesoft_hcm.py" ]]; then
        print_success "Main script found: ${SCRIPT_DIR}/peoplesoft_hcm.py"
        if [[ -x "${SCRIPT_DIR}/peoplesoft_hcm.py" ]]; then
            print_info "  Script is executable"
        else
            print_info "  Script is not executable (fine — invoked via python3)"
        fi
    else
        print_fail "Main script not found: ${SCRIPT_DIR}/peoplesoft_hcm.py"
        print_info "  Copy peoplesoft_hcm.py to ${SCRIPT_DIR}/"
    fi

    # requirements.txt
    if [[ -f "${SCRIPT_DIR}/requirements.txt" ]]; then
        print_success "requirements.txt present"
    else
        print_fail "requirements.txt not found at ${SCRIPT_DIR}/requirements.txt"
    fi

    # logs/ directory
    LOG_DIR=$(dirname "${SCRIPT_DIR}")/logs
    if [[ -d "${LOG_DIR}" ]]; then
        if [[ -w "${LOG_DIR}" ]]; then
            print_success "logs/ directory writable: ${LOG_DIR}"
        else
            print_warning "logs/ directory not writable: ${LOG_DIR}"
            print_info    "  Fix: chmod 755 ${LOG_DIR} or chown <service-account>"
        fi
    else
        print_info "logs/ directory not found at ${LOG_DIR} — will be auto-created on first run"
    fi

    # Current user
    CURRENT_USER=$(id -un 2>/dev/null || echo "unknown")
    print_info "Running as user: ${CURRENT_USER}"
    if [[ "${CURRENT_USER}" == "pshcm-veza" ]]; then
        print_success "Running as dedicated service account"
    else
        print_warning "Not running as the recommended service account (pshcm-veza)"
        print_info    "  This is fine for testing; use the service account in production"
    fi

    # Install path check
    if [[ "${SCRIPT_DIR}" == "${RECOMMENDED_BASE}" ]]; then
        print_success "Install path matches recommended: ${RECOMMENDED_BASE}"
    else
        print_info "Install path: ${SCRIPT_DIR} (recommended: ${RECOMMENDED_BASE})"
    fi

    # --dry-run support
    if ${PYTHON} "${SCRIPT_DIR}/peoplesoft_hcm.py" --help 2>&1 | grep -q '\-\-dry-run'; then
        print_success "Script accepts --dry-run flag"
    else
        print_warning "Could not verify --dry-run flag (script may not be present)"
    fi
}

# ===========================================================================
# SECTION 8 — Validation Summary
# ===========================================================================
print_summary() {
    print_header "Validation Summary"

    echo -e "  ${GREEN}Passed:${NC}    ${TESTS_PASSED}"
    echo -e "  ${RED}Failed:${NC}    ${TESTS_FAILED}"
    echo -e "  ${YELLOW}Warnings:${NC}  ${TESTS_WARNING}"
    echo ""

    if [[ "${TESTS_FAILED}" -eq 0 ]]; then
        echo -e "${BOLD}${GREEN}  ✓ All checks passed. Ready to deploy.${NC}"
        echo ""
        echo -e "  ${CYAN}Recommended next step (dry-run):${NC}"
        echo -e "  cd ${SCRIPT_DIR} && ${PYTHON} peoplesoft_hcm.py --dry-run --save-json --log-level DEBUG"
    else
        echo -e "${BOLD}${RED}  ✗ ${TESTS_FAILED} check(s) failed. Address the issues above before deployment.${NC}"
    fi
    echo ""
}

# ===========================================================================
# Utility — generate .env template
# ===========================================================================
generate_env_template() {
    print_header "Generate .env Template"
    if [[ -f "${SCRIPT_DIR}/.env.example" ]]; then
        cp "${SCRIPT_DIR}/.env.example" "${ENV_FILE}"
        chmod 600 "${ENV_FILE}"
        print_success "Generated ${ENV_FILE} from .env.example"
        print_info "Edit ${ENV_FILE} and fill in real values"
    else
        cat > "${ENV_FILE}" <<'EOF'
# PeopleSoft HCM → Veza OAA — Configuration
PS_DB_HOST=your-oracle-host.example.com
PS_DB_PORT=1521
PS_DB_SERVICE=your_oracle_service_name
PS_DB_USER=mimreader
PS_DB_PASSWORD=your_db_password_here
JDBC_DRIVER_PATH=/opt/VEZA/peoplesoft-hcm-veza/jdbc/ojdbc11.jar
VEZA_URL=https://your-tenant.veza.com
VEZA_API_KEY=your_veza_api_key_here
PROVIDER_NAME=PeopleSoft HCM
DATASOURCE_NAME=PeopleSoft HCM
EOF
        chmod 600 "${ENV_FILE}"
        print_success "Generated ${ENV_FILE} with placeholders — edit before use"
    fi
}

# ===========================================================================
# Utility — show current config (masked)
# ===========================================================================
show_current_config() {
    print_header "Current Configuration (masked)"
    if [[ ! -f "${ENV_FILE}" ]]; then
        print_fail ".env not found at ${ENV_FILE}"
        return
    fi
    set -a; source "${ENV_FILE}"; set +a
    for var in VEZA_URL VEZA_API_KEY PS_DB_HOST PS_DB_PORT PS_DB_SERVICE \
                PS_DB_USER PS_DB_PASSWORD JDBC_DRIVER_PATH PROVIDER_NAME DATASOURCE_NAME; do
        val="${!var:-}"
        if echo "${var}" | grep -qiE 'PASSWORD|KEY|TOKEN|SECRET'; then
            [[ -n "${val}" ]] && display="$(mask_value "${val}" 8)" || display="(not set)"
        else
            display="${val:-(not set)}"
        fi
        echo -e "  ${CYAN}${var}${NC}=${display}"
    done
}

# ---------------------------------------------------------------------------
# Utility — install dependencies
# ---------------------------------------------------------------------------
install_dependencies() {
    print_header "Install Python Dependencies"
    if [[ -f "${SCRIPT_DIR}/requirements.txt" ]]; then
        "${PYTHON}" -m pip install -r "${SCRIPT_DIR}/requirements.txt"
        print_success "pip install complete"
    else
        print_fail "requirements.txt not found"
    fi
}

# ===========================================================================
# Run all checks (--all mode)
# ===========================================================================
run_all_checks() {
    check_system_requirements
    check_python_dependencies
    check_configuration
    check_network_connectivity
    check_authentication
    check_endpoint_access
    check_deployment_structure
    print_summary
    [[ "${TESTS_FAILED}" -gt 0 ]] && exit 1
    exit 0
}

# ===========================================================================
# Interactive menu
# ===========================================================================
interactive_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}  PeopleSoft HCM → Veza OAA — Preflight Menu${NC}"
        echo -e "  ${CYAN}Log: ${LOG_FILE}${NC}"
        echo ""
        echo "  1)  System Requirements"
        echo "  2)  Python Dependencies"
        echo "  3)  Configuration File"
        echo "  4)  Network Connectivity"
        echo "  5)  Authentication (Oracle DB + Veza API)"
        echo "  6)  Veza Endpoint Access"
        echo "  7)  Deployment Structure"
        echo "  8)  Run All Checks"
        echo ""
        echo "  Utilities:"
        echo "  9)  Show Current Configuration"
        echo "  10) Generate .env Template"
        echo "  11) Install Python Dependencies"
        echo ""
        echo "  0)  Exit"
        echo ""
        read -r -p "  Choice: " choice </dev/tty

        TESTS_PASSED=0; TESTS_FAILED=0; TESTS_WARNING=0

        case "${choice}" in
            1) check_system_requirements;   print_summary ;;
            2) check_python_dependencies;   print_summary ;;
            3) check_configuration;         print_summary ;;
            4) check_network_connectivity;  print_summary ;;
            5) check_authentication;        print_summary ;;
            6) check_endpoint_access;       print_summary ;;
            7) check_deployment_structure;  print_summary ;;
            8) run_all_checks ;;
            9) show_current_config ;;
            10) generate_env_template ;;
            11) install_dependencies ;;
            0) echo "Exiting."; exit 0 ;;
            *) echo -e "${YELLOW}  Invalid choice — enter 0–11${NC}" ;;
        esac
    done
}

# ===========================================================================
# Entry point
# ===========================================================================
if [[ "${1:-}" == "--all" ]]; then
    run_all_checks
else
    interactive_menu
fi
