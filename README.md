# nebula-actions

CI y mantenimiento automático de dependencias para todos los repos de Nebula-Syst. **Toda la lógica vive aquí**; cada repo solo tiene dos archivos:

| Archivo en el repo | Qué es | ¿Igual en todos? |
| --- | --- | --- |
| `.github/workflows/ci.yml` | Llama a los workflows de aquí | **Sí, idéntico** |
| `.github/dependabot.yml` | Qué vigila Dependabot (lo exige GitHub en cada repo) | Según use npm, Composer o Docker |

Es público a propósito: así lo pueden llamar todos los repos de la org, públicos y privados. Solo contiene lógica genérica: los secretos viven en cada repo y no hay ninguna lista de repos.

> 📖 ¿Primera vez? Empieza por **[la guía](docs/GUIA.md)**: qué es cada pieza, qué pasa con cada PR, cómo se implementa y qué hacer cuando algo falla. Este README es la referencia rápida.

## Cómo funciona

```
push a main o PR en un repo
  └─ ci.yml del repo
       ├─ tests       → nebula-actions/tests.yml
       │                 detecta la tecnología y pasa los tests
       └─ dependabot  → nebula-actions/dependabot.yml   (solo PRs de Dependabot)
                         con el resultado: etiqueta, mergea o lo deja para ti, y crea la release
```

### `tests.yml`: tests de cualquier repo

| Detecta | Ejecuta |
| --- | --- |
| `composer.json` + `artisan` | PHP (de `config.platform.php` en composer.json) + MySQL 8 + `php artisan test` |
| `pnpm-lock.yaml` | Node (de `.nvmrc` / `.node-version`, o 24) + `pnpm install --frozen-lockfile` + `pnpm test` |
| `package-lock.json` | Node + `npm ci` + `npm test` |
| Sin tests (sin script `test`, o sin `tests/*Test.php`) | Nada: no falla, avisa en el resumen |

Si package.json tiene `"packageManager": "pnpm@x"`, usa esa versión de pnpm.

### `dependabot.yml`: decide qué hacer con cada PR de Dependabot

| PR | Comprobación | Resultado |
| --- | --- | --- |
| Patch o minor (incluidas vulnerabilidades) | Tests | Auto-merge si pasan |
| Major | Tests | Revisión manual (con aviso si es de seguridad) |
| Docker / docker-compose | `docker build` de todos los Dockerfile + `docker pull` del compose + `docker/smoke.sh` si existe | Siempre revisión manual |
| Repo sin tests | Ninguna | Solo se auto-mergean vulnerabilidades patch o minor |

- **Etiquetas** `patch` / `minor` / `major`, `security` y el ecosistema. Si no existen, se crean.
- **Release**: tras cada merge de Dependabot, automático o manual, sube el patch del último tag `vX.Y.Z` (o empieza en `v0.0.1`) y crea una GitHub Release.
- **Seguridad**: solo actúa si el autor del PR y quien hizo el último cambio son Dependabot, y solo mergea el commit exacto que pasó los tests. Ante cualquier duda, revisión manual.
- **Resumen**: cada ejecución explica en la pestaña *Summary* por qué mergeó o no.

## Puesta en marcha

### 1. Crear la GitHub App (una vez)

Sin ella todo funciona, pero lo que mergea el `GITHUB_TOKEN` no dispara otros workflows (deploy, `on: release`) ni puede mergear PRs que tocan `.github/workflows`. Las versiones nuevas de este repo llegan igual gracias al tag `@v1`; solo el salto a una versión mayor (`@v2`) habría que mergearlo a mano.

1. En la org, ve a **Settings → Developer settings → GitHub Apps → New GitHub App**.
2. En **Name** pon `Nebula Deps`. En **Homepage URL** vale `https://github.com/Nebula-Syst`.
3. En **Webhook**, desmarca *Active*.
4. En **Repository permissions** marca *Contents*, *Pull requests*, *Issues* y *Workflows* como **Read and write**.
5. Elige *Only on this account* y pulsa **Create GitHub App**.
6. Apunta el **App ID** y pulsa **Generate a private key**. Se descarga un `.pem`.
7. Pulsa **Install App** y selecciona los repos, o *All repositories*.

