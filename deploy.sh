#!/usr/bin/env bash
# ==============================================================================
# deploy.sh  |  Automated Docker Deployment Script
# ==============================================================================
# Author: Adedayo Adenugba
# Description:
#   A single, self-contained Bash script that:
#     1. Collects parameters (repo, SSH, etc.)
#     2. Clones or updates a Git repo using a PAT
#     3. Validates Dockerfile/docker-compose.yml
#     4. Connects to a remote server via SSH
#     5. Prepares remote environment (Docker, Nginx)
#     6. Transfers files and runs containers
#     7. Configures Nginx reverse proxy
#     8. Validates deployment and logs all actions
#     9. Supports --cleanup flag for full removal
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh          → normal deployment
#   ./deploy.sh --cleanup → remove deployed resources
# ==============================================================================

set -o errexit
set -o nounset
set -o pipefail

# ------------------------------------------------------------------------------
# Logging setup
# ------------------------------------------------------------------------------
LOG_DIR="./logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "$(date --iso-8601=seconds) [INFO]  $*"; }
err() { echo "$(date --iso-8601=seconds) [ERROR] $*" >&2; }
die() { err "$1"; exit "${2:-1}"; }

trap 'err "Unexpected error occurred at line $LINENO"; exit 1' ERR

# ------------------------------------------------------------------------------
# Section 1 — Collect User Input
# ------------------------------------------------------------------------------
if [[ "${1:-}" == "--cleanup" ]]; then
  CLEANUP_MODE=true
else
  CLEANUP_MODE=false
fi

log "=== Collecting user inputs ==="
read -rp "Git repository URL (HTTPS): " GIT_REPO
printf "Personal Access Token (hidden): "
stty -echo; read -r GIT_PAT; stty echo; echo
read -rp "Branch (default 'main'): " BRANCH; BRANCH=${BRANCH:-main}
read -rp "Remote SSH username: " REMOTE_USER
read -rp "Remote server IP address: " REMOTE_HOST
read -rp "SSH key path (e.g. ~/.ssh/id_rsa): " SSH_KEY
read -rp "Application internal port (container): " APP_PORT

[[ -n "$GIT_REPO" ]] || die "Repository URL is required."
[[ -f "$SSH_KEY" ]] || die "SSH key not found at $SSH_KEY."

REPO_NAME="$(basename -s .git "$GIT_REPO")"
LOCAL_DIR="./${REPO_NAME}"
AUTH_URL="${GIT_REPO/https:\/\//https://${GIT_PAT}@}"

log "Collected inputs:
  Repo: $GIT_REPO
  Branch: $BRANCH
  Remote: $REMOTE_USER@$REMOTE_HOST
  SSH Key: $SSH_KEY
  App Port: $APP_PORT
  Repo Folder: $LOCAL_DIR
"

# ------------------------------------------------------------------------------
# Section 2 — Clone or Pull the Repository
# ------------------------------------------------------------------------------
log "=== Cloning or updating repository ==="
if [[ -d "${LOCAL_DIR}/.git" ]]; then
  log "Repository exists, pulling latest changes..."
  (
    cd "$LOCAL_DIR"
    git remote set-url origin "$AUTH_URL"
    git fetch origin
    git checkout "$BRANCH"
    git pull origin "$BRANCH"
  )
else
  git clone --branch "$BRANCH" "$AUTH_URL" "$LOCAL_DIR"
fi

# ------------------------------------------------------------------------------
# Section 3 — Validate Project Structure
# ------------------------------------------------------------------------------
log "=== Validating Docker configuration ==="
cd "$LOCAL_DIR"
if [[ -f Dockerfile ]]; then
  DEPLOY_MODE="dockerfile"
  log "Dockerfile found."
elif [[ -f docker-compose.yml || -f docker-compose.yaml ]]; then
  DEPLOY_MODE="compose"
  log "docker-compose file found."
else
  die "No Dockerfile or docker-compose.yml found in project root."
fi
cd ..

# ------------------------------------------------------------------------------
# Section 4 — Test SSH Connectivity
# ------------------------------------------------------------------------------
log "=== Testing SSH connection to remote server ==="
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=8 "${REMOTE_USER}@${REMOTE_HOST}" "echo SSH_OK" >/dev/null \
  || die "SSH connection failed. Check IP, username, and key."

# ------------------------------------------------------------------------------
# Section 5 — Prepare Remote Environment
# ------------------------------------------------------------------------------
log "=== Preparing remote server environment ==="
ssh -i "$SSH_KEY" "${REMOTE_USER}@${REMOTE_HOST}" bash -s <<'REMOTE'
set -e
if ! command -v docker >/dev/null; then
  echo "Installing Docker..."
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg lsb-release
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo "deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
  https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -y && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

