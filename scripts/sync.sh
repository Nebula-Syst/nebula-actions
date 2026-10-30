#!/usr/bin/env bash
# Sincroniza las plantillas de nebula-actions en los repos de la org que tienen
# el topic `nebula-deps`, abriendo (o actualizando) un PR en cada uno.
#
#   scripts/sync.sh --dry-run            enseña qué cambiaría, sin tocar nada
#   scripts/sync.sh                      abre o actualiza un PR en cada repo
#   scripts/sync.sh orbity-auth ...      solo esos repos
#
# Cada repo recibe dos archivos: .github/workflows/ci.yml (igual en todos) y
# .github/dependabot.yml (con los ecosistemas que usa: npm, composer, docker).
# Solo sobrescribe archivos que lleven la marca "# nebula-actions: managed" en
# la primera línea o que no existan; un dependabot.yml o un workflow de tests
# propio (p. ej. Forvia) se respeta.
#
# Requisitos: gh autenticado (gh auth login) con permiso de escritura en los
# repos, y git.
set -euo pipefail

ORG="${ORG:-Nebula-Syst}"
TOPIC="${TOPIC:-nebula-deps}"
BRANCH="nebula-actions/sync"
MARKER="# nebula-actions: managed"
TPL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/templates"
# Restos de versiones anteriores de la automatización.
OBSOLETE=(
  .github/dependabot-node.yml
  .github/dependabot_composer-node.yml
  .github/workflows/dependabot-automation.yml
  .github/workflows/dependabot-automation_test.yml
  .github/workflows/dependabot-automerge.yml
)

# ¿Lo gestiona nebula-actions? La marca, o la plantilla antigua de
# Nebula_Utils (anterior a nebula-actions), que se adopta en la primera sync.
is_managed() {
  head -n1 "$1" | grep -qF "$MARKER" && return 0
  grep -qE 'dependabot-automation|Todas las vulnerabilidades de seguridad' "$1"
}

# Escribe $2 en $1 si el archivo no existe o lo gestiona nebula-actions.
put() {
  local dest=$1 content=$2
  if [ -f "$dest" ] && ! is_managed "$dest"; then
    echo "  ! $dest es propio (sin la marca): no se toca"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' "$content" > "$dest"
}

# Genera los archivos en el repo del directorio actual. $1 = versión (vX.Y.Z).
generate() {
  local version=$1 f

  # ── Stack (solo para dependabot.yml: los tests los detecta tests.yml) ────
  local pm="" laravel=false docker=false own_tests=""
  [ -f composer.json ] && laravel=true
  if [ -f pnpm-lock.yaml ]; then pm=pnpm; elif [ -f package-lock.json ]; then pm=npm; fi
  [ -d docker ] && docker=true
  # Un workflow de tests propio (como el test.yml de Forvia) se usa en lugar
  # del de nebula-actions.
  for f in .github/workflows/tests.yml .github/workflows/test.yml; do
    if [ -f "$f" ] && ! is_managed "$f"; then own_tests=$f; break; fi
  done
  local desc="${pm:-sin node}"
  if $laravel; then desc+=" + laravel"; fi
  if $docker; then desc+=" + docker"; fi
  echo "  stack: $desc${own_tests:+ · tests propios: $own_tests}"

  # ── .github/dependabot.yml ───────────────────────────────────────────────
  local dep
  dep=$(cat "$TPL/dependabot/_header.yml")
  if [ -n "$pm" ]; then dep+=$'\n'$(cat "$TPL/dependabot/npm.yml")$'\n'; fi
  if $laravel; then dep+=$'\n'$(cat "$TPL/dependabot/composer.yml")$'\n'; fi
  if $docker; then
    dep+=$'\n'$(cat "$TPL/dependabot/docker.yml")$'\n'
    dep+=$'\n'$(cat "$TPL/dependabot/docker-compose.yml")$'\n'
  fi
  dep+=$'\n'$(cat "$TPL/dependabot/github-actions.yml")
  put .github/dependabot.yml "$dep"

  # ── .github/workflows/ci.yml ─────────────────────────────────────────────
  # Un workflow de tests propio que no se puede llamar rompería ci.yml:
  # mejor no tocar la automatización existente hasta adaptarlo.
  if [ -n "$own_tests" ] && ! grep -q 'workflow_call' "$own_tests"; then
    echo "  ! $own_tests no tiene 'workflow_call': añádelo (ver README) y vuelve a sincronizar."
    echo "    Mientras, no se toca la automatización de Dependabot de este repo."
    return 0
  fi
  local ci
  ci=$(sed -E "s#(Nebula-Syst/nebula-actions/\.github/workflows/[a-z]+\.yml)@v[0-9.]+#\1@$version#" "$TPL/workflows/ci.yml")
  if [ -n "$own_tests" ]; then
    ci=$(sed -E "s#uses: Nebula-Syst/nebula-actions/\.github/workflows/tests\.yml@.*#uses: ./$own_tests#" <<< "$ci")
  fi
  put .github/workflows/ci.yml "$ci"

  # ── Limpieza ─────────────────────────────────────────────────────────────
  # ci.yml sustituye al tests.yml y al dependabot.yml de las plantillas
  # anteriores; solo se borran si eran plantilla (nunca uno propio).
  for f in .github/workflows/tests.yml .github/workflows/dependabot.yml; do
    if [ -f "$f" ] && is_managed "$f"; then rm "$f"; echo "  - $f (sustituido por ci.yml)"; fi
  done
  for f in "${OBSOLETE[@]}"; do
    if [ -f "$f" ]; then rm "$f"; echo "  - $f (obsoleto)"; fi
  done
}