### 2. Añadir un repo

```bash
gh repo edit Nebula-Syst/<repo> --add-topic nebula-deps        # marcarlo
bash scripts/set-secrets.sh <app-id> ruta/a/la-clave.pem <repo>  # secretos de la App
bash scripts/sync.sh --dry-run <repo>                             # ver qué haría
bash scripts/sync.sh <repo>                                       # abre el PR
```

Sin argumentos de repo, los scripts actúan sobre todos los que tienen el topic. Después, en el repo: **Settings → Code security → Dependabot security updates**, activado.

### Qué hace `sync.sh`

- Escribe `ci.yml`, apuntando a la última versión publicada de este repo.
- Escribe `dependabot.yml` con los ecosistemas que encuentra (npm/pnpm, Composer, Docker, y siempre GitHub Actions).
- Borra lo que sustituye: `tests.yml` y llamadas de plantillas anteriores, `dependabot-automation*.yml`, `dependabot-automerge.yml`, `.github/dependabot-node.yml`…
- **Nunca toca un archivo propio**: solo los que llevan la marca `# nebula-actions: managed` en la primera línea o la plantilla antigua de Nebula_Utils.
- Volver a ejecutarlo es seguro: si el repo está al día, no hace nada, y si ya hay PR, lo actualiza.

### Repos con tests especiales (p. ej. Forvia)

Si el repo tiene su propio `tests.yml` o `test.yml` (sin la marca), `ci.yml` lo usa en lugar del de aquí. Necesita poder llamarse, así que hay que añadirle:

```yaml
on:
  # …lo que ya tenga…
  workflow_call:
```

Sin eso, `sync.sh` no toca la automatización de ese repo y avisa.

### Opciones de `tests.yml`

Para casos raros, en `ci.yml`, debajo de `uses: …/tests.yml@…`:

```yaml
    with:
      node-version: "22"            # si no hay .nvmrc
      php-version: "8.4"            # si composer.json no tiene config.platform.php
      test-command: pnpm test:ci    # otro comando de tests
      stack: npm                    # forzar la tecnología
```

### Smoke test de Docker (opcional)

Copia `templates/docker/smoke.sh` a `docker/smoke.sh` del repo y ajusta `DOCKERFILE`, `PORT` y las variables mínimas. En los PRs de Docker construye la imagen de producción, la arranca y espera a que esté `healthy` o responda HTTP.

## Publicar una versión

Los repos llaman a `nebula-actions` con **`@v1`**, un tag móvil que siempre apunta a la última `v1.x.y`. Al publicar una versión, `major-tag.yml` lo mueve solo, así que **todos los repos usan la versión nueva en su siguiente ejecución, sin PRs**.

1. Cambia lo que haga falta y haz push. `lint.yml` (actionlint + shellcheck) tiene que salir en verde.
2. Publica el tag siguiendo semver: `git tag v1.2.0 && git push origin v1.2.0`, o crea una Release desde GitHub.
   - **patch o minor** (`v1.2.0`): compatible, llega a todos al momento.
   - **major** (`v2.0.0`): cambio incompatible, como una entrada nueva obligatoria. `v1` no se mueve, y Dependabot abre un PR en cada repo para pasar a `@v2`, que revisas tú.
3. Si cambian las plantillas (`templates/`), ejecuta `bash scripts/sync.sh`: abre un PR en cada repo.

> ⚠️ Como una versión nueva llega a todos a la vez, prueba antes los cambios grandes en un repo apuntándolo a la rama (`@mi-rama`) en un PR.

## Contenido

```
.github/workflows/tests.yml        tests reutilizables (pnpm / npm / Laravel)
.github/workflows/dependabot.yml   gestión de PRs de Dependabot reutilizable
.github/workflows/lint.yml         valida este repo en cada push
.github/workflows/major-tag.yml    mueve el tag v1 a cada versión nueva
templates/workflows/ci.yml         el archivo que va en cada repo
templates/dependabot/              trozos de dependabot.yml por ecosistema
templates/docker/smoke.sh          smoke test opcional para PRs de Docker
scripts/sync.sh                    instala/actualiza los archivos en los repos (un PR por repo)
scripts/set-secrets.sh             guarda los secretos de la App en los repos
```
