#!/usr/bin/env bash
# Monte une machine de travail AD Lab sur une Debian fraîche, en une fois.
#
# Deux jetons suffisent : celui de Claude Code et celui de GitHub. Aucun n'est
# passé en argument (une ligne de commande se lit dans « ps »), aucun n'est
# affiché, aucun n'atterrit dans l'historique du shell.
#
#   sudo bash bootstrap.sh
#
# À lancer en root sur une machine JETABLE. Il crée un compte avec « sudo »
# sans mot de passe et y fait tourner un agent en régime non interactif : ça ne
# se défend que sur une machine qu'on réinstalle sans regret.
set -Eeuo pipefail

readonly USER_NAME="${ADLAB_USER:-lab}"
readonly REPO_DIR="${ADLAB_REPO_DIR:-/opt/platform}"
readonly REPO_URL="${ADLAB_REPO_URL:-https://github.com/daubercyanthony-dotcom/platform}"
readonly RUNTIME_DIR="${ADLAB_RUNTIME_DIR:-/etc/daubercy-lab}"
readonly ENV_FILE="$RUNTIME_DIR/cycle.env"

log()   { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die()   { printf '\nERREUR : %s\n' "$*" >&2; exit 2; }
title() { printf '\n== %s ==\n' "$*"; }
note()  { printf '  %s\n' "$*"; }

# Lecture silencieuse depuis le terminal et non depuis l'entrée standard : le
# script peut arriver par un tube (« curl … | bash »), auquel cas « read »
# mangerait le script lui-même.
ask_secret() {
  local label="$1" answer=''
  [[ -r /dev/tty ]] || die "pas de terminal pour saisir « $label » ; utiliser la variable d'environnement"
  printf '  %s : ' "$label" >&2
  read -rs answer </dev/tty
  printf '\n' >&2
  printf '%s' "$answer"
}

as_user() { sudo -u "$USER_NAME" -H bash -lc "$1"; }

# ---------------------------------------------------------------- 0. contrôles

[[ "$(id -u)" == 0 ]] || die 'à lancer en root (sudo bash bootstrap.sh)'
command -v apt-get >/dev/null || die 'machine non Debian/Ubuntu : apt-get absent'

title 'Ce qui va être installé'
note "Compte de travail   $USER_NAME, avec sudo sans mot de passe"
note "Dépôt               $REPO_URL → $REPO_DIR"
note 'Paquets             docker, compose, client PostgreSQL, python3-venv, openssl'
note 'Agent               Claude Code, lancé en veille par systemd'
note "Jetons              $ENV_FILE et ~$USER_NAME/.git-credentials, en 0600"

# ------------------------------------------------------------------ 1. jetons

title 'Jetons'
claude_token="${ADLAB_CLAUDE_TOKEN:-}"
github_token="${ADLAB_GITHUB_TOKEN:-}"
[[ -n "$claude_token" ]] || claude_token="$(ask_secret 'Jeton Claude Code (invisible à la frappe)')"
[[ -n "$github_token" ]] || github_token="$(ask_secret 'Jeton GitHub (invisible à la frappe)')"
[[ -n "$claude_token" ]] || die 'jeton Claude Code vide'
[[ -n "$github_token" ]] || die 'jeton GitHub vide'
note 'Les deux jetons sont en mémoire ; ils ne seront ni affichés ni journalisés.'

# ----------------------------------------------------------------- 2. paquets

title 'Paquets'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# « docker-compose-plugin » n'existe pas dans Debian : le paquet qui fournit le
# greffon « docker compose » v2 s'y appelle « docker-compose ». OBSERVÉ sur
# trixie, où docker-compose 2.26.1-4 donne bien un « docker compose version ».
apt-get install -y -qq \
  curl git ca-certificates sudo \
  docker.io docker-buildx docker-compose \
  postgresql-client python3 python3-venv openssl >/dev/null
docker compose version >/dev/null 2>&1 \
  || die 'le greffon « docker compose » reste absent après installation'
note "$(docker --version)"
note "$(docker compose version)"

# ------------------------------------------------------------------ 3. compte

title 'Compte de travail'
if id -u "$USER_NAME" >/dev/null 2>&1; then
  note "$USER_NAME existe déjà, conservé"
else
  useradd --create-home --shell /bin/bash "$USER_NAME"
  note "$USER_NAME créé"
fi
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$USER_NAME" >"/etc/sudoers.d/$USER_NAME"
chmod 0440 "/etc/sudoers.d/$USER_NAME"
usermod -aG docker "$USER_NAME"
# L'appartenance au groupe ne prend effet qu'à la session suivante ; « sudo -i »
# et le service systemd en ouvrent une neuve, donc le point est réglé pour eux.
note 'sudo sans mot de passe, et membre du groupe docker'

home="$(getent passwd "$USER_NAME" | cut -d: -f6)"
[[ -n "$home" ]] || die "pas de répertoire personnel pour $USER_NAME"

# ------------------------------------------------------- 4. identifiants Git

title 'Identifiants Git'
umask 077
credentials="$home/.git-credentials"
# Forme « x-access-token:<jeton> », celle qu'utilise GitHub Actions ; elle vaut
# pour les jetons classiques comme pour les jetons à portée fine. On ne la
# suppose pas : le clone qui suit la met à l'épreuve tout de suite.
printf 'https://x-access-token:%s@github.com\n' "$github_token" >"$credentials"
chown "$USER_NAME:$USER_NAME" "$credentials"
chmod 0600 "$credentials"
as_user "git config --global credential.helper store"
as_user "git config --global user.name 'AD Lab'"
as_user "git config --global user.email '$USER_NAME@$(hostname -f 2>/dev/null || hostname)'"
note "$credentials en 0600 ; le jeton n'est écrit nulle part ailleurs"

# --------------------------------------------------------------- 5. le dépôt

title 'Dépôt'
install -d -o "$USER_NAME" -g "$USER_NAME" "$REPO_DIR"
if [[ -d "$REPO_DIR/.git" ]]; then
  as_user "git -C '$REPO_DIR' pull --ff-only" \
    || die "le dépôt existe mais ne se met pas à jour ; le regarder avant de continuer"
  note 'dépôt déjà présent, mis à jour'
else
  # Premier vrai essai du jeton GitHub. S'il est faux, ça casse ici, avec un
  # message clair, et rien d'autre n'a encore été démarré.
  as_user "git clone --quiet '$REPO_URL' '$REPO_DIR'" \
    || die "clone impossible : jeton GitHub invalide, expiré, ou sans accès à ce dépôt"
  note "cloné dans $REPO_DIR"
fi
chown -R "$USER_NAME:$USER_NAME" "$REPO_DIR"

# --------------------------------------------------------- 6. l'agent Claude

title 'Claude Code'
if as_user "test -x '$home/.local/bin/claude'"; then
  note 'déjà installé, conservé'
else
  as_user "curl -fsSL https://claude.ai/install.sh | bash" >/dev/null \
    || die "installation de Claude Code impossible"
fi
if ! grep -q '.local/bin' "$home/.bashrc" 2>/dev/null; then
  printf 'export PATH="$HOME/.local/bin:$PATH"\n' >>"$home/.bashrc"
  chown "$USER_NAME:$USER_NAME" "$home/.bashrc"
fi
version="$(as_user "'$home/.local/bin/claude' --version" 2>/dev/null || true)"
[[ -n "$version" ]] || die "« claude --version » ne répond pas"
note "$version"

# « --version » ne prouve que l'installation. Une seule vraie question prouve
# le jeton, et c'est la différence entre « installé » et « éprouvé ». Le jeton
# passe par l'environnement du processus, jamais par la ligne de commande :
# « ps » ne montrera que « sudo -u … bash -lc … ».
note 'Première question posée à l’agent, pour éprouver le jeton…'
reponse="$(CLAUDE_CODE_OAUTH_TOKEN="$claude_token" \
  sudo -u "$USER_NAME" -H --preserve-env=CLAUDE_CODE_OAUTH_TOKEN \
  bash -lc "'$home/.local/bin/claude' -p 'Réponds exactement ce mot et rien d’autre : PRET'" 2>&1 || true)"
if [[ "$reponse" != *PRET* ]]; then
  printf '%s\n' "$reponse" >&2
  die 'l’agent n’a pas répondu : jeton Claude Code invalide, expiré, ou accès réseau bloqué'
fi
note 'Jeton Claude Code accepté, réponse obtenue'

# ------------------------------------------------------------- 7. le service

title 'Veille'
install -d -m 0700 "$RUNTIME_DIR"
temporary="$ENV_FILE.tmp"
rm -f "$temporary"
install -m 0600 /dev/null "$temporary"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$claude_token" >"$temporary"
mv -f "$temporary" "$ENV_FILE"
note "jeton Claude dans $ENV_FILE, 0600, root seulement"

unset claude_token github_token

bash "$REPO_DIR/install/service.sh" apply

title 'Terminé'
note "Journal en direct    journalctl -fu daubercy-cycle.service"
note "Contrôles            sudo bash $REPO_DIR/install/service.sh doctor"
note "Arrêter la veille    sudo bash $REPO_DIR/install/service.sh stop"
printf '\n'
note 'La veille ne lancera un cycle que si WORK.md change dans le dépôt.'
note 'Rien à faire sur cette machine : la consigne arrive par Git.'
log 'BOOTSTRAP_OK'
