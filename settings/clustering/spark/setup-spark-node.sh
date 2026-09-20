#!/usr/bin/env bash
set -Eeuo pipefail

SPARK_VERSION='4.2.0'
SPARK_DIR_NAME='spark-4.2.0-bin-hadoop3'
SPARK_ARCHIVE_NAME='spark-4.2.0-bin-hadoop3.tgz'
SPARK_DOWNLOAD_URL='https://dlcdn.apache.org/spark/spark-4.2.0/spark-4.2.0-bin-hadoop3.tgz'

CONDA_ENV_NAME='spark'
REQUIRED_PYTHON_VERSION='3.12'
REQUIRED_JAVA_MAJOR='17'

CONDA_BIN=''
HOME_DIR=''
SPARK_HOME=''
ARCHIVE_PATH=''
SPARK_ENV_FILE=''

LOCAL_IP=''
MASTER_HOST_IP=''
MASTER_PORT=''
MASTER_WEBUI_PORT=''
WORKER_CORES=''
WORKER_MEMORY=''
DAEMON_MEMORY=''

die() {
  printf '오류: %s\n' "$*" >&2
  exit 1
}

print_stage() {
  printf '\n[%s]\n' "$*"
}

require_command() {
  local command_name="$1"

  command -v "$command_name" >/dev/null 2>&1 ||
    die "필수 명령을 찾을 수 없습니다: $command_name"
}

require_wsl() {
  [[ -r /proc/sys/kernel/osrelease ]] ||
    die '이 스크립트는 WSL 환경에서 실행해야 합니다.'

  grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease ||
    die '이 스크립트는 WSL 환경에서 실행해야 합니다.'
}

is_valid_ipv4() {
  local value="$1"

  [[ "$value" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1

  awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9][0-9]?[0-9]?$/ || ($i + 0) > 255) {
          exit 1
        }
      }
      exit 0
    }
  ' <<< "$value"
}

