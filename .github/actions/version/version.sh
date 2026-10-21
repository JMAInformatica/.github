#!/usr/bin/env bash
# Calcula a versão JMA, cria a tag git anotada e grava os outputs do Actions.
# A serialização entre pushes é feita pelo concurrency do workflow; este script
# ainda recusa uma tag que perdeu a corrida e tenta o próximo N.
set -euo pipefail

fail() {
  echo "versão: $*" >&2
  exit 1
}

log() {
  echo "versão: $*" >&2
}

out() {
  local key="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
  fi
  printf '%s=%s\n' "$key" "$value"
}

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "o diretório atual não é um repositório git"

GITHUB_SHA="${GITHUB_SHA:-$(git rev-parse HEAD)}"
GITHUB_REF="${GITHUB_REF:-}"
GITHUB_REF_NAME="${GITHUB_REF_NAME:-}"
GITHUB_RUN_ID="${GITHUB_RUN_ID:-local}"
GITHUB_EVENT_NAME="${GITHUB_EVENT_NAME:-}"
JMA_BUMP="${JMA_BUMP:-}"
JMA_TAG="${JMA_TAG:-}"
JMA_DEFAULT_BRANCH="${JMA_DEFAULT_BRANCH:-}"
JMA_PUSH_RETRIES="${JMA_PUSH_RETRIES:-6}"
JMA_RETRY_SLEEP="${JMA_RETRY_SLEEP:-1}"

HEAD_SHA="$(git rev-parse HEAD)"
if [[ "$HEAD_SHA" != "$GITHUB_SHA" ]]; then
  fail "HEAD (${HEAD_SHA}) difere de GITHUB_SHA (${GITHUB_SHA})"
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
export GIT_TERMINAL_PROMPT=0

