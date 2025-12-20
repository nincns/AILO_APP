#!/bin/bash
# Merge eines Branches nach main

set -e

# Branch als Parameter oder interaktiv abfragen
BRANCH=${1:-""}

if [[ -z "$BRANCH" ]]; then
    echo "Verfügbare Branches:"
    git branch -a | grep -v HEAD
    echo ""
    read -p "Branch name to merge (z.B. claude/analyze-project-owHwR): " BRANCH
fi

if [[ -z "$BRANCH" ]]; then
    echo "❌ Kein Branch angegeben. Abbruch."
    exit 1
fi

echo "🔄 Merging '$BRANCH' into main..."

# Aktuelle Änderungen stashen falls vorhanden
STASHED=false
if [[ -n $(git status --porcelain) ]]; then
    echo "📦 Stashing local changes..."
    git stash
    STASHED=true
fi

# Fetch latest
echo "⬇️  Fetching latest..."
git fetch origin

# Zu main wechseln
echo "🔀 Switching to main..."
git checkout main

# Pull mit merge-Strategie (nicht rebase) um divergierende Branches zu handhaben
echo "⬇️  Pulling latest main..."
git pull origin main --no-rebase || {
    echo "⚠️  Pull failed, trying reset to origin/main..."
    git reset --hard origin/main
}

# Branch mergen
echo "🔀 Merging $BRANCH..."
if [[ "$BRANCH" == origin/* ]]; then
    git merge "$BRANCH" --no-edit
else
    git merge "origin/$BRANCH" --no-edit 2>/dev/null || git merge "$BRANCH" --no-edit
fi

# Push to main
echo "⬆️  Pushing to main..."
git push origin main

# Optional: Branch löschen
read -p "Branch '$BRANCH' löschen? (y/N): " DELETE_BRANCH
if [[ "$DELETE_BRANCH" == "y" || "$DELETE_BRANCH" == "Y" ]]; then
    echo "🗑️  Deleting branch..."
    git branch -d "${BRANCH#origin/}" 2>/dev/null || true
    git push origin --delete "${BRANCH#origin/}" 2>/dev/null || true
    echo "✅ Branch deleted."
fi

# Stash wiederherstellen
if [[ "$STASHED" == true ]]; then
    echo "📦 Restoring stashed changes..."
    git stash pop
fi

echo "✅ Done! '$BRANCH' merged into main."