is_valid_port() {
  local value="$1"

  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  (( 10#$value >= 1 && 10#$value <= 65535 ))
}

is_valid_positive_integer() {
  local value="$1"

  [[ "$value" =~ ^[1-9][0-9]*$ ]]
}

is_valid_memory() {
  local value="$1"

  [[ "$value" =~ ^[1-9][0-9]*[kKmMgGtTpP]$ ]]
}

prompt_ipv4() {
  local variable_name="$1"
  local label="$2"
  local value

  while true; do
    read -r -p "$label: " value

    if is_valid_ipv4 "$value"; then
      printf -v "$variable_name" '%s' "$value"
      return
    fi

    printf '올바른 IPv4 주소를 입력하세요.\n' >&2
  done
}

prompt_port() {
  local variable_name="$1"
  local label="$2"
  local value

  while true; do
    read -r -p "$label: " value

    if is_valid_port "$value"; then
      printf -v "$variable_name" '%s' "$value"
      return
    fi

    printf '포트는 1부터 65535 사이의 정수여야 합니다.\n' >&2
  done
}

prompt_positive_integer() {
  local variable_name="$1"
  local label="$2"
  local value

  while true; do
    read -r -p "$label: " value

    if is_valid_positive_integer "$value"; then
      printf -v "$variable_name" '%s' "$value"
      return
    fi

    printf '양의 정수를 입력하세요.\n' >&2
  done
}

prompt_memory() {
  local variable_name="$1"
  local label="$2"
  local value

  while true; do
    read -r -p "$label: " value

    if is_valid_memory "$value"; then
      printf -v "$variable_name" '%s' "$value"
      return
    fi

    printf '메모리는 숫자와 단위(k, m, g, t, p)를 포함해야 합니다. 예: 6g\n' >&2
  done
}

find_conda() {
  local candidate

  CONDA_BIN="$(type -P conda 2>/dev/null || true)"

  if [[ -n "$CONDA_BIN" ]]; then
    return
  fi

  for candidate in \
    "$HOME_DIR/miniforge3/bin/conda" \
    "$HOME_DIR/miniconda3/bin/conda" \
    "$HOME_DIR/anaconda3/bin/conda" \
    /opt/conda/bin/conda; do
    if [[ -x "$candidate" ]]; then
      CONDA_BIN="$candidate"
      return
    fi
  done

  die 'Conda 실행 파일을 찾을 수 없습니다.'
}

print_conda_recreate_instructions() {
  local current_python="$1"
  local current_java="$2"

  printf '\n현재 Conda 환경 %s의 버전이 요구사항과 다릅니다.\n' "$CONDA_ENV_NAME"
  printf '현재 Python: %s\n' "$current_python"
  printf '현재 Java: %s\n' "$current_java"
  printf '필요한 버전: Python %s, OpenJDK %s\n' \
    "$REQUIRED_PYTHON_VERSION" "$REQUIRED_JAVA_MAJOR"
  printf '\n가상환경 %s를 제거한 뒤 스크립트를 다시 실행하세요.\n' "$CONDA_ENV_NAME"
  printf '%s\n' \
    'conda deactivate' \
    "conda env remove -y -n $CONDA_ENV_NAME" \
    'bash setup-spark-node.sh'
}

validate_conda_versions() {
  local python_version
  local java_version_line
  local java_version
  local java_major
  local java_line_lower

  [[ "$CONDA_DEFAULT_ENV" == "$CONDA_ENV_NAME" ]] ||
    die "Conda 환경 $CONDA_ENV_NAME 활성화에 실패했습니다."

  [[ -n "$CONDA_PREFIX" ]] ||
    die '활성화된 Conda 환경 경로를 확인할 수 없습니다.'

  [[ -x "$CONDA_PREFIX/bin/python" ]] ||
    die "Python 실행 파일이 없습니다: $CONDA_PREFIX/bin/python"

  [[ -x "$CONDA_PREFIX/bin/java" ]] ||
    die "Java 실행 파일이 없습니다: $CONDA_PREFIX/bin/java"

  if ! python_version="$("$CONDA_PREFIX/bin/python" -c 'import sys; print("%s.%s" % sys.version_info[:2])')"; then
    die 'Conda 환경의 Python 버전을 확인할 수 없습니다.'
  fi

  java_version_line="$("$CONDA_PREFIX/bin/java" -version 2>&1 | awk 'NR == 1 { print; exit }')"
  java_version="$(printf '%s\n' "$java_version_line" | awk -F'"' '{ print $2 }')"
  java_major="$(printf '%s\n' "$java_version" | awk -F. '{ print $1 }')"
  java_line_lower="$(printf '%s' "$java_version_line" | tr '[:upper:]' '[:lower:]')"

  if [[ "$python_version" != "$REQUIRED_PYTHON_VERSION" ||
        "$java_major" != "$REQUIRED_JAVA_MAJOR" ||
        "$java_line_lower" != *openjdk* ]]; then
    print_conda_recreate_instructions "$python_version" "$java_version_line"
    return 1
  fi

  printf 'Conda 환경 확인 완료: %s (Python %s, OpenJDK %s)\n' \
    "$CONDA_ENV_NAME" "$python_version" "$REQUIRED_JAVA_MAJOR"
}

setup_conda_environment() {
  local environment_exists=0

  find_conda

  eval "$("$CONDA_BIN" shell.bash hook)"

  if conda env list | awk -v environment="$CONDA_ENV_NAME" '
    $1 == environment { found = 1 }
    END { exit(found ? 0 : 1) }
  '; then
    environment_exists=1
  fi

  if (( environment_exists == 0 )); then
    printf 'Conda 환경 %s를 생성합니다.\n' "$CONDA_ENV_NAME"
    conda create -y -n "$CONDA_ENV_NAME" \
      "python=$REQUIRED_PYTHON_VERSION" \
      "openjdk=$REQUIRED_JAVA_MAJOR"
  else
    printf '기존 Conda 환경 %s를 사용합니다.\n' "$CONDA_ENV_NAME"
  fi

  conda activate "$CONDA_ENV_NAME"
  validate_conda_versions
}

prompt_cluster_values() {
  printf '\nSpark Standalone 설정값을 입력하세요.\n'

  LOCAL_IP="$(hostname -I | awk '{print $1}')"
  is_valid_ipv4 "$LOCAL_IP" ||
    die "hostname -I did not return a valid IPv4 address: $LOCAL_IP"
  printf 'local IP auto-detected: %s\n' "$LOCAL_IP"
  prompt_ipv4 MASTER_HOST_IP 'master host IP'
  prompt_port MASTER_PORT 'master port'
  prompt_port MASTER_WEBUI_PORT 'master web UI port'
  prompt_positive_integer WORKER_CORES 'worker cores'
  prompt_memory WORKER_MEMORY 'worker memory'
  prompt_memory DAEMON_MEMORY 'daemon memory'
}

remove_existing_spark_installation() {
  if [[ ! -e "$SPARK_HOME" && ! -L "$SPARK_HOME" ]]; then
    printf '기존 Spark 설치 경로가 없습니다.\n'
    return
  fi

  [[ "$SPARK_HOME" == "$HOME_DIR/$SPARK_DIR_NAME" ]] ||
    die "삭제 대상 경로가 예상 경로와 다릅니다: $SPARK_HOME"

  printf '기존 Spark 설치 경로를 삭제합니다: %s\n' "$SPARK_HOME"
  rm -rf -- "$SPARK_HOME"
}

download_and_extract_spark() {
  if [[ -e "$ARCHIVE_PATH" && ! -f "$ARCHIVE_PATH" ]]; then
    die "Spark 압축 파일 경로가 일반 파일이 아닙니다: $ARCHIVE_PATH"
  fi

  if [[ -f "$ARCHIVE_PATH" ]]; then
    printf '기존 Spark 압축 파일을 재사용합니다: %s\n' "$ARCHIVE_PATH"
  else
    printf 'Spark %s 압축 파일을 다운로드합니다.\n' "$SPARK_VERSION"
    curl --fail --location --retry 3 \
      --output "$ARCHIVE_PATH" \
      "$SPARK_DOWNLOAD_URL"
  fi

  printf 'Spark 압축 파일을 해제합니다.\n'
  tar -xzf "$ARCHIVE_PATH" -C "$HOME_DIR"

  [[ -d "$SPARK_HOME" ]] ||
    die "압축 해제 후 Spark 설치 경로를 찾을 수 없습니다: $SPARK_HOME"
}

write_spark_env() {
  mkdir -p "$SPARK_HOME/conf"

  cat > "$SPARK_ENV_FILE" <<EOF
export PYSPARK_PYTHON=\$CONDA_PREFIX/bin/python
export PYSPARK_DRIVER_PYTHON="\$PYSPARK_PYTHON"

export SPARK_LOCAL_IP="$LOCAL_IP"
export SPARK_MASTER_HOST="$MASTER_HOST_IP"
export SPARK_MASTER_PORT="$MASTER_PORT"
export SPARK_MASTER_WEBUI_PORT="$MASTER_WEBUI_PORT"

export SPARK_WORKER_CORES="$WORKER_CORES"
export SPARK_WORKER_MEMORY="$WORKER_MEMORY"
export SPARK_DAEMON_MEMORY="$DAEMON_MEMORY"
EOF

  chmod +x "$SPARK_ENV_FILE"
  bash -n "$SPARK_ENV_FILE"
}

ensure_launcher_permissions() {
  chmod +x \
    "$SPARK_HOME/bin/spark-submit" \
    "$SPARK_HOME/sbin/start-master.sh" \
    "$SPARK_HOME/sbin/start-worker.sh"

  find "$SPARK_HOME/bin" "$SPARK_HOME/sbin" \
    -maxdepth 1 \
    -type f \
    -name '*.sh' \
    -exec chmod +x {} +
}

verify_spark_installation() {
  local required_file

  for required_file in \
    "$SPARK_HOME/bin/spark-submit" \
    "$SPARK_HOME/sbin/start-master.sh" \
    "$SPARK_HOME/sbin/start-worker.sh" \
    "$SPARK_ENV_FILE"; do
    [[ -f "$required_file" ]] ||
      die "필수 파일을 찾을 수 없습니다: $required_file"
  done
}

print_summary() {
  printf '\nSpark 노드 설치 및 설정이 완료되었습니다.\n'
  printf 'Conda 환경: %s\n' "$CONDA_ENV_NAME"
  printf 'Spark 버전: %s\n' "$SPARK_VERSION"
  printf 'Spark 경로: ~/%s\n' "$SPARK_DIR_NAME"
  printf 'Spark 압축 파일: ~/%s\n' "$SPARK_ARCHIVE_NAME"
  printf 'local IP: %s\n' "$LOCAL_IP"
  printf 'Master 주소: %s:%s\n' "$MASTER_HOST_IP" "$MASTER_PORT"
  printf 'Master Web UI 포트: %s\n' "$MASTER_WEBUI_PORT"
  printf 'Worker cores: %s\n' "$WORKER_CORES"
  printf 'Worker memory: %s\n' "$WORKER_MEMORY"
  printf 'Daemon memory: %s\n' "$DAEMON_MEMORY"

  printf '\nMaster 시작 명령:\n'
  printf 'cd ~/%s\n' "$SPARK_DIR_NAME"
  printf 'conda activate %s\n' "$CONDA_ENV_NAME"
  printf './sbin/start-master.sh\n'

  printf '\nWorker 시작 명령:\n'
  printf 'cd ~/%s\n' "$SPARK_DIR_NAME"
  printf 'conda activate %s\n' "$CONDA_ENV_NAME"
  printf './sbin/start-worker.sh "spark://%s:%s"\n' \
    "$MASTER_HOST_IP" "$MASTER_PORT"

  printf '\n참고: spark-defaults.conf는 생성하지 않았습니다. '
  printf 'Spark Standalone 데몬 시작에는 필요하지 않으며, Job 제출용 기본값이 필요할 때 별도로 작성하면 됩니다.\n'
}

main() {
  require_wsl

  cd ~
  HOME_DIR="$PWD"

  require_command awk
  require_command bash
  require_command hostname
  require_command cat
  require_command chmod
  require_command curl
  require_command find
  require_command grep
  require_command rm
  require_command tar
  require_command tr

  print_stage 'Conda 환경 준비'
  setup_conda_environment

  print_stage 'Spark 설정값 입력'
  prompt_cluster_values

  SPARK_HOME="$HOME_DIR/$SPARK_DIR_NAME"
  ARCHIVE_PATH="$HOME_DIR/$SPARK_ARCHIVE_NAME"
  SPARK_ENV_FILE="$SPARK_HOME/conf/spark-env.sh"

  print_stage '기존 Spark 설치 제거'
  remove_existing_spark_installation

  print_stage 'Spark 다운로드 및 압축 해제'
  download_and_extract_spark

  print_stage 'spark-env.sh 생성'
  write_spark_env

  print_stage '실행 파일 및 설치 상태 확인'
  ensure_launcher_permissions
  verify_spark_installation

  print_summary
}

main "$@"

