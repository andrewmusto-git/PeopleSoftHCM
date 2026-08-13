#!/usr/bin/env python3
"""
PeopleSoft HCM to Veza OAA Integration Script

Collects identity and permission data from PeopleSoft HCM via Oracle JDBC
and pushes it into Veza's Open Authorization API (OAA).

Entity mapping:
  PeopleSoft Operator  (PSOPRDEFN)   → OAA Local User
  PeopleSoft Role      (PSROLEDEFN)  → OAA Local Role
  Row Security Class   (PSCLASSDEFN) → OAA Application Resource
  Role assignment      (PSROLEUSER)  → user.add_role()
  Row security assign  (PSOPRDEFN.ROWSECCLASS) → permission on resource

Usage:
  python3 peoplesoft_hcm.py [--env-file .env] [--dry-run] [--save-json] [--log-level DEBUG]
"""

import argparse
import json
import logging
import os
import sys
from collections import defaultdict
from datetime import datetime
from logging.handlers import TimedRotatingFileHandler

from dotenv import load_dotenv

try:
    from oaaclient.client import OAAClient, OAAClientError
    from oaaclient.templates import CustomApplication, OAAPermission, OAAPropertyType
except ImportError:
    print("ERROR: oaaclient is not installed. Run: pip install 'oaaclient>=1.1.0'", file=sys.stderr)
    sys.exit(1)

try:
    import jaydebeapi
except ImportError:
    print(
        "ERROR: jaydebeapi is not installed. Run: pip install jaydebeapi JPype1",
        file=sys.stderr,
    )
    sys.exit(1)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log = logging.getLogger(__name__)


def _setup_logging(log_level: str = "INFO") -> None:
    """Configure file-only logging with hourly rotation to the logs/ folder."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    log_dir = os.path.join(script_dir, "logs")
    os.makedirs(log_dir, exist_ok=True)

    timestamp = datetime.now().strftime("%d%m%Y-%H%M")
    script_name = os.path.splitext(os.path.basename(__file__))[0]
    log_file = os.path.join(log_dir, f"{script_name}_{timestamp}.log")

    handler = TimedRotatingFileHandler(
        log_file,
        when="h",
        interval=1,
        backupCount=24,
        encoding="utf-8",
    )
    handler.setFormatter(
        logging.Formatter(
            fmt="%(asctime)s %(levelname)-8s %(message)s",
            datefmt="%Y-%m-%dT%H:%M:%S",
        )
    )

    root = logging.getLogger()
    root.setLevel(getattr(logging, log_level.upper(), logging.INFO))
    root.addHandler(handler)


# ---------------------------------------------------------------------------
# SQL Queries — derived from PeopleSoft HCM schema
# ---------------------------------------------------------------------------

# All operators (one row per user; ROWSECCLASS may be blank)
SQL_USERS = """
    SELECT
        A.OPRID,
        A.EMPLID,
        A.OPRDEFNDESC,
        A.ROWSECCLASS
    FROM sysadm.PSOPRDEFN A
    ORDER BY A.OPRID
"""

# User ↔ Role assignments (DYNAMIC_SW='N' = static role, not dynamic)
SQL_USER_ROLES = """
    SELECT
        ROLEUSER,
        ROLENAME
    FROM sysadm.PSROLEUSER
    WHERE DYNAMIC_SW = 'N'
    ORDER BY ROLEUSER, ROLENAME
"""

# Role definitions
SQL_ROLES = """
    SELECT
        ROLENAME,
        DESCR        AS DISPLAYNAME,
        DESCRLONG    AS DESCRIPTION
    FROM SYSADM.PSROLEDEFN
    ORDER BY ROLENAME
"""

# Row Security Class definitions
SQL_ROWSECCLASSES = """
    SELECT
        CLASSID,
        CLASSDEFNDESC AS DESCRIPTION
    FROM sysadm.PSCLASSDEFN
    ORDER BY CLASSID
