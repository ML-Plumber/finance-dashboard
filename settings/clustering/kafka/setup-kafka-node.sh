#!/usr/bin/env bash

set -Eeuo pipefail

KAFKA_VERSION="4.3.1"
SCALA_VERSION="2.13"
ARCHIVE_NAME="kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"
DOWNLOAD_URL="https://www.apache.org/dyn/closer.lua/kafka/${KAFKA_VERSION}/${ARCHIVE_NAME}?action=download"
KAFKA_DIR="${HOME}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}"
LOG_DIR="${KAFKA_DIR}/logs"
ARCHIVE_PATH="${HOME}/${ARCHIVE_NAME}"
NODE_PROPERTIES="${KAFKA_DIR}/config/node.properties"
CONTROLLER_PORT=9093
BROKER_PORT=9092

die() {
    printf '오류: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "필수 명령을 찾을 수 없습니다: $1"
}

setup_kafka_conda_environment() {
    local conda_bin=''
    local candidate

    conda_bin="$(type -P conda 2>/dev/null || true)"
    if [[ -z "$conda_bin" ]]; then
        for candidate in \
            "$HOME/miniforge3/bin/conda" \
            "$HOME/miniconda3/bin/conda" \
            "/opt/conda/bin/conda"; do
            if [[ -x "$candidate" ]]; then
                conda_bin="$candidate"
                break
            fi
        done
    fi

    [[ -n "$conda_bin" ]] || die 'Conda를 찾을 수 없습니다. 먼저 Miniforge 또는 Conda를 설치하세요.'

    eval "$("$conda_bin" shell.bash hook)"

    if ! conda env list | awk '$1 == "kafka" {found = 1} END {exit(found ? 0 : 1)}'; then
        printf 'Conda 환경 kafka가 없어 새로 생성합니다.\n'
        conda create -y -n kafka python=3.12 openjdk=17
    fi

    conda activate kafka
    [[ "${CONDA_DEFAULT_ENV:-}" == 'kafka' ]] || die 'Conda 환경 kafka 활성화에 실패했습니다.'
    [[ -n "${CONDA_PREFIX:-}" ]] || die '활성화된 kafka 환경의 경로를 확인할 수 없습니다.'
    [[ -x "${CONDA_PREFIX}/bin/java" ]] || die 'kafka 환경에서 OpenJDK 실행 파일을 찾을 수 없습니다.'

    export JAVA_HOME="$CONDA_PREFIX"
    export KAFKA_CONDA_ENV='kafka'
    printf 'Conda 환경 kafka가 활성화되었습니다. JAVA_HOME=%s\n' "$JAVA_HOME"
}

