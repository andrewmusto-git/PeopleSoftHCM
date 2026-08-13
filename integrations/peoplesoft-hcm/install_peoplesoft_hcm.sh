#!/usr/bin/env bash
# =============================================================================
# install_peoplesoft_hcm.sh
# One-command installer for the PeopleSoft HCM → Veza OAA integration
# =============================================================================
# Usage:
#   Interactive (default):
#     bash install_peoplesoft_hcm.sh
#
#   Non-interactive / CI:
#     VEZA_URL=https://your-tenant.veza.com \
#     VEZA_API_KEY=your_api_key \
#     PS_DB_HOST=oracle-host.example.com \
#     PS_DB_PORT=1521 \
#     PS_DB_SERVICE=your_service \
#     PS_DB_USER=mimreader \
#     PS_DB_PASSWORD=your_password \
#     bash install_peoplesoft_hcm.sh --non-interactive
#
# Flags:
#   --non-interactive    Skip all prompts; use env vars only
#   --overwrite-env      Overwrite existing .env file
#   --install-dir <path> Custom install base (default: /opt/VEZA/peoplesoft-hcm-veza)
#   --repo-url <url>     Git repository URL for integration files
#   --branch <name>      Git branch to clone (default: main)
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Milestone tracking
# ---------------------------------------------------------------------------
MILESTONE_TOTAL=10
MILESTONE_CURRENT=0

milestone() {
    MILESTONE_CURRENT=$((MILESTONE_CURRENT + 1))
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}  [MILESTONE ${MILESTONE_CURRENT}/${MILESTONE_TOTAL}] $1${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
INSTALL_BASE="/opt/VEZA/peoplesoft-hcm-veza"
SCRIPTS_DIR=""
LOGS_DIR=""
JDBC_DIR=""
VENV_DIR=""
BRANCH="main"
REPO_URL="https://github.com/andrewmusto-git/PeopleSoftHCM"
NON_INTERACTIVE=false
OVERWRITE_ENV=false
INTEGRATION_SUBDIR="integrations/peoplesoft-hcm"

# JDBC driver
JDBC_JAR_NAME="ojdbc11.jar"
JDBC_MAVEN_URL="https://repo1.maven.org/maven2/com/oracle/database/jdbc/ojdbc11/23.7.0.25.01/ojdbc11-23.7.0.25.01.jar"
JDBC_DRIVER_CLASS="oracle.jdbc.driver.OracleDriver"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo -e "${CYAN}  ℹ  $*${NC}"; }
success() { echo -e "${GREEN}  ✓  $*${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠  $*${NC}"; }
die()     { echo -e "${RED}  ✗  ERROR: $*${NC}" >&2; exit 1; }

prompt_value() {
    # Usage: prompt_value "Label" [default_value]
    local label="$1"
    local default="${2:-}"
    local value=""
    if [[ -n "${default}" ]]; then
        IFS= read -r -p "  ${label} [${default}]: " value </dev/tty
        echo "${value:-${default}}"
    else
        while [[ -z "${value}" ]]; do
            IFS= read -r -p "  ${label}: " value </dev/tty
        done
        echo "${value}"
    fi
}

prompt_secret() {
    local label="$1"
    local value=""
    while [[ -z "${value}" ]]; do
        IFS= read -r -s -p "  ${label}: " value </dev/tty
        echo "" >/dev/tty
    done
    echo "${value}"
}

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true;      shift ;;
        --overwrite-env)   OVERWRITE_ENV=true;        shift ;;
        --install-dir)     INSTALL_BASE="${2:?}";     shift 2 ;;
        --repo-url)        REPO_URL="${2:?}";         shift 2 ;;
        --branch)          BRANCH="${2:?}";           shift 2 ;;
        *) die "Unknown flag: $1" ;;
    esac
done

# Derive subdirs from base
SCRIPTS_DIR="${INSTALL_BASE}/scripts"
LOGS_DIR="${INSTALL_BASE}/logs"
JDBC_DIR="${INSTALL_BASE}/jdbc"
VENV_DIR="${SCRIPTS_DIR}/venv"

