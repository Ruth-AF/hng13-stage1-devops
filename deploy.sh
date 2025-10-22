#!/bin/bash
set -euo pipefail  # Enhanced error handling: exit on errors, undefined vars, pipeline fails

# Trap for unexpected errors, logging the failure
trap 'log "ERROR" "Script failed at line $LINENO with exit code $?"; exit 1' ERR

# ===============================================================
# Global Variables and Functions
# ===============================================================

# --- Create timestamped log file ---
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

# --- Logging function with levels ---
log() {
  local level="$1"
  local message="$2"
  local timestamp="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
  if [ "$level" = "ERROR" ]; then
    echo "$timestamp" | tee -a "$LOG_FILE"
  else
    echo "$timestamp" >> "$LOG_FILE"
  fi
}

log "INFO" "---------------------------------------------------------"
log "INFO" " Deployment Initialization Started"
log "INFO" " Log file: $LOG_FILE"
log "INFO" "---------------------------------------------------------"

# ===============================================================
# Step 1: Collect and Validate User Parameters
# ===============================================================

# 1.1 Git Repository URL
while true; do
  read -p "Enter Git repository URL (HTTPS or SSH): " GIT_URL
  if [[ "$GIT_URL" =~ ^(https:\/\/|git@)([A-Za-z0-9._-]+)(:[0-9]+)?[/:][A-Za-z0-9._-]+\/[A-Za-z0-9._-]+(\.git)?$ ]]; then
    log "INFO" "Validated Git repository URL: $GIT_URL"
    break
  else
    echo "Invalid URL format. Example: https://github.com/user/repo.git or git@github.com:user/repo.git"
  fi
done

