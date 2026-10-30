#!/usr/bin/env bash
# Guarda los secretos de la GitHub App (DEPS_APP_ID y DEPS_APP_PRIVATE_KEY) en
# los repos con el topic `nebula-deps`, dos veces en cada uno:
#   · como secretos de Dependabot: los workflows que lanza Dependabot solo ven esos
#   · como secretos de Actions: para los merges manuales y el evento de release
# En GitHub Free los secretos de organización no llegan a los repos privados,
# por eso van repo a repo. Vuelve a ejecutarlo si rotas la clave.
#
#   scripts/set-secrets.sh <app-id> <clave-privada.pem>              todos los repos con el topic
#   scripts/set-secrets.sh <app-id> <clave-privada.pem> orbity-auth  solo esos repos
#
# Requisitos: gh autenticado con permiso de administración en los repos.
set -euo pipefail

ORG="${ORG:-Nebula-Syst}"
TOPIC="${TOPIC:-nebula-deps}"

if [ $# -lt 2 ]; then
  sed -n '2,13p' "$0"
  exit 1
fi
app_id=$1
key=$2
shift 2
[[ "$app_id" =~ ^[0-9]+$ ]] || { echo "El app-id debe ser numérico." >&2; exit 1; }
grep -q 'PRIVATE KEY' "$key" 2>/dev/null || { echo "$key no parece una clave privada .pem." >&2; exit 1; }

repos=("$@")
if [ ${#repos[@]} -eq 0 ]; then
  mapfile -t repos < <(gh repo list "$ORG" --topic "$TOPIC" --no-archived --source --limit 200 --json name -q '.[].name' | sort)
fi
[ ${#repos[@]} -gt 0 ] || { echo "Ningún repo con el topic '$TOPIC' en $ORG."; exit 0; }

failed=()
for repo in "${repos[@]}"; do
  echo "▸ $repo"
  ok=true
  for app in actions dependabot; do
    gh secret set DEPS_APP_ID --app "$app" --repo "$ORG/$repo" --body "$app_id" || ok=false
    gh secret set DEPS_APP_PRIVATE_KEY --app "$app" --repo "$ORG/$repo" < "$key" || ok=false
  done
  $ok || failed+=("$repo")
done

echo
[ ${#failed[@]} -eq 0 ] && echo "Listo: ${#repos[@]} repos." || { echo "Fallaron: ${failed[*]}"; exit 1; }
echo "Guarda la .pem en un sitio seguro (gestor de contraseñas) y bórrala de la carpeta de descargas."
