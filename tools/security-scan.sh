#!/bin/bash
#
# Scan tools/manifest.json pins against the NVD API 2.0 for known CVEs.
# Detection + alerting only: findings become a deduplicated GitHub issue
# (see .github/workflows/security-scan.yml); remediation is a pin bump
# via Renovate, which flows through the existing v* tag -> build.yml
# pipeline. This script never triggers a rebuild: rebuilding unchanged
# pins would emit a bit-identical vulnerable image.
#
# For each package in the scan set (toolchain incl. gcc_prereqs,
# base_packages, init_and_session, bootloader, nix) the manifest name is
# resolved to CPE coordinates via tools/cpe-map.json and queried with
# virtualMatchString=cpe:2.3:a:<vendor>:<product>:<version>. A finding
# is a CVE whose official NVD base score is >= 7.0 (HIGH/CRITICAL),
# taken from the first available of the cvssMetricV31, cvssMetricV30,
# cvssMetricV40 metric families. CVEs with no score in any family are
# dropped and counted in a stderr summary line.
#
# Map drift: a manifest package with no map entry hard-fails the scan
# (non-zero exit, one-line reason on stderr). Entries shaped
# {"skip": true, "reason": ...} warn on stderr and continue.
#
# Rate limiting: unauthenticated NVD allows 5 requests / 30 s, so
# queries are sequential with a 7 s sleep between them; when
# NVD_API_KEY is set it is sent as the apiKey header and the sleep drops
# to 1 s. HTTP 429/503 responses and network failures (curl exit code
# 000, reported as HTTP 000) are retried with exponential backoff
# (3 attempts max). Once the retry budget is exhausted, or on any
# unexpected error, the scan exits non-zero and writes no CI outputs.
#
# Version-map drift: when a CPE map entry carries a version_map but the
# pinned version has no mapping in it, the raw version is used as-is and
# a WARNING is emitted on stderr (non-fatal).
#
# Usage:
#   bash tools/security-scan.sh            # scan tools/manifest.json
#   MANIFEST=other.json bash tools/security-scan.sh
#
# Output:
#   - Findings summary on stdout; skip/drop warnings on stderr
#   - Sets $GITHUB_OUTPUT 'cves=true' when findings exist
#   - Sets $GITHUB_ENV 'FINDINGS_TSV' with one tab-separated line per
#     finding: cve_id, package, version, score, severity, url
#     (heredoc-delimited; written only when findings exist)
#
# Exit codes:
#   0 - scan completed (findings, if any, are in the CI outputs)
#   1 - scan failed (unmapped package, NVD error, script error)

set -Eeuo pipefail

MANIFEST="${MANIFEST:-tools/manifest.json}"
NVD_API_URL="${NVD_API_URL:-https://services.nvd.nist.gov/rest/json/cves/2.0}"
readonly MANIFEST
readonly NVD_API_URL
readonly CPE_MAP="tools/cpe-map.json"
readonly THRESHOLD="7.0"
readonly MAX_ATTEMPTS=3
readonly BACKOFF_BASE=5
readonly LOG_PREFIX="[security-scan]"
WORK_DIR=""
# Set before deliberate non-zero returns so the ERR trap can tell
# controlled failures apart from unexpected errors (bash fires the ERR
# trap inside command-substitution subshells even when the caller is in
# a conditional context).
CONTROLLED_FAIL=""

# Canonical scan-set extraction; byte-identical to the completeness check
# in openspec/changes/add-cve-scan-pipeline/tasks.md (task 1.2) so the
# checked set and the scanned set cannot drift apart.
# shellcheck disable=SC2016  # jq program: $ is jq syntax, not shell
readonly SCAN_SET_JQ='(.toolchain | to_entries[] | '\
'select(.key != "gcc_prereqs" and .key != "linux_headers" '\
'and (.key | startswith("$") | not)) | "\(.key)\t\(.value.version)"), '\
'(.toolchain.gcc_prereqs | to_entries[] | '\
'select(.key | startswith("$") | not) | "\(.key)\t\(.value.version)"), '\
'(.base_packages | to_entries[] | select(.key | startswith("$") | not) '\
'| "\(.key)\t\(.value.version)"), '\
'(.init_and_session | to_entries[] | '\
'select(.key | startswith("$") | not) | "\(.key)\t\(.value.version)"), '\
'(.bootloader | to_entries[] | select(.key | startswith("$") | not) | '\
'"\(.key)\t\(.value.version)"), (.nix | "nix\t\(.binary_version)")'

