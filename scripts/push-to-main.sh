#!/bin/bash
# Push lokale Änderungen nach main

set -e

echo "🔄 Pushing local changes to main..."

# Sicherstellen dass wir auf main sind
git checkout main

# Lokale Änderungen committen falls vorhanden
if [[ -n $(git status --porcelain) ]]; then
    echo "📝 Staging all changes..."
    git add -A

    read -p "Commit message: " commit_msg
    if [[ -z "$commit_msg" ]]; then
        commit_msg="Update from local"
    fi

    git commit -m "$commit_msg"
fi

# Erst pullen um Konflikte zu vermeiden
echo "⬇️  Pulling latest from main..."
git pull origin main --rebase

# Dann pushen
echo "⬆️  Pushing to main..."
git push origin main

echo "✅ Done! Local changes pushed to main."
