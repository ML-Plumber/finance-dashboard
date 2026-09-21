#!/usr/bin/env bash

set -Eeuo pipefail

readonly MONGODB_VERSION="7.0.39"
readonly REPLICA_SET_NAME="rs0"
readonly MONGODB_PORT="27017"
readonly CONFIG_FILE="/etc/mongod.conf"
readonly KEYRING_FILE="/usr/share/keyrings/mongodb-server-7.0.gpg"
readonly REPO_FILE="/etc/apt/sources.list.d/mongodb-org-7.0.list"
readonly WAIT_SECONDS="60"
readonly RUN_ID="$(date +%Y%m%d-%H%M%S)"

MY_IP=""
MY_HOSTNAME=""
DB_PATH="/var/lib/mongodb"
BACKUP_DIR=""

stage() {
    printf '\n============================================================\n'
    printf '  %s\n' "$1"
    printf '============================================================\n'
}

info() {
    printf '[INFO] %s\n' "$1"
}

warn() {
    printf '[WARN] %s\n' "$1" >&2
}

die() {
    printf '[ERROR] %s\n' "$1" >&2
    exit 1
}

run_priv() {
    if [[ "$EUID" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

apt_get() {
    if [[ "$EUID" -eq 0 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get "$@"
    else
        sudo env DEBIAN_FRONTEND=noninteractive apt-get "$@"
    fi
}

is_installed_package() {
    local package_name="$1"
    local package_status

    package_status="$(dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null || true)"
    [[ "$package_status" == "install ok installed" ]]
}

installed_package_version() {
    local package_name="$1"

    dpkg-query -W -f='${Version}' "$package_name" 2>/dev/null || true
}

check_prerequisites() {
    stage "Stage 1/9 - Check Ubuntu and systemd prerequisites"

    [[ -r /etc/os-release ]] || die "/etc/os-release was not found. This script requires Ubuntu."
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || die "This script supports Ubuntu only. Detected: ${ID:-unknown}."

    command -v systemctl >/dev/null 2>&1 || die "systemctl is not available."
    command -v hostname >/dev/null 2>&1 || die "hostname is not available."
    command -v awk >/dev/null 2>&1 || die "awk is not available."
    command -v dpkg-query >/dev/null 2>&1 || die "dpkg-query is not available."
    command -v getent >/dev/null 2>&1 || die "getent is not available."

    local init_process
    init_process="$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$init_process" == "systemd" ]] || die "PID 1 is not systemd. Start this script in an Ubuntu environment with systemd enabled."

    if [[ "$EUID" -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 || die "sudo is required when the script is not run as root."
        sudo -v || die "sudo authentication failed."
    fi

    local architecture
    architecture="$(dpkg --print-architecture)"
    case "$architecture" in
        amd64|arm64) ;;
        *) die "Unsupported Ubuntu architecture: $architecture. MongoDB 7.0 requires amd64 or a supported arm64 platform." ;;
    esac

    case "${VERSION_CODENAME:-}" in
        focal|jammy) ;;
        *) die "MongoDB 7.0.39 is supported by this script only on Ubuntu 20.04 (focal) or 22.04 (jammy). Detected: ${VERSION_CODENAME:-unknown}." ;;
    esac

    info "Ubuntu codename: ${VERSION_CODENAME}"
    info "Ubuntu architecture: ${architecture}"
}

detect_host_addresses() {
    stage "Stage 2/9 - Detect the local hostname and address"

    MY_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
    MY_HOSTNAME="${MY_HOSTNAME//$'\n'/}"
    [[ -n "$MY_HOSTNAME" ]] || die "The local hostname could not be determined."

    if [[ "$MY_HOSTNAME" == "localhost" || "$MY_HOSTNAME" == localhost.* ]]; then
        die "The local hostname resolves to localhost. Configure a real hostname before creating the Replica Set."
    fi

    local resolved_addresses
    resolved_addresses="$(getent ahostsv4 "$MY_HOSTNAME" | awk '{print $1}' | sort -u || true)"
    [[ -n "$resolved_addresses" ]] || die "The hostname '$MY_HOSTNAME' is not resolvable on this Ubuntu host."

    MY_IP="$(
        for candidate in $(hostname -I 2>/dev/null); do
            if [[ "$candidate" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$candidate" != 127.* ]] && grep -Fxq "$candidate" <<<"$resolved_addresses"; then
                printf '%s' "$candidate"
                break
            fi
        done
    )"
    [[ -n "$MY_IP" ]] || die "No non-loopback IPv4 address from hostname -I resolves to '$MY_HOSTNAME'. Configure DNS or /etc/hosts before creating the Replica Set."

    info "Detected hostname: $MY_HOSTNAME"
    info "Detected IPv4 address: $MY_IP"
    warn "The hostname must also resolve to the same host from every future MongoDB client."
}

ensure_official_repository() {
    stage "Configure the official MongoDB APT repository"

    apt_get update
    apt_get install -y --no-install-recommends ca-certificates curl gnupg

    local temporary_key temporary_keyring temporary_repo
    temporary_key="$(mktemp)"
    temporary_keyring="$(mktemp)"
    temporary_repo="$(mktemp)"
    trap 'rm -f "$temporary_key" "$temporary_keyring" "$temporary_repo"' RETURN

    curl -fsSL "https://www.mongodb.org/static/pgp/server-7.0.asc" -o "$temporary_key" || die "Could not download the MongoDB 7.0 signing key."
    gpg --batch --yes --dearmor -o "$temporary_keyring" "$temporary_key" || die "Could not convert the MongoDB signing key."
    run_priv install -o root -g root -m 0644 "$temporary_keyring" "$KEYRING_FILE"

    printf 'deb [ arch=amd64,arm64 signed-by=%s ] https://repo.mongodb.org/apt/ubuntu %s/mongodb-org/7.0 multiverse\n' \
        "$KEYRING_FILE" "$VERSION_CODENAME" > "$temporary_repo"
    run_priv install -o root -g root -m 0644 "$temporary_repo" "$REPO_FILE"

    apt_get update
    trap - RETURN
    rm -f "$temporary_key" "$temporary_keyring" "$temporary_repo"
}

install_or_validate_mongodb() {
    stage "Stage 3/9 - Install or validate MongoDB ${MONGODB_VERSION}"

    if is_installed_package mongodb; then
        die "The unofficial Ubuntu package 'mongodb' is installed. It conflicts with mongodb-org; remove or migrate it manually first."
    fi

    local installed_server_version
    installed_server_version="$(installed_package_version mongodb-org-server)"
    if [[ -n "$installed_server_version" && "$installed_server_version" != "$MONGODB_VERSION" ]]; then
        die "mongodb-org-server ${installed_server_version} is installed, but this script requires ${MONGODB_VERSION}. It will not replace another MongoDB version automatically."
    fi

    local need_install="false"
    if ! command -v mongod >/dev/null 2>&1 || ! command -v mongosh >/dev/null 2>&1; then
        need_install="true"
    elif [[ "$(mongod --version | awk '/^db version/ {sub(/^v/, "", $3); print $3; exit}')" != "$MONGODB_VERSION" ]]; then
        die "mongod is installed, but its version is not ${MONGODB_VERSION}."
    elif ! systemctl cat mongod.service >/dev/null 2>&1; then
        need_install="true"
    fi

    if [[ "$need_install" == "true" ]]; then
        ensure_official_repository

        local packages=(
            "mongodb-org=${MONGODB_VERSION}"
            "mongodb-org-database=${MONGODB_VERSION}"
            "mongodb-org-server=${MONGODB_VERSION}"
            "mongodb-mongosh"
            "mongodb-org-shell=${MONGODB_VERSION}"
            "mongodb-org-mongos=${MONGODB_VERSION}"
            "mongodb-org-tools=${MONGODB_VERSION}"
            "mongodb-org-database-tools-extra=${MONGODB_VERSION}"
        )
        apt_get install -y "${packages[@]}" || die "MongoDB ${MONGODB_VERSION} packages could not be installed."
    fi

    command -v mongod >/dev/null 2>&1 || die "mongod is not available after installation."
    command -v mongosh >/dev/null 2>&1 || die "mongosh is not available after installation."

    local actual_version
    actual_version="$(mongod --version | awk '/^db version/ {sub(/^v/, "", $3); print $3; exit}')"
    [[ "$actual_version" == "$MONGODB_VERSION" ]] || die "Installed mongod version is ${actual_version:-unknown}; expected ${MONGODB_VERSION}."

    info "mongod version: $actual_version"
    info "mongosh version: $(mongosh --version | head -n 1)"
}

start_mongodb() {
    run_priv systemctl daemon-reload
    run_priv systemctl enable --now mongod
}

mongodb_ping() {
    local result
    result="$(mongosh --quiet --host 127.0.0.1 --port "$MONGODB_PORT" --eval 'db.adminCommand({ ping: 1 }).ok' 2>/dev/null || true)"
    [[ "$(printf '%s\n' "$result" | tail -n 1 | tr -d '[:space:]')" == "1" ]]
}

wait_for_ping() {
    local attempt
    for ((attempt = 1; attempt <= WAIT_SECONDS; attempt++)); do
        if mongodb_ping; then
            return 0
        fi
        sleep 1
    done
    return 1
}

get_replica_set_name() {
    local result
    result="$(mongosh --quiet --host 127.0.0.1 --port "$MONGODB_PORT" --eval 'const h = db.hello(); print(h.setName || "")' 2>/dev/null || true)"
    printf '%s\n' "$result" | tail -n 1 | tr -d '[:space:]'
}

get_config_repl_set_name() {
    local result
    result="$(awk '$1 == "replSetName:" {print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true)"
    result="${result#\"}"
    result="${result%\"}"
    result="${result#\'}"
    result="${result%\'}"
    printf '%s' "$result"
}

read_db_path() {
    local result
    result="$(awk '$1 == "dbPath:" {print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true)"
    result="${result#\"}"
    result="${result%\"}"
    result="${result#\'}"
    result="${result%\'}"
    printf '%s' "${result:-/var/lib/mongodb}"
}

create_backup() {
    stage "Stage 5/9 - Back up configuration and record the data path"

    BACKUP_DIR="/var/backups/mongodb-setup-${RUN_ID}"
    run_priv install -d -o root -g root -m 0700 "$BACKUP_DIR"

    if [[ -f "$CONFIG_FILE" ]]; then
        run_priv cp -a "$CONFIG_FILE" "$BACKUP_DIR/mongod.conf"
    fi

    DB_PATH="$(read_db_path)"
    local metadata_file
    metadata_file="$(mktemp)"
    {
        printf 'created_at=%s\n' "$(date --iso-8601=seconds)"
        printf 'storage.dbPath=%s\n' "$DB_PATH"
        printf 'mongod_version=%s\n' "$(mongod --version | awk '/^db version/ {print $3; exit}')"
        printf 'mongosh_version=%s\n' "$(mongosh --version | head -n 1)"
        printf '\ninstalled MongoDB packages:\n'
        dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Status}\n' 'mongodb-*' 'mongodb-org*' 2>/dev/null || true
    } > "$metadata_file"
    run_priv install -o root -g root -m 0600 "$metadata_file" "$BACKUP_DIR/package-and-path.txt"
    rm -f "$metadata_file"

    info "Configuration backup: $BACKUP_DIR/mongod.conf"
    info "Data directory recorded only: $DB_PATH"
    info "The data directory itself was not copied."
}

update_replication_config() {
    local source_file="$1"
    local destination_file="$2"

    awk -v replica_set="$REPLICA_SET_NAME" '
        BEGIN { in_replication = 0; replication_seen = 0; repl_name_seen = 0 }
        /^[^[:space:]#][^:]*:[[:space:]]*$/ {
            if (in_replication && !repl_name_seen) {
                print "  replSetName: " replica_set
                repl_name_seen = 1
            }
            in_replication = ($0 ~ /^replication:[[:space:]]*$/)
            if (in_replication) replication_seen = 1
        }
        in_replication && /^[[:space:]]+replSetName:[[:space:]]*/ {
            print "  replSetName: " replica_set
            repl_name_seen = 1
            next
        }
        { print }
        END {
            if (in_replication && !repl_name_seen) {
                print "  replSetName: " replica_set
            }
            if (!replication_seen) {
                print ""
                print "replication:"
                print "  replSetName: " replica_set
            }
        }
    ' "$source_file" > "$destination_file"
}

update_bind_config() {
    local source_file="$1"
    local destination_file="$2"

    if grep -Eq '^[[:space:]]*bindIpAll:[[:space:]]*true([[:space:]]*(#.*)?)?$' "$source_file"; then
        cp "$source_file" "$destination_file"
        return 0
    fi

    awk -v host="$MY_HOSTNAME" '
        BEGIN { in_net = 0; net_seen = 0; bind_seen = 0 }
        /^[^[:space:]#][^:]*:[[:space:]]*$/ {
            if (in_net && !bind_seen) {
                print "  bindIp: 127.0.0.1," host
                bind_seen = 1
            }
            in_net = ($0 ~ /^net:[[:space:]]*$/)
            if (in_net) net_seen = 1
        }
        in_net && /^[[:space:]]+bindIp:[[:space:]]*/ {
            value = $0
            sub(/^[[:space:]]*bindIp:[[:space:]]*/, "", value)
            sub(/[[:space:]]+#.*$/, "", value)
            gsub(/[[:space:]]+$/, "", value)
            if (value == "") {
                value = host
            } else if (index("," value ",", "," host ",") == 0) {
                value = value "," host
            }
            print "  bindIp: " value
            bind_seen = 1
            next
        }
        { print }
        END {
            if (in_net && !bind_seen) {
                print "  bindIp: 127.0.0.1," host
            }
            if (!net_seen) {
                print ""
                print "net:"
                print "  bindIp: 127.0.0.1," host
            }
        }
    ' "$source_file" > "$destination_file"
}

merge_configuration() {
    stage "Stage 6/9 - Stop MongoDB and merge Replica Set settings"

    local replication_count
    replication_count="$(grep -Ec '^[[:space:]]*replication:[[:space:]]*$' "$CONFIG_FILE" || true)"
    [[ "$replication_count" -le 1 ]] || die "Multiple replication sections were found in $CONFIG_FILE. No changes were made."

    local current_config_repl
    current_config_repl="$(get_config_repl_set_name)"
    if [[ -n "$current_config_repl" && "$current_config_repl" != "$REPLICA_SET_NAME" ]]; then
        die "The existing configuration uses Replica Set '$current_config_repl'. It will not be renamed automatically."
    fi

    run_priv systemctl stop mongod

    local first_temp second_temp
    first_temp="$(mktemp)"
    second_temp="$(mktemp)"
    update_replication_config "$CONFIG_FILE" "$first_temp"
    update_bind_config "$first_temp" "$second_temp"
    run_priv install -o root -g root -m 0644 "$second_temp" "$CONFIG_FILE"
    rm -f "$first_temp" "$second_temp"
}

stop_and_restart_mongodb() {
    stage "Stage 7/9 - Start MongoDB with the Replica Set configuration"

    run_priv systemctl start mongod
    wait_for_ping || die "MongoDB did not respond to ping within ${WAIT_SECONDS} seconds after restart. Check: journalctl -u mongod and /var/log/mongodb/mongod.log"
}

initialize_replica_set() {
    stage "Stage 8/9 - Initialize and verify the single-member Replica Set"

    mongosh --quiet --host 127.0.0.1 --port "$MONGODB_PORT" --eval \
        "rs.initiate({_id: '${REPLICA_SET_NAME}', members: [{_id: 0, host: '${MY_HOSTNAME}:${MONGODB_PORT}'}]})" \
        || die "rs.initiate() failed. Verify hostname resolution, bindIp, and MongoDB authentication settings."

    local attempt state
    for ((attempt = 1; attempt <= WAIT_SECONDS; attempt++)); do
        state="$(mongosh --quiet --host 127.0.0.1 --port "$MONGODB_PORT" --eval 'try { print(rs.status().myState) } catch (error) { print("0") }' 2>/dev/null | tail -n 1 | tr -d '[:space:]' || true)"
        if [[ "$state" == "1" ]]; then
            break
        fi
        sleep 1
    done

    [[ "${state:-0}" == "1" ]] || die "The Replica Set did not reach PRIMARY state within ${WAIT_SECONDS} seconds."
}

print_summary() {
    stage "Stage 9/9 - Final result"

    printf 'MongoDB version: %s\n' "$(mongod --version | awk '/^db version/ {print $3; exit}')"
    printf 'mongosh version: %s\n' "$(mongosh --version | head -n 1)"
    printf 'Replica Set: %s\n' "$REPLICA_SET_NAME"
    printf 'Hostname: %s\n' "$MY_HOSTNAME"
    printf 'IPv4 address: %s\n' "$MY_IP"
    printf 'Port: %s\n' "$MONGODB_PORT"
    printf 'Connection URI: mongodb://%s:%s/?replicaSet=%s\n' "$MY_HOSTNAME" "$MONGODB_PORT" "$REPLICA_SET_NAME"
    printf 'Configuration backup: %s\n' "${BACKUP_DIR:-not created (already configured)}"
    printf '\nReplica Set configuration and status:\n'
    mongosh --quiet --host 127.0.0.1 --port "$MONGODB_PORT" --eval 'printjson(rs.conf()); printjson(rs.status())'
}

main() {
    check_prerequisites
    detect_host_addresses
    install_or_validate_mongodb

    stage "Stage 4/9 - Start MongoDB and check the current state"
    start_mongodb
    wait_for_ping || die "MongoDB did not respond to ping within ${WAIT_SECONDS} seconds. Check: journalctl -u mongod and /var/log/mongodb/mongod.log"

    local current_set_name
    current_set_name="$(get_replica_set_name)"
    case "$current_set_name" in
        "$REPLICA_SET_NAME")
            stage "Existing Replica Set detected"
            info "Replica Set '$REPLICA_SET_NAME' is already configured. rs.initiate() will not be repeated."
            print_summary
            return 0
            ;;
        "")
            info "MongoDB is currently running as a Standalone instance."
            ;;
        *)
            die "MongoDB is already configured with Replica Set '$current_set_name'. It will not be renamed automatically."
            ;;
    esac

    create_backup
    merge_configuration
    stop_and_restart_mongodb
    initialize_replica_set
    print_summary
}

main "$@"
