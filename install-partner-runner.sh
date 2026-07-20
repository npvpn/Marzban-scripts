#!/usr/bin/env bash
# Install a GitHub Actions self-hosted runner for partner panel deploys
# (npvpn/telegram_bot → workflow Deploy partner panels).
#
# Usage:
#   sudo bash install-partner-runner.sh --token <TOKEN> --label partner-<slug> [--project-dir /opt/marzban]
#
# Or via curl:
#   sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/install-partner-runner.sh)" @ \
#     --token <TOKEN> --label partner-my_bot

set -euo pipefail

REPO_URL="https://github.com/npvpn/telegram_bot"
DEPLOY_USER="deploy"
PROJECT_DIR="/opt/marzban"
LABEL=""
TOKEN=""
RUNNER_NAME=""
FORCE="false"
SKIP_SERVICE="false"

colorized_echo() {
    local color=$1
    local text=$2
    case $color in
        red) printf "\e[91m%s\e[0m\n" "$text" ;;
        green) printf "\e[92m%s\e[0m\n" "$text" ;;
        yellow) printf "\e[93m%s\e[0m\n" "$text" ;;
        blue) printf "\e[94m%s\e[0m\n" "$text" ;;
        cyan) printf "\e[96m%s\e[0m\n" "$text" ;;
        *) echo "$text" ;;
    esac
}

usage() {
    cat <<'EOF'
Install GitHub Actions self-hosted runner for partner panel deploys.

Required:
  --token TOKEN          Registration token from:
                         telegram_bot → Settings → Actions → Runners → New self-hosted runner
  --label LABEL          Runner label, e.g. partner-my_vpn_bot
                         (must match deploy-partner-panels.yml / Run workflow input)

Optional:
  --project-dir PATH     Panel compose directory (default: /opt/marzban)
  --repo-url URL         GitHub repo to register against
                         (default: https://github.com/npvpn/telegram_bot)
  --name NAME            Runner name in GitHub UI (default: <label>-<hostname>)
  --user NAME            Linux user for the runner (default: deploy)
  --force                Reconfigure if a runner is already set up in ~/actions-runner
  --skip-service         Configure runner but do not install/start systemd service
  -h, --help             Show this help
EOF
}

check_running_as_root() {
    if [ "$(id -u)" != "0" ]; then
        colorized_echo red "This command must be run as root."
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --token)
                TOKEN="$2"
                shift 2
                ;;
            --label)
                LABEL="$2"
                shift 2
                ;;
            --project-dir)
                PROJECT_DIR="$2"
                shift 2
                ;;
            --repo-url)
                REPO_URL="$2"
                shift 2
                ;;
            --name)
                RUNNER_NAME="$2"
                shift 2
                ;;
            --user)
                DEPLOY_USER="$2"
                shift 2
                ;;
            --force)
                FORCE="true"
                shift
                ;;
            --skip-service)
                SKIP_SERVICE="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            @)
                # Allow: bash -c "$(curl …)" @ --token …
                shift
                ;;
            *)
                colorized_echo red "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

