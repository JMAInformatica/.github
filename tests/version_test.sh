#!/usr/bin/env bash
# Exercita o cálculo de versão contra um remote local, sem GitHub.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/.github/actions/version/version.sh"
PASS=0

fail() {
  echo "FALHOU: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" != "$expected" ]]; then
    fail "${label}: esperado '${expected}', obtido '${actual}'"
  fi
}

read_out() {
  local key="$1"
  local file="$2"
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}

version_gt() {
  local left="$1" right="$2" i
  local lx ly x y
  IFS='.' read -r -a lx <<<"$left"
  IFS='.' read -r -a ly <<<"$right"
  for i in 0 1 2; do
    x="${lx[$i]:-0}"
    y="${ly[$i]:-0}"
    if ((10#$x > 10#$y)); then
      return 0
    fi
    if ((10#$x < 10#$y)); then
      return 1
    fi
  done
  return 1
}

new_repo() {
  local root remote
  root="$(mktemp -d)"
  remote="$root/remote.git"
  git init --bare -b main "$remote" >/dev/null
  git init -b main "$root/repo" >/dev/null
  git -C "$root/repo" config user.email "test@example.com"
  git -C "$root/repo" config user.name "Test"
  echo "conteudo" >"$root/repo/README.md"
  git -C "$root/repo" add README.md
  git -C "$root/repo" commit -m init >/dev/null
  git -C "$root/repo" remote add origin "$remote"
  git -C "$root/repo" push -u origin main >/dev/null
  printf '%s\n' "$root/repo"
}

run_version() {
  local repo="$1"
  local outfile="$2"
  shift 2
  (
    cd "$repo"
    export GITHUB_OUTPUT="$outfile"
    export GITHUB_SHA
    GITHUB_SHA="$(git rev-parse HEAD)"
    export GITHUB_REF="${GITHUB_REF:-refs/heads/main}"
    export GITHUB_REF_NAME="${GITHUB_REF_NAME:-main}"
    export GITHUB_RUN_ID="${GITHUB_RUN_ID:-1000}"
    export GITHUB_EVENT_NAME="${GITHUB_EVENT_NAME:-push}"
    export JMA_DEFAULT_BRANCH="${JMA_DEFAULT_BRANCH:-main}"
    export JMA_NOW="${JMA_NOW:-2026-01-05}"
    export JMA_BUMP="${JMA_BUMP:-}"
    export JMA_TAG="${JMA_TAG:-}"
    export JMA_PUSH_RETRIES="${JMA_PUSH_RETRIES:-8}"
    export JMA_RETRY_SLEEP="${JMA_RETRY_SLEEP:-0.2}"
    : >"$GITHUB_OUTPUT"
    bash "$SCRIPT"
  )
}

check() {
  local name="$1"
  shift
  echo "== ${name}"
  "$@"
  PASS=$((PASS + 1))
  echo "ok ${name}"
}

test_daily_shape() {
  local repo out
  repo="$(new_repo)"
  out="$(mktemp)"
  GITHUB_RUN_ID=11 JMA_NOW=2026-01-05 run_version "$repo" "$out"
  assert_eq "$(read_out version "$out")" "2026.1.5.1" "version"
  assert_eq "$(read_out tag "$out")" "v2026.1.5.1" "tag"
  assert_eq "$(read_out channel "$out")" "daily" "channel"
  assert_eq "$(read_out product_version "$out")" "26.1.501" "product"
  assert_eq "$(read_out build_number "$out")" "1" "n"
  assert_eq "$(read_out date_tag "$out")" "v2026.1.5.1" "date tag"
  git -C "$repo" rev-parse -q --verify refs/tags/v2026.1.5.1 >/dev/null
}

test_second_build_same_day() {
  local repo out
  repo="$(new_repo)"
  out="$(mktemp)"
  GITHUB_RUN_ID=21 JMA_NOW=2026-01-05 run_version "$repo" "$out"
  echo "outro" >>"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m segundo >/dev/null
  git -C "$repo" push origin main >/dev/null
  GITHUB_RUN_ID=22 JMA_NOW=2026-01-05 run_version "$repo" "$out"
  assert_eq "$(read_out version "$out")" "2026.1.5.2" "version"
  assert_eq "$(read_out product_version "$out")" "26.1.502" "product"
}

test_rerun_is_stable() {
  local repo out
  repo="$(new_repo)"
  out="$(mktemp)"
  GITHUB_RUN_ID=30 JMA_NOW=2026-01-05 run_version "$repo" "$out"
  GITHUB_RUN_ID=30 JMA_NOW=2026-01-05 run_version "$repo" "$out"
  assert_eq "$(read_out build_number "$out")" "1" "n estável no mesmo run"
  assert_eq "$(git -C "$repo" tag -l 'v2026.1.5.*' | wc -l | tr -d ' ')" "1" "uma tag"
}

test_august_has_no_leading_zero() {
  local repo out
  repo="$(new_repo)"
  out="$(mktemp)"
  GITHUB_RUN_ID=40 JMA_NOW=2026-08-09 run_version "$repo" "$out"
  assert_eq "$(read_out version "$out")" "2026.8.9.1" "version"
  assert_eq "$(read_out product_version "$out")" "26.8.901" "product"
}

test_neighbor_days_do_not_collide() {
  local repo out jan feb dec next_year
  repo="$(new_repo)"
  out="$(mktemp)"
  GITHUB_RUN_ID=51 JMA_NOW=2026-01-31 run_version "$repo" "$out"
  jan="$(read_out product_version "$out")"
  echo x >>"$repo/README.md"
  git -C "$repo" commit -am feb >/dev/null
  git -C "$repo" push origin main >/dev/null
  GITHUB_RUN_ID=52 JMA_NOW=2026-02-01 run_version "$repo" "$out"
  feb="$(read_out product_version "$out")"
  echo x >>"$repo/README.md"
  git -C "$repo" commit -am dec >/dev/null
  git -C "$repo" push origin main >/dev/null
  GITHUB_RUN_ID=53 JMA_NOW=2026-12-31 run_version "$repo" "$out"
  dec="$(read_out product_version "$out")"
  echo x >>"$repo/README.md"
  git -C "$repo" commit -am y2027 >/dev/null
  git -C "$repo" push origin main >/dev/null
  GITHUB_RUN_ID=54 JMA_NOW=2027-01-01 run_version "$repo" "$out"
  next_year="$(read_out product_version "$out")"
  assert_eq "$jan" "26.1.3101" "31 de janeiro"
  assert_eq "$feb" "26.2.101" "1 de fevereiro"
  assert_eq "$dec" "26.12.3101" "31 de dezembro"
  assert_eq "$next_year" "27.1.101" "ano seguinte"
  version_gt "$feb" "$jan" || fail "fevereiro deve ser maior que janeiro"
  version_gt "$dec" "$feb" || fail "dezembro deve ser maior que fevereiro"
  version_gt "$next_year" "$dec" || fail "2027 deve ser maior que dezembro de 2026"
}

test_unrelated_tags_do_not_consume_n() {
  local repo out
  repo="$(new_repo)"
  git -C "$repo" tag v2026.1.15.1
  git -C "$repo" tag v2026.11.5.1
  git -C "$repo" tag v2026.1.5
  git -C "$repo" push origin --tags >/dev/null
  out="$(mktemp)"
  GITHUB_RUN_ID=60 JMA_NOW=2026-01-05 run_version "$repo" "$out"
  assert_eq "$(read_out version "$out")" "2026.1.5.1" "N ignora tags vizinhas"
}

test_bump_is_monotonic_over_daily() {
  local repo out daily final
  repo="$(new_repo)"
  out="$(mktemp)"
  GITHUB_RUN_ID=71 JMA_NOW=2026-01-05 run_version "$repo" "$out"
  daily="$(read_out product_version "$out")"
  GITHUB_RUN_ID=72 JMA_NOW=2026-01-05 JMA_BUMP=major JMA_EVENT=workflow_dispatch run_version "$repo" "$out"
  assert_eq "$(read_out version "$out")" "1.0.0" "marketing"
  assert_eq "$(read_out tag "$out")" "v1.0.0" "tag final"
  assert_eq "$(read_out channel "$out")" "final" "channel"
  assert_eq "$(read_out date_tag "$out")" "v2026.1.5.2" "data reservada"
  final="$(read_out product_version "$out")"
  assert_eq "$final" "26.1.502" "product final"
  version_gt "$final" "$daily" || fail "a final do mesmo dia deve atualizar o daily anterior"
  GITHUB_RUN_ID=73 JMA_NOW=2026-02-02 JMA_BUMP=minor run_version "$repo" "$out"
  assert_eq "$(read_out version "$out")" "1.1.0" "minor"
  assert_eq "$(read_out product_version "$out")" "26.2.201" "product minor"
  GITHUB_RUN_ID=74 JMA_NOW=2026-02-02 JMA_BUMP=patch run_version "$repo" "$out"
  assert_eq "$(read_out version "$out")" "1.1.1" "patch"
}

test_explicit_tag_reuses_product_version() {
  local repo out first second
  repo="$(new_repo)"
  out="$(mktemp)"
  GITHUB_RUN_ID=81 JMA_NOW=2026-01-05 JMA_TAG=v2.0.0 run_version "$repo" "$out"
  first="$(read_out product_version "$out")"
  assert_eq "$(read_out version "$out")" "2.0.0" "marketing"
  assert_eq "$first" "26.1.501" "product"
  GITHUB_REF=refs/tags/v2.0.0 GITHUB_REF_NAME=v2.0.0 GITHUB_EVENT_NAME=push \
    GITHUB_RUN_ID=82 JMA_NOW=2026-01-05 JMA_TAG='' run_version "$repo" "$out"
  second="$(read_out product_version "$out")"
  assert_eq "$second" "$first" "reexecução da tag não avança N"
  assert_eq "$(read_out channel "$out")" "final" "channel"
}

test_limit_99() {
  local repo out
  repo="$(new_repo)"
  git -C "$repo" tag -a v2026.1.5.99 -m "BuildNumber: 99"
  git -C "$repo" push origin v2026.1.5.99 >/dev/null
  out="$(mktemp)"
  if GITHUB_RUN_ID=90 JMA_NOW=2026-01-05 run_version "$repo" "$out" >/dev/null 2>"$out.err"; then
    fail "o 100º build do dia deveria falhar"
  fi
  grep -q "fora de 1..99" "$out.err"
}

test_rejects_non_default_branch() {
  local repo out
  repo="$(new_repo)"
  out="$(mktemp)"
  if GITHUB_REF=refs/heads/feature GITHUB_REF_NAME=feature GITHUB_RUN_ID=91 \
    JMA_NOW=2026-01-05 run_version "$repo" "$out" >/dev/null 2>"$out.err"; then
    fail "build diário em outra branch deveria falhar"
  fi
  grep -q "branch padrão" "$out.err"
}

test_parallel_builds_get_distinct_n() {
  local root remote out_a out_b status n1 n2 pv1 pv2
  root="$(mktemp -d)"
  remote="$root/remote.git"
  git init --bare -b main "$remote" >/dev/null
  git init -b main "$root/seed" >/dev/null
  git -C "$root/seed" config user.email "test@example.com"
  git -C "$root/seed" config user.name "Test"
  echo a >"$root/seed/README.md"
  git -C "$root/seed" add README.md
  git -C "$root/seed" commit -m init >/dev/null
  git -C "$root/seed" remote add origin "$remote"
  git -C "$root/seed" push -u origin main >/dev/null
  git clone "$remote" "$root/a" >/dev/null
  git clone "$remote" "$root/b" >/dev/null
  git -C "$root/a" config user.email "test@example.com"
  git -C "$root/a" config user.name "Test"
  git -C "$root/b" config user.email "test@example.com"
  git -C "$root/b" config user.name "Test"
  out_a="$(mktemp)"
  out_b="$(mktemp)"
  status=0
  GITHUB_RUN_ID=101 JMA_NOW=2026-01-05 JMA_RETRY_SLEEP=0.1 run_version "$root/a" "$out_a" >/tmp/jma-a.log 2>&1 &
  local pid_a=$!
  GITHUB_RUN_ID=102 JMA_NOW=2026-01-05 JMA_RETRY_SLEEP=0.1 run_version "$root/b" "$out_b" >/tmp/jma-b.log 2>&1 &
  local pid_b=$!
  wait "$pid_a" || status=1
  wait "$pid_b" || status=1
  if ((status != 0)); then
    echo "----- clone A -----" >&2
    cat /tmp/jma-a.log >&2 || true
    echo "----- clone B -----" >&2
    cat /tmp/jma-b.log >&2 || true
    fail "uma das publicações paralelas falhou"
  fi
  n1="$(read_out build_number "$out_a")"
  n2="$(read_out build_number "$out_b")"
  pv1="$(read_out product_version "$out_a")"
  pv2="$(read_out product_version "$out_b")"
  if [[ "$n1" == "$n2" ]]; then
    fail "dois pushes no mesmo dia receberam N=${n1}"
  fi
  if [[ "$pv1" == "$pv2" ]]; then
    fail "ProductVersion duplicado: ${pv1}"
  fi
  [[ "$n1" == "1" || "$n1" == "2" ]] || fail "N inesperado: ${n1}"
  [[ "$n2" == "1" || "$n2" == "2" ]] || fail "N inesperado: ${n2}"
}

check "diária sem zero à esquerda" test_daily_shape
check "segundo build do dia" test_second_build_same_day
check "reexecução do mesmo run" test_rerun_is_stable
check "agosto não cai em octal" test_august_has_no_leading_zero
check "ordem entre dias e anos" test_neighbor_days_do_not_collide
check "tags vizinhas não entram no N" test_unrelated_tags_do_not_consume_n
check "final monotônica sobre o daily" test_bump_is_monotonic_over_daily
check "tag final reaproveita ProductVersion" test_explicit_tag_reuses_product_version
check "limite de 99 builds" test_limit_99
check "branch que não é a padrão" test_rejects_non_default_branch
check "dois pushes paralelos" test_parallel_builds_get_distinct_n

echo "${PASS} testes de versão passaram."
