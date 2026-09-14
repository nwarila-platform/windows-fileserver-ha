#!/usr/bin/env bash
# Runs the local YAML, materialization, and PowerShell-pair checks from the repository checkout.
#
# Usage: POWERSHELL_TEMPLATE_ROOT=/absolute/path/to/powershell-template ./scripts/verify.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "${POWERSHELL_TEMPLATE_ROOT:-}" ] || [[ "${POWERSHELL_TEMPLATE_ROOT}" != /* ]]; then
    printf '%s\n' \
        'verify: POWERSHELL_TEMPLATE_ROOT must be an absolute powershell-template checkout' >&2
    exit 1
fi

mapfile -t template_pins < <(
    sed -nE "s/^[[:space:]]*template-ref:[[:space:]]*'([0-9a-f]{40})'.*/\\1/p" \
        "${ROOT}/.github/workflows/powershell.yml" |
        LC_ALL=C sort -u
)
if [ "${#template_pins[@]}" -ne 1 ]; then
    printf '%s\n' \
        'verify: powershell.yml must declare exactly one unique full-SHA template-ref' >&2
    exit 1
fi

TEMPLATE_PIN="${template_pins[0]}"
HARNESS="${POWERSHELL_TEMPLATE_ROOT}/harness/Invoke-PairTests.ps1"
[ -f "${HARNESS}" ] || {
    printf 'verify: missing harness: %s\n' "${HARNESS}" >&2
    exit 1
}
git -C "${POWERSHELL_TEMPLATE_ROOT}" rev-parse --verify HEAD >/dev/null 2>&1 || {
    printf 'verify: not a Git checkout: %s\n' "${POWERSHELL_TEMPLATE_ROOT}" >&2
    exit 1
}
actual_pin="$(git -C "${POWERSHELL_TEMPLATE_ROOT}" rev-parse HEAD)"
[ "${actual_pin}" = "${TEMPLATE_PIN}" ] || {
    printf 'verify: harness checkout is at %s, expected %s\n' \
        "${actual_pin}" "${TEMPLATE_PIN}" >&2
    exit 1
}
[ -z "$(git -C "${POWERSHELL_TEMPLATE_ROOT}" status \
    --porcelain=v1 --untracked-files=all)" ] || {
    printf '%s\n' 'verify: harness checkout is not clean' >&2
    exit 1
}
cd "${ROOT}"

printf 'verify: [1/3] yamllint -c .yamllint.yml ansible\n'
yamllint -c .yamllint.yml ansible
printf 'verify: OK yamllint\n'

printf 'verify: [2/3] scripts/materialize-role-scripts.sh --check\n'
scripts/materialize-role-scripts.sh --check
printf 'verify: OK materialize-role-scripts\n'

printf 'verify: [3/3] pwsh Invoke-PairTests.ps1 -Path scripts\n'
pwsh -NoProfile -File "${HARNESS}" -Path scripts
printf 'verify: OK powershell-pairs\n'

printf 'verify: selected checks passed\n'
exit 0