resolve_today() {
  local raw
  if [[ -n "${JMA_NOW:-}" ]]; then
    raw="$JMA_NOW"
  else
    raw="$(TZ=America/Fortaleza date +%Y-%m-%d)"
  fi
  if [[ ! "$raw" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
    fail "data inválida: ${raw} (use AAAA-MM-DD)"
  fi
  YEAR="${BASH_REMATCH[1]}"
  MONTH=$((10#${BASH_REMATCH[2]}))
  DAY=$((10#${BASH_REMATCH[3]}))
  if ((MONTH < 1 || MONTH > 12 || DAY < 1 || DAY > 31)); then
    fail "data inválida: ${raw}"
  fi
  BUILD_DATE="${YEAR}.${MONTH}.${DAY}"
  PV_MAJOR=$((10#$YEAR % 100))
}

product_version_of() {
  local n="$1"
  local build
  if ((n < 1 || n > 99)); then
    fail "N=${n} está fora de 1..99. O ProductVersion usa dia*100+N e N>=100 colide com o dia seguinte."
  fi
  build=$((DAY * 100 + n))
  if ((build > 65535)); then
    fail "ProductVersion build ${build} excede 65535"
  fi
  printf '%s.%s.%s\n' "$PV_MAJOR" "$MONTH" "$build"
}

version_gt() {
  local left="$1"
  local right="$2"
  local i lx ly
  IFS='.' read -r -a lx <<<"$left"
  IFS='.' read -r -a ly <<<"$right"
  for i in 0 1 2; do
    local x="${lx[$i]:-0}"
    local y="${ly[$i]:-0}"
    if ((10#$x > 10#$y)); then
      return 0
    fi
    if ((10#$x < 10#$y)); then
      return 1
    fi
  done
  return 1
}

is_final_tag() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

is_daily_tag() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

normalize_tag() {
  local value="$1"
  value="${value#refs/tags/}"
  if [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    value="v${value}"
  fi
  if ! is_final_tag "$value"; then
    fail "tag final inválida: ${1}. Use vX.Y.Z, por exemplo v1.2.0."
  fi
  printf '%s\n' "$value"
}

fetch_tags() {
  git remote get-url origin >/dev/null 2>&1 || fail "o remote origin é obrigatório para publicar a tag"
  git fetch origin --prune --prune-tags '+refs/tags/*:refs/tags/*'
}

field() {
  local key="$1"
  local text="$2"
  printf '%s\n' "$text" | sed -n "s/^${key}: //p" | head -n 1
}

tag_message() {
  local name="$1"
  git for-each-ref "refs/tags/${name}" --format='%(contents)'
}

find_message_by_key() {
  local key="$1"
  local expected="$2"
  local name contents value
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    contents="$(tag_message "$name")"
    value="$(field "$key" "$contents")"
    if [[ "$value" == "$expected" ]]; then
      printf '%s\n' "$contents"
      return 0
    fi
  done < <(git tag -l)
  return 1
}

max_build_number() {
  local max=0
  local tag n
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    if [[ "$tag" =~ ^v${YEAR}\.${MONTH}\.${DAY}\.([0-9]+)$ ]]; then
      n="${BASH_REMATCH[1]}"
      if ((10#$n > max)); then
        max=$((10#$n))
      fi
    fi
  done < <(git tag -l "v${YEAR}.${MONTH}.${DAY}.*")
  printf '%s\n' "$max"
}

previous_final_tag() {
  local exclude="${1:-}"
  local tag version best=""
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    is_final_tag "$tag" || continue
    [[ "$tag" == "$exclude" ]] && continue
    version="${tag#v}"
    if [[ -z "$best" ]] || version_gt "$version" "$best"; then
      best="$version"
    fi
  done < <(git tag -l 'v*')
  if [[ -n "$best" ]]; then
    printf 'v%s\n' "$best"
  fi
}

emit_from_message() {
  local contents="$1"
  local channel marketing product build_date build_number date_tag marketing_tag sha_short previous
  channel="$(field Channel "$contents")"
  marketing="$(field MarketingVersion "$contents")"
  product="$(field ProductVersion "$contents")"
  build_date="$(field BuildDate "$contents")"
  build_number="$(field BuildNumber "$contents")"
  date_tag="$(field DateTag "$contents")"
  marketing_tag="$(field MarketingTag "$contents")"
  [[ -n "$channel" && -n "$marketing" && -n "$product" && -n "$date_tag" && -n "$marketing_tag" ]] ||
    fail "tag existente sem metadados JMA completos"
  sha_short="$(git rev-parse --short=7 HEAD)"
  if [[ "$channel" == "final" ]]; then
    previous="$(previous_final_tag "$marketing_tag")"
    out tag "$marketing_tag"
  else
    previous=""
    out tag "$date_tag"
  fi
  out version "$marketing"
  out marketing_version "$marketing"
  out channel "$channel"
  out product_version "$product"
  out build_date "$build_date"
  out build_number "$build_number"
  out date_tag "$date_tag"
  out sha "$HEAD_SHA"
  out sha_short "$sha_short"
  out previous_final_tag "$previous"
}

ensure_remote_tag() {
  local name="$1"
  local message="$2"
  if git rev-parse -q --verify "refs/tags/${name}" >/dev/null; then
    local current
    current="$(tag_message "$name")"
    if [[ "$current" == "$message" ]]; then
      return 0
    fi
    local current_run
    current_run="$(field RunId "$current")"
    if [[ -n "$current_run" && "$current_run" != "$GITHUB_RUN_ID" ]]; then
      fail "a tag ${name} já existe com outro RunId (${current_run})"
    fi
  fi
  git tag -a "$name" -m "$message"
  git push origin "refs/tags/${name}"
}

write_message() {
  local channel="$1"
  local marketing="$2"
  local marketing_tag="$3"
  local product="$4"
  local build_number="$5"
  local date_tag="$6"
  cat <<EOF
JMA release ${marketing_tag}
Channel: ${channel}
MarketingVersion: ${marketing}
MarketingTag: ${marketing_tag}
ProductVersion: ${product}
BuildDate: ${BUILD_DATE}
BuildNumber: ${build_number}
DateTag: ${date_tag}
Commit: ${HEAD_SHA}
RunId: ${GITHUB_RUN_ID}
EOF
}

validate_marketing() {
  local version="$1"
  local major="${version%%.*}"
  if ((10#$major >= 100)); then
    fail "versão final ${version} tem major >= 100. A versão final é X.Y.Z (ex. 1.2.0); o calendário fica na tag vAAAA.M.D.N."
  fi
}

# Garante a tag no remoto sem reescrever uma tag que já aponta para este commit.
ensure_tag() {
  local name="$1"
  local message="$2"
  local expected_run pointed current_run
  expected_run="$(field RunId "$message")"
  if git rev-parse -q --verify "refs/tags/${name}" >/dev/null; then
    current_run="$(field RunId "$(tag_message "$name")")"
    if [[ -n "$current_run" && "$current_run" == "$expected_run" ]]; then
      return 0
    fi
    pointed="$(git rev-parse "${name}^{}")"
    if [[ "$pointed" == "$HEAD_SHA" ]]; then
      log "tag ${name} já existia neste commit; ela foi mantida"
      return 0
    fi
    fail "a tag ${name} já existe no commit ${pointed}"
  fi
  git tag -a "$name" -m "$message"
  git push origin "refs/tags/${name}"
}

ensure_recorded() {
  local contents="$1"
  local channel marketing_tag date_tag
  channel="$(field Channel "$contents")"
  marketing_tag="$(field MarketingTag "$contents")"
  date_tag="$(field DateTag "$contents")"
  ensure_tag "$date_tag" "$contents"
  if [[ "$channel" == "final" && -n "$marketing_tag" && "$marketing_tag" != "$date_tag" ]]; then
    ensure_tag "$marketing_tag" "$contents"
  fi
  emit_from_message "$contents"
}

require_default_branch() {
  [[ -n "$JMA_DEFAULT_BRANCH" ]] || fail "branch padrão não informada"
  if [[ "$GITHUB_REF" != "refs/heads/${JMA_DEFAULT_BRANCH}" ]]; then
    fail "publicação automática só roda na branch padrão ${JMA_DEFAULT_BRANCH} (ref atual: ${GITHUB_REF:-desconhecida})"
  fi
}

resolve_mode() {
  if [[ -n "$JMA_BUMP" && -n "$JMA_TAG" ]]; then
    fail "informe bump ou tag, não os dois"
  fi
  case "$JMA_BUMP" in
    "" | major | minor | patch) ;;
    *) fail "bump inválido: ${JMA_BUMP}. Use major, minor ou patch." ;;
  esac

  if [[ -n "$JMA_BUMP" ]]; then
    MODE="bump"
    CHANNEL="final"
    require_default_branch
    return
  fi
  if [[ -n "$JMA_TAG" ]]; then
    MODE="explicit-tag"
    CHANNEL="final"
    MARKETING_TAG="$(normalize_tag "$JMA_TAG")"
    return
  fi
  if [[ "$GITHUB_REF" == refs/tags/* ]] && is_final_tag "$GITHUB_REF_NAME"; then
    MODE="pushed-tag"
    CHANNEL="final"
    MARKETING_TAG="$GITHUB_REF_NAME"
    return
  fi
  if [[ "$GITHUB_REF" == refs/tags/* ]] && is_daily_tag "$GITHUB_REF_NAME"; then
    MODE="existing-daily-tag"
    CHANNEL="daily"
    return
  fi
  if [[ "$GITHUB_REF" == refs/heads/* ]]; then
    MODE="daily"
    CHANNEL="daily"
    require_default_branch
    return
  fi
  fail "não foi possível decidir o canal a partir de ref=${GITHUB_REF:-vazia} event=${GITHUB_EVENT_NAME:-vazio}"
}

next_marketing_version() {
  local latest tag version
  latest="0.0.0"
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    is_final_tag "$tag" || continue
    version="${tag#v}"
    if version_gt "$version" "$latest"; then
      latest="$version"
    fi
  done < <(git tag -l 'v*')
  local major minor patch
  IFS='.' read -r major minor patch <<<"$latest"
  case "$JMA_BUMP" in
    major)
      major=$((10#$major + 1))
      minor=0
      patch=0
      ;;
    minor)
      minor=$((10#$minor + 1))
      patch=0
      ;;
    patch)
      patch=$((10#$patch + 1))
      ;;
  esac
  printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}

publish_new() {
  local marketing="" marketing_tag="" attempt max_n n date_tag product message
  local created_date=0 created_marketing=0
  local contents=""

  if [[ "$CHANNEL" == "final" && "$MODE" == "bump" ]]; then
    marketing="$(next_marketing_version)"
    validate_marketing "$marketing"
    marketing_tag="v${marketing}"
  elif [[ "$CHANNEL" == "final" ]]; then
    marketing_tag="$MARKETING_TAG"
    marketing="${marketing_tag#v}"
    validate_marketing "$marketing"
    if git rev-parse -q --verify "refs/tags/${marketing_tag}" >/dev/null; then
      local pointed
      pointed="$(git rev-parse "${marketing_tag}^{}")"
      if [[ "$pointed" != "$HEAD_SHA" ]]; then
        fail "a tag ${marketing_tag} já aponta para ${pointed}, não para ${HEAD_SHA}"
      fi
    fi
  fi

  for ((attempt = 1; attempt <= JMA_PUSH_RETRIES; attempt++)); do
    created_date=0
    created_marketing=0
    fetch_tags
    if contents="$(find_message_by_key RunId "$GITHUB_RUN_ID")"; then
      log "reutilizando a versão já criada neste run ${GITHUB_RUN_ID}"
      ensure_recorded "$contents"
      return 0
    fi
    if [[ "$CHANNEL" == "final" ]]; then
      contents="$(find_message_by_key MarketingTag "$marketing_tag" || true)"
      if [[ -n "$contents" ]]; then
        log "reutilizando ProductVersion já associado a ${marketing_tag}"
        ensure_recorded "$contents"
        return 0
      fi
    fi

    max_n="$(max_build_number)"
    n=$((max_n + 1))
    date_tag="v${YEAR}.${MONTH}.${DAY}.${n}"
    product="$(product_version_of "$n")"
    if [[ "$CHANNEL" == "daily" ]]; then
      marketing="${date_tag#v}"
      marketing_tag="$date_tag"
    fi
    message="$(write_message "$CHANNEL" "$marketing" "$marketing_tag" "$product" "$n" "$date_tag")"

    if ! git tag -a "$date_tag" -m "$message"; then
      log "tentativa ${attempt} não criou ${date_tag}; buscando o próximo N"
      sleep "$JMA_RETRY_SLEEP"
      continue
    fi
    created_date=1
    if [[ "$marketing_tag" != "$date_tag" ]] && ! git rev-parse -q --verify "refs/tags/${marketing_tag}" >/dev/null; then
      if ! git tag -a "$marketing_tag" -m "$message"; then
        git tag -d "$date_tag" >/dev/null 2>&1 || true
        log "tentativa ${attempt} não criou ${marketing_tag}"
        sleep "$JMA_RETRY_SLEEP"
        continue
      fi
      created_marketing=1
    fi

    local -a push_refs=("refs/tags/${date_tag}")
    if ((created_marketing)); then
      push_refs+=("refs/tags/${marketing_tag}")
    fi
    if git push origin "${push_refs[@]}"; then
      log "tag ${marketing_tag} publicada (ProductVersion ${product})"
      ensure_recorded "$message"
      return 0
    fi

    log "tentativa ${attempt} perdeu a corrida da tag ${date_tag}; buscando o próximo N"
    if ((created_date)); then
      git tag -d "$date_tag" >/dev/null 2>&1 || true
    fi
    if ((created_marketing)); then
      git tag -d "$marketing_tag" >/dev/null 2>&1 || true
    fi
    sleep "$JMA_RETRY_SLEEP"
  done
  fail "não foi possível reservar um N exclusivo após ${JMA_PUSH_RETRIES} tentativas"
}

main() {
  local contents=""
  resolve_today
  fetch_tags
  resolve_mode

  if [[ "$MODE" == "existing-daily-tag" ]]; then
    contents="$(tag_message "$GITHUB_REF_NAME")"
    if [[ -z "$(field RunId "$contents")" ]]; then
      fail "a tag diária ${GITHUB_REF_NAME} não foi criada por este fluxo"
    fi
    emit_from_message "$contents"
    return 0
  fi

  if contents="$(find_message_by_key RunId "$GITHUB_RUN_ID")"; then
    log "run ${GITHUB_RUN_ID} já possui versão"
    ensure_recorded "$contents"
    return 0
  fi

  publish_new
}

main
