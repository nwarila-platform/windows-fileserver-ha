#!/usr/bin/env bash
# Runs all contributor-local quality gates from the repository checkout.
#
# Usage: POWERSHELL_TEMPLATE_ROOT=/absolute/path/to/powershell-template ./scripts/verify.sh
set -euo pipefail

if [ -z "${POWERSHELL_TEMPLATE_ROOT:-}" ] || [[ "${POWERSHELL_TEMPLATE_ROOT}" != /* ]]; then
    printf '%s\n' \
        'verify: POWERSHELL_TEMPLATE_ROOT must be an absolute path to a powershell-template' \
        'checkout at the ref pinned in .github/workflows/powershell.yml; supply it before running' >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

printf 'verify: [1/3] yamllint -c .yamllint.yml ansible\n'
yamllint -c .yamllint.yml ansible
printf 'verify: OK yamllint\n'

printf 'verify: [2/3] scripts/materialize-role-scripts.sh --check\n'
scripts/materialize-role-scripts.sh --check
printf 'verify: OK materialize-role-scripts\n'

printf 'verify: [3/3] pwsh Invoke-PairTests.ps1 -Path scripts\n'
pwsh -NoProfile -File "${POWERSHELL_TEMPLATE_ROOT}/harness/Invoke-PairTests.ps1" -Path scripts
printf 'verify: OK powershell-pairs\n'

printf 'verify: all gates passed\n'
exit 0
