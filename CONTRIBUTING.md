# Contributing

Thanks for taking a look. PRs welcome.

## Useful contributions

- Tested `NV_Modes` strings for other DSC-locked monitors (LG OLEDs, ASUS PG / ROG Swift OLEDs, Samsung Neo / OLED variants).
- Better Task Scheduler event filters for catching driver-installer events specifically.
- AMD equivalent (different registry mechanism, same persistence problem).
- Bugs, edge cases, weird hardware combinations.

## Before opening a PR

1. **Test on a real machine.** Registry edits affect display output — `Set-ItemProperty` typos cause black screens. The script auto-backs up; verify yours works.
2. **Keep ASCII.** PowerShell 5.1 reads `.ps1` files without BOM as ANSI/CP1252. Em-dashes and curly quotes break parsing. Stick to `-`, `'`, `"`.
3. **Check it lints clean.** CI runs PSScriptAnalyzer on PRs. Locally:
   ```powershell
   Install-Module PSScriptAnalyzer -Scope CurrentUser
   Invoke-ScriptAnalyzer -Path .\Set-NvModes.ps1
   ```
4. **Run the script after your change** with `-List` and `-Apply` to confirm nothing exploded.

## Code style

- PowerShell 5.1 compatible (built into Windows 10/11 — no PS 7 dependency).
- Single-file script. No modules, no compiled binaries.
- Verb-Noun function names, approved verbs only (`Get-Verb` to check).
- Idempotent operations — running `-Apply` twice should be a no-op the second time.

## Reporting bugs

Open an issue with:

- Windows version (`winver`)
- GPU and driver version
- Monitor model
- Output of `.\Set-NvModes.ps1 -List`
- Output of `.\Set-NvModes.ps1 -Apply -Verbose` if reproducing a write failure

## License

By submitting a PR, you agree your contribution is licensed under the MIT License (same as the project).
