#!/usr/bin/env bash
#
# bootstrap.sh — deja una Mac nueva lista para trabajar en la flota Skylabs.
#
#   curl -fsSL https://raw.githubusercontent.com/skylabs-digital/.github/main/bootstrap.sh | bash
#
# Se corre UNA VEZ POR MÁQUINA. Después, cada repo se alista con un comando:
#
#   git clone <repo> && cd <repo> && sl setup
#
# ─────────────────────────────────────────────────────────────────────────────
# QUÉ HACE, en orden. Cada paso es idempotente: volver a correrlo no reinstala
# nada ni pisa nada.
#
#   1. Verifica que estén `brew`, `node` (>= 24), `gh`, `sops` y `age`.
#      Lo que falte, te lo dice y te PREGUNTA antes de instalarlo con brew.
#   2. `corepack enable` — es lo que da `yarn`; los repos lo declaran en
#      `packageManager` y no traen yarn adentro.
#   3. `gh auth status`. Si no hay sesión, `gh auth login`. Si la hay pero al
#      token le falta el scope `read:packages`, `gh auth refresh -s read:packages`.
#      Ese scope es el paso que hoy nadie sabe que existe: sin él, instalar
#      desde GitHub Packages devuelve 403.
#   4. Instala el CLI de la flota, PINEADO a la versión de abajo (nunca `latest`),
#      con el token que `gh auth token` resuelve en tu máquina, en el momento.
#   5. Llama a `sl auth init`, que genera tus identidades (age + SSH), abre el PR
#      de alta y espera el merge avisándote cuando ya podés descifrar.
#
# QUÉ INSTALA: sólo lo de arriba, y sólo lo que falte. Todo con `brew`, salvo el
# CLI, que va con `npm install -g`. Nada con `sudo`.
#
# QUÉ NO HACE — y son garantías, no omisiones:
#
#   · NO escribe ningún secreto. El token sale de `gh auth token` en el momento,
#     vive en el entorno del `npm` que este script lanza, y no se guarda en
#     ningún archivo ni se imprime nunca.
#   · NO toca `~/.zshrc`, `~/.bash_profile` ni ningún otro profile. No hay
#     ninguna variable que tengas que exportar para que la flota ande: `sl` le
#     inyecta las credenciales a los procesos que lanza.
#   · NO instala "lo último". El CLI va pineado acá abajo, a la vista. Un
#     `curl | bash` que instala latest es un canal de despliegue automático
#     hacia las laptops del equipo.
#   · NO instala Homebrew por vos. Su instalador te pide que agregues una línea
#     a tu profile, y este script no toca profiles: si falta brew, te da el
#     comando y salís a correrlo vos.
#   · NO clona ningún repo ni corre nada con `sudo`.
#
# Sólo macOS: Linux y CI quedan fuera de alcance a propósito (CI ya resuelve lo
# suyo con el `NODE_AUTH_TOKEN` de Actions).
#
# Fuente: https://github.com/skylabs-digital/.github/blob/main/bootstrap.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# La versión del CLI está pineada A PROPÓSITO. Para subirla hace falta un PR a
# este repo, que es lo que vuelve auditable lo que corre en las máquinas del
# equipo. `sl` avisa solo cuando se quedó viejo contra un descriptor nuevo.
CLI_PAQUETE="@skylabs-digital/cli"
CLI_VERSION="1.11.0"
CLI_REGISTRY="https://npm.pkg.github.com"
NODE_MAYOR_MINIMO=24

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/skylabs"

# ── salida ───────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_AVISO=$'\033[33m'; C_ERR=$'\033[31m'; C_TIT=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_AVISO=""; C_ERR=""; C_TIT=""; C_OFF=""
fi

titulo()  { printf '\n%s%s%s\n' "$C_TIT" "$*" "$C_OFF"; }
info()    { printf '  %s\n' "$*"; }
ok()      { printf '  %s✓%s %s\n' "$C_OK" "$C_OFF" "$*"; }
aviso()   { printf '  %s!%s %s\n' "$C_AVISO" "$C_OFF" "$*"; }
morir()   { printf '\n%s✗ %s%s\n\n' "$C_ERR" "$*" "$C_OFF" >&2; exit 1; }