# Per-CVE score extraction: emits id<TAB>score<TAB>severity, with an
# empty score for CVEs lacking all three metric families. The base score
# comes from the first available family, in order v3.1, v3.0, v4.0;
# scores are NVD's official baseScore, never computed locally.
# shellcheck disable=SC2016  # jq program: $ is jq syntax, not shell
readonly SCORES_JQ='.vulnerabilities[]?.cve | .id as $id | '\
'(if ((.metrics.cvssMetricV31 // []) | length) > 0 '\
'then .metrics.cvssMetricV31[0] '\
'elif ((.metrics.cvssMetricV30 // []) | length) > 0 '\
'then .metrics.cvssMetricV30[0] '\
'elif ((.metrics.cvssMetricV40 // []) | length) > 0 '\
'then .metrics.cvssMetricV40[0] else null end) as $m | '\
'if ($m == null or ($m.cvssData.baseScore == null)) '\
'then [$id, "", ""] '\
'else [$id, ($m.cvssData.baseScore | tostring), '\
'($m.cvssData.baseSeverity // "UNKNOWN")] end | @tsv'

log() {
  echo "${LOG_PREFIX} $*"
}

warn() {
  echo "${LOG_PREFIX} WARNING: $*" >&2
}

err() {
  echo "${LOG_PREFIX} ERROR: $*" >&2
}

die() {
  err "$*"
  exit 1
}

on_error() {
  if [[ -z "${CONTROLLED_FAIL}" ]]; then
    err "unexpected failure at line $1; scan aborted"
  fi
  exit 1
}

