" expand environment variable

if exists('g:loaded_envx')
  finish
endif
let g:loaded_envx = 1

let s:save_cpo = &cpo
set cpo&vim

let s:suppress_warnings = 0
let s:unset_var_count = 0

" Matches $NAME, ${NAME} and ${NAME:-default}. Defaults can't contain braces,
" so nested ${A:-${B}} isn't matched as a whole.
let s:VAR_PATTERN = '\${\w\+\%(:-[^{}]*\)\=}\|\$\w\+'

function! s:IsVarUnset(varname)
  return !exists('$' . a:varname)
endfunction

" Raw value via eval(), not expand(): Neovim's expand('$X') also globs the
" value, turning X='*.txt' into a file list. NAME is \w\+, so eval is safe.
function! s:EnvValue(varname)
  return eval('$' . a:varname)
endfunction

" Parse a s:VAR_PATTERN match into {name, has_default, default}.
function! s:ParseRef(full)
  let l:m = matchlist(a:full, '^\${\(\w\+\)\(:-\([^{}]*\)\)\=}$')
  if empty(l:m)
    return {'name': a:full[1:], 'has_default': 0, 'default': ''}
  endif
  return {'name': l:m[1], 'has_default': l:m[2] !=# '', 'default': l:m[3]}
endfunction

" Replacement text for one reference. Like bash, ${NAME:-default} uses the
" (itself expanded) default when NAME is unset or empty. A plain reference
" to an unset variable is kept as written, never collapsed to empty.
function! s:ExpandRef(full)
  let l:ref = s:ParseRef(a:full)
  let l:unset = s:IsVarUnset(l:ref.name)
  if l:ref.has_default
    let l:value = l:unset ? '' : s:EnvValue(l:ref.name)
    return l:value ==# '' ? s:ExpandEnvVarsInText(l:ref.default) : l:value
  endif
  if l:unset
    let s:unset_var_count += 1
    if !s:suppress_warnings
      echohl WarningMsg
      echom '⚠️ Environment variable $' . l:ref.name . ' is not defined'
      echohl None
    endif
    return a:full
  endif
  return s:EnvValue(l:ref.name)
endfunction

function! EnvxExpandUnderCursor()
  let l:line = getline('.')
  let l:pos = col('.') - 1  " cursor index, 0-based

  " Find the $VAR/${VAR} match (if any) that contains the cursor.
  let l:match = matchstrpos(l:line, s:VAR_PATTERN, 0)
  while l:match[1] != -1
        \ && !(l:pos >= l:match[1] && l:pos < l:match[1] + len(l:match[0]))
    let l:match = matchstrpos(l:line, s:VAR_PATTERN, l:match[1] + 1)
  endwhile

  if l:match[1] == -1
    echohl WarningMsg
    echom "No environment variable under cursor"
    echohl None
    return
  endif

  let l:start = l:match[1]
  let l:end = l:start + len(l:match[0])
  " strpart avoids negative-index surprises at the start of the line
  let l:replacement = strpart(l:line, 0, l:start)
        \ . s:ExpandRef(l:match[0]) . strpart(l:line, l:end)
  if l:replacement !=# l:line
    call setline('.', l:replacement)
  endif
endfunction


function! s:ExpandEnvVarsInText(text)
  " Single substitute() pass: a var's expanded VALUE is never rescanned for
  " further $VAR references, unlike two chained substitute() calls would.
  return substitute(a:text, s:VAR_PATTERN, '\=s:ExpandRef(submatch(0))', 'g')
endfunction


" Bulk paths report one summary instead of a warning per variable, which
" would otherwise stack up into hit-enter prompts.
function! s:ExpandRange(first, last)
  let s:suppress_warnings = 1
  let s:unset_var_count = 0
  try
    let l:lines = getline(a:first, a:last)
    let l:new = map(copy(l:lines), 's:ExpandEnvVarsInText(v:val)')
    if l:new !=# l:lines
      call setline(a:first, l:new)
    endif
  finally
    let s:suppress_warnings = 0
  endtry
  if s:unset_var_count > 0
    echohl WarningMsg
    echom '⚠️ ' . s:unset_var_count . ' environment variable(s) not defined, left unchanged'
    echohl None
  endif
endfunction

function! EnvxExpandLine()
  call s:ExpandRange(line('.'), line('.'))
endfunction

function! EnvxExpandVisual()
  call s:ExpandRange(line("'<"), line("'>"))
endfunction

function! EnvxExpandBuffer()
  call s:ExpandRange(1, line('$'))
endfunction

let s:env_stub_value = ""
let s:env_stub_active = 0

function! s:CancelExtraction()
  let s:env_stub_value = ""
  let s:env_stub_active = 0
  echohl WarningMsg
  echom '⚠️ envx: extraction cancelled (use u to undo)'
  echohl None
endfunction

function! s:EnterInsertAfterMessage()
  " If the user left Normal mode during the delay, feeding "i$" would insert
  " literal text, and leaving the stub active would fire on some later,
  " unrelated InsertLeave.
  if mode() ==# 'n'
    call feedkeys("i$", 'n')
  else
    call s:CancelExtraction()
  endif
endfunction

function! s:ExtractToEnvStubAutoAssign()
  if !has('timers')
    echohl WarningMsg
    echom "Timers not supported in your Vim version."
    echohl None
    return
  endif

  " Yank via register z, then restore z and the unnamed register (setreg()
  " on z also repoints unnamed) so the user's registers survive.
  let l:save_z = [getreg('z'), getregtype('z')]
  let l:save_unnamed = [getreg('"'), getregtype('"')]
  normal! gv"zy
  let s:env_stub_value = @z
  let s:env_stub_active = 1
  call setreg('z', l:save_z[0], l:save_z[1])
  call setreg('"', l:save_unnamed[0], l:save_unnamed[1])

  normal! gv"_d

  " Force screen update
  redraw

  " Show the message clearly
  echohl ModeMsg
  echom "↳ Defining env variable name..."
  echohl None

  " Delay entry to insert mode so message is visible
  call timer_start(800, { -> <SID>EnterInsertAfterMessage() })
endfunction

function! s:InsertEnvAssignmentAbove()
  if !s:env_stub_active || s:env_stub_value ==# ""
    return
  endif
  let l:varname = expand('<cword>')
  if l:varname !~# '^\w\+$'
    call s:CancelExtraction()
    return
  endif
  call append(line('.') - 1, l:varname . '="' . escape(s:env_stub_value, '\"') . '"')
  let s:env_stub_value = ""
  let s:env_stub_active = 0
endfunction

augroup EnvxExtract
  autocmd!
  autocmd InsertLeave * call <SID>InsertEnvAssignmentAbove()
augroup END

" <Plug> mappings: stable targets that survive default-keybinding changes.
" Rebind by mapping to the <Plug> name instead of editing this file, e.g.:
"   xmap <leader>myex <Plug>(EnvxExtract)
xnoremap <silent> <Plug>(EnvxExpandVisual) :<C-u>call EnvxExpandVisual()<CR>
nnoremap <silent> <Plug>(EnvxExpandLine) :call EnvxExpandLine()<CR>
nnoremap <silent> <Plug>(EnvxExpandUnderCursor) :call EnvxExpandUnderCursor()<CR>
xnoremap <silent> <Plug>(EnvxExtract) :<C-u>call <SID>ExtractToEnvStubAutoAssign()<CR>

if !hasmapto('<Plug>(EnvxExpandVisual)', 'x')
  xmap <leader>ev <Plug>(EnvxExpandVisual)
endif
if !hasmapto('<Plug>(EnvxExpandLine)', 'n')
  nmap <leader>eev <Plug>(EnvxExpandLine)
endif
if !hasmapto('<Plug>(EnvxExpandUnderCursor)', 'n')
  nmap <leader>ev <Plug>(EnvxExpandUnderCursor)
endif
if !hasmapto('<Plug>(EnvxExtract)', 'x')
  xmap <leader>ex <Plug>(EnvxExtract)
endif

command! EnvxExpandAll call EnvxExpandBuffer()

" === Highlight $VAR / ${VAR} references that aren't set in the environment ===

highlight default link EnvxUnsetVar WarningMsg

" Filetypes where $VAR usually means "an environment variable". Elsewhere
" (markdown math like $E = mc^2$, C++ macros, ...) the highlight would be
" noise. Users can replace the list with g:envx_highlight_filetypes, or turn
" the feature off with g:envx_highlight_unset = 0.
let s:DEFAULT_HIGHLIGHT_FILETYPES = [
      \ 'sh', 'bash', 'zsh', 'ksh', 'dockerfile', 'yaml', 'env', 'dotenv']

" Shell scripts define their own variables, which the editor's environment
" doesn't know about; for these filetypes such names are not flagged.
let s:SHELL_FILETYPES = ['sh', 'bash', 'zsh', 'ksh']

" Buffers longer than this are not scanned: every scan is whole-buffer.
let s:DEFAULT_HIGHLIGHT_MAX_LINES = 2000

function! s:FiletypeMatches(list)
  for l:ft in split(&filetype, '\.')
    if index(a:list, l:ft) >= 0
      return 1
    endif
  endfor
  return 0
endfunction

function! s:HighlightEnabled()
  return get(g:, 'envx_highlight_unset', 1)
        \ && s:FiletypeMatches(get(g:, 'envx_highlight_filetypes', s:DEFAULT_HIGHLIGHT_FILETYPES))
        \ && line('$') <= get(g:, 'envx_highlight_max_lines', s:DEFAULT_HIGHLIGHT_MAX_LINES)
endfunction

" Names a shell buffer defines itself: `NAME=`, `NAME+=`, `NAME[i]=`,
" `for NAME in`, and the operands of read/local/declare/typeset/readonly/
" export (`local -a st`, `local n=0 ans`, `read -rp "prompt" ans`).
" A heuristic, not a parser. Submatch 1/2/3 = assigned name / for-loop name /
" rest of the line after the keyword.
let s:SHELL_DEFINE_PATTERN = '\%(^\|\n\|[[:space:];&|(]\)\%('
      \ . '\(\h\w*\)\%(\[[^]\n]*\]\)\=+\==\%(=\)\@!'
      \ . '\|for\s\+\(\h\w*\)\s\+in\>'
      \ . '\|\%(read\|local\|declare\|typeset\|readonly\|export\)\s\+\([^\n]*\)\)'

" Closed shell constructs, leftmost first: an escaped char, '...' or "...".
let s:SHELL_CLOSED_QUOTES = '\\.\|''[^'']*''\|"\%(\\.\|[^"\\]\)*"'

let s:shell_defined = {}

" Operands of read/local/...: drop quoted strings (prompts, values), stop at
" the first command separator, then every token that starts with a name
" (`ans`, `changed=0`) is a definition; options (`-rp`) and `$x` are not.
function! s:RecordShellOperands(operands)
  let l:text = substitute(a:operands, s:SHELL_CLOSED_QUOTES, ' ', 'g')
  let l:text = substitute(l:text, '[;|&#].*', '', '')
  for l:tok in split(l:text)
    let l:name = matchstr(l:tok, '^\h\w*')
    if l:name !=# ''
      let s:shell_defined[l:name] = 1
    endif
  endfor
endfunction

function! s:RecordShellNames(assigned, forname, operands)
  for l:n in [a:assigned, a:forname]
    if l:n !=# ''
      let s:shell_defined[l:n] = 1
    endif
  endfor
  call s:RecordShellOperands(a:operands)
  return ''
endfunction

" One substitute() over the whole text (lines joined with "\n"): the regex
" scan runs in C and only the (few) definitions call back into Vimscript.
" Matching per line instead measured about twice as slow.
function! s:ShellDefinedNames(lines)
  let s:shell_defined = {}
  call substitute(join(a:lines, "\n"), s:SHELL_DEFINE_PATTERN,
        \ '\=s:RecordShellNames(submatch(1), submatch(2), submatch(3))', 'g')
  return s:shell_defined
endfunction

" Is byte index `col` of a shell line inside '...'? A shell never expands $VAR
" there (sed -n '3,$p', awk and jq programs). Look at the text from `from` to
" `col`: strip the closed constructs, then an unclosed ' that comes before any
" unclosed " or a comment # means yes.
function! s:InSingleQuotes(line, from, col)
  let l:before = substitute(strpart(a:line, a:from, a:col - a:from), s:SHELL_CLOSED_QUOTES, '', 'g')
  return matchstr(l:before, '\%(^\|\s\)#\|[''"]') ==# "'"
endfunction

" Single-quoted strings that run over several lines (jq/awk programs). Returns
" a list indexed by line: the byte index where the carried-in string ends on
" that line (len+1 for a line wholly inside it), or 0 for none. A string
" that isn't closed within s:SQ_MAX_LINES lines is assumed to be a stray
" apostrophe (heredoc text, ...) and ignored, so a mistake stays local.
let s:SQ_MAX_LINES = 40

function! s:SingleQuoteCarry(lines)
  let l:n = len(a:lines)
  let l:carry = repeat([0], l:n)
  let l:i = 0
  let l:from = 0
  while l:i < l:n
    let l:line = a:lines[l:i]
    if (l:from == 0 && stridx(l:line, "'") < 0)
          \ || !s:InSingleQuotes(l:line, l:from, len(l:line))
      let l:i += 1
      let l:from = 0
      continue
    endif
    " Opens a ' that this line doesn't close: look for the closing line.
    let l:j = l:i + 1
    while l:j < l:n && l:j - l:i <= s:SQ_MAX_LINES && stridx(a:lines[l:j], "'") < 0
      let l:j += 1
    endwhile
    if l:j >= l:n || l:j - l:i > s:SQ_MAX_LINES
      let l:i += 1
      let l:from = 0
      continue
    endif
    for l:k in range(l:i + 1, l:j - 1)
      let l:carry[l:k] = len(a:lines[l:k]) + 1
    endfor
    let l:close = stridx(a:lines[l:j], "'") + 1
    let l:carry[l:j] = l:close
    let l:i = l:j
    let l:from = l:close
  endwhile
  return l:carry
endfunction

function! s:HighlightUnsetEnvVars()
  " Always clear first: window-local matches outlive the buffer shown in
  " the window, and the filetype/switch may have changed since the last scan.
  if exists('w:envx_match_ids')
    for l:id in w:envx_match_ids
      silent! call matchdelete(l:id)
    endfor
  endif
  let w:envx_match_ids = []

  if !s:HighlightEnabled()
    return
  endif

  let l:is_shell = s:FiletypeMatches(s:SHELL_FILETYPES)
  let l:lines = getline(1, '$')
  let l:assigned = v:null  " built lazily, only if a candidate shows up
  let l:carry = v:null

  " Memoize per scan: a var referenced many times in one buffer should only
  " need one exists() lookup, not one per occurrence.
  let l:unset_cache = {}
  for l:i in range(len(l:lines))
    let l:lnum = l:i + 1
    let l:line = l:lines[l:i]
    if stridx(l:line, '$') < 0
      continue
    endif
    let l:idx = 0
    while 1
      let l:match = matchstrpos(l:line, s:VAR_PATTERN, l:idx)
      if l:match[1] == -1
        break
      endif
      let l:full = l:match[0]
      let l:ref = s:ParseRef(l:full)
      let l:idx = l:match[1] + len(l:full)
      " A ${NAME:-default} reference has a fallback, so it's never flagged.
      " Digit-only names ($1, $10) and $_ are positional/special parameters,
      " never environment variables.
      if l:ref.has_default || l:ref.name =~# '^\%(\d\+\|_\)$'
        continue
      endif
      if !has_key(l:unset_cache, l:ref.name)
        let l:unset_cache[l:ref.name] = s:IsVarUnset(l:ref.name)
      endif
      if !l:unset_cache[l:ref.name]
        continue
      endif
      if l:is_shell
        if l:assigned is v:null
          let l:assigned = s:ShellDefinedNames(l:lines)
        endif
        if has_key(l:assigned, l:ref.name)
          continue
        endif
        if l:carry is v:null
          let l:carry = s:SingleQuoteCarry(l:lines)
        endif
        if l:carry[l:i] > l:match[1]
              \ || s:InSingleQuotes(l:line, l:carry[l:i], l:match[1])
          continue
        endif
      endif
      let l:pattern = '\%' . l:lnum . 'l\%' . (l:match[1] + 1) . 'c\V' . escape(l:full, '\')
      call add(w:envx_match_ids, matchadd('EnvxUnsetVar', l:pattern))
    endwhile
  endfor
endfunction

augroup EnvxHighlightUnset
  autocmd!
  autocmd BufEnter,FileType,TextChanged,InsertLeave * call s:HighlightUnsetEnvVars()
augroup END

let &cpo = s:save_cpo
unlet s:save_cpo
