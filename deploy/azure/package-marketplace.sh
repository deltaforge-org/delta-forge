#!/usr/bin/env bash
#
# package-marketplace.sh
# ======================
#
# Build the Azure Marketplace "Azure Application" offer artifacts for the three
# DeltaForge license tiers: community, standard, professional.
#
# For each tier this script:
#   1. Compiles deploy/azure/<tier>.bicep to mainTemplate.json with the Azure CLI
#      bicep compiler (az bicep build).
#   2. Copies deploy/azure/createUiDefinition.json next to it. Both files land at
#      the ROOT of the staging folder, never in a subfolder, because the Azure
#      Marketplace "Azure Application" package requires mainTemplate.json and
#      createUiDefinition.json at the zip root.
#   3. Zips the staged folder contents into deploy/azure/dist/<tier>.zip so that
#      both files sit at the archive root.
#   4. Runs ARM-TTK (Azure/arm-ttk, Test-AzTemplate via pwsh) over the staged
#      folder and prints a per-tier PASS/FAIL summary (count of failed tests).
#
# ARM-TTK lives at https://github.com/Azure/arm-ttk. If it is not already cloned
# into the cache dir (deploy/azure/.arm-ttk) the script clones it once with a
# shallow checkout and reuses it on later runs. The importable module is at
# <clone>/arm-ttk/arm-ttk.psd1.
#
# Robustness notes (this gates an expensive Marketplace submission, so it follows
# the project rule "validate every script before it gates expensive work"):
#   - Runs under "set -u" (unset variables are errors) but NOT a bare "set -e";
#     every step is guarded explicitly so a non-fatal failure (for example a
#     missing ARM-TTK) cannot abort the whole run after the zips are produced.
#   - ARM-TTK is best-effort: if pwsh is missing or the clone fails, the script
#     warns and keeps going. The zips are the real deliverable and still get
#     produced.
#   - No "cmd | head" under pipefail (that SIGPIPEs the producer to exit 141);
#     pipefail is left off and the few pipelines used are SIGPIPE-safe.
#   - Output and staging dirs are created with mkdir -p; the staging dir is wiped
#     clean at the start of every run.
#   - Zip tooling is detected at run time: a real "zip" binary is preferred, and
#     pwsh Compress-Archive is the fallback on Windows where "zip" is often
#     absent.
#
# Usage:
#   bash deploy/azure/package-marketplace.sh
#   bash deploy/azure/package-marketplace.sh community           # one tier only
#   bash deploy/azure/package-marketplace.sh community standard  # a subset
#
# Environment overrides (all optional):
#   DF_SKIP_ARMTTK=1   Skip the ARM-TTK validation pass entirely.
#   DF_ARMTTK_DIR      Use an existing ARM-TTK clone instead of the cache dir.
#
# Requirements:
#   - az CLI with the bicep extension (az bicep build).
#   - git (only needed the first time, to clone ARM-TTK).
#   - pwsh (PowerShell 7+) for ARM-TTK; optional, validation is skipped without it.
#   - zip OR pwsh (for Compress-Archive) to build the archives.
#
# Exit status: 0 when every requested tier produced its zip. Non-zero only when a
# zip could NOT be produced for one or more tiers (a hard packaging failure). A
# non-zero ARM-TTK failed-test count does NOT fail the script; it is reported in
# the summary so a human (or a later gate) decides what to do with it.

set -u

# --------------------------------------------------------------------------
# Resolve paths relative to this script so it runs from any working directory.
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
AZURE_DIR="${SCRIPT_DIR}"
DIST_DIR="${AZURE_DIR}/dist"
STAGE_DIR="${AZURE_DIR}/.stage"
ARMTTK_CACHE_DIR="${DF_ARMTTK_DIR:-${AZURE_DIR}/.arm-ttk}"
CREATE_UI_DEF="${AZURE_DIR}/createUiDefinition.json"

ALL_TIERS=(community standard professional)

# Tiers may be passed as positional args; default to all three.
if [ "$#" -gt 0 ]; then
  TIERS=("$@")
else
  TIERS=("${ALL_TIERS[@]}")
fi

# --------------------------------------------------------------------------
# Small logging helpers. Plain echo, no colour assumptions, no pipes.
# --------------------------------------------------------------------------
log()  { printf '%s\n' "[package-marketplace] $*"; }
warn() { printf '%s\n' "[package-marketplace] WARNING: $*" >&2; }
err()  { printf '%s\n' "[package-marketplace] ERROR: $*" >&2; }

# --------------------------------------------------------------------------
# Tool detection. Each returns 0 when the tool is usable.
# --------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# az is required for the actual build. Detect once and report clearly.
HAVE_AZ=0
if have az; then
  HAVE_AZ=1
else
  warn "the Azure CLI (az) was not found on PATH; bicep compilation will be skipped and no zips can be produced."
