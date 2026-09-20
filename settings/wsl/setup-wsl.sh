#!/usr/bin/env bash
# Basic WSL environment setup.
# Run this script inside an already-installed and initialized WSL2 distribution.

set -Eeuo pipefail

readonly WSL_CONF='/etc/wsl.conf'
readonly MINIFORGE_PREFIX="${HOME}/miniforge3"
readonly MINIFORGE_INSTALLER="Miniforge3-$(uname -s)-$(uname -m).sh"
readonly MINIFORGE_URL="https://github.com/conda-forge/miniforge/releases/latest/download/${MINIFORGE_INSTALLER}"
readonly RUN_TIMESTAMP="$(date +%Y%m%d%H%M%S)"

TEMP_FILES=()
WSL_CONFIG_PATH=''
WSL_CONFIG_UPDATED='false'

cleanup() {
  local file
  for file in "${TEMP_FILES[@]}"; do
    [[ -n "$file" && -e "$file" ]] && rm -f "$file"
  done
}
trap cleanup EXIT

log() {
  printf '[setup-wsl] %s\n' "$*"
}

warn() {
  printf '[setup-wsl] Warning: %s\n' "$*" >&2
}

die() {
  printf '[setup-wsl] Error: %s\n' "$*" >&2
  exit 1
}

if (( EUID == 0 )); then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || die 'sudo is required.'
  sudo -v || die 'The current user does not have sudo permission.'
  SUDO=(sudo)
fi

command -v apt-get >/dev/null 2>&1 || die 'Run this script in an apt-based WSL distribution.'
command -v awk >/dev/null 2>&1 || die 'awk is required.'
command -v install >/dev/null 2>&1 || die 'install is required.'

systemd_is_running() {
  [[ -d /run/systemd/system ]]
}

