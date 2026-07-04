# Contributing

## Implementations

There are two parallel implementations that must be kept in feature parity:

| File                | Platform | Language   |
| ------------------- | -------- | ---------- |
| `src/backdrop.sh`   | Linux    | Bash       |
| `src/backdrop.psm1` | Windows  | PowerShell |

Changes to commands, sources, config keys, or behaviour should be applied to both files.

## Setup

After cloning, install the Node dev dependencies:

```bash
npm install
```

This registers the git hooks via `simple-git-hooks`:

- **pre-commit** - runs Prettier, shfmt, ShellCheck, and BATS against the bash implementation, and PSScriptAnalyzer and Pester against the PowerShell implementation
- **prepare-commit-msg** - launches an interactive conventional commit prompt (`czg`)

You also need [**shellcheck**](https://github.com/koalaman/shellcheck) and [**shfmt**](https://github.com/mvdan/sh) installed locally for `npm run lint:sh` / `npm run test:sh` to work:

```bash
# Ubuntu/Debian
sudo apt install shellcheck shfmt

# macOS
brew install shellcheck shfmt
```

For the PowerShell side, you need [**PowerShell 7+**](https://github.com/PowerShell/PowerShell) (`pwsh`) installed. Then install PSScriptAnalyzer and Pester:

```bash
npm run install:ps
```

This is required for `npm run lint:ps` / `npm run test:ps` to work. Since the pre-commit hook runs `npm run lint` and `npm run test` (which cover both implementations), it won't pass without these installed.

## Commits

Commits must follow the [Conventional Commits](https://www.conventionalcommits.org/) spec. The pre-commit hook will guide you through it. You can also run the prompt manually:

```bash
npm run commit
```

## Testing

To run the full test suite (ShellCheck + BATS, plus Pester for PowerShell):

```bash
npm test
```

To run just one implementation's tests:

```bash
npm run test:sh
```

or

```bash
npm run test:ps
```

Tests live in `test/backdrop.bats` and cover the pure and file-I/O functions in `src/backdrop.sh`; things like config read/write, source validation, image dimension detection, wallpaper option selection, metadata read/write, version comparison, and source rotation. Source resolver functions are tested using a stub `curl` script injected via `PATH`. The `_rotation_index` helper takes a unix timestamp as a parameter rather than calling `date`, so rotation tests run without needing to stub `date`; `get_active_source` integration tests stub `date` via `PATH` in the same way as `curl`.

The PowerShell module (`src/backdrop.psm1`) is tested with [Pester 5](https://pester.dev/). Tests live in `test/backdrop.tests.ps1` and run via `Invoke-Pester test/backdrop.tests.ps1`. The `Get-UnixTimestamp` helper is extracted so rotation tests can mock it without stubbing `[DateTimeOffset]::UtcNow` directly.

## Image metadata

**Bash (`backdrop.sh`):** each `resolve_<source>()` function emits `META_TITLE:`, `META_DESC:`, and `META_URL:` prefixed lines before the image URLs it returns. `apply_wallpaper` strips these out to get the candidate URL list, then stores the values in the `META_TITLE`/`META_DESC`/`META_URL` globals.

**PowerShell (`backdrop.psm1`):** each `Resolve-<Source>` function returns a hashtable with `Title`, `Desc`, `Url`, and `ImageUrls` keys directly, avoiding the stdout multiplexing used by the bash version.

In both implementations, after a successful download the metadata is saved to a `<source>-<date>.meta` file (key = value format) alongside the `.jpg`. The `status` command reads this file to display image title, description, and URL. Old `.meta` files are pruned on the same 14-day schedule as wallpaper images.

## Linting

To check formatting:

```bash
npm run lint
```

To check just one implementation:

```bash
npm run lint:sh
```

or

```bash
npm run lint:ps
```

To auto-fix formatting:

```bash
npm run lint:fix
```

`lint:ps:fix` uses `Invoke-ScriptAnalyzer -Fix`, which only corrects rules that support automatic fixes (mostly formatting/whitespace). Violations like `PSAvoidUsingCmdletAliases` still need to be fixed by hand; re-run `npm run lint:ps` afterward to see what's left.
