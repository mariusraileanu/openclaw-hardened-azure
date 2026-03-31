#!/usr/bin/env bash
set -euo pipefail

if ! command -v git >/dev/null 2>&1; then
  echo "ERROR: git is required" >&2
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: must run inside a git repository" >&2
  exit 1
fi

violations=()

is_violation() {
  local path="$1"

  case "$path" in
    # Terraform local state and caches
    .terraform/*|*/.terraform/*|*.tfstate|*.tfstate.*|*.tfplan|*.tfvars)
      return 0
      ;;

    # Dependency trees
    node_modules/*|*/node_modules/*)
      return 0
      ;;

    # Root env files and secrets (deprecated; do not track)
    .env|.env.*)
      return 0
      ;;

    # Sensitive key material
    *.pem|*.key)
      return 0
      ;;

    # Build outputs that must remain generated-only
    teams-app/dist/*|teams-relay/dist/*)
      return 0
      ;;
  esac

  return 1
}

while IFS= read -r -d '' file; do
  if is_violation "$file"; then
    violations+=("$file")
  fi
done < <(git ls-files -z)

if [ "${#violations[@]}" -eq 0 ]; then
  echo "Hygiene check passed: no forbidden tracked files found."
  exit 0
fi

echo "Hygiene check failed: forbidden tracked files found:" >&2
for path in "${violations[@]}"; do
  echo "  - $path" >&2
done

echo >&2
echo "Fix guidance:" >&2
echo "  1) Remove from index: git rm --cached -r <path>" >&2
echo "  2) Keep local copy if needed (already ignored by .gitignore)" >&2
echo "  3) Re-run: make hygiene-check" >&2

exit 1