backup_file() {
  local file="$1"
  local backup="${file}.before-setup-wsl-${RUN_TIMESTAMP}.bak"

  if [[ -e "$file" ]]; then
    if [[ "$file" == /etc/* ]]; then
      "${SUDO[@]}" cp -p "$file" "$backup"
    else
      cp "$file" "$backup"
    fi
    log "Backup created: ${backup}"
  fi
}

# Add or replace one key in an INI section while preserving unrelated content.
set_ini_key() {
  local file="$1" target_section="$2" key="$3" value="$4" temp_file
  temp_file="$(mktemp)"
  TEMP_FILES+=("$temp_file")

  awk -v target="$target_section" -v key="$key" -v value="$value" '
    function section_name(line, name) {
      name = line
      sub(/^[[:space:]]*\[/, "", name)
      sub(/\].*$/, "", name)
      return name
    }
    BEGIN { inside=0; section_found=0; key_written=0 }
    /^[[:space:]]*\[[^]]+\]/ {
      if (inside && !key_written) {
        print key "=" value
        key_written=1
      }
      current=section_name($0)
      inside=(current == target)
      if (inside) {
        section_found=1
        key_written=0
      }
      print
      next
    }
    inside && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      if (!key_written) {
        print key "=" value
        key_written=1
      }
      next
    }
    { print }
    END {
      if (inside && !key_written) print key "=" value
      if (!section_found) {
        print ""
        print "[" target "]"
        print key "=" value
      }
    }
  ' "$file" > "$temp_file"

  mv "$temp_file" "$file"
  TEMP_FILES=("${TEMP_FILES[@]/$temp_file}")
}

# Remove a key only from the requested INI section.
remove_ini_key() {
  local file="$1" target_section="$2" key="$3" temp_file
  temp_file="$(mktemp)"
  TEMP_FILES+=("$temp_file")

  awk -v target="$target_section" -v key="$key" '
    function section_name(line, name) {
      name = line
      sub(/^[[:space:]]*\[/, "", name)
      sub(/\].*$/, "", name)
      return name
    }
    BEGIN { inside=0 }
    /^[[:space:]]*\[[^]]+\]/ {
      inside=(section_name($0) == target)
      print
      next
    }
    inside && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { next }
    { print }
  ' "$file" > "$temp_file"

  mv "$temp_file" "$file"
  TEMP_FILES=("${TEMP_FILES[@]/$temp_file}")
}

write_wsl_conf() {
  local temp_file
  temp_file="$(mktemp)"
  TEMP_FILES+=("$temp_file")

  if "${SUDO[@]}" test -f "$WSL_CONF"; then
    backup_file "$WSL_CONF"
    "${SUDO[@]}" cat "$WSL_CONF" > "$temp_file"
  else
    : > "$temp_file"
  fi

  set_ini_key "$temp_file" 'boot' 'systemd' 'true'
  set_ini_key "$temp_file" 'network' 'generateHosts' 'false'
  "${SUDO[@]}" install -o root -g root -m 644 "$temp_file" "$WSL_CONF"
}

install_miniforge() {
  local installer_temp

  case "$(uname -s):$(uname -m)" in
    Linux:x86_64|Linux:aarch64) ;;
    *) die "Unsupported WSL platform: $(uname -s) $(uname -m)" ;;
  esac

  if [[ -x "$MINIFORGE_PREFIX/bin/conda" ]]; then
    log "Miniforge already exists: ${MINIFORGE_PREFIX}"
  else
    [[ ! -e "$MINIFORGE_PREFIX" ]] || die "${MINIFORGE_PREFIX} exists but conda is not available there."

    installer_temp="$(mktemp --suffix=.sh)"
    TEMP_FILES+=("$installer_temp")
    curl --fail --location --retry 3 --output "$installer_temp" "$MINIFORGE_URL"
    bash "$installer_temp" -b -p "$MINIFORGE_PREFIX"
    rm -f "$installer_temp"
  fi

  [[ -x "$MINIFORGE_PREFIX/bin/conda" ]] || die 'Miniforge installation did not produce conda.'
  "$MINIFORGE_PREFIX/bin/conda" init bash >/dev/null
  # shellcheck disable=SC1091
  source "$MINIFORGE_PREFIX/etc/profile.d/conda.sh"
}

configure_ssh() {
  if systemd_is_running; then
    if ! "${SUDO[@]}" systemctl enable --now ssh; then
      warn 'SSH could not be enabled through systemd. Check the service after restarting WSL.'
    fi
    return
  fi

  # Enabling a unit does not require the systemd daemon to be running. This
  # makes the setting effective on the next WSL start.
  if ! "${SUDO[@]}" systemctl enable ssh >/dev/null 2>&1; then
    warn 'SSH could not be enabled for the next systemd start.'
  fi

  if ! "${SUDO[@]}" service ssh start; then
    warn 'SSH could not be started in the current session.'
  fi
  warn 'systemd is not active in this session. Restart WSL after the script finishes.'
}

find_windows_wslconfig() {
  local windows_profile windows_profile_linux

  command -v powershell.exe >/dev/null 2>&1 || return 1
  command -v wslpath >/dev/null 2>&1 || return 1

  windows_profile="$(powershell.exe -NoProfile -NonInteractive -Command '[Environment]::GetFolderPath("UserProfile")' 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d' | tail -n 1)"
  [[ -n "$windows_profile" ]] || return 1

  windows_profile_linux="$(wslpath -u "$windows_profile" 2>/dev/null | tr -d '\r')" || return 1
  [[ -d "$windows_profile_linux" ]] || return 1

  WSL_CONFIG_PATH="${windows_profile_linux}/.wslconfig"
}

write_windows_wslconfig() {
  local temp_file

  if ! find_windows_wslconfig; then
    warn 'Could not locate the Windows user profile through WSL interop; .wslconfig was not changed.'
    warn 'Check that powershell.exe and wslpath are available, then run the script again.'
    return
  fi

  temp_file="$(mktemp)"
  TEMP_FILES+=("$temp_file")

  if [[ -e "$WSL_CONFIG_PATH" ]]; then
    backup_file "$WSL_CONFIG_PATH"
    cp "$WSL_CONFIG_PATH" "$temp_file"
  else
    : > "$temp_file"
  fi

  # generateHosts=false belongs in /etc/wsl.conf, never in .wslconfig.
  remove_ini_key "$temp_file" 'network' 'generateHosts'
  set_ini_key "$temp_file" 'wsl2' 'networkingMode' 'mirrored'
  set_ini_key "$temp_file" 'experimental' 'hostAddressLoopback' 'true'

  if ! cp "$temp_file" "$WSL_CONFIG_PATH"; then
    warn "Could not write ${WSL_CONFIG_PATH}."
    return
  fi

  WSL_CONFIG_UPDATED='true'
}

print_status() {
  printf '\n===== setup-wsl status =====\n'

  printf '\n[Packages]\n'
  git --version
  curl --version | sed -n '1p'

  printf '\n[SSH]\n'
  if systemd_is_running; then
    printf 'systemd: active\n'
    printf 'enabled: '
    "${SUDO[@]}" systemctl is-enabled ssh 2>/dev/null || true
    printf 'active: '
    "${SUDO[@]}" systemctl is-active ssh 2>/dev/null || true
  else
    printf 'systemd: not active in the current session\n'
    "${SUDO[@]}" service ssh status 2>/dev/null || true
  fi


  printf '\n[Miniforge]\n'
  conda --version

  printf '\n[/etc/wsl.conf]\n'
  "${SUDO[@]}" cat "$WSL_CONF"

  printf '\n[Windows .wslconfig]\n'
  if [[ "$WSL_CONFIG_UPDATED" == 'true' ]]; then
    printf 'path: %s\n' "$WSL_CONFIG_PATH"
    cat "$WSL_CONFIG_PATH"
  else
    printf 'not updated by this run\n'
  fi
}

log 'Installing common packages.'
"${SUDO[@]}" apt-get update
"${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git \
  curl \
  ca-certificates \
  iproute2 \
  iputils-ping \
  openssh-server

log 'Updating /etc/wsl.conf.'
write_wsl_conf

log 'Configuring SSH.'
configure_ssh

log 'Installing Miniforge.'
install_miniforge

log 'Updating Windows .wslconfig.'
write_windows_wslconfig

print_status

printf '\nSetup completed. Run the following from Windows PowerShell, then start WSL again:\n'
printf 'wsl --shutdown\n'
