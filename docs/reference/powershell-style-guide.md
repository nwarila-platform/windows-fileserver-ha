# PowerShell in this repository

The organization defines PowerShell **once**, in
[NWarila/powershell-template](https://github.com/NWarila/powershell-template): the house
style (PSScriptAnalyzer settings + custom rules), the script contract, the pair-testing
convention, and the single reusable workflow matrix that tests every script. The full
contract is that repository's
[docs/reference/pester-pair-testing.md](https://github.com/NWarila/powershell-template/blob/main/docs/reference/pester-pair-testing.md);
nothing here duplicates it. This page records only how this repository plugs into it.

## The three files of every script

| File | Here | Tracked |
|---|---|---|
| `scripts/<Name>.ps1` | The script. House style, Change/NoChange contract, dual transport ($Ansible / JSON). | yes |
| `scripts/<Name>.pester.ps1` | Its self-contained spec (inline `$Ansible` context, inline cmdlet stubs — no imports). | yes |
| `ansible/applications/<role>/files/<Name>.ps1.stub` | Build marker naming the source script. | yes |
| `ansible/applications/<role>/files/<Name>.ps1` | Materialized copy the role executes. | **never** — build artifact |

`scripts/materialize-role-scripts.sh` resolves every stub before the role is linted or run
(`--check` verifies without writing; both modes fail closed on a stub whose name, source, or
spec pairing is wrong). The composed deploy lifecycle runs it as a build step when it lands
(see `docs/explanation/technical-debt.md` TD-001).

## CI

`.github/workflows/powershell.yml` is a thin caller: it triggers only when a `*.ps1` under `scripts/`
changes in a pull request and imports the org's reusable `pester-matrix`
workflow, which discovers every pair under `scripts/` (only `.ps1` files participate; the directory is the generic script home shared with Python and bash tooling) and runs one matrix leg per script
(house analyzer at zero findings, then the spec). Adopting new organizational tests is a pin
bump on that single `uses:` line.

## The local loop

```sh
# Everything CI runs, from a checkout of the org repo:
pwsh -File <powershell-template>/harness/Invoke-PairTests.ps1 -Path scripts

# Materialize role scripts before running/linting the ansible tree:
./scripts/materialize-role-scripts.sh
```

## Ansible-side idiom

Complex Windows mutations are these first-class scripts executed through
`ansible.windows.win_powershell` with typed `parameters:` — never `win_shell` block scalars
(Ansible style guide §5, first-class-PowerShell rule). No `changed_when` on such tasks: the
script's `$Ansible.Changed` verdict is the change report, which is what keeps the play recap
honest — `ok` from a genuine read on a converged host, `changed` with a one-sentence `msg`
otherwise, and drift detail in `.Result` for `-v` runs.
