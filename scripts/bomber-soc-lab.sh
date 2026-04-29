#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

LAB_ROOT="${SOC_LAB_ROOT:-$HOME/soc-lab}"
LEGACY_LAB_ROOT="$HOME/elastic-lab"
DEFAULT_USER="default"
PROFILE=""
AUTO_APPROVE=0

C_RESET="$(printf '\033[0m')"
C_BOLD="$(printf '\033[1m')"
C_BLUE="$(printf '\033[38;5;45m')"
C_CYAN="$(printf '\033[38;5;81m')"
C_GOLD="$(printf '\033[38;5;221m')"
C_GREEN="$(printf '\033[38;5;84m')"
C_RED="$(printf '\033[38;5;203m')"

info() { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$1"; }
ok() { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn() { printf '%s[WARN]%s %s\n' "$C_GOLD" "$C_RESET" "$1"; }
fail() { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit 1; }
phase() { printf '\n%s%s[%s]%s %s\n' "$C_BOLD" "$C_CYAN" "$1" "$C_RESET" "$2"; }

banner() {
cat <<EOF

${C_BOLD}${C_RED}╔════════════════════════════════════════════════════════════════════╗${C_RESET}
${C_BOLD}${C_RED}║${C_RESET} ${C_BOLD}${C_GOLD}Blackout Protocol${C_RESET} ${C_BLUE}::${C_RESET} SOC Lab Removal Utility                     ${C_BOLD}${C_RED}║${C_RESET}
${C_BOLD}${C_RED}║${C_RESET} ${C_BLUE}Profile-based teardown for config-only, full lab, or full host wipe${C_RESET} ${C_BOLD}${C_RED}║${C_RESET}
${C_BOLD}${C_RED}╚════════════════════════════════════════════════════════════════════╝${C_RESET}

EOF
}

usage() {
  cat <<EOF
Usage: bash scripts/bomber-soc-lab.sh [OPTIONS]

Options:
  --profile light|mid|heavy   Select teardown depth. If omitted, an interactive chooser is shown
  --yes                       Non-interactive mode
  -h, --help                  Show this help text

Profiles:
  light   Remove rebuildable generated configs and transient lab runtime files only.
  mid     Remove the full lab footprint, including containers, volumes, Filebeat, and telemetry hooks.
  heavy   Remove everything from mid plus Docker packages/data and the helper Linux user.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        shift
        PROFILE="${1:-}"
        ;;
      --yes)
        AUTO_APPROVE=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
    shift
  done

  case "$PROFILE" in
    "") ;;
    light|mid|heavy) ;;
    *) fail "Unsupported profile '$PROFILE'. Use light, mid, or heavy." ;;
  esac
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

can_sudo_noninteractive() {
  have_cmd sudo && sudo -n true >/dev/null 2>&1
}

confirm() {
  local prompt="$1"
  local default_answer="${2:-n}"
  local reply

  if (( AUTO_APPROVE )); then
    [[ "$default_answer" == "y" ]]
    return $?
  fi

  read -r -p "$prompt" reply
  reply="${reply:-$default_answer}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

select_profile() {
  if [[ -n "$PROFILE" ]]; then
    return 0
  fi

  if (( AUTO_APPROVE )); then
    PROFILE="mid"
    return 0
  fi

  printf '\n%sAvailable Profiles%s\n' "$C_BOLD" "$C_RESET"
  printf '  1. light  - remove rebuildable generated config/runtime files only\n'
  printf '  2. mid    - remove the full lab footprint\n'
  printf '  3. heavy  - remove the full lab footprint plus Docker and helper user\n'

  while true; do
    local choice
    read -r -p "Select teardown profile [1-3] (default: 2): " choice
    choice="${choice:-2}"

    case "$choice" in
      1|light|LIGHT|Light)
        PROFILE="light"
        return 0
        ;;
      2|mid|MID|Mid)
        PROFILE="mid"
        return 0
        ;;
      3|heavy|HEAVY|Heavy)
        PROFILE="heavy"
        return 0
        ;;
      *)
        warn "Invalid selection. Choose 1, 2, or 3."
        ;;
    esac
  done
}

remove_dir_if_present() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  rm -rf "$path"
}

remove_file_if_present() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  rm -f "$path"
}

remove_audit_rule_if_present() {
  have_cmd auditctl || return 0

  if is_root; then
    auditctl -l 2>/dev/null | grep -q 'exec_log' || return 0
    auditctl -d always,exit -F arch=b64 -S execve -k exec_log >/dev/null 2>&1 || true
    return 0
  fi

  if can_sudo_noninteractive; then
    sudo -n auditctl -l 2>/dev/null | grep -q 'exec_log' || return 0
    sudo -n auditctl -d always,exit -F arch=b64 -S execve -k exec_log >/dev/null 2>&1 || true
  else
    warn "Skipping audit rule removal because sudo would prompt interactively"
  fi
}