# ── entrada ──────────────────────────────────────────────────────────────────
#
# Corriendo como `curl … | bash`, el script ES el stdin del shell: no se puede
# preguntar nada por ahí. Se abre `/dev/tty`, que es la terminal de verdad.
# Si no hay ninguna (un CI, un cron), no se pregunta ni se instala nada: el
# script dice qué falta y corta.

# Ojo: que `/dev/tty` exista no quiere decir que se pueda abrir — un proceso sin
# terminal de control la ve ahí y falla con "Device not configured". Por eso se
# prueba a abrirla de verdad, en un subshell para que el error no se propague.
TTY_IN=""
if [[ -t 0 ]]; then
  TTY_IN="/dev/stdin"
elif ( : </dev/tty ) 2>/dev/null; then
  TTY_IN="/dev/tty"
fi

hay_terminal() { [[ -n "$TTY_IN" ]]; }

# Pregunta por sí o por no. Default NO: nada se instala por inercia.
confirmar() {
  local pregunta="$1" respuesta=""
  hay_terminal || return 1
  printf '  %s [s/N] ' "$pregunta"
  IFS= read -r respuesta <"$TTY_IN" || respuesta=""
  [[ "$respuesta" == [sSyY]* ]]
}

# ── 0. dónde estamos ─────────────────────────────────────────────────────────

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  sed -n '2,50p' "$0" 2>/dev/null || true
  exit 0
fi

[[ "$(uname -s)" == "Darwin" ]] ||
  morir "Este bootstrap es sólo para macOS. En Linux, instalá gh/sops/age/node a mano e instalá el CLI con: npm install -g ${CLI_PAQUETE}@${CLI_VERSION}"

[[ "${EUID:-$(id -u)}" -ne 0 ]] ||
  morir "No corras esto con sudo: instala en tu usuario, y con root te dejaría archivos que después no podés escribir."

titulo "Bootstrap de la flota Skylabs — CLI pineado a ${CLI_PAQUETE}@${CLI_VERSION}"
hay_terminal || aviso "Sin terminal interactiva: voy a verificar todo, pero no instalo nada sin poder preguntarte."

# ── 1. herramientas ──────────────────────────────────────────────────────────

titulo "1/5 · Herramientas"

# shellcheck disable=SC2016  # el $(curl …) es literal: es el comando que tiene
# que correr la persona, no algo que expandamos nosotros.
command -v brew >/dev/null 2>&1 || morir "$(
  printf 'Falta Homebrew, y es de donde sale todo lo demás.\n'
  printf '  Instalalo con el comando oficial y volvé a correr este script:\n\n'
  printf '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"\n\n'
  printf '  (Su instalador te va a pedir que agregues una línea a tu profile:\n'
  printf '   hacelo vos. Este script no toca profiles.)'
)"
ok "brew — $(brew --version 2>/dev/null | head -1)"

FALTAN=()          # fórmulas de brew a instalar
ACTUALIZAR=()      # fórmulas de brew a actualizar

for cmd in gh sops age; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd — $(command -v "$cmd")"
  else
    aviso "$cmd — no está"
    FALTAN+=("$cmd")
  fi
done