fi

# pwsh is needed for ARM-TTK and for the Compress-Archive zip fallback.
HAVE_PWSH=0
if have pwsh; then
  HAVE_PWSH=1
fi

# A native zip binary is preferred when present.
HAVE_ZIP=0
if have zip; then
  HAVE_ZIP=1
fi

if [ "${HAVE_ZIP}" -eq 0 ] && [ "${HAVE_PWSH}" -eq 0 ]; then
  warn "neither 'zip' nor 'pwsh' (for Compress-Archive) was found; archives cannot be built."
fi

# --------------------------------------------------------------------------
# ensure_armttk: make sure ARM-TTK is available; clone it once if needed.
# Echoes the path to the importable .psd1 on stdout and returns 0 on success.
# Returns non-zero (and prints nothing on stdout) when ARM-TTK is unavailable;
# the caller treats that as "skip validation, keep going".
# --------------------------------------------------------------------------
ensure_armttk() {
  local psd1="${ARMTTK_CACHE_DIR}/arm-ttk/arm-ttk.psd1"

  if [ -f "${psd1}" ]; then
    printf '%s\n' "${psd1}"
    return 0
  fi

  # Only the clone path needs git. If git is missing we cannot fetch ARM-TTK.
  if ! have git; then
    warn "ARM-TTK is not cached at ${ARMTTK_CACHE_DIR} and git is not available to clone it; skipping validation." >&2
    return 1
  fi

  log "ARM-TTK not found in cache; cloning Azure/arm-ttk (shallow) into ${ARMTTK_CACHE_DIR} ..." >&2
  # Guard the clone: a network/permission failure must not abort the run.
  if git clone --depth 1 https://github.com/Azure/arm-ttk.git "${ARMTTK_CACHE_DIR}" >&2; then
    if [ -f "${psd1}" ]; then
      printf '%s\n' "${psd1}"
      return 0
    fi
    warn "cloned ARM-TTK but did not find the module at ${psd1}; skipping validation." >&2
    return 1
  fi

  warn "failed to clone Azure/arm-ttk; skipping validation." >&2
  return 1
}

# --------------------------------------------------------------------------
# run_armttk <template_dir>: run ARM-TTK over a staged folder and echo the
# number of FAILED tests on stdout. Echoes a sentinel "-1" when validation
# could not run at all (no pwsh, no ARM-TTK, or pwsh errored). All diagnostic
# chatter goes to stderr so stdout carries only the count.
# --------------------------------------------------------------------------
run_armttk() {
  local template_dir="$1"

  if [ "${DF_SKIP_ARMTTK:-0}" = "1" ]; then
    log "DF_SKIP_ARMTTK=1 set; skipping ARM-TTK for ${template_dir}." >&2
    printf '%s\n' "-1"
    return 0
  fi

  if [ "${HAVE_PWSH}" -eq 0 ]; then
    warn "pwsh not found; skipping ARM-TTK for ${template_dir}." >&2
    printf '%s\n' "-1"
    return 0
  fi

  local psd1
  psd1="$(ensure_armttk)"
  if [ -z "${psd1}" ] || [ ! -f "${psd1}" ]; then
    # ensure_armttk already warned on stderr.
    printf '%s\n' "-1"
    return 0
  fi

  # Build the PowerShell program. It imports the module, runs Test-AzTemplate,
  # prints each failing test's name, and finally prints a machine-readable line
  # "ARMTTK_FAILED_COUNT=<n>" that we parse back out. -ErrorAction is left at
  # default so a thrown ARM-TTK error surfaces; we wrap the whole thing in
  # try/catch so a failure still yields a clean sentinel instead of a crash.
  local ps_program
  ps_program=$(cat <<'PWSH'
$ErrorActionPreference = 'Stop'
try {
    Import-Module $env:DF_ARMTTK_PSD1 -Force
    $results = Test-AzTemplate -TemplatePath $env:DF_ARMTTK_TEMPLATE_DIR
    $failed = @($results | Where-Object { -not $_.Passed })
    foreach ($f in $failed) {
        Write-Host ("FAIL: " + $f.Name)
    }
    Write-Host ("ARMTTK_FAILED_COUNT=" + $failed.Count)
}
catch {
    Write-Host ("ARMTTK_ERROR: " + $_.Exception.Message)
    Write-Host "ARMTTK_FAILED_COUNT=-1"
}
PWSH
)

  # Capture combined output so we can both echo the failing-test names to the
  # operator (stderr) and parse the count line. No "| head" pipeline is used,
  # so there is no SIGPIPE exposure here.
  local output
  output="$(DF_ARMTTK_PSD1="${psd1}" \
            DF_ARMTTK_TEMPLATE_DIR="${template_dir}" \
            pwsh -NoProfile -NonInteractive -Command "${ps_program}" 2>&1)"
  local rc=$?

  # Surface the human-readable lines to stderr for the operator log.
  printf '%s\n' "${output}" >&2

  # Extract the count line. grep with a fixed pattern; tail -1 takes the last
  # match (no producer SIGPIPE risk because grep finishes before tail reads).
  local count_line
  count_line="$(printf '%s\n' "${output}" | grep -E '^ARMTTK_FAILED_COUNT=' | tail -n 1)"
  if [ -z "${count_line}" ]; then
    warn "could not parse ARM-TTK result for ${template_dir} (pwsh exit ${rc}); treating as unknown." >&2
    printf '%s\n' "-1"
    return 0
  fi

  local count="${count_line#ARMTTK_FAILED_COUNT=}"
  # Validate it is an integer (it may be -1 on the catch path).
  case "${count}" in
    ''|*[!0-9-]*)
      warn "ARM-TTK count '${count}' for ${template_dir} is not an integer; treating as unknown." >&2
      printf '%s\n' "-1"
      ;;
    *)
      printf '%s\n' "${count}"
      ;;
  esac
  return 0
}