if ! command -v docker-compose >/dev/null && ! docker compose version >/dev/null 2>&1; then
  echo "Installing docker-compose..."
  sudo apt-get install -y docker-compose
fi

if ! command -v nginx >/dev/null; then
  echo "Installing Nginx..."
  sudo apt-get install -y nginx
fi

sudo systemctl enable --now docker nginx
sudo usermod -aG docker "\$USER" || true
docker --version
nginx -v
echo "REMOTE_SETUP_DONE"
REMOTE

# ------------------------------------------------------------------------------
# Cleanup Mode (optional)
# ------------------------------------------------------------------------------
if [[ "$CLEANUP_MODE" == true ]]; then
  log "=== Cleanup Mode Enabled ==="
  ssh -i "$SSH_KEY" "${REMOTE_USER}@${REMOTE_HOST}" bash -s <<REMOTE
sudo docker rm -f ${REPO_NAME} 2>/dev/null || true
sudo docker compose -f /opt/${REPO_NAME}/docker-compose.yml down 2>/dev/null || true
sudo rm -rf /opt/${REPO_NAME} /etc/nginx/sites-available/${REPO_NAME}.conf /etc/nginx/sites-enabled/${REPO_NAME}.conf
sudo systemctl reload nginx
echo "Cleanup completed."
REMOTE
  exit 0
fi

# ------------------------------------------------------------------------------
# Section 6 — Transfer Files & Deploy Containers
# ------------------------------------------------------------------------------
log "=== Transferring project files to remote host ==="
rsync -avz --delete --exclude '.git' --exclude 'node_modules' \
  -e "ssh -i ${SSH_KEY}" "${LOCAL_DIR}/" "${REMOTE_USER}@${REMOTE_HOST}:/opt/${REPO_NAME}/"

log "=== Building and running Docker containers ==="
if [[ "$DEPLOY_MODE" == "compose" ]]; then
  ssh -i "$SSH_KEY" "${REMOTE_USER}@${REMOTE_HOST}" "cd /opt/${REPO_NAME} && sudo docker compose down && sudo docker compose up -d --build"
else
  ssh -i "$SSH_KEY" "${REMOTE_USER}@${REMOTE_HOST}" bash -s <<REMOTE
cd /opt/${REPO_NAME}
sudo docker rm -f ${REPO_NAME} 2>/dev/null || true
sudo docker build -t ${REPO_NAME}:latest .
sudo docker run -d --name ${REPO_NAME} --restart unless-stopped -p 127.0.0.1:${APP_PORT}:${APP_PORT} ${REPO_NAME}:latest
REMOTE
fi

# ------------------------------------------------------------------------------
# Section 7 — Configure Nginx Reverse Proxy
# ------------------------------------------------------------------------------
log "=== Configuring Nginx reverse proxy ==="
ssh -i "$SSH_KEY" "${REMOTE_USER}@${REMOTE_HOST}" sudo tee /etc/nginx/sites-available/${REPO_NAME}.conf > /dev/null <<NGCONF
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NGCONF

ssh -i "$SSH_KEY" "${REMOTE_USER}@${REMOTE_HOST}" "sudo ln -sf /etc/nginx/sites-available/${REPO_NAME}.conf /etc/nginx/sites-enabled/${REPO_NAME}.conf && sudo nginx -t && sudo systemctl reload nginx"

# ------------------------------------------------------------------------------
# Section 8 — Validate Deployment
# ------------------------------------------------------------------------------
log "=== Validating deployment ==="
ssh -i "$SSH_KEY" "${REMOTE_USER}@${REMOTE_HOST}" bash -s <<REMOTE
set -e
sudo systemctl is-active --quiet docker || { echo "Docker not running"; exit 1; }
sudo docker ps | grep ${REPO_NAME} || { echo "Container not running"; exit 1; }
curl -I --max-time 5 http://127.0.0.1:${APP_PORT} >/dev/null 2>&1 || { echo "Local port not responding"; exit 1; }
sudo systemctl is-active --quiet nginx || { echo "Nginx not running"; exit 1; }
echo "Deployment validated successfully."
REMOTE

log "=== Testing remote HTTP endpoint ==="
curl -I --max-time 10 "http://${REMOTE_HOST}" || die "Remote endpoint not accessible."

# ------------------------------------------------------------------------------
# Section 9 — Completion
# ------------------------------------------------------------------------------
log "Deployment successful!"
log "Access the app at: http://${REMOTE_HOST}"
log "Full log stored at: ${LOG_FILE}"

exit 0