profile_summary() {
  case "$PROFILE" in
    light)
      printf '%s\n' "Remove generated lab config/runtime files only. Keep containers, volumes, Docker, Filebeat package, and helper user."
      ;;
    mid)
      printf '%s\n' "Remove the full lab footprint: containers, volumes, runtime files, Filebeat package/config, telemetry hooks, and cloned lab artifacts."
      ;;
    heavy)
      printf '%s\n' "Remove everything from mid, then also remove Docker packages/data and the helper Linux user."
      ;;
  esac
}

teardown_light() {
  phase "1/3" "Config Reset"

  if have_cmd systemctl; then
    sudo systemctl stop filebeat >/dev/null 2>&1 || true
  elif have_cmd service; then
    sudo service filebeat stop >/dev/null 2>&1 || true
  fi

  sudo rm -f /etc/filebeat/filebeat.yml /etc/profile.d/soc-lab-history-sync.sh
  remove_file_if_present "$LAB_ROOT/.credentials.env"
  remove_file_if_present "$LAB_ROOT/.wsl-retro-ingest-complete"
  remove_file_if_present "$LAB_ROOT/docker-compose.yml"
  remove_file_if_present "$HOME/filebeat-8.12.2-amd64.deb"
  ok "Generated config files removed"

  phase "2/3" "Lab Runtime Notes"
  info "Containers, volumes, Filebeat package, and Docker remain installed under the light profile"
  info "Re-running install.sh will rebuild the removed config artifacts"

  phase "3/3" "Complete"
  ok "Light teardown complete"
}

teardown_mid() {
  phase "1/5" "Docker Stack Removal"
  if have_cmd docker; then
    if [[ -f "$LAB_ROOT/docker-compose.yml" ]]; then
      (cd "$LAB_ROOT" && docker compose down -v --remove-orphans) || true
    fi
    docker rm -f elasticsearch kibana fleet-server >/dev/null 2>&1 || true
    docker volume rm -f soc-lab_esdata >/dev/null 2>&1 || true
    docker network rm soc-lab_default >/dev/null 2>&1 || true
    docker image prune -f >/dev/null 2>&1 || true
  else
    warn "Docker not found; skipping container cleanup"
  fi
  ok "Lab-owned Docker resources removed"

  phase "2/5" "Filebeat And Host Telemetry Cleanup"
  if have_cmd systemctl; then
    sudo systemctl stop filebeat >/dev/null 2>&1 || true
    sudo systemctl disable filebeat >/dev/null 2>&1 || true
  elif have_cmd service; then
    sudo service filebeat stop >/dev/null 2>&1 || true
  fi

  sudo apt-get purge -y filebeat >/dev/null 2>&1 || sudo dpkg -r filebeat >/dev/null 2>&1 || true
  sudo rm -rf /etc/filebeat /var/lib/filebeat /etc/profile.d/soc-lab-history-sync.sh
  remove_audit_rule_if_present
  ok "Filebeat and telemetry hooks removed"

  phase "3/5" "Runtime And Artifact Cleanup"
  remove_dir_if_present "$LAB_ROOT"
  remove_dir_if_present "$LEGACY_LAB_ROOT"
  remove_dir_if_present "$HOME/atomic-red-team"
  remove_dir_if_present "$HOME/mitre"
  remove_file_if_present "$HOME/filebeat-8.12.2-amd64.deb"
  ok "Runtime directories and generated artifacts removed"

  phase "4/5" "System Prune"
  if have_cmd docker; then
    docker system prune -af >/dev/null 2>&1 || true
  fi
  ok "System prune complete"

  phase "5/5" "Complete"
  ok "Mid teardown complete"
}

teardown_heavy() {
  teardown_mid

  phase "Heavy-1" "Helper User Cleanup"
  if id "$DEFAULT_USER" >/dev/null 2>&1; then
    sudo userdel -r "$DEFAULT_USER" >/dev/null 2>&1 || warn "Unable to fully remove helper user '$DEFAULT_USER'"
    ok "Helper user '$DEFAULT_USER' removed"
  else
    info "Helper user '$DEFAULT_USER' was not present"
  fi

  phase "Heavy-2" "Docker Removal"
  sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin docker-ce-rootless-extras docker.io docker-doc docker-compose podman-docker >/dev/null 2>&1 || true
  sudo rm -rf /var/lib/docker /etc/docker
  ok "Docker packages and data removed"

  phase "Heavy-3" "Complete"
  ok "Heavy teardown complete"
}

main() {
  parse_args "$@"
  select_profile

  if [[ -t 1 ]]; then
    clear || true
  fi

  banner
  info "Selected profile: $PROFILE"
  info "$(profile_summary)"

  if ! confirm "Proceed with '$PROFILE' SOC lab teardown? [y/N]: " "n"; then
    info "Teardown cancelled"
    exit 0
  fi

  case "$PROFILE" in
    light) teardown_light ;;
    mid) teardown_mid ;;
    heavy) teardown_heavy ;;
  esac

  printf '\n%s[SUCCESS]%s The host is ready for the next step for profile %s.\n' "$C_GREEN" "$C_RESET" "$PROFILE"
}

main "$@"