# --------------------------------------------------------------------------
# make_zip <src_dir> <zip_path>: archive the CONTENTS of src_dir (not the dir
# itself) so the files land at the archive root. Prefers the native zip binary,
# falls back to pwsh Compress-Archive. Returns 0 on success.
# --------------------------------------------------------------------------
make_zip() {
  local src_dir="$1"
  local zip_path="$2"

  # Always start from a clean target so a stale archive is never shipped.
  rm -f "${zip_path}" 2>/dev/null

  if [ "${HAVE_ZIP}" -eq 1 ]; then
    # Run zip from inside src_dir so paths are stored relative to the root.
    # A subshell keeps the cd local and avoids a permission prompt on the cd.
    if ( cd "${src_dir}" && zip -q -r -X "${zip_path}" . ); then
      return 0
    fi
    warn "'zip' failed for ${zip_path}; trying pwsh Compress-Archive fallback."
  fi

  if [ "${HAVE_PWSH}" -eq 1 ]; then
    # Compress-Archive with a wildcard path stores the matched entries at the
    # archive root, which is exactly what the Marketplace package requires.
    # -Force overwrites any existing archive. Errors are made terminating so a
    # failure is caught and reported rather than silently producing nothing.
    if DF_ZIP_SRC="${src_dir}" DF_ZIP_DST="${zip_path}" pwsh -NoProfile -NonInteractive -Command \
        'Compress-Archive -Path (Join-Path $env:DF_ZIP_SRC "*") -DestinationPath $env:DF_ZIP_DST -Force -ErrorAction Stop'; then
      return 0
    fi
    warn "pwsh Compress-Archive failed for ${zip_path}."
    return 1
  fi

  err "no usable zip tool (zip or pwsh Compress-Archive) to build ${zip_path}."
  return 1
}

# --------------------------------------------------------------------------
# build_tier <tier>: compile, stage, and zip one tier. Echoes a single summary
# line on stdout in the form "<tier>|<zip_path_or_dash>|<armttk_count>" so the
# main loop can collect it for the final table. Returns 0 only when the zip was
# produced.
# --------------------------------------------------------------------------
build_tier() {
  local tier="$1"
  local bicep="${AZURE_DIR}/${tier}.bicep"
  local tier_stage="${STAGE_DIR}/${tier}"
  local main_template="${tier_stage}/mainTemplate.json"
  local staged_ui="${tier_stage}/createUiDefinition.json"
  local zip_path="${DIST_DIR}/${tier}.zip"
  local armttk_count="-1"

  log "=== Tier: ${tier} ==="

  if [ ! -f "${bicep}" ]; then
    err "bicep source not found: ${bicep}; skipping ${tier}."
    printf '%s\n' "${tier}|-|skip-no-bicep"
    return 1
  fi

  if [ ! -f "${CREATE_UI_DEF}" ]; then
    err "createUiDefinition.json not found: ${CREATE_UI_DEF}; skipping ${tier}."
    printf '%s\n' "${tier}|-|skip-no-ui"
    return 1
  fi

  if [ "${HAVE_AZ}" -eq 0 ]; then
    err "az CLI unavailable; cannot compile ${bicep}; skipping ${tier}."
    printf '%s\n' "${tier}|-|skip-no-az"
    return 1
  fi

  # Clean per-tier staging folder, then recreate it.
  rm -rf "${tier_stage}" 2>/dev/null
  if ! mkdir -p "${tier_stage}"; then
    err "could not create staging dir ${tier_stage}; skipping ${tier}."
    printf '%s\n' "${tier}|-|skip-stage-dir"
    return 1
  fi

  # Step 1: compile the bicep to mainTemplate.json.
  log "Compiling ${tier}.bicep -> mainTemplate.json ..."
  if ! az bicep build --file "${bicep}" --outfile "${main_template}"; then
    err "az bicep build failed for ${tier}; skipping ${tier}."
    printf '%s\n' "${tier}|-|skip-bicep-build"
    return 1
  fi
  if [ ! -f "${main_template}" ]; then
    err "az bicep build reported success but ${main_template} is missing; skipping ${tier}."
    printf '%s\n' "${tier}|-|skip-no-output"
    return 1
  fi

  # Step 2: copy createUiDefinition.json next to mainTemplate.json (zip root).
  log "Staging createUiDefinition.json ..."
  if ! cp -f "${CREATE_UI_DEF}" "${staged_ui}"; then
    err "failed to copy createUiDefinition.json into ${tier_stage}; skipping ${tier}."
    printf '%s\n' "${tier}|-|skip-copy-ui"
    return 1
  fi

  # Step 3: zip the staged contents (both files at the archive root).
  log "Zipping -> ${zip_path} ..."
  if ! make_zip "${tier_stage}" "${zip_path}"; then
    err "failed to build ${zip_path} for ${tier}."
    printf '%s\n' "${tier}|-|skip-zip-failed"
    return 1
  fi
  log "Produced ${zip_path}"

  # Step 4: ARM-TTK validation (best-effort, never fatal).
  log "Running ARM-TTK over ${tier_stage} ..."
  armttk_count="$(run_armttk "${tier_stage}")"

  printf '%s\n' "${tier}|${zip_path}|${armttk_count}"
  return 0
}