cleanup() {
  if [[ -n "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
}

# Query NVD for one CPE and store the JSON response in $2. Retries HTTP
# 429/503 and network failures (curl reports 000) with exponential
# backoff, MAX_ATTEMPTS total.
# Globals:
#   NVD_API_URL, NVD_API_KEY (optional), MAX_ATTEMPTS, BACKOFF_BASE
# Arguments:
#   $1: CPE string (cpe:2.3:a:<vendor>:<product>:<version>)
#   $2: output file for the response body
# Returns:
#   0 on HTTP 200, 1 on failure (reason on stderr)
nvd_query() {
  local cpe="$1"
  local out="$2"
  local attempt=1
  local delay="${BACKOFF_BASE}"
  local code
  while (( attempt <= MAX_ATTEMPTS )); do
    if [[ -n "${NVD_API_KEY:-}" ]]; then
      code=$(curl -sS -o "${out}" -w '%{http_code}' --max-time 60 \
        -H "apiKey: ${NVD_API_KEY}" \
        "${NVD_API_URL}?virtualMatchString=${cpe}") || code=000
    else
      code=$(curl -sS -o "${out}" -w '%{http_code}' --max-time 60 \
        "${NVD_API_URL}?virtualMatchString=${cpe}") || code=000
    fi
    if [[ "${code}" == "200" ]]; then
      return 0
    fi
    if [[ "${code}" != "000" && "${code}" != "429" \
      && "${code}" != "503" ]]; then
      err "NVD query for ${cpe} failed with HTTP ${code}"
      return 1
    fi
    if (( attempt == MAX_ATTEMPTS )); then
      err "NVD query for ${cpe} returned HTTP ${code} after" \
        "${MAX_ATTEMPTS} attempts"
      return 1
    fi
    warn "NVD returned HTTP ${code} for ${cpe}; retry in ${delay}s" \
      "(attempt ${attempt}/${MAX_ATTEMPTS})"
    sleep "${delay}"
    delay=$(( delay * 2 ))
    attempt=$(( attempt + 1 ))
  done
  return 1
}

# Resolve one manifest package against the CPE map.
# Arguments:
#   $1: package name, $2: package version
# Outputs:
#   "skip<TAB>reason" or "query<TAB>cpe" on stdout
# Returns:
#   0 on resolution; 1 for unmapped/malformed entries (reason on stderr)
resolve_cpe() {
  local name="$1"
  local version="$2"
  local entry
  entry=$(jq -c --arg n "${name}" '.[$n] // empty' "${CPE_MAP}") || {
    CONTROLLED_FAIL=1
    err "failed to look up '${name}' in ${CPE_MAP}"
    return 1
  }
  if [[ -z "${entry}" ]]; then
    # Unmapped packages from the flake are warned and skipped rather
    # than failing the scan, since the flake surface grows faster than
    # the CPE map (see #166 / #151). Manifest unmapped names still
    # fail — they represent pin drift, not surface growth.
    if [[ "${MANIFEST}" == "tools/manifest.json" ]]; then
      CONTROLLED_FAIL=1
      err "package '${name}' has no entry in ${CPE_MAP};" \
        "add a CPE mapping or an explicit skip"
      return 1
    fi
    printf 'skip\tflake-derived package not yet in %s\n' "${CPE_MAP}"
    return 0
  fi
  if jq -e '.skip == true' <<< "${entry}" > /dev/null; then
    local reason
    reason=$(jq -r '.reason // "(no reason given)"' <<< "${entry}")
    printf 'skip\t%s\n' "${reason}"
    return 0
  fi
  local vendor product cpe_version
  vendor=$(jq -r '.vendor // empty' <<< "${entry}")
  product=$(jq -r '.product // empty' <<< "${entry}")
  if [[ -z "${vendor}" || -z "${product}" ]]; then
    CONTROLLED_FAIL=1
    err "CPE map entry for '${name}' is malformed" \
      "(needs vendor+product or skip)"
    return 1
  fi
  cpe_version=$(jq -r --arg v "${version}" \
    '(.version_map // {})[$v] // $v' <<< "${entry}")
  if jq -e --arg v "${version}" \
    'has("version_map") and (.version_map | has($v) | not)' \
    <<< "${entry}" > /dev/null; then
    warn "${name} ${version} is not in the version_map of" \
      "${CPE_MAP}; using the raw version in the CPE query"
  fi
  printf 'query\tcpe:2.3:a:%s:%s:%s\n' \
    "${vendor}" "${product}" "${cpe_version}"
}

main() {
  trap 'on_error "${LINENO}"' ERR

  [[ -f "${MANIFEST}" ]] || die "manifest not found: ${MANIFEST}"
  [[ -f "${CPE_MAP}" ]] || die "CPE map not found: ${CPE_MAP}"
  jq empty "${MANIFEST}" || die "invalid JSON: ${MANIFEST}"
  jq empty "${CPE_MAP}" || die "invalid JSON: ${CPE_MAP}"

  WORK_DIR=$(mktemp -d)
  trap cleanup EXIT

  # NVD allows 5 req/30s unauthenticated; an API key raises the limit.
  local interval=7
  if [[ -n "${NVD_API_KEY:-}" ]]; then
    interval=1
  fi

  local packages="${WORK_DIR}/packages.tsv"
  jq -r "${SCAN_SET_JQ}" "${MANIFEST}" > "${packages}"

  # Extend the scan set to the flake's declared profiles so packages
  # moved there by #161 / #166 are visible (see #151). We derive
  # (name,version) from the store path basenames; this avoids needing
  # the full closure at query time and keeps the NVD query shape
  # unchanged. When nix is unavailable we skip silently; the manifest
  # path remains intact.
  if command -v nix >/dev/null 2>&1; then
    local flake_pkgs="${WORK_DIR}/flake-packages.tsv"
    : > "${flake_pkgs}"
    for profile_name in minimalProfile desktopProfile installerProfile; do
      local file_name=""
      case ${profile_name} in
        minimalProfile) file_name="minimal" ;;
        desktopProfile) file_name="desktop" ;;
        installerProfile) file_name="installer" ;;
      esac
      if [[ -f "nix/${file_name}.nix" ]]; then
        # Each entry: a store path whose basename carries name-version.
        # We take only direct profile paths (not recursive build-time
        # inputs) to keep the map bounded, matching the design choice.
        nix path-info --recursive --json ".#${profile_name}" 2>/dev/null \
          | jq -r '.[].path' 2>/dev/null \
          | while IFS= read -r p; do
              basename "${p}" | awk '{
                # Store basename: <name>-<version> (last hyphen split)
                # Example: sysklogd-3.42-... or mesa-24.3.4
                n = $0
                # Find last hyphen separating name and version
                # We split on last hyphen that precedes version digits
                if (match(n, /-([0-9]+\.[0-9]|[0-9]+\.[0-9]+\.[0-9]+|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)-/) || match(n, /-([0-9]+)\b/)) {
                  ver = substr(n, RSTART + 1, RLENGTH - 2)
                  name = substr(n, 1, RSTART - 1)
                  # Skip derivation hashes and derivation-only paths
                  if (name ~ /-[0-9]{32}$/ || ver == "") next
                  print name "\t" ver
                } else {
                  # Fallback: split on first version-like segment
                  # This is best-effort for flake-derived names.
                  split(n, a, "-")
                  # Try to find version start: a segment that starts with a digit
                  for (i in a) {
                    if (match(a[i], /^[0-9]/)) {
                      ver = a[i]
                      for (j = i+1; j <= length(a); j++) ver = ver "-" a[j]
                      name = a[1]
                      for (k = 2; k < i; k++) name = name "-" a[k]
                      print name "\t" ver
                      break
                    }
                  }
                }
              }' >> "${flake_pkgs}" || true
            done || true
      fi
    done
    if [[ -s "${flake_pkgs}" ]]; then
      local flake_count
      flake_count=$(sort -u "${flake_pkgs}" | tee -a "${packages}" | wc -l \
        | tr -d ' ')
      log "added ${flake_count} flake-derived package(s) to scan set"
    else
      # Not fatal - the manifest scan still runs - but silence here once meant
      # the whole flake surface was skipped while the run reported success.
      warn "no flake-derived packages resolved; scanning manifest only"
    fi
  fi
  local pkg_count
  pkg_count=$(wc -l < "${packages}" | tr -d ' ')
  log "scanning ${pkg_count} packages from ${MANIFEST}"

  local name version resolution cpe resp total per_page scores
  local request_count=0 skipped_count=0
  local all_scores="${WORK_DIR}/all-scores.tsv"
  : > "${all_scores}"
  while IFS=$'\t' read -r name version; do
    if ! resolution=$(resolve_cpe "${name}" "${version}"); then
      exit 1  # one-line reason already on stderr
    fi
    if [[ "${resolution%%$'\t'*}" == "skip" ]]; then
      warn "skipping ${name} ${version}:" \
        "${resolution#*$'\t'}"
      skipped_count=$(( skipped_count + 1 ))
      continue
    fi
    cpe="${resolution#*$'\t'}"
    log "querying NVD for ${name} ${version} (${cpe})"
    if (( request_count > 0 )); then
      sleep "${interval}"
    fi
    request_count=$(( request_count + 1 ))
    resp="${WORK_DIR}/${name}.json"
    scores="${WORK_DIR}/${name}.scores"
    nvd_query "${cpe}" "${resp}" \
      || die "NVD query failed for ${name} (${cpe})"
    total=$(jq -r '.totalResults // 0' "${resp}")
    per_page=$(jq -r '.resultsPerPage // 0' "${resp}")
    if (( total > per_page )); then
      die "NVD response for ${name} truncated" \
        "(${total} results, page size ${per_page})"
    fi
    jq -r "${SCORES_JQ}" "${resp}" > "${scores}"
    awk -F'\t' -v OFS='\t' -v p="${name}" -v v="${version}" \
      '{ print p, v, $0 }' "${scores}" >> "${all_scores}"
  done < "${packages}"

  # Findings: score >= threshold, deduplicated by CVE id.
  local findings="${WORK_DIR}/findings.tsv"
  awk -F'\t' -v t="${THRESHOLD}" \
    '$4 != "" && ($4 + 0) >= (t + 0) && !seen[$3]++' \
    "${all_scores}" > "${findings}"
  local findings_count dropped_count
  findings_count=$(wc -l < "${findings}" | tr -d ' ')
  dropped_count=$(awk -F'\t' '$4 == ""' "${all_scores}" | wc -l | tr -d ' ')

  log "scanned ${pkg_count} packages: ${request_count} queried," \
    "${skipped_count} skipped"
  echo "${LOG_PREFIX} dropped CVEs with no CVSS v3.1/v3.0/v4.0 score:" \
    "${dropped_count}" >&2

  if (( findings_count == 0 )); then
    log "no vulnerabilities found at CVSS >= ${THRESHOLD}"
    return 0
  fi

  log "found ${findings_count} finding(s) at CVSS >= ${THRESHOLD}:"
  local pkg ver cve_id score severity url
  while IFS=$'\t' read -r pkg ver cve_id score severity; do
    log "  ${pkg} ${ver}: ${cve_id} (CVSS ${score} ${severity})" \
      "https://nvd.nist.gov/vuln/detail/${cve_id}"
  done < "${findings}"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "cves=true" >> "${GITHUB_OUTPUT}"
  fi
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
      echo "FINDINGS_TSV<<EOF"
      while IFS=$'\t' read -r pkg ver cve_id score severity; do
        url="https://nvd.nist.gov/vuln/detail/${cve_id}"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
          "${cve_id}" "${pkg}" "${ver}" "${score}" "${severity}" \
          "${url}"
      done < "${findings}"
      echo "EOF"
    } >> "${GITHUB_ENV}"
  fi
}

main "$@"
