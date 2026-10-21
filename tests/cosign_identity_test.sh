#!/usr/bin/env bash
# O SAN keyless de um workflow reutilizável é job_workflow_ref, não o chamador.
# ^, \. e .* têm o mesmo significado no ERE do bash e no RE2 do cosign.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$ROOT/.github/workflows/docker-publish.yml"
README="$ROOT/README.md"

EXPECTED='^https://github.com/JMAInformatica/\.github/\.github/workflows/docker-publish\.yml@.*'
ISSUER='https://token.actions.githubusercontent.com'
# A expressão é do Actions, não do bash. Precisa aparecer literal no workflow.
# shellcheck disable=SC2016
REPO_FLAG='--certificate-github-workflow-repository "${{ github.repository }}"'

fail() {
  echo "FALHOU: $*" >&2
  exit 1
}

extract_regexp() {
  local file="$1"
  local line count
  count="$(grep -c -- '--certificate-identity-regexp' "$file" || true)"
  if [[ "$count" != "1" ]]; then
    fail "${file} deveria ter um certificate-identity-regexp, tem ${count}"
  fi
  line="$(grep -F -- '--certificate-identity-regexp' "$file")"
  if [[ "$line" != *" '${EXPECTED}'"* ]]; then
    fail "${file} não usa a identidade do workflow reutilizável: ${line}"
  fi
}

accept() {
  local san="$1"
  if [[ ! "$san" =~ $EXPECTED ]]; then
    fail "SAN do workflow reutilizável foi rejeitado: ${san}"
  fi
}

reject() {
  local san="$1"
  if [[ "$san" =~ $EXPECTED ]]; then
    fail "SAN indevido foi aceito: ${san}"
  fi
}

[[ -f "$WF" && -f "$README" ]] || fail "arquivos de workflow ou README ausentes"

extract_regexp "$WF"
extract_regexp "$README"

grep -F -- '--certificate-oidc-issuer' "$WF" | grep -F -q -- "$ISSUER" \
  || fail "docker-publish.yml não fixa o issuer do Actions"
grep -F -q -- "$REPO_FLAG" "$WF" \
  || fail "docker-publish.yml não amarra o repositório chamador"
grep -F -q -- '--certificate-github-workflow-repository' "$README" \
  || fail "README não mostra --certificate-github-workflow-repository"
grep -F -q -- "$ISSUER" "$README" \
  || fail "README não mostra o issuer do Actions"

if grep -R -n -- '--certificate-identity-regexp' "$ROOT/.github" "$ROOT/README.md" \
  | grep -v -F -- "$EXPECTED"; then
  fail "sobrou uma identidade que não é a do workflow reutilizável"
fi

verify_hits="$(grep -R -n -E 'cosign verify|verify-blob|gh attestation verify' \
  "$ROOT/.github" "$ROOT/examples" "$ROOT/README.md" || true)"
if [[ -z "$verify_hits" ]]; then
  fail "nenhum comando de verificação foi encontrado"
fi
if grep -F -v 'docker-publish.yml' <<<"$verify_hits" | grep -F -v 'README.md' | grep -q .; then
  fail "verificação de assinatura fora de docker-publish.yml e do README: ${verify_hits}"
fi

if grep -n -E 'repo_re|github.com/\$\{repo_re\}' "$WF"; then
  fail "docker-publish.yml ainda monta a identidade a partir do repositório chamador"
fi

accept "https://github.com/JMAInformatica/.github/.github/workflows/docker-publish.yml@refs/heads/main"
accept "https://github.com/JMAInformatica/.github/.github/workflows/docker-publish.yml@refs/heads/cursor/fix-cosign-verify-identity-2243"
accept "https://github.com/JMAInformatica/.github/.github/workflows/docker-publish.yml@refs/tags/v1.2.3"
accept "https://github.com/JMAInformatica/.github/.github/workflows/docker-publish.yml@3d32040e1c6d9319863800a9086e3ed9dcdfdc8e"

reject "https://github.com/JMAInformatica/ByllOps/.github/workflows/docker.yml@refs/heads/main"
reject "https://github.com/JMAInformatica/.github/.github/workflows/version.yml@refs/heads/main"
reject "https://github.com/JMAInformatica/.github/.github/workflows/msi-release.yml@refs/heads/main"
reject "https://github.com/evil/.github/.github/workflows/docker-publish.yml@refs/heads/main"
reject "https://github.com/JMAInformaticaXgithub/.github/workflows/docker-publish.yml@refs/heads/main"
reject "https://github.com/JMAInformatica/.github/.github/workflows/docker-publish.yml"
reject "https://github.com/JMAInformatica/.github/.github/workflows/docker-publishXyml@refs/heads/main"
reject "http://github.com/JMAInformatica/.github/.github/workflows/docker-publish.yml@refs/heads/main"
reject "https://github.com/jmainformatica/.github/.github/workflows/docker-publish.yml@refs/heads/main"

echo "identidade do cosign confere com o workflow reutilizável."
