#!/bin/bash
# ============================================================
# Creates the logicmonitor_eda GitHub repo and pushes files
# Run this from your Mac terminal:
#   chmod +x setup_github_repo.sh && ./setup_github_repo.sh
# ============================================================

TOKEN="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"
GITHUB_USER="mlowcher61"
REPO_NAME="logicmonitor_eda"
SOURCE_DIR="/Users/mlowcher/Documents/claude-repos/logicmonitor-eda-aap"

echo "==> Creating GitHub repository: ${GITHUB_USER}/${REPO_NAME}"
RESPONSE=$(curl -s -X POST \
  -H "Authorization: token ${TOKEN}" \
  -H "Accept: application/vnd.github.v3+json" \
  https://api.github.com/user/repos \
  -d "{\"name\":\"${REPO_NAME}\",\"description\":\"LogicMonitor EDA Ansible Automation Platform playbooks and rulebooks\",\"private\":false,\"auto_init\":false}")

echo "$RESPONSE" | grep -q '"full_name"' && echo "  Repo created successfully!" || echo "  Note: $RESPONSE"

echo "==> Initializing git in ${SOURCE_DIR}"
cd "${SOURCE_DIR}" || { echo "ERROR: Directory not found: ${SOURCE_DIR}"; exit 1; }

git init
git checkout -b main 2>/dev/null || git checkout -b main

echo "==> Staging all files"
git add .

echo "==> Committing files"
git commit -m "Initial commit: LogicMonitor EDA AAP playbooks, rulebooks, and collections"

echo "==> Setting remote origin"
git remote remove origin 2>/dev/null
git remote add origin "https://${GITHUB_USER}:${TOKEN}@github.com/${GITHUB_USER}/${REPO_NAME}.git"

echo "==> Pushing to GitHub"
git push -u origin main

echo ""
echo "==> Done! View your repo at: https://github.com/${GITHUB_USER}/${REPO_NAME}"

# Clean up token from remote URL for security
git remote set-url origin "https://github.com/${GITHUB_USER}/${REPO_NAME}.git"
echo "==> Remote URL cleaned up (token removed)"