# ---------------------------------------------------------------------------
# Detect OS / package manager
# ---------------------------------------------------------------------------
OS_ID=""
PKG_MGR=""
if [[ -f /etc/os-release ]]; then
    OS_ID=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
fi

if   command -v dnf  &>/dev/null; then PKG_MGR="dnf"
elif command -v yum  &>/dev/null; then PKG_MGR="yum"
elif command -v apt-get &>/dev/null; then PKG_MGR="apt-get"
fi

_install_pkg() {
    local pkg="$1"
    info "Installing ${pkg}..."
    case "${PKG_MGR}" in
        dnf|yum) "${PKG_MGR}" install -y "${pkg}" >/dev/null 2>&1 ;;
        apt-get) apt-get install -y "${pkg}"       >/dev/null 2>&1 ;;
        *)       die "No supported package manager found (dnf/yum/apt-get)" ;;
    esac
}

# ===========================================================================
# MILESTONE 1 — System Requirements
# ===========================================================================
milestone "System Requirements Check"

# curl
if ! command -v curl &>/dev/null; then
    if [[ "${OS_ID}" == "amzn" ]]; then
        warn "Skipping curl install on Amazon Linux (curl-minimal conflict — already present)"
    else
        _install_pkg curl
    fi
fi
command -v curl &>/dev/null && success "curl found: $(curl --version | head -1)" \
    || die "curl is required but could not be installed"

# git
command -v git &>/dev/null || _install_pkg git
command -v git &>/dev/null && success "git found: $(git --version)" \
    || die "git is required but could not be installed"

# jq (optional)
if command -v jq &>/dev/null; then
    success "jq found (optional): $(jq --version)"
else
    warn "jq not found (optional — install for JSON inspection)"
fi

# ===========================================================================
# MILESTONE 2 — Python Environment
# ===========================================================================
milestone "Python Environment"

# python3
command -v python3 &>/dev/null || _install_pkg python3
command -v python3 &>/dev/null || die "python3 is required but could not be installed"

# Check Python version >= 3.8
PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PY_MAJOR=$(echo "${PY_VER}" | cut -d. -f1)
PY_MINOR=$(echo "${PY_VER}" | cut -d. -f2)
if [[ "${PY_MAJOR}" -lt 3 ]] || { [[ "${PY_MAJOR}" -eq 3 ]] && [[ "${PY_MINOR}" -lt 8 ]]; }; then
    die "Python 3.8+ required (found ${PY_VER})"
fi
success "Python ${PY_VER}"

# pip3
if ! python3 -m pip --version &>/dev/null; then
    _install_pkg python3-pip
fi
python3 -m pip --version &>/dev/null || die "pip3 is required but could not be installed"
success "pip3: $(python3 -m pip --version)"

# venv
if ! python3 -m venv --help &>/dev/null; then
    case "${PKG_MGR}" in
        dnf|yum) _install_pkg python3-virtualenv ;;
        apt-get) _install_pkg python3-venv ;;
    esac
fi
python3 -m venv --help &>/dev/null || die "python3 venv module not available"
success "python3 venv available"

# ===========================================================================
# MILESTONE 3 — Java Runtime Check (required for JDBC / JPype1)
# ===========================================================================
milestone "Java Runtime Check"

JAVA_OK=false
if command -v java &>/dev/null; then
    JAVA_VER=$(java -version 2>&1 | head -1)
    success "Java found: ${JAVA_VER}"
    JAVA_OK=true
else
    warn "Java not found — attempting to install OpenJDK 11..."
    case "${PKG_MGR}" in
        dnf|yum)  _install_pkg java-11-openjdk-headless ;;
        apt-get)  _install_pkg openjdk-11-jre-headless  ;;
        *)        warn "Cannot auto-install Java — please install OpenJDK 11+ manually" ;;
    esac
    if command -v java &>/dev/null; then
        JAVA_VER=$(java -version 2>&1 | head -1)
        success "Java installed: ${JAVA_VER}"
        JAVA_OK=true
    else
        die "Java is required for JDBC connectivity (jaydebeapi/JPype1). Install OpenJDK 11+ and re-run."
    fi
