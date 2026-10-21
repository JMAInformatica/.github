#!/usr/bin/env bash
# Confere os uses: dos workflows reutilizáveis.
# Caminho local (./ e $/) é arquivo deste repositório e não precisa de rede.
# Tag remota (owner/repo@ref) só existe se o GitHub responder; sem rede o teste falha
# em vez de fingir que a tag foi verificada.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "FALHOU: $*" >&2
  exit 1
}

files=(
  .github/workflows/docker-publish.yml
  .github/workflows/msi-release.yml
  .github/workflows/version.yml
  .github/actions/version/action.yml
)

command -v gh >/dev/null 2>&1 || fail "gh é necessário para conferir tags remotas"

local_ok=0
remote_ok=0

ref_exists() {
  local owner="$1"
  local name="$2"
  local ref="$3"
  if [[ "$ref" =~ ^[0-9a-fA-F]{40}$ ]]; then
    gh api "repos/${owner}/${name}/commits/${ref}" --silent >/dev/null
    return
  fi
  gh api "repos/${owner}/${name}/git/ref/tags/${ref}" --silent >/dev/null
}

for file in "${files[@]}"; do
  [[ -f "$file" ]] || fail "arquivo ausente: ${file}"
  lineno=0
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    lineno=$((lineno + 1))
    line="${raw%%#*}"
    [[ "$line" =~ uses:[[:space:]]*([^[:space:]]+) ]] || continue
    spec="${BASH_REMATCH[1]}"
    spec="${spec%\"}"
    spec="${spec#\"}"
    spec="${spec%\'}"
    spec="${spec#\'}"
    prefix="${spec:0:2}"
    if [[ "$prefix" == "./" || "$prefix" == '$/' ]]; then
      rel="${spec:2}"
      if [[ -f "$rel" || -f "$rel/action.yml" || -f "$rel/action.yaml" ]]; then
        local_ok=$((local_ok + 1))
        continue
      fi
      fail "${file}:${lineno} ${spec} não existe neste repositório"
    fi
    if [[ "$spec" != */*@* ]]; then
      fail "${file}:${lineno} uses sem owner/repo@ref: ${spec}"
    fi
    repo="${spec%@*}"
    ref="${spec##*@}"
    owner="${repo%%/*}"
    rest="${repo#*/}"
    name="${rest%%/*}"
    if [[ -z "$owner" || -z "$name" || -z "$ref" ]]; then
      fail "${file}:${lineno} uses inválido: ${spec}"
    fi
    errfile="$(mktemp)"
    if ! ref_exists "$owner" "$name" "$ref" 2>"$errfile"; then
      detail="$(tr '\n' ' ' <"$errfile")"
      fail "${file}:${lineno} ${owner}/${name}@${ref} não existe (${detail})"
    fi
    remote_ok=$((remote_ok + 1))
  done <"$file"
done

if ((remote_ok == 0)); then
  fail "nenhuma referência remota foi conferida"
fi

echo "${local_ok} caminhos locais e ${remote_ok} tags remotas existem."