# node necesita, además de existir, ser >= 24. Y si no salió de brew (nvm, fnm,
# volta, asdf), no es este script el que lo tiene que tocar.
if command -v node >/dev/null 2>&1; then
  node_v="$(node -v 2>/dev/null | tr -d 'v')"
  node_mayor="${node_v%%.*}"
  if [[ "${node_mayor:-0}" -ge "$NODE_MAYOR_MINIMO" ]]; then
    ok "node — v${node_v}"
  elif [[ "$(command -v node)" == "$(brew --prefix)"/* ]]; then
    aviso "node — v${node_v}, y hace falta >= ${NODE_MAYOR_MINIMO}"
    ACTUALIZAR+=("node")
  else
    morir "node v${node_v} es menor que ${NODE_MAYOR_MINIMO}, y no salió de brew ($(command -v node)). Actualizalo con el manejador que lo instaló (nvm/fnm/volta/asdf) y volvé a correr este script."
  fi
else
  aviso "node — no está"
  FALTAN+=("node")
fi

if [[ ${#FALTAN[@]} -gt 0 || ${#ACTUALIZAR[@]} -gt 0 ]]; then
  info ""
  [[ ${#FALTAN[@]} -eq 0 ]]     || info "Voy a correr:  brew install ${FALTAN[*]}"
  [[ ${#ACTUALIZAR[@]} -eq 0 ]] || info "Voy a correr:  brew upgrade ${ACTUALIZAR[*]}"
  if confirmar "¿Lo hago?"; then
    [[ ${#FALTAN[@]} -eq 0 ]]     || brew install "${FALTAN[@]}"
    [[ ${#ACTUALIZAR[@]} -eq 0 ]] || brew upgrade "${ACTUALIZAR[@]}"
  else
    morir "$(
      printf 'Sin esas herramientas no sigo. Cuando las tengas, volvé a correr este script:\n\n'
      [[ ${#FALTAN[@]} -eq 0 ]]     || printf '    brew install %s\n' "${FALTAN[*]}"
      [[ ${#ACTUALIZAR[@]} -eq 0 ]] || printf '    brew upgrade %s\n' "${ACTUALIZAR[*]}"
    )"
  fi
else
  ok "Nada para instalar."
fi

# ── 2. corepack ──────────────────────────────────────────────────────────────

titulo "2/5 · corepack (es lo que da yarn)"

if command -v corepack >/dev/null 2>&1; then
  if corepack enable >/dev/null 2>&1; then
    ok "corepack enable — listo"
    if command -v yarn >/dev/null 2>&1; then
      ok "yarn — $(command -v yarn)"
    fi
  else
    aviso "corepack enable falló. Probá a mano: corepack enable"
    aviso "Sin yarn, 'sl setup' no va a poder instalar dependencias."
  fi
else
  aviso "No encontré corepack, que viene con node. Revisá tu instalación de node."
fi

# ── 3. sesión de gh y el scope read:packages ─────────────────────────────────

titulo "3/5 · Sesión de GitHub"

scopes_de_gh() { gh auth status 2>&1 | sed -n "s/.*Token scopes: *//p" | tr -d "'"; }
tiene_read_packages() { scopes_de_gh | grep -q 'read:packages'; }

if gh auth status >/dev/null 2>&1; then
  ok "gh — ya hay sesión ($(gh api user --jq .login 2>/dev/null || echo 'usuario desconocido'))"
else
  aviso "gh — no hay sesión."
  hay_terminal || morir "Necesito una terminal para 'gh auth login'. Corré el script desde una, o corré: gh auth login -s read:packages"
  info "Voy a correr:  gh auth login -s read:packages"
  confirmar "¿Lo hago?" || morir "Sin sesión de gh no puedo bajar el CLI. Corré: gh auth login -s read:packages"
  gh auth login -s read:packages <"$TTY_IN"
fi

# El token que deja `gh auth login` NO trae read:packages salvo que se lo pidas.
# Sin ese scope, `npm install -g` contra GitHub Packages devuelve 403. Está
# medido, y es el paso que hoy hace perder la tarde.
if tiene_read_packages; then
  ok "El token tiene read:packages."
elif [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
  aviso "Estás autenticado con un token de una variable de entorno (GH_TOKEN/GITHUB_TOKEN):"
  aviso "no lo puedo refrescar. Asegurate de que ese token tenga read:packages."
else
  aviso "Al token le falta el scope read:packages — sin él, instalar el CLI da 403."
  info "Voy a correr:  gh auth refresh -s read:packages"
  if confirmar "¿Lo hago?"; then
    gh auth refresh -s read:packages <"${TTY_IN:-/dev/null}"
    if tiene_read_packages; then
      ok "Listo: el token ya tiene read:packages."
    else
      aviso "Sigo sin ver read:packages en los scopes. Si el paso siguiente da 403, es por acá."
    fi
  else
    aviso "Seguimos sin el scope. Si el paso 4 da 403, corré: gh auth refresh -s read:packages"
  fi
fi

# ── 4. el CLI, pineado ───────────────────────────────────────────────────────

titulo "4/5 · CLI ${CLI_PAQUETE}@${CLI_VERSION}"

version_instalada=""
command -v sl >/dev/null 2>&1 && version_instalada="$(sl --version 2>/dev/null | tr -d '[:space:]' || true)"

instalar_cli() {
  # El token se resuelve acá, se le pasa SÓLO al npm que lanzamos, y muere con
  # esta función: no se escribe en ningún archivo, no se exporta a la sesión y
  # no se imprime. `env` es la única forma de pasarle a npm claves de config que
  # no son identificadores válidos de shell (`@scope:registry`, `//host/:_authToken`).
  local token
  token="$(gh auth token 2>/dev/null || true)"
  [[ -n "$token" ]] || morir "gh no me devolvió un token. Corré: gh auth login -s read:packages"

  env \
    "npm_config_${CLI_PAQUETE%%/*}:registry=${CLI_REGISTRY}" \
    "npm_config_//npm.pkg.github.com/:_authToken=${token}" \
    "NODE_AUTH_TOKEN=${token}" \
    npm install --global --no-fund --no-audit "${CLI_PAQUETE}@${CLI_VERSION}"
}

if [[ "$version_instalada" == "$CLI_VERSION" ]]; then
  ok "sl ${CLI_VERSION} ya está instalado ($(command -v sl)). No reinstalo nada."
else
  if [[ -z "$version_instalada" ]]; then
    aviso "sl — no está"
  else
    aviso "sl — tenés ${version_instalada}, y este bootstrap pinea ${CLI_VERSION}"
  fi
  info "Voy a correr:  npm install -g ${CLI_PAQUETE}@${CLI_VERSION}"
  info "               (con el token de 'gh auth token', que no queda escrito en ningún lado)"
  if confirmar "¿Lo hago?"; then
    instalar_cli
    command -v sl >/dev/null 2>&1 ||
      morir "$(
        printf 'npm lo instaló pero "sl" no está en tu PATH.\n'
        printf '  Está en: %s/bin\n' "$(npm prefix -g 2>/dev/null || echo '<npm prefix -g>')"
        printf '  Agregá ese directorio a tu PATH vos (este script no toca profiles) y volvé a correrlo.'
      )"
    ok "sl $(sl --version 2>/dev/null | tr -d '[:space:]') — $(command -v sl)"
  else
    morir "Sin el CLI no hay flota. Cuando quieras: npm install -g ${CLI_PAQUETE}@${CLI_VERSION}"
  fi
fi

# ── 5. identidad del operador ────────────────────────────────────────────────

titulo "5/5 · Tu identidad de operador (sl auth init)"

if [[ -f "$CONFIG_DIR/config.env" ]]; then
  ok "Ya tenés $CONFIG_DIR/config.env: esta máquina ya está dada de alta."
  info "Si querés revisar cómo quedó:  sl doctor"
  if confirmar "¿Corro 'sl auth init' igual?"; then
    sl auth init <"$TTY_IN"
  fi
else
  info "'sl auth init' genera tus claves age y SSH, abre el PR de alta contra infra"
  info "y espera el merge para avisarte cuando ya podés descifrar los secretos."
  info "Hasta que ese PR se mergee y CI re-cifre, tu clave nueva no descifra NADA."
  if hay_terminal && confirmar "¿Lo corro ahora?"; then
    sl auth init <"$TTY_IN"
  else
    aviso "Saltado. Cuando quieras, corré:  sl auth init"
  fi
fi

# ── cierre ───────────────────────────────────────────────────────────────────

titulo "Listo."
info "Una vez que el PR de alta esté mergeado, cada repo se alista con un comando:"
info ""
info "    git clone git@github.com:skylabs-digital/<repo>.git"
info "    cd <repo> && sl setup"
info ""
info "Y si algo no cierra:  sl doctor"
printf '\n'