# Determine if HTTPS (needs PAT) or SSH
if [[ "$GIT_URL" =~ ^https:// ]]; then
  IS_HTTPS=true
else
  IS_HTTPS=false
fi

# 1.2 GitHub Personal Access Token (only for HTTPS)
if [ "$IS_HTTPS" = true ]; then
  while true; do
    read -s -p "Enter your GitHub Personal Access Token: " GIT_PAT
    echo  # newline

    # Format check (covers classic ghp_ and fine-grained github_pat_)
    if [[ ! "$GIT_PAT" =~ ^(ghp_|github_pat_)[A-Za-z0-9_]{20,}$ ]]; then
      echo "Invalid token format. Expected: ghp_xxx or github_pat_xxx (check GitHub docs)"
      continue
    fi

    # Live verification via GitHub API
    echo "Verifying token with GitHub..."
    response=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -H "Authorization: token $GIT_PAT" https://api.github.com/user)
    if [[ "$response" -eq 200 ]]; then
      echo "PAT verified successfully."
      log "INFO" "GitHub PAT verified successfully."
      break
    else
      echo "GitHub authentication failed (HTTP $response)."
      read -p "Re-enter token? (y/n): " choice
      [[ "$choice" =~ ^[Yy]$ ]] || { log "ERROR" "PAT verification failed."; exit 2; }
    fi
  done
else
  log "INFO" "SSH URL detected; no PAT required for cloning."
fi

# 1.3 Branch name
read -p "Enter branch name (default: main): " BRANCH
BRANCH=${BRANCH:-main}
if [[ ! "$BRANCH" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
  echo "Invalid branch name format."
  log "ERROR" "Invalid branch name."
  exit 3
fi

# Branch existence check (for HTTPS with PAT; skip for SSH)
DEFAULT_BRANCH="main"
if [ "$IS_HTTPS" = true ]; then
  echo "Checking if branch '$BRANCH' exists..."
  REPO_PATH=$(echo "$GIT_URL" | sed -E 's#https://github.com/##; s#\.git$##')
  branch_check=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -H "Authorization: token $GIT_PAT" "https://api.github.com/repos/${REPO_PATH}/branches/$BRANCH")
  if [[ "$branch_check" -eq 200 ]]; then
    echo "✅ Branch '$BRANCH' exists."
    log "INFO" "Branch '$BRANCH' validated."
  else
    echo "Branch '$BRANCH' not found. Defaulting to '$DEFAULT_BRANCH'."
    log "WARN" "Branch '$BRANCH' not found; defaulting to '$DEFAULT_BRANCH'."
    BRANCH="$DEFAULT_BRANCH"
    # Optional: Check if default branch exists
    default_check=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -H "Authorization: token $GIT_PAT" "https://api.github.com/repos/${REPO_PATH}/branches/$DEFAULT_BRANCH")

  fi
else
  log "WARN" "SSH URL; skipping remote branch check (will verify during clone)."
fi

# 1.4 SSH Username
while true; do
  read -p "Enter remote server SSH username: " SSH_USER
  if [[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    log "INFO" "Validated SSH username: $SSH_USER"
    break
  else
    echo "Invalid username format (lowercase letters, numbers, _, -)."
  fi
done

# 1.5 SSH IP Address
while true; do
  read -p "Enter remote server IP address: " SSH_IP
  if [[ "$SSH_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    if ping -c 1 -W 2 "$SSH_IP" &> /dev/null; then
      echo "IP reachable via ping."
      log "INFO" "Validated and reachable IP: $SSH_IP"
      break
    else
      echo "⚠️ IP not reachable via ping."
      read -p "Proceed anyway? (y/n): " choice
      if [[ "$choice" =~ ^[Yy]$ ]]; then
        log "WARN" "Proceeding with unreachable IP: $SSH_IP"
        break
      fi
    fi
  else
    echo "Invalid IP format (e.g., 192.168.1.100)."
  fi
done

# 1.6 SSH Key Path
while true; do
  read -p "Enter SSH key path (e.g., ~/.ssh/id_rsa): " SSH_KEY
  SSH_KEY="${SSH_KEY/#\~/$HOME}"
  if [ -f "$SSH_KEY" ] && ssh-keygen -l -f "$SSH_KEY" &> /dev/null; then
    echo "Valid SSH key found."
    log "INFO" "Validated SSH key: $SSH_KEY"
    break
  else
    echo "Invalid or missing SSH key file."
  fi
done

# 1.7 Application Port
while true; do
  read -p "Enter application port (1-65535): " APP_PORT
  if [[ "$APP_PORT" =~ ^[0-9]+$ ]] && (( APP_PORT >= 1 && APP_PORT <= 65535 )); then
    log "INFO" "Validated app port: $APP_PORT"
    break
  else
    echo "Invalid port (must be 1-65535)."
  fi
done

# 1.8 Summary and Confirmation
MASKED_PAT=""
if [ "$IS_HTTPS" = true ]; then
  MASKED_PAT="${GIT_PAT:0:4}****************${GIT_PAT: -4}"
fi

echo -e "\n🧾 Parameter Summary:"
echo "-----------------------------------------"
echo "Git URL:       $GIT_URL"
echo "Branch:        $BRANCH"
echo "PAT (masked):  ${MASKED_PAT:-N/A (SSH)}"
echo "SSH User:      $SSH_USER"
echo "SSH IP:        $SSH_IP"
echo "SSH Key:       $SSH_KEY"
echo "App Port:      $APP_PORT"
echo "-----------------------------------------"

log "INFO" "Git URL: $GIT_URL"
log "INFO" "Branch: $BRANCH"
log "INFO" "PAT (masked): ${MASKED_PAT:-N/A}"
log "INFO" "SSH User: $SSH_USER"
log "INFO" "SSH IP: $SSH_IP"
log "INFO" "SSH Key: $SSH_KEY"
log "INFO" "App Port: $APP_PORT"

read -p "Proceed? (y/n): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log "WARN" "Deployment aborted by user."
  echo "🚫 Cancelled."
  exit 0
fi

log "INFO" "Proceeding with deployment."
log "INFO" "---------------------------------------------------------"

# ===============================================================
# Step 2: Clone the Repository
# ===============================================================
log "INFO" "Handling repository..."

REPO_NAME=$(basename "$GIT_URL" .git)

if [ -d "$REPO_NAME" ]; then
  log "INFO" "Repo exists; pulling changes..."
  cd "$REPO_NAME"
  git fetch --all
  if ! git checkout "$BRANCH"; then
    echo "⚠️ Branch '$BRANCH' not found locally. Defaulting to '$DEFAULT_BRANCH'."
    log "WARN" "Local branch '$BRANCH' not found; defaulting to '$DEFAULT_BRANCH'."
    BRANCH="$DEFAULT_BRANCH"
    git checkout "$BRANCH"
  fi
  git pull origin "$BRANCH"
else
  log "INFO" "Cloning repo..."
  if [ "$IS_HTTPS" = true ]; then
    CLONE_URL="https://${GIT_PAT}@${GIT_URL#https://}"
    git clone "$CLONE_URL" "$REPO_NAME"
  else
    git clone "$GIT_URL" "$REPO_NAME"
  fi
  cd "$REPO_NAME"
  if ! git checkout "$BRANCH"; then
    echo "⚠️ Branch '$BRANCH' not found. Defaulting to '$DEFAULT_BRANCH'."
    log "WARN" "Branch '$BRANCH' not found; defaulting to '$DEFAULT_BRANCH'."
    BRANCH="$DEFAULT_BRANCH"
    git checkout "$BRANCH"
  fi
fi

log "INFO" "Repo handled on branch '$BRANCH'."
cd - > /dev/null

log "INFO" "---------------------------------------------------------"

# ===============================================================
# Step 3: Verify Cloned Directory Files
# ===============================================================
log "INFO" "Verifying files..."

cd "$REPO_NAME"
USE_COMPOSE=false
if [ -f "docker-compose.yml" ]; then
  USE_COMPOSE=true
  log "INFO" "Using Docker Compose."
elif [ -f "Dockerfile" ]; then
  log "INFO" "Using single Dockerfile."
else
  log "ERROR" "No Dockerfile or docker-compose.yml."
  exit 5
fi

log "INFO" "Files verified."
cd - > /dev/null
log "INFO" "---------------------------------------------------------"

# ===============================================================
# Step 4: SSH Connectivity
# ===============================================================
log "INFO" "Checking SSH..."

SSH_CMD="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 $SSH_USER@$SSH_IP"
if $SSH_CMD "echo 'SSH OK'" &> /dev/null; then
  log "INFO" "SSH connected."
else
  log "ERROR" "SSH failed."
  exit 6
fi

log "INFO" "---------------------------------------------------------"

# ===============================================================
# Step 5: Prepare Remote Environment
# ===============================================================
log "INFO" "Preparing remote..."

$SSH_CMD << EOF
set -euo pipefail

# Detect distro
. /etc/os-release
DISTRO=\$ID

case \$DISTRO in
  ubuntu|debian)
    PKG_MANAGER="apt install -y"
    sudo apt update -y && sudo apt upgrade -y
    ;;
  fedora)
    PKG_MANAGER="dnf install -y"
    sudo dnf update -y
    ;;
  centos|rhel|rocky|almalinux)
    PKG_MANAGER="yum install -y"
    sudo yum update -y
    ;;
  *)
    echo "Unsupported distro: \$DISTRO"
    exit 1
    ;;
esac

# Install Docker if missing (using convenience script for simplicity)
if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | sudo sh
fi

# Install Compose plugin if missing
if ! docker compose version &> /dev/null; then
  sudo mkdir -p /usr/local/lib/docker/cli-plugins
  sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-\$(uname -m) -o /usr/local/lib/docker/cli-plugins/docker-compose
  sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi

# Install Nginx if missing
if ! command -v nginx &> /dev/null; then
  sudo \$PKG_MANAGER nginx
fi

# Add to docker group
sudo usermod -aG docker \$USER

# Start services
sudo systemctl enable --now docker nginx

# Versions
docker --version
docker compose version
nginx -v
EOF

log "INFO" "Remote prepared."
log "INFO" "---------------------------------------------------------"

# ===============================================================
# Step 6: Deploy Application
# ===============================================================
log "INFO" "Deploying..."

REMOTE_DIR="/home/$SSH_USER/$REPO_NAME"
$SSH_CMD "mkdir -p $REMOTE_DIR"
rsync -avz --delete -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10" ./$REPO_NAME/* "$SSH_USER@$SSH_IP:$REMOTE_DIR"

CONTAINER_NAME="${REPO_NAME}-app"
IMAGE_NAME="${REPO_NAME}-image"

$SSH_CMD << EOF
set -euo pipefail
cd $REMOTE_DIR

if [ "$USE_COMPOSE" = true ]; then
  docker compose down -v --rmi all --remove-orphans || true
  docker compose up -d --build
  docker compose ps
  docker compose logs -t --tail=50
else
  docker stop $CONTAINER_NAME || true
  docker rm $CONTAINER_NAME || true
  docker build -t $IMAGE_NAME .
  docker run -d --name $CONTAINER_NAME -p $APP_PORT:$APP_PORT $IMAGE_NAME
  docker ps | grep $CONTAINER_NAME
  docker logs $CONTAINER_NAME
fi

# Health check
for i in {1..6}; do
  if curl -f --max-time 5 http://localhost:$APP_PORT; then
    echo "Healthy"
    break
  fi
  sleep 5
done || echo "Timeout - check logs"
EOF

log "INFO" "Deployed."
log "INFO" "---------------------------------------------------------"

# ===============================================================
# Step 7: Configure Nginx
# ===============================================================
log "INFO" "Configuring Nginx..."

NGINX_CONF="
server {
    listen 80;
    server_name $SSH_IP;

    location / {
        proxy_pass http://localhost:$APP_PORT/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

# For SSL: sudo apt/dnf/yum install certbot python3-certbot-nginx; sudo certbot --nginx
"

$SSH_CMD "echo '$NGINX_CONF' | sudo tee /etc/nginx/sites-available/default > /dev/null"
$SSH_CMD "sudo nginx -t && sudo systemctl reload nginx"

log "INFO" "Nginx configured."
log "INFO" "---------------------------------------------------------"

# ===============================================================
# Step 8: Validate Deployment
# ===============================================================
log "INFO" "Validating..."

$SSH_CMD "systemctl status docker | grep Active"
if [ "$USE_COMPOSE" = true ]; then
  $SSH_CMD "cd $REMOTE_DIR && docker compose ps | grep Up"
else
  $SSH_CMD "docker ps | grep $CONTAINER_NAME"
fi

$SSH_CMD "curl -f --max-time 5 http://localhost" || log "WARN" "Remote local curl failed."
curl -f --max-time 10 "http://$SSH_IP" || log "WARN" "External curl failed (firewall?)."

log "INFO" "Validated."
log "INFO" "---------------------------------------------------------"

# ===============================================================
# Step 10: Cleanup (if flagged)
# ===============================================================
if [ "${1:-}" = "--cleanup" ]; then
  log "INFO" "Cleanup mode..."
  $SSH_CMD << EOF || true
  cd $REMOTE_DIR || true
  if [ -f "docker-compose.yml" ]; then
    docker compose down -v --rmi all --remove-orphans || true
  else
    docker stop $CONTAINER_NAME || true
    docker rm $CONTAINER_NAME || true
    docker rmi $IMAGE_NAME || true
  fi
  rm -rf $REMOTE_DIR
  sudo systemctl reload nginx || true
EOF
  log "INFO" "Cleanup done."
fi

log "INFO" "Process completed."
echo "Finished. Log: $LOG_FILE"