# --------------------------------------------------------------------------
# Main.
# --------------------------------------------------------------------------
log "DeltaForge Azure Marketplace packaging"
log "Azure dir : ${AZURE_DIR}"
log "Dist dir  : ${DIST_DIR}"
log "Tiers     : ${TIERS[*]}"

# Prepare a clean staging dir and ensure dist exists.
rm -rf "${STAGE_DIR}" 2>/dev/null
if ! mkdir -p "${STAGE_DIR}"; then
  err "could not create staging dir ${STAGE_DIR}; aborting."
  exit 1
fi
if ! mkdir -p "${DIST_DIR}"; then
  err "could not create dist dir ${DIST_DIR}; aborting."
  exit 1
fi

# Collect one summary line per tier. Using a normal array (no subshell) so the
# results survive the loop.
SUMMARY_LINES=()
HARD_FAILURES=0

for tier in "${TIERS[@]}"; do
  # Validate the tier name against the known set so a typo fails loudly here
  # rather than producing a confusing "bicep not found" later.
  known=0
  for t in "${ALL_TIERS[@]}"; do
    if [ "${tier}" = "${t}" ]; then
      known=1
      break
    fi
  done
  if [ "${known}" -eq 0 ]; then
    warn "unknown tier '${tier}' (expected one of: ${ALL_TIERS[*]}); skipping."
    SUMMARY_LINES+=("${tier}|-|skip-unknown-tier")
    HARD_FAILURES=$((HARD_FAILURES + 1))
    continue
  fi

  line="$(build_tier "${tier}")"
  rc=$?
  # build_tier always echoes exactly one summary line as its last stdout line.
  # Take that last line so any stray stdout from sub-tools cannot corrupt it.
  summary="$(printf '%s\n' "${line}" | tail -n 1)"
  SUMMARY_LINES+=("${summary}")
  if [ "${rc}" -ne 0 ]; then
    HARD_FAILURES=$((HARD_FAILURES + 1))
  fi
done

# --------------------------------------------------------------------------
# Final summary table.
# --------------------------------------------------------------------------
printf '\n'
log "================ Summary ================"
printf '%-14s %-44s %s\n' "TIER" "ZIP" "ARM-TTK FAILED"
printf '%-14s %-44s %s\n' "----" "---" "--------------"
for entry in "${SUMMARY_LINES[@]}"; do
  tier="${entry%%|*}"
  rest="${entry#*|}"
  zip_path="${rest%%|*}"
  count="${rest#*|}"

  # Render the ARM-TTK column. -1 means "not run / unknown".
  case "${count}" in
    -1)        count_display="not run" ;;
    skip-*)    count_display="${count}" ;;
    *)         count_display="${count}" ;;
  esac

  printf '%-14s %-44s %s\n' "${tier}" "${zip_path}" "${count_display}"
done
printf '%s\n' "========================================"

if [ "${HARD_FAILURES}" -gt 0 ]; then
  err "${HARD_FAILURES} tier(s) did not produce a zip. See the log above."
  exit 1
fi

log "All requested tiers packaged. Zips are in ${DIST_DIR}."
log "ARM-TTK failed-test counts above are advisory; a non-zero count does not fail this script."
exit 0