fi

# Ensure JAVA_HOME is set (JPype1 needs it)
if [[ -z "${JAVA_HOME:-}" ]]; then
    # Try to discover JAVA_HOME
    if command -v java &>/dev/null; then
        JAVA_BIN=$(readlink -f "$(command -v java)")
        JAVA_HOME=$(dirname "$(dirname "${JAVA_BIN}")")
        export JAVA_HOME
        info "Discovered JAVA_HOME=${JAVA_HOME}"
    fi
fi
[[ -n "${JAVA_HOME:-}" ]] && success "JAVA_HOME=${JAVA_HOME}" \
    || warn "JAVA_HOME not set — JPype1 may fail. Set JAVA_HOME in your shell profile."

# ===========================================================================
# MILESTONE 4 — Directory Structure
# ===========================================================================
milestone "Directory Structure"

info "Creating directory layout under ${INSTALL_BASE}..."
mkdir -p "${SCRIPTS_DIR}" "${LOGS_DIR}" "${JDBC_DIR}"
success "Created: ${SCRIPTS_DIR}"
success "Created: ${LOGS_DIR}"
success "Created: ${JDBC_DIR}"

# ===========================================================================
# MILESTONE 5 — Git Repository Clone
# ===========================================================================
milestone "Cloning Integration Files from Repository"

# Prompt for repo URL if not provided
if [[ -z "${REPO_URL}" ]]; then
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        warn "REPO_URL not set and --non-interactive mode active — skipping git clone"
        warn "Copy peoplesoft_hcm.py and requirements.txt manually to ${SCRIPTS_DIR}/"
    else
        echo ""
        echo -e "${CYAN}  Enter your Git repository URL for the PeopleSoft HCM integration.${NC}"
        echo -e "${CYAN}  Leave blank to skip the git clone (copy files manually).${NC}"
        echo ""
        REPO_URL=$(prompt_value "Git repository URL (or leave blank to skip)" "https://github.com/andrewmusto-git/PeopleSoftHCM")
    fi
fi

if [[ -n "${REPO_URL}" ]]; then
    info "Cloning from ${REPO_URL} (branch: ${BRANCH})..."
    tmp_dir=$(mktemp -d)
    if GIT_TERMINAL_PROMPT=0 git clone \
            --branch "${BRANCH}" \
            --depth 1 \
            --single-branch \
            "${REPO_URL}" "${tmp_dir}" 2>&1 | grep -v "^$"; then
        SRC="${tmp_dir}/${INTEGRATION_SUBDIR}"
        if [[ -d "${SRC}" ]]; then
            cp -f "${SRC}/peoplesoft_hcm.py"  "${SCRIPTS_DIR}/" 2>/dev/null && success "Copied peoplesoft_hcm.py"
            cp -f "${SRC}/requirements.txt"   "${SCRIPTS_DIR}/" 2>/dev/null && success "Copied requirements.txt"
            cp -f "${SRC}/preflight_peoplesoft_hcm.sh" "${SCRIPTS_DIR}/" 2>/dev/null && success "Copied preflight_peoplesoft_hcm.sh"
        else
            warn "Integration subfolder not found in repo: ${INTEGRATION_SUBDIR}"
            warn "Copy integration files to ${SCRIPTS_DIR}/ manually"
        fi
        rm -rf "${tmp_dir}"
        success "Repository clone complete"
    else
        rm -rf "${tmp_dir}"
        warn "git clone failed — copy integration files to ${SCRIPTS_DIR}/ manually"
    fi
else
    warn "No repo URL provided — skipping git clone"
    info "Manually copy peoplesoft_hcm.py and requirements.txt to ${SCRIPTS_DIR}/"
fi

# ===========================================================================
# MILESTONE 6 — JDBC Driver Installation
# ===========================================================================
milestone "Oracle JDBC Driver Installation"