is_valid_ipv4() {
    local value="$1"
    local octet
    local part_count=0

    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    IFS='.' read -r -a octets <<< "$value"
    for octet in "${octets[@]}"; do
        ((10#$octet <= 255)) || return 1
        ((part_count += 1))
    done

    ((part_count == 4)) || return 1
    [[ "$value" != "0.0.0.0" && "$value" != "255.255.255.255" ]]
}

is_valid_identifier() {
    local value="$1"
    [[ "$value" =~ ^[A-Za-z0-9_-]+$ ]]
}

prompt_node_count() {
    local value

    while true; do
        read -r -p '클러스터 노드 수: ' value
        if [[ "$value" =~ ^[1-9][0-9]*$ ]] && ((value <= 999)); then
            NODE_COUNT="$value"
            return
        fi
        printf '노드 수는 1부터 999 사이의 정수여야 합니다.\n' >&2
    done
}

prompt_node_id() {
    local value

    while true; do
        read -r -p "현재 노드의 node.id (1~${NODE_COUNT}): " value
        if [[ "$value" =~ ^[1-9][0-9]*$ ]] && ((value >= 1 && value <= NODE_COUNT)); then
            NODE_ID="$value"
            return
        fi
        printf 'node.id는 1부터 %s 사이의 정수여야 합니다.\n' "$NODE_COUNT" >&2
    done
}

detect_current_ip() {
    local route_ip
    local candidate
    local route_match=0
    local -a candidates=()

    mapfile -t candidates < <(
        ip -4 -o addr show scope global 2>/dev/null |
            awk '{split($4, address, "/"); if (address[1] !~ /^169\.254\./) print address[1]}' |
            sort -u
    )

    route_ip="$(
        ip -4 route get 1.1.1.1 2>/dev/null |
            awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true
    )"
    route_ip="$(printf '%s' "$route_ip" | tr -d '\r\n')"

    if [[ -n "$route_ip" ]]; then
        for candidate in "${candidates[@]}"; do
            if [[ "$candidate" == "$route_ip" ]]; then
                route_match=1
                break
            fi
        done
    fi

    if ((route_match == 1)); then
        MY_IP="$route_ip"
    elif ((${#candidates[@]} == 1)); then
        MY_IP="${candidates[0]}"
    else
        printf '현재 노드의 IPv4 주소를 하나로 결정하지 못했습니다.\n' >&2
        if ((${#candidates[@]} == 0)); then
            printf 'WSL 네트워크 인터페이스에서 전역 IPv4 주소를 찾지 못했습니다.\n' >&2
        else
            printf '확인된 후보 주소: %s\n' "${candidates[*]}" >&2
            printf '기본 경로의 src 주소도 후보에 포함되지 않았습니다.\n' >&2
        fi
        die 'ip 명령으로 실제 WSL 주소를 확인한 뒤 다시 실행하세요.'
    fi

    is_valid_ipv4 "$MY_IP" || die "자동 조회된 주소가 올바른 IPv4가 아닙니다: $MY_IP"
}

prompt_other_node_ips() {
    local i
    local value
    local existing
    declare -A seen_ips=()

    NODE_IPS=()
    NODE_IPS[$NODE_ID]="$MY_IP"
    seen_ips["$MY_IP"]="$NODE_ID"

    printf '현재 node.id %s의 IP 주소 (WSL 내부 설정에서 자동 조회): %s\n' "$NODE_ID" "$MY_IP"

    for ((i = 1; i <= NODE_COUNT; i++)); do
        [[ "$i" == "$NODE_ID" ]] && continue

        while true; do
            read -r -p "node ${i}의 IP 주소: " value
            if ! is_valid_ipv4 "$value"; then
                printf '올바른 IPv4 주소를 입력하세요.\n' >&2
                continue
            fi

            if [[ -n "${seen_ips[$value]+x}" ]]; then
                existing="${seen_ips[$value]}"
                printf '이미 node %s에 입력한 주소입니다. 노드마다 다른 IP를 입력하세요.\n' "$existing" >&2
                continue
            fi

            NODE_IPS[$i]="$value"
            seen_ips["$value"]="$i"
            break
        done
    done
}

prompt_cluster_id() {
    local value

    read -r -p 'CLUSTER_ID (빈 입력 시 새 클러스터 ID와 directory-id 자동 생성): ' value
    if [[ -z "$value" ]]; then
        CLUSTER_ID_MODE='generate'
        CLUSTER_ID=''
        printf '새 클러스터 모드입니다. Kafka 도구로 CLUSTER_ID와 모든 directory-id를 생성합니다.\n'
        return
    fi

    is_valid_identifier "$value" || die 'CLUSTER_ID에는 공백이나 특수문자를 사용할 수 없습니다.'
    CLUSTER_ID_MODE='input'
    CLUSTER_ID="$value"
}

prompt_directory_ids() {
    local i
    local value
    local existing
    declare -A seen_ids=()

    DIRECTORY_IDS=()

    if [[ "$CLUSTER_ID_MODE" == 'generate' ]]; then
        printf 'directory-id는 Kafka storage 도구 실행 후 node 1부터 순서대로 생성합니다.\n'
        return
    fi

    for ((i = 1; i <= NODE_COUNT; i++)); do
        while true; do
            read -r -p "node ${i}의 directory-id: " value
            if ! is_valid_identifier "$value"; then
                printf 'directory-id에는 공백이나 특수문자를 사용할 수 없습니다.\n' >&2
                continue
            fi

            if [[ -n "${seen_ids[$value]+x}" ]]; then
                existing="${seen_ids[$value]}"
                printf '이미 node %s에 입력한 directory-id입니다. 노드마다 다른 값을 입력하세요.\n' "$existing" >&2
                continue
            fi

            DIRECTORY_IDS[$i]="$value"
            seen_ids["$value"]="$i"
            break
        done
    done
}

download_and_extract_kafka() {
    [[ ! -e "$KAFKA_DIR" ]] || die "Kafka 설치 디렉터리가 이미 존재합니다: $KAFKA_DIR"
    [[ ! -e "$ARCHIVE_PATH" ]] || die "Kafka 압축 파일이 이미 존재합니다. 삭제하거나 이름을 바꾼 뒤 다시 실행하세요: $ARCHIVE_PATH"

    printf 'Kafka %s 바이너리를 다운로드합니다.\n' "$KAFKA_VERSION"
    curl --fail --location --retry 3 --output "$ARCHIVE_PATH" "$DOWNLOAD_URL"

    printf 'Kafka 압축을 해제합니다.\n'
    tar -xzf "$ARCHIVE_PATH" -C "$HOME"
    [[ -d "$KAFKA_DIR" ]] || die "압축 해제 후 Kafka 디렉터리를 찾지 못했습니다: $KAFKA_DIR"

    mkdir -p "$LOG_DIR"
}

generate_random_uuid() {
    local output
    local value

    if ! output="$("$KAFKA_DIR/bin/kafka-storage.sh" random-uuid 2>&1)"; then
        printf '%s\n' "$output" >&2
        die 'kafka-storage.sh random-uuid 실행에 실패했습니다.'
    fi

    value="$(printf '%s\n' "$output" | awk 'NF {value = $NF} END {print value}' | tr -d '\r\n')"
    is_valid_identifier "$value" || die "Kafka가 유효한 UUID를 반환하지 않았습니다: $value"
    printf '%s' "$value"
}

generate_cluster_ids_if_needed() {
    local i

    if [[ "$CLUSTER_ID_MODE" != 'generate' ]]; then
        return
    fi

    CLUSTER_ID="$(generate_random_uuid)"
    for ((i = 1; i <= NODE_COUNT; i++)); do
        DIRECTORY_IDS[$i]="$(generate_random_uuid)"
    done
}

build_controller_values() {
    local i

    CONTROLLER_BOOTSTRAP_SERVERS=''
    INITIAL_CONTROLLERS=''

    for ((i = 1; i <= NODE_COUNT; i++)); do
        if [[ -n "$CONTROLLER_BOOTSTRAP_SERVERS" ]]; then
            CONTROLLER_BOOTSTRAP_SERVERS+=','
            INITIAL_CONTROLLERS+=','
        fi
        CONTROLLER_BOOTSTRAP_SERVERS+="${NODE_IPS[$i]}:${CONTROLLER_PORT}"
        INITIAL_CONTROLLERS+="${i}@${NODE_IPS[$i]}:${CONTROLLER_PORT}:${DIRECTORY_IDS[$i]}"
    done
}

write_node_properties() {
    local min_in_sync_replicas

    if ((NODE_COUNT == 1)); then
        min_in_sync_replicas=1
    else
        min_in_sync_replicas=$((NODE_COUNT - 1))
    fi

    mkdir -p "${KAFKA_DIR}/config"
    cat > "$NODE_PROPERTIES" <<EOF
process.roles=broker,controller
node.id=${NODE_ID}
controller.quorum.bootstrap.servers=${CONTROLLER_BOOTSTRAP_SERVERS}
listeners=PLAINTEXT://0.0.0.0:${BROKER_PORT},CONTROLLER://${MY_IP}:${CONTROLLER_PORT}
advertised.listeners=PLAINTEXT://${MY_IP}:${BROKER_PORT}
listener.security.protocol.map=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
inter.broker.listener.name=PLAINTEXT
controller.listener.names=CONTROLLER
log.dirs=${LOG_DIR}
num.partitions=3
default.replication.factor=${NODE_COUNT}
min.insync.replicas=${min_in_sync_replicas}
offsets.topic.replication.factor=${NODE_COUNT}
transaction.state.log.replication.factor=${NODE_COUNT}
transaction.state.log.min.isr=${min_in_sync_replicas}
auto.create.topics.enable=false
group.initial.rebalance.delay.ms=0
EOF
}

format_kraft_metadata() {
    printf 'KRaft metadata를 포맷합니다.\n'
    "$KAFKA_DIR/bin/kafka-storage.sh" format \
        --cluster-id "$CLUSTER_ID" \
        --config "$NODE_PROPERTIES" \
        --initial-controllers "$INITIAL_CONTROLLERS"
}

update_bashrc() {
    local bashrc="${HOME}/.bashrc"
    local temp_file
    local old_mode=''
    local i
    local variable_name
    local marker_start='# >>> kafka-4.3.1-cluster >>>'
    local marker_end='# <<< kafka-4.3.1-cluster <<<'

    touch "$bashrc"
    temp_file="$(mktemp "${bashrc}.tmp.XXXXXX")"

    awk -v start="$marker_start" -v end="$marker_end" '
        $0 == start {skip = 1; next}
        $0 == end {skip = 0; next}
        !skip {print}
    ' "$bashrc" > "$temp_file"

    {
        printf '%s\n' "$marker_start"
        printf 'export CLUSTER_ID=%q\n' "$CLUSTER_ID"
        printf 'export NODE_COUNT=%q\n' "$NODE_COUNT"
        printf 'export NODE_ID=%q\n' "$NODE_ID"
        printf 'export MY_IP=%q\n' "$MY_IP"
        for ((i = 1; i <= NODE_COUNT; i++)); do
            variable_name="NODE_IP_${i}"
            printf 'export %s=%q\n' "$variable_name" "${NODE_IPS[$i]}"
        done
        for ((i = 1; i <= NODE_COUNT; i++)); do
            variable_name="DIRECTORY_${i}"
            printf 'export %s=%q\n' "$variable_name" "${DIRECTORY_IDS[$i]}"
        done
        printf 'export INITIAL_CONTROLLERS=%q\n' "$INITIAL_CONTROLLERS"
        printf '%s\n' "$marker_end"
    } >> "$temp_file"

    if old_mode="$(stat -c '%a' "$bashrc" 2>/dev/null)"; then
        chmod "$old_mode" "$temp_file"
    fi
    mv "$temp_file" "$bashrc"

    export CLUSTER_ID NODE_COUNT NODE_ID MY_IP INITIAL_CONTROLLERS
}

print_summary() {
    local i

    printf '\n===== Kafka KRaft 클러스터 최종 요약 =====\n'
    printf 'CLUSTER_ID (cluster UUID): %s\n' "$CLUSTER_ID"
    if [[ "$CLUSTER_ID_MODE" == 'generate' ]]; then
        printf 'CLUSTER_ID 상태: 이번 실행에서 자동 생성\n'
    else
        printf 'CLUSTER_ID 상태: 입력값 사용\n'
    fi
    printf '활성 Conda 환경: %s\n' "$KAFKA_CONDA_ENV"
    printf 'JAVA_HOME: %s\n' "$JAVA_HOME"
    printf '현재 node.id: %s\n' "$NODE_ID"
    printf '현재 node IP: %s\n\n' "$MY_IP"
    printf '%-8s %-18s %s\n' 'node.id' 'IP address' 'directory-id'
    for ((i = 1; i <= NODE_COUNT; i++)); do
        if [[ "$i" == "$NODE_ID" ]]; then
            printf '%-8s %-18s %s  (현재 노드)\n' "$i" "${NODE_IPS[$i]}" "${DIRECTORY_IDS[$i]}"
        else
            printf '%-8s %-18s %s\n' "$i" "${NODE_IPS[$i]}" "${DIRECTORY_IDS[$i]}"
        fi
    done
    printf '\nINITIAL_CONTROLLERS: %s\n' "$INITIAL_CONTROLLERS"
    printf 'node.properties: %s\n' "$NODE_PROPERTIES"
    printf '\nKafka 실행 전 반드시 Conda 환경을 활성화하세요:\n'
    printf 'conda activate kafka\n'
    printf '\n활성화된 kafka 환경에서 실행할 Kafka 시작 명령:\n'
    printf '%s\n' "$KAFKA_DIR/bin/kafka-server-start.sh $NODE_PROPERTIES"
    printf '\n/etc/hosts는 수정하지 않았습니다. 모든 노드는 위의 실제 IP를 사용합니다.\n'
}

main() {
    local command_name
    if [[ ! -r /proc/sys/kernel/osrelease ]] || ! grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease; then
        die '이 스크립트는 WSL 내부에서 실행해야 합니다.'
    fi

    setup_kafka_conda_environment

    for command_name in awk curl grep ip java mktemp sort stat tar tr; do
        require_command "$command_name"
    done

    prompt_node_count
    prompt_cluster_id
    prompt_node_id
    detect_current_ip
    prompt_other_node_ips
    prompt_directory_ids
    download_and_extract_kafka
    generate_cluster_ids_if_needed
    build_controller_values
    write_node_properties
    format_kraft_metadata
    update_bashrc
    print_summary
}

main "$@"