validate_args() {
    if [ -z "$TOKEN" ]; then
        colorized_echo red "Missing required --token"
        exit 1
    fi
    if [ -z "$LABEL" ]; then
        colorized_echo red "Missing required --label (e.g. partner-my_vpn_bot)"
        exit 1
    fi
    if [[ ! "$LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        colorized_echo red "Invalid --label '$LABEL'. Use letters, digits, '.', '_' , '-'."
        exit 1
    fi
    if [ -z "$RUNNER_NAME" ]; then
        local host_part
        host_part=$(hostname -s 2>/dev/null || hostname || echo "host")
        RUNNER_NAME="${LABEL}-${host_part}"
    fi
}

ensure_deploy_user() {
    if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
        colorized_echo blue "Creating user ${DEPLOY_USER}"
        useradd -m -s /bin/bash "$DEPLOY_USER"
    fi

    if getent group docker >/dev/null 2>&1; then
        usermod -aG docker "$DEPLOY_USER"
    else
        colorized_echo yellow "Group 'docker' not found. Install Docker before deploying panels via Actions."
    fi
}

ensure_project_dir() {
    if [ ! -d "$PROJECT_DIR" ]; then
        colorized_echo red "Project directory not found: $PROJECT_DIR"
        colorized_echo yellow "Install the partner panel first (marzban.sh install-partner)."
        exit 1
    fi
    if [ ! -f "$PROJECT_DIR/docker-compose.yml" ]; then
        colorized_echo red "docker-compose.yml not found in $PROJECT_DIR"
        exit 1
    fi
    colorized_echo blue "Setting ownership of $PROJECT_DIR to ${DEPLOY_USER}:${DEPLOY_USER}"
    chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "$PROJECT_DIR"
}

download_latest_runner() {
    local runner_dir=$1
    local version archive url

    colorized_echo blue "Resolving latest GitHub Actions runner release"
    version=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | sed -n 's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' | head -1)
    if [ -z "$version" ]; then
        colorized_echo red "Failed to resolve latest runner version from GitHub API"
        exit 1
    fi

    archive="actions-runner-linux-x64-${version}.tar.gz"
    url="https://github.com/actions/runner/releases/download/v${version}/${archive}"

    mkdir -p "$runner_dir"
    chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "$runner_dir"

    if [ -f "$runner_dir/config.sh" ] && [ "$FORCE" != "true" ]; then
        colorized_echo yellow "Runner files already present in $runner_dir (skip download)"
        return 0
    fi

    colorized_echo blue "Downloading runner v${version}"
    curl -fsSL -o "/tmp/${archive}" "$url"
    # Clear previous extract if forcing reinstall of binaries
    if [ "$FORCE" = "true" ] && [ -f "$runner_dir/config.sh" ]; then
        find "$runner_dir" -mindepth 1 -maxdepth 1 ! -name '_work' -exec rm -rf {} +
    fi
    tar xzf "/tmp/${archive}" -C "$runner_dir"
    rm -f "/tmp/${archive}"
    chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "$runner_dir"

    if [ -x "$runner_dir/bin/installdependencies.sh" ]; then
        colorized_echo blue "Installing runner OS dependencies"
        "$runner_dir/bin/installdependencies.sh"
    fi
}

configure_runner() {
    local runner_dir=$1

    if [ -f "$runner_dir/.runner" ] && [ "$FORCE" != "true" ]; then
        colorized_echo yellow "Runner already configured at $runner_dir (.runner exists)."
        colorized_echo yellow "Pass --force to remove and reconfigure."
        return 0
    fi

    if [ -f "$runner_dir/.runner" ] && [ "$FORCE" = "true" ]; then
        colorized_echo yellow "Removing existing runner configuration (--force)"
        # Best-effort remove; ignore failures if token expired / already removed
        su - "$DEPLOY_USER" -c "cd '$runner_dir' && ./config.sh remove --token '$TOKEN'" || true
        rm -f "$runner_dir/.runner" "$runner_dir/.credentials" "$runner_dir/.credentials_rsaparams" 2>/dev/null || true
    fi

    colorized_echo blue "Configuring runner: name=${RUNNER_NAME} labels=${LABEL}"
    su - "$DEPLOY_USER" -c "cd '$runner_dir' && ./config.sh --url '$REPO_URL' --token '$TOKEN' --labels '$LABEL' --name '$RUNNER_NAME' --unattended"

    # PROJECT_DIR for deploy-partner-panels.yml
    local env_file="$runner_dir/.env"
    touch "$env_file"
    chown "${DEPLOY_USER}:${DEPLOY_USER}" "$env_file"
    if grep -qE '^PROJECT_DIR=' "$env_file" 2>/dev/null; then
        sed -i -E "s|^PROJECT_DIR=.*|PROJECT_DIR=${PROJECT_DIR}|" "$env_file"
    else
        printf 'PROJECT_DIR=%s\n' "$PROJECT_DIR" >> "$env_file"
    fi
    colorized_echo green "Wrote PROJECT_DIR=${PROJECT_DIR} to $env_file"
}

install_service() {
    local runner_dir=$1

    if [ "$SKIP_SERVICE" = "true" ]; then
        colorized_echo yellow "Skipping systemd service (--skip-service)"
        return 0
    fi

    colorized_echo blue "Installing systemd service for user ${DEPLOY_USER}"
    cd "$runner_dir"
    if [ -f "$runner_dir/.service" ]; then
        ./svc.sh stop 2>/dev/null || true
        ./svc.sh uninstall 2>/dev/null || true
    fi
    ./svc.sh install "$DEPLOY_USER"
    ./svc.sh start
    ./svc.sh status || true
}

print_summary() {
    colorized_echo blue "====================================="
    colorized_echo green "Partner runner install complete"
    colorized_echo blue "====================================="
    colorized_echo cyan "Repo:    $REPO_URL"
    colorized_echo cyan "Label:   $LABEL"
    colorized_echo cyan "Name:    $RUNNER_NAME"
    colorized_echo cyan "PROJECT_DIR=$PROJECT_DIR"
    echo
    colorized_echo yellow "Next steps:"
    echo "  1. GitHub → ${REPO_URL} → Settings → Actions → Runners — status Idle, label ${LABEL}"
    echo "  2. Add ${LABEL} to deploy-partner-panels.yml (options + ALL_PARTNERS), merge to master"
    echo "  3. Actions → Deploy partner panels → partner=${LABEL}"
    colorized_echo blue "====================================="
}

main() {
    parse_args "$@"
    check_running_as_root
    validate_args

    local home_dir runner_dir
    ensure_deploy_user
    home_dir=$(getent passwd "$DEPLOY_USER" | cut -d: -f6)
    runner_dir="${home_dir}/actions-runner"

    ensure_project_dir
    download_latest_runner "$runner_dir"
    configure_runner "$runner_dir"
    install_service "$runner_dir"
    print_summary
}

main "$@"