JDBC_DRIVER_PATH="${JDBC_DIR}/${JDBC_JAR_NAME}"

if [[ -f "${JDBC_DRIVER_PATH}" ]]; then
    success "JDBC driver already present: ${JDBC_DRIVER_PATH}"
else
    echo ""
    echo -e "${CYAN}  The Oracle JDBC driver (ojdbc11.jar) is required for database connectivity.${NC}"
    echo ""
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        JDBC_CHOICE="auto"
    else
        echo "  [1] Download automatically from Maven Central (ojdbc11 v23.7.0.25.01)"
        echo "  [2] Specify path to an existing ojdbc*.jar on this server"
        echo "  [3] Skip (set JDBC_DRIVER_PATH in .env manually later)"
        echo ""
        read -r -p "  Choice [1/2/3]: " JDBC_CHOICE </dev/tty
    fi

    case "${JDBC_CHOICE}" in
        1|auto)
            info "Downloading ${JDBC_JAR_NAME} from Maven Central..."
            if curl -fsSL --progress-bar \
                    -o "${JDBC_DRIVER_PATH}" \
                    "${JDBC_MAVEN_URL}"; then
                success "Downloaded ${JDBC_JAR_NAME} to ${JDBC_DRIVER_PATH}"
            else
                warn "Download failed — set JDBC_DRIVER_PATH in .env manually"
                JDBC_DRIVER_PATH="REPLACE_WITH_PATH_TO_OJDBC_JAR"
            fi
            ;;
        2)
            EXISTING_PATH=$(prompt_value "Full path to existing ojdbc*.jar" "")
            if [[ -f "${EXISTING_PATH}" ]]; then
                cp -f "${EXISTING_PATH}" "${JDBC_DRIVER_PATH}"
                success "Copied JDBC driver to ${JDBC_DRIVER_PATH}"
            else
                warn "File not found: ${EXISTING_PATH} — set JDBC_DRIVER_PATH in .env manually"
                JDBC_DRIVER_PATH="REPLACE_WITH_PATH_TO_OJDBC_JAR"
            fi
            ;;
        3|*)
            warn "Skipping JDBC driver installation — set JDBC_DRIVER_PATH in .env manually"
            JDBC_DRIVER_PATH="REPLACE_WITH_PATH_TO_OJDBC_JAR"
            ;;
    esac
fi

# ===========================================================================
# MILESTONE 7 — Python Virtual Environment
# ===========================================================================
milestone "Python Virtual Environment"

if [[ -d "${VENV_DIR}" ]]; then
    info "Virtual environment already exists at ${VENV_DIR}"
else
    info "Creating virtual environment..."
    python3 -m venv "${VENV_DIR}" || die "Failed to create virtual environment"
    success "Virtual environment created at ${VENV_DIR}"
fi

# ===========================================================================
# MILESTONE 8 — Python Dependencies
# ===========================================================================
milestone "Python Dependencies Installation"

REQUIREMENTS_FILE="${SCRIPTS_DIR}/requirements.txt"

if [[ ! -f "${REQUIREMENTS_FILE}" ]]; then
    warn "requirements.txt not found at ${REQUIREMENTS_FILE}"
    warn "Creating default requirements.txt..."
    cat > "${REQUIREMENTS_FILE}" <<'EOF'
oaaclient>=1.1.0
python-dotenv>=1.0.0
jaydebeapi>=1.2.3
JPype1>=1.4.0
requests>=2.31.0
urllib3>=2.0.0
EOF
    success "Created default requirements.txt"
fi

info "Upgrading pip..."
"${VENV_DIR}/bin/pip" install --quiet --upgrade pip

info "Installing Python dependencies (this may take a moment)..."
"${VENV_DIR}/bin/pip" install --quiet -r "${REQUIREMENTS_FILE}" \
    || die "pip install failed — check ${REQUIREMENTS_FILE} and your network connection"

success "Python dependencies installed"

