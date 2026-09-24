# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

vim-envx is a single-file Vim/Neovim plugin (`plugin/envx.vim`, plain Vimscript) that expands and extracts shell-style environment variable expressions (`$VAR`, `${VAR}`) inside buffers. There is no build system, package manifest, linter, or test suite.

It is consumed by the owner's dotfiles: vim-plug in `~/dotfiles/vim/config/plugins.vim` and lazy.nvim in `~/dotfiles/nvim/lua/plugins/data-tools.lua` (whose `keys` table must match the default mappings here). Both track `master`; changes reach them only after `git push` plus `:PlugUpdate` / `:Lazy update`.

## Testing

No test suite. Verify changes in headless Neovim against a scratch file, e.g.:

```sh
nvim --headless -u NONE -c 'source plugin/envx.vim' -c 'edit /tmp/t.sh' -c 'EnvxExpandAll' -c 'echo getline(1)' -c 'qa!'
```

Pitfalls when scripting tests:
- Use `normal` (no bang) to trigger the plugin's own mappings; `normal!` bypasses them.
- Visual marks are only set after leaving Visual mode: `execute "normal! ggVG\<Esc>"`.
- `s:` functions/variables can't be reached from `-c`; test through the public `Envx*` functions or mappings.
- The extract flow's 800 ms `timer_start` + `feedkeys` step can't be driven reliably headless; verify it by hand.

## Architecture

Public entry points (global, `Envx`-prefixed), each exposed as a `<Plug>` mapping with a default key installed only if the user hasn't mapped that `<Plug>` target (`hasmapto`):

- `EnvxExpandUnderCursor()` — `<Plug>(EnvxExpandUnderCursor)`, `n <leader>ev`
- `EnvxExpandLine()` — `<Plug>(EnvxExpandLine)`, `n <leader>eev`
- `EnvxExpandVisual()` — `<Plug>(EnvxExpandVisual)`, `x <leader>ev`
- `EnvxExpandBuffer()` — `:EnvxExpandAll`
- `s:ExtractToEnvStubAutoAssign()` — `<Plug>(EnvxExtract)`, `x <leader>ex`

Key invariants:
- **Single definition of "unset":** `s:IsVarUnset()` (`expand('$X') ==# '$X'`). Both expansion (`s:ExpandOrKeep`) and highlighting use it; don't re-implement the check.
- **Unset vars are preserved**, never collapsed to empty. `s:ExpandOrKeep` returns the original `$VAR`/`${VAR}` text.
- **Single-pass substitution:** `s:ExpandEnvVarsInText` uses one `substitute()` over `s:VAR_PATTERN_CAPTURE`, so an expanded value containing `$word` is never rescanned. Don't split it into chained passes.
- **Bulk paths go through `s:ExpandRange()`**, which suppresses per-var warnings and prints one summary (avoids hit-enter prompt cascades), writes with a single `setline()` (one undo step), and skips the write if nothing changed. Only the under-cursor path warns per variable.
- **Extract flow** is two-phase: yank the selection into script-local `s:env_stub_value` (registers `z` and unnamed are restored afterwards), delete it, then after an 800 ms timer feed `i$` so the user types the name; an `InsertLeave` autocmd reads `<cword>` and appends `NAME="value"` (quotes/backslashes escaped) above. Any abort path must go through `s:CancelExtraction()` so the stub never lingers into a later, unrelated `InsertLeave`.
- **Unset-var highlighting** (`EnvxUnsetVar` group, linked to `WarningMsg`) does a full-buffer rescan on `BufEnter`/`TextChanged`/`InsertLeave`, with window-local match IDs in `w:envx_match_ids`. The full rescan is an accepted trade-off for the small shell/env files this targets.

Conventions: the file starts with a `g:loaded_envx` guard and a `cpoptions` save/restore. Every autocmd lives in an `augroup` with `autocmd!`. Use `==#`/`!=#` for string comparisons.