sync_repo() {
  local repo=$1 version=$2 dry=$3 dir="$work/$1"
  gh repo clone "$ORG/$repo" "$dir" -- --depth 1 --quiet
  cd "$dir"
  local base
  base=$(git rev-parse --abbrev-ref HEAD)

  generate "$version"

  git add -A .github
  if git diff --cached --quiet; then
    echo "  = al día"
    return 0
  fi
  git diff --cached --stat | sed 's/^/  /'
  if $dry; then
    echo "  (dry-run: no se sube nada)"
    return 0
  fi
  git checkout -q -B "$BRANCH"
  git commit -q -m "chore(ci): sincronizar automatización de dependencias (nebula-actions $version)"
  git push -q -f origin "$BRANCH"
  if gh pr view "$BRANCH" --repo "$ORG/$repo" >/dev/null 2>&1; then
    echo "  ↻ PR actualizado: $(gh pr view "$BRANCH" --repo "$ORG/$repo" --json url -q .url)"
  else
    gh pr create --repo "$ORG/$repo" --base "$base" --head "$BRANCH" \
      --title "chore(ci): automatización de dependencias (nebula-actions $version)" \
      --body "Generado por \`scripts/sync.sh\` de [nebula-actions](https://github.com/$ORG/nebula-actions). Los archivos con la marca \`$MARKER\` se regeneran en cada sincronización." \
      | sed 's/^/  + PR: /'
  fi
}

main() {
  local dry=false repos=() arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry=true ;;
      -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
      *) repos+=("$arg") ;;
    esac
  done

  # Las llamadas apuntan a la última versión publicada de nebula-actions.
  local version
  version=$(gh api "repos/$ORG/nebula-actions/tags" --paginate -q '.[].name' \
    | { grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true; } | sort -V | tail -n1)
  [ -n "$version" ] || { echo "nebula-actions no tiene ningún tag vX.Y.Z: publica uno antes." >&2; exit 1; }

  if [ ${#repos[@]} -eq 0 ]; then
    mapfile -t repos < <(gh repo list "$ORG" --topic "$TOPIC" --no-archived --source --limit 200 --json name -q '.[].name' | sort)
  fi
  [ ${#repos[@]} -gt 0 ] || { echo "Ningún repo con el topic '$TOPIC' en $ORG."; exit 0; }

  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT

  echo "nebula-actions $version → ${#repos[@]} repos$($dry && echo ' (dry-run)' || true)"
  local failed=() repo
  for repo in "${repos[@]}"; do
    echo "▸ $repo"
    ( sync_repo "$repo" "$version" "$dry" ) || { echo "  ✗ falló"; failed+=("$repo"); }
  done
  [ ${#failed[@]} -eq 0 ] || { echo "Fallaron: ${failed[*]}"; exit 1; }
}

# Ejecutable directamente; también se puede `source` para probar generate().
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
