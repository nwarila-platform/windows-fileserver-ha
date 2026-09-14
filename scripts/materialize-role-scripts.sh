#!/usr/bin/env bash
# Resolves every PowerShell stub marker under the role trees (org three-file
# convention: powershell-template docs/reference/pester-pair-testing.md §1).
#
# A role that executes a first-class PowerShell script carries
# files/<Name>.ps1.stub instead of the script itself; the script is developed,
# reviewed, and pair-tested once under scripts/. This build step copies each
# stub's source script to files/<Name>.ps1 so the role runs effortlessly. The
# materialized copies are build artifacts: the default-deny .gitignore never
# allowlists them, so they cannot be committed.
#
# Fail-closed contract, checked for EVERY stub before any copy:
#   * stub content (comments/blank lines stripped) is exactly one repo-relative
#     source path under scripts/, with no '..' and no symlink out of the tree;
#   * the source exists, and its basename + '.stub' equals the stub's basename,
#     so a copy-pasted stub pointing at the wrong script dies loudly;
#   * the source has a sibling <Name>.pester.ps1 spec — an untested script
#     never reaches a role.
#
# Usage: scripts/materialize-role-scripts.sh [--check]
#   --check  verify every stub resolves and every materialized copy is current,
#            without writing anything (CI/lint mode).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_ONLY=0
case "$#" in
    0) CHECK_ONLY=0 ;;
    1)
        [ "$1" = '--check' ] || {
            printf 'usage: %s [--check]\n' "$0" >&2
            exit 2
        }
        CHECK_ONLY=1
        ;;
    *)
        printf 'usage: %s [--check]\n' "$0" >&2
        exit 2
        ;;
esac

FAILED=0
fail() {
    printf 'materialize-role-scripts: %s\n' "$1" >&2
    FAILED=1
}

mapfile -t stubs < <(find "${ROOT}/ansible/applications" -type f -name '*.ps1.stub' | sort)

if [ "${#stubs[@]}" -eq 0 ]; then
    printf 'materialize-role-scripts: no stubs found; nothing to do\n'
    exit 0
fi

# Pass 1 -- validate EVERY stub before anything is copied, so a bad stub anywhere fails the build
# with nothing materialized, and so a source is proven to live under scripts/ of THIS checkout:
# a stub naming '../elsewhere/x.ps1', or a symlink out of the tree, would otherwise route an
# unreviewed script around the pair matrix.
scripts_root="$(cd "${ROOT}/scripts" && pwd -P)"
declare -a plan=()
for stub in "${stubs[@]}"; do
    rel_stub="${stub#"${ROOT}"/}"

    mapfile -t lines < <(grep -vE '^[[:space:]]*(#|$)' "${stub}" || true)
    if [ "${#lines[@]}" -ne 1 ]; then
        fail "${rel_stub}: expected exactly one source path line, found ${#lines[@]}"
        continue
    fi

    source_rel="$(printf '%s' "${lines[0]}" | tr -d '[:space:]')"
    case "${source_rel}" in
        scripts/*) ;;
        *) fail "${rel_stub}: source '${source_rel}' must be a repo-relative path under scripts/"; continue ;;
    esac
    case "/${source_rel}/" in
        */../*) fail "${rel_stub}: source '${source_rel}' must not contain '..'"; continue ;;
    esac
    source_abs="${ROOT}/${source_rel}"
    expected_stub_name="$(basename "${source_rel}").stub"

    if [ "$(basename "${stub}")" != "${expected_stub_name}" ]; then
        fail "${rel_stub}: names '${source_rel}' but a stub for it must be called '${expected_stub_name}'"
        continue
    fi
    if [ ! -f "${source_abs}" ]; then
        fail "${rel_stub}: source '${source_rel}' does not exist"
        continue
    fi
    # Resolve symlinks and prove the real file sits under scripts/ of this checkout -- in any
    # subdirectory of it, which is why the test is a prefix and not a basename.
    source_real="$(cd "$(dirname "${source_abs}")" && pwd -P)/$(basename "${source_abs}")"
    case "${source_real}" in
        "${scripts_root}"/*) ;;
        *) fail "${rel_stub}: source '${source_rel}' resolves outside scripts/ (symlink or path escape)"; continue ;;
    esac
    if [ -L "${source_abs}" ]; then
        fail "${rel_stub}: source '${source_rel}' is a symlink; the script itself must live under scripts/"
        continue
    fi
    if [ ! -f "${source_abs%.ps1}.pester.ps1" ]; then
        fail "${rel_stub}: source '${source_rel}' has no sibling .pester.ps1 spec; an untested script never reaches a role"
        continue
    fi

    plan+=("${stub}|${source_abs}|${source_rel}")
done

if [ "${FAILED}" -ne 0 ]; then
    printf 'materialize-role-scripts: validation failed; nothing materialized\n' >&2
    exit "${FAILED}"
fi

# Pass 2 -- copy (or check) only once every stub has been validated.
for entry in "${plan[@]}"; do
    stub="${entry%%|*}"; rest="${entry#*|}"
    source_abs="${rest%%|*}"; source_rel="${rest#*|}"
    rel_stub="${stub#"${ROOT}"/}"
    target="${stub%.stub}"
    rel_target="${target#"${ROOT}"/}"
    # A destination that is a symlink is refused in both modes: cp and cmp would follow it, so a
    # planted link could make --check approve a file outside the tree or make a copy overwrite one.
    if [ -L "${target}" ]; then
        fail "${rel_target}: is a symlink; refusing to materialize over or check through it"
        continue
    fi
    if [ "${CHECK_ONLY}" -eq 1 ]; then
        # The materialized copy is a BUILD-TREE artifact: its absence here is the normal,
        # clean state of a source checkout. Only an existing-but-stale copy is an error,
        # because a stale copy is what actually executes.
        if [ ! -f "${target}" ]; then
            printf 'materialize-role-scripts: OK %s (stub resolves; not materialized — clean source tree)\n' "${rel_stub}"
        elif ! cmp -s "${source_abs}" "${target}"; then
            fail "${rel_target}: stale; differs from '${source_rel}' — re-run scripts/materialize-role-scripts.sh or delete the copy"
        else
            printf 'materialize-role-scripts: OK %s (materialized and current)\n' "${rel_target}"
        fi
    else
        # Written beside the target and moved into place, so a reader never sees a half-copied
        # script and an interrupted run leaves either the old copy or the new one, never a stub.
        cp "${source_abs}" "${target}.tmp.$$"
        mv -f "${target}.tmp.$$" "${target}"
        printf 'materialize-role-scripts: %s <- %s\n' "${rel_target}" "${source_rel}"
    fi
done

exit "${FAILED}"