# Verify key packages
for pkg in oaaclient jaydebeapi jpype1; do
    if "${VENV_DIR}/bin/python3" -c "import ${pkg}" 2>/dev/null; then
        success "  Package verified: ${pkg}"
    else
        warn "  Package import failed: ${pkg} — check install log"
    fi
done

# ===========================================================================
# MILESTONE 9 — Configuration (.env)
# ===========================================================================
milestone "Configuration"

ENV_FILE="${SCRIPTS_DIR}/.env"

if [[ -f "${ENV_FILE}" && "${OVERWRITE_ENV}" != "true" ]]; then
    warn ".env already exists at ${ENV_FILE} — skipping (use --overwrite-env to replace)"
else
    echo ""
    echo -e "${BOLD}  ── Veza Configuration ──────────────────────────────────────${NC}"
    echo ""

    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        CFG_VEZA_URL="${VEZA_URL:-}"
        CFG_VEZA_API_KEY="${VEZA_API_KEY:-}"
        CFG_PS_DB_HOST="${PS_DB_HOST:-}"
        CFG_PS_DB_PORT="${PS_DB_PORT:-1521}"
        CFG_PS_DB_SERVICE="${PS_DB_SERVICE:-}"
        CFG_PS_DB_USER="${PS_DB_USER:-mimreader}"
        CFG_PS_DB_PASSWORD="${PS_DB_PASSWORD:-}"
        CFG_PROVIDER_NAME="${PROVIDER_NAME:-PeopleSoft HCM}"
        CFG_DATASOURCE_NAME="${DATASOURCE_NAME:-PeopleSoft HCM}"
    else
        echo -e "${CYAN}  Enter your Veza tenant details:${NC}"
        CFG_VEZA_URL=$(prompt_value "Veza URL (e.g. https://your-tenant.veza.com)" "${VEZA_URL:-}")
        CFG_VEZA_API_KEY=$(prompt_secret "Veza API Key")

        echo ""
        echo -e "${BOLD}  ── Oracle Database Configuration ───────────────────────────${NC}"
        echo ""
        echo -e "${CYAN}  Enter PeopleSoft HCM Oracle database connection details:${NC}"
        CFG_PS_DB_HOST=$(prompt_value "Oracle DB Hostname"         "${PS_DB_HOST:-}")
        CFG_PS_DB_PORT=$(prompt_value "Oracle DB Port"             "${PS_DB_PORT:-1521}")
        CFG_PS_DB_SERVICE=$(prompt_value "Oracle Service Name"     "${PS_DB_SERVICE:-}")
        CFG_PS_DB_USER=$(prompt_value "Oracle DB Username"         "${PS_DB_USER:-mimreader}")
        CFG_PS_DB_PASSWORD=$(prompt_secret "Oracle DB Password")

        echo ""
        echo -e "${BOLD}  ── OAA Provider Settings ───────────────────────────────────${NC}"
        echo ""
        CFG_PROVIDER_NAME=$(prompt_value "Provider Name in Veza"   "${PROVIDER_NAME:-PeopleSoft HCM}")
        CFG_DATASOURCE_NAME=$(prompt_value "Datasource Name"       "${DATASOURCE_NAME:-PeopleSoft HCM}")
    fi

    # Resolve final JDBC driver path
    FINAL_JDBC_PATH="${JDBC_DRIVER_PATH}"
    if [[ ! -f "${FINAL_JDBC_PATH}" ]]; then
        FINAL_JDBC_PATH="${JDBC_DIR}/${JDBC_JAR_NAME}"
    fi

    # Write .env
    cat > "${ENV_FILE}" <<EOF
# PeopleSoft HCM → Veza OAA Integration — Configuration
# Generated: $(date -Iseconds)
# File permissions: 600 (credentials — do not share or commit to version control)

# ── Oracle JDBC Configuration ─────────────────────────────────────────────
PS_DB_HOST=${CFG_PS_DB_HOST}
PS_DB_PORT=${CFG_PS_DB_PORT}
PS_DB_SERVICE=${CFG_PS_DB_SERVICE}
PS_DB_USER=${CFG_PS_DB_USER}
PS_DB_PASSWORD=${CFG_PS_DB_PASSWORD}