"""


# ---------------------------------------------------------------------------
# Configuration loading
# ---------------------------------------------------------------------------

def load_config(args) -> dict:
    """Load configuration from env file, env vars, and CLI args (CLI wins)."""
    env_file = args.env_file or ".env"
    if os.path.exists(env_file):
        load_dotenv(env_file)
        log.info("Loaded environment from %s", env_file)
    else:
        log.warning("Env file not found: %s — relying on environment variables", env_file)

    cfg = {
        "veza_url":         args.veza_url         or os.getenv("VEZA_URL", ""),
        "veza_api_key":     args.veza_api_key      or os.getenv("VEZA_API_KEY", ""),
        "provider_name":    args.provider_name     or os.getenv("PROVIDER_NAME", "PeopleSoft HCM"),
        "datasource_name":  args.datasource_name   or os.getenv("DATASOURCE_NAME", "PeopleSoft HCM"),
        "db_host":          args.db_host           or os.getenv("PS_DB_HOST", ""),
        "db_port":          args.db_port           or os.getenv("PS_DB_PORT", "1521"),
        "db_service":       args.db_service        or os.getenv("PS_DB_SERVICE", ""),
        "db_user":          args.db_user           or os.getenv("PS_DB_USER", ""),
        "db_password":      args.db_password       or os.getenv("PS_DB_PASSWORD", ""),
        "jdbc_driver_path": args.jdbc_driver_path  or os.getenv("JDBC_DRIVER_PATH", ""),
        "jdbc_driver_class": "oracle.jdbc.driver.OracleDriver",
    }

    # Validate required fields
    missing = []
    required = {
        "VEZA_URL": cfg["veza_url"],
        "VEZA_API_KEY": cfg["veza_api_key"],
        "PS_DB_HOST": cfg["db_host"],
        "PS_DB_SERVICE": cfg["db_service"],
        "PS_DB_USER": cfg["db_user"],
        "PS_DB_PASSWORD": cfg["db_password"],
        "JDBC_DRIVER_PATH": cfg["jdbc_driver_path"],
    }
    for name, value in required.items():
        if not value:
            missing.append(name)

    if missing:
        log.error("Missing required configuration: %s", ", ".join(missing))
        print(f"ERROR: Missing required configuration: {', '.join(missing)}", file=sys.stderr)
        sys.exit(1)

    if not os.path.isfile(cfg["jdbc_driver_path"]):
        log.error("JDBC driver not found at: %s", cfg["jdbc_driver_path"])
        print(f"ERROR: JDBC driver JAR not found: {cfg['jdbc_driver_path']}", file=sys.stderr)
        print("       Set JDBC_DRIVER_PATH in your .env file or use --jdbc-driver-path", file=sys.stderr)
        sys.exit(1)

    cfg["jdbc_url"] = (
        f"jdbc:oracle:thin:@{cfg['db_host']}:{cfg['db_port']}/{cfg['db_service']}"
    )

    log.info("JDBC URL: %s", cfg["jdbc_url"])
    log.info("Provider: %s  |  Datasource: %s", cfg["provider_name"], cfg["datasource_name"])
    return cfg


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def get_db_connection(cfg: dict):
    """Open and return a JDBC connection to Oracle via jaydebeapi."""
    log.info("Connecting to Oracle DB via JDBC (%s)", cfg["jdbc_url"])
    try:
        conn = jaydebeapi.connect(
            cfg["jdbc_driver_class"],
            cfg["jdbc_url"],
            [cfg["db_user"], cfg["db_password"]],
            cfg["jdbc_driver_path"],
        )
        log.info("JDBC connection established")
        return conn
    except Exception as exc:
        log.error("Failed to connect to Oracle DB: %s", exc)
        print(f"ERROR: Cannot connect to Oracle DB — {exc}", file=sys.stderr)
        sys.exit(1)


def _query(conn, sql: str, label: str) -> list[dict]:
    """Execute a read-only SQL query and return list of dicts."""
    cursor = conn.cursor()
    try:
        log.debug("Executing query: %s", label)
        cursor.execute(sql)
        columns = [desc[0].upper() for desc in cursor.description]
        rows = cursor.fetchall()
        result = [dict(zip(columns, row)) for row in rows]
        log.info("Query [%s] returned %d row(s)", label, len(result))
        return result
    except Exception as exc:
        log.error("Query [%s] failed: %s", label, exc)
        raise
    finally:
        cursor.close()


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def load_all_data(conn: object) -> tuple[list, list, list, list]:
    """
    Load all PeopleSoft HCM data from Oracle DB.

    Returns:
        users          — rows from PSOPRDEFN
        user_roles     — rows from PSROLEUSER
        roles          — rows from PSROLEDEFN
        rowsec_classes — rows from PSCLASSDEFN
    """
    users = _query(conn, SQL_USERS, "PSOPRDEFN users")
    user_roles = _query(conn, SQL_USER_ROLES, "PSROLEUSER assignments")
    roles = _query(conn, SQL_ROLES, "PSROLEDEFN roles")
    rowsec_classes = _query(conn, SQL_ROWSECCLASSES, "PSCLASSDEFN row security classes")
    return users, user_roles, roles, rowsec_classes


# ---------------------------------------------------------------------------
# OAA payload assembly
# ---------------------------------------------------------------------------

def _clean(value) -> str:
    """Return a stripped string, or empty string if None/blank.

    Handles Oracle CLOB objects returned by jaydebeapi, which must be
    read via their Java .getSubString() method before Python can use them.
    """
    if value is None:
        return ""
    # jaydebeapi returns Oracle CLOBs as Java objects; convert to string first
    type_name = type(value).__name__
    if "CLOB" in type_name or "Clob" in type_name:
        try:
            # Java CLOB API: getSubString(pos, length) — pos is 1-based
            length = int(value.length())
            value = value.getSubString(1, length) if length > 0 else ""
        except Exception:
            value = str(value)
    return str(value).strip()


def build_oaa_payload(
    users: list,
    user_roles: list,
    roles: list,
    rowsec_classes: list,
    cfg: dict,
) -> CustomApplication:
    """Build the Veza OAA CustomApplication payload from PeopleSoft data."""

    app = CustomApplication(
        name=cfg["datasource_name"],
        application_type=cfg["provider_name"],
    )

    # ------------------------------------------------------------------
    # Define custom permissions
    # ------------------------------------------------------------------
    app.add_custom_permission("role_access",        [OAAPermission.DataRead])
    app.add_custom_permission("row_security_access", [OAAPermission.DataRead])

    # ------------------------------------------------------------------
    # Define custom user properties
    # ------------------------------------------------------------------
    app.property_definitions.define_local_user_property("EmployeeID", OAAPropertyType.STRING)

    # ------------------------------------------------------------------
    # Row Security Classes → Application Resources
    # ------------------------------------------------------------------
    rsc_ids: set[str] = set()
    rsc_objects: dict[str, object] = {}
    for rsc in rowsec_classes:
        class_id = _clean(rsc.get("CLASSID"))
        if not class_id:
            continue
        description = _clean(rsc.get("DESCRIPTION")) or class_id
        resource = app.add_resource(class_id, resource_type="RowSecurityClass")
        resource.name = description
        rsc_ids.add(class_id)
        rsc_objects[class_id] = resource

    log.info("Added %d row security class resources", len(rsc_ids))

    # ------------------------------------------------------------------
    # PeopleSoft Roles → Local Roles
    # ------------------------------------------------------------------
    role_ids: set[str] = set()
    for role in roles:
        role_name = _clean(role.get("ROLENAME"))
        if not role_name:
            continue
        display_name = _clean(role.get("DISPLAYNAME")) or role_name
        description  = _clean(role.get("DESCRIPTION"))

        local_role = app.add_local_role(role_name)
        local_role.name = display_name
        if description:
            local_role.description = description

        role_ids.add(role_name)

    log.info("Added %d local roles", len(role_ids))

    # ------------------------------------------------------------------
    # Build user → roles index
    # ------------------------------------------------------------------
    user_roles_map: dict[str, list[str]] = defaultdict(list)
    skipped_role_refs = 0
    for assignment in user_roles:
        roleuser = _clean(assignment.get("ROLEUSER")).upper()
        rolename = _clean(assignment.get("ROLENAME"))
        if roleuser and rolename:
            if rolename in role_ids:
                user_roles_map[roleuser].append(rolename)
            else:
                skipped_role_refs += 1
                log.debug("Skipping unknown role reference: user=%s role=%s", roleuser, rolename)

    if skipped_role_refs:
        log.warning(
            "%d user-role assignments reference roles not found in PSROLEDEFN — skipped",
            skipped_role_refs,
        )

    # ------------------------------------------------------------------
    # PeopleSoft Operators → Local Users
    # ------------------------------------------------------------------
    added_users = 0
    skipped_users = 0
    for user_data in users:
        oprid = _clean(user_data.get("OPRID")).upper()
        if not oprid:
            skipped_users += 1
            continue

        emplid       = _clean(user_data.get("EMPLID"))
        display_name = _clean(user_data.get("OPRDEFNDESC")) or oprid
        rowsecclass  = _clean(user_data.get("ROWSECCLASS")).upper()

        local_user = app.add_local_user(oprid)
        local_user.name      = display_name
        local_user.is_active = True

        if emplid:
            local_user.set_property("EmployeeID", emplid)

        # Assign static roles
        for role_name in user_roles_map.get(oprid, []):
            local_user.add_role(role_name)

        # Assign row security class resource permission
        if rowsecclass:
            if rowsecclass in rsc_ids:
                local_user.add_permission(
                    "row_security_access",
                    resources=[rsc_objects[rowsecclass]],
                    apply_to_application=False,
                )
            else:
                log.debug(
                    "User %s has ROWSECCLASS=%s not found in PSCLASSDEFN — skipped",
                    oprid,
                    rowsecclass,
                )

        added_users += 1

    if skipped_users:
        log.warning("%d user row(s) had empty OPRID — skipped", skipped_users)

    log.info("Added %d local users", added_users)
    return app


# ---------------------------------------------------------------------------
# Veza push
# ---------------------------------------------------------------------------

def push_to_veza(cfg: dict, app: CustomApplication, dry_run: bool, save_json: bool) -> None:
    """Push or dry-run the OAA payload to Veza."""

    if save_json or dry_run:
        payload_path = os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            f"peoplesoft_hcm_payload_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json",
        )
        try:
            payload_data = app.get_payload()
            with open(payload_path, "w", encoding="utf-8") as fh:
                json.dump(payload_data, fh, indent=2, default=str)
            log.info("Payload saved to %s", payload_path)
            print(f"Payload saved → {payload_path}")
        except Exception as exc:
            log.warning("Could not save payload JSON: %s", exc)

    if dry_run:
        log.info("[DRY RUN] Payload built successfully — skipping Veza push")
        print("[DRY RUN] Payload built successfully — Veza push skipped.")
        return

    veza_url = cfg["veza_url"].rstrip("/")
    if not veza_url.startswith("https://"):
        veza_url = f"https://{veza_url}"

    veza_con = OAAClient(url=veza_url, token=cfg["veza_api_key"])

    # Ensure the provider exists before pushing; create it if absent
    try:
        veza_con.create_provider(cfg["provider_name"], custom_template="application")
        log.info("Created Veza provider: %s", cfg["provider_name"])
    except OAAClientError as exc:
        if exc.status_code == 409:
            log.info("Provider already exists: %s", cfg["provider_name"])
        else:
            log.error("Failed to create provider: %s — %s (HTTP %s)", exc.error, exc.message, exc.status_code)
            print(f"ERROR: Failed to create provider — {exc.message}", file=sys.stderr)
            sys.exit(1)

    try:
        log.info(
            "Pushing to Veza: provider=%s  datasource=%s",
            cfg["provider_name"],
            cfg["datasource_name"],
        )
        response = veza_con.push_application(
            provider_name=cfg["provider_name"],
            data_source_name=cfg["datasource_name"],
            application_object=app,
        )
        if response and response.get("warnings"):
            for w in response["warnings"]:
                log.warning("Veza warning: %s", w)
        log.info("Successfully pushed to Veza")
        print("Successfully pushed to Veza.")
    except OAAClientError as exc:
        log.error(
            "Veza push failed: %s — %s (HTTP %s)",
            exc.error,
            exc.message,
            exc.status_code,
        )
        if hasattr(exc, "details") and exc.details:
            for detail in exc.details:
                log.error("  Detail: %s", detail)
        print(f"ERROR: Veza push failed — {exc.message}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        log.error("Unexpected error during Veza push: %s", exc)
        print(f"ERROR: Unexpected error — {exc}", file=sys.stderr)
        sys.exit(1)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="PeopleSoft HCM → Veza OAA Integration",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )

    # Env / Veza
    parser.add_argument("--env-file",        default=".env",              help="Path to .env file")
    parser.add_argument("--veza-url",        default=None,                help="Veza tenant URL (overrides VEZA_URL)")
    parser.add_argument("--veza-api-key",    default=None,                help="Veza API key (overrides VEZA_API_KEY)")
    parser.add_argument("--provider-name",   default=None,                help="Provider name in Veza (overrides PROVIDER_NAME)")
    parser.add_argument("--datasource-name", default=None,                help="Datasource name in Veza (overrides DATASOURCE_NAME)")

    # DB connection
    parser.add_argument("--db-host",         default=None,                help="Oracle DB hostname (overrides PS_DB_HOST)")
    parser.add_argument("--db-port",         default=None,                help="Oracle DB port (overrides PS_DB_PORT, default 1521)")
    parser.add_argument("--db-service",      default=None,                help="Oracle service name (overrides PS_DB_SERVICE)")
    parser.add_argument("--db-user",         default=None,                help="Oracle DB username (overrides PS_DB_USER)")
    parser.add_argument("--db-password",     default=None,                help="Oracle DB password (overrides PS_DB_PASSWORD)")
    parser.add_argument("--jdbc-driver-path",default=None,                help="Path to ojdbc*.jar (overrides JDBC_DRIVER_PATH)")

    # Run mode
    parser.add_argument("--dry-run",         action="store_true",         help="Build payload without pushing to Veza")
    parser.add_argument("--save-json",       action="store_true",         help="Save OAA payload as JSON for inspection")
    parser.add_argument("--log-level",       default="INFO",
                        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
                        help="Logging verbosity")

    return parser.parse_args()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    args = parse_args()
    _setup_logging(args.log_level)

    print("=" * 60)
    print("  PeopleSoft HCM → Veza OAA Integration")
    print(f"  Started: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)

    log.info("PeopleSoft HCM OAA integration started")

    cfg = load_config(args)

    conn = get_db_connection(cfg)
    try:
        users, user_roles, roles, rowsec_classes = load_all_data(conn)
    finally:
        try:
            conn.close()
        except Exception:
            pass

    print(
        f"  Loaded: {len(users)} users | {len(roles)} roles | "
        f"{len(rowsec_classes)} row security classes | {len(user_roles)} role assignments"
    )
    log.info(
        "Data loaded: users=%d roles=%d rowsec=%d assignments=%d",
        len(users), len(roles), len(rowsec_classes), len(user_roles),
    )

    app = build_oaa_payload(users, user_roles, roles, rowsec_classes, cfg)

    push_to_veza(cfg, app, dry_run=args.dry_run, save_json=args.save_json)

    log.info("Integration complete")
    print("=" * 60)
    print("  Integration complete.")
    print("=" * 60)


if __name__ == "__main__":
    main()