# Path to Oracle JDBC driver JAR (ojdbc11.jar)
JDBC_DRIVER_PATH=${FINAL_JDBC_PATH}

# ── Veza Configuration ────────────────────────────────────────────────────
VEZA_URL=${CFG_VEZA_URL}
VEZA_API_KEY=${CFG_VEZA_API_KEY}

# ── OAA Provider Settings (optional — change to match your Veza setup) ───
PROVIDER_NAME=${CFG_PROVIDER_NAME}
DATASOURCE_NAME=${CFG_DATASOURCE_NAME}
EOF

    chmod 600 "${ENV_FILE}"
    success ".env written to ${ENV_FILE} (chmod 600)"
fi

# ===========================================================================
# MILESTONE 10 — Final Verification & Summary
# ===========================================================================
milestone "Installation Complete"

# Verify core files exist
VERIFY_OK=true
for f in "peoplesoft_hcm.py" "requirements.txt"; do
    if [[ -f "${SCRIPTS_DIR}/${f}" ]]; then
        success "${f} present"
    else
        warn "${f} not found at ${SCRIPTS_DIR}/${f} — copy it manually"
        VERIFY_OK=false
    fi
done

if [[ -f "${ENV_FILE}" ]]; then
    success ".env present (chmod $(stat -c '%a' "${ENV_FILE}" 2>/dev/null || stat -f '%A' "${ENV_FILE}" 2>/dev/null))"
else
    warn ".env not found — create ${ENV_FILE} before running"
    VERIFY_OK=false
fi

if [[ -f "${JDBC_DIR}/${JDBC_JAR_NAME}" ]]; then
    success "JDBC driver: ${JDBC_DIR}/${JDBC_JAR_NAME}"
else
    warn "JDBC driver not found at ${JDBC_DIR}/${JDBC_JAR_NAME}"
    warn "Update JDBC_DRIVER_PATH in ${ENV_FILE} with the correct path"
fi

echo ""
echo -e "${BOLD}${GREEN}  ╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}  ║         PeopleSoft HCM Veza OAA — INSTALLED              ║${NC}"
echo -e "${BOLD}${GREEN}  ╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Install directory:${NC}  ${INSTALL_BASE}"
echo -e "  ${BOLD}Scripts:${NC}            ${SCRIPTS_DIR}"
echo -e "  ${BOLD}Logs:${NC}               ${LOGS_DIR}"
echo -e "  ${BOLD}JDBC driver:${NC}        ${JDBC_DIR}/${JDBC_JAR_NAME}"
echo -e "  ${BOLD}Config file:${NC}        ${ENV_FILE}"
echo -e "  ${BOLD}Virtual env:${NC}        ${VENV_DIR}"
echo ""
echo -e "  ${BOLD}${CYAN}Next steps:${NC}"
echo ""
echo -e "  1. Verify and update your configuration:"
echo -e "     ${CYAN}nano ${ENV_FILE}${NC}"
echo ""
echo -e "  2. Run the preflight check:"
echo -e "     ${CYAN}bash ${SCRIPTS_DIR}/preflight_peoplesoft_hcm.sh --all${NC}"
echo ""
echo -e "  3. Run the integration (dry-run first):"
echo -e "     ${CYAN}cd ${SCRIPTS_DIR} && ${VENV_DIR}/bin/python3 peoplesoft_hcm.py --dry-run --save-json${NC}"
echo ""
echo -e "  4. Push to Veza when ready:"
echo -e "     ${CYAN}cd ${SCRIPTS_DIR} && ${VENV_DIR}/bin/python3 peoplesoft_hcm.py${NC}"
echo ""
echo -e "  5. Schedule with cron (example — daily at 3 AM):"
echo -e "     ${CYAN}0 3 * * * cd ${SCRIPTS_DIR} && ${VENV_DIR}/bin/python3 peoplesoft_hcm.py >> ${LOGS_DIR}/cron.log 2>&1${NC}"
echo ""
