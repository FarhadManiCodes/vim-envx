" expand environment variable


let s:suppress_warnings = 0
let s:unset_var_count = 0

" Non-capturing: for matchstrpos() scans that just need match boundaries.
let s:VAR_PATTERN = '\${\w\+}\|\$\w\+'
" Capturing: for substitute() replacements that need submatch(1)/submatch(2).
let s:VAR_PATTERN_CAPTURE = '\${\(\w\+\)}\|\$\(\w\+\)'

function! s:IsVarUnset(varname)
  return expand('$' . a:varname) ==# ('$' . a:varname)
endfunction

" Extract the bare NAME out of a "$NAME" or "${NAME}" match string.
function! s:VarNameFromMatch(full)
  return (a:full[1] ==# '{') ? a:full[2:-2] : a:full[1:]
endfunction

function! s:SetLineIfChanged(lnum, text)
  if getline(a:lnum) !=# a:text
    call setline(a:lnum, a:text)
  endif
endfunction

function! s:ExpandOrKeep(varname, prefix)
  if s:IsVarUnset(a:varname)
    let s:unset_var_count += 1
    if !s:suppress_warnings
      echohl WarningMsg
      echom '⚠️ Environment variable $' . a:varname . ' is not defined'
      echohl None
    endif
    if a:prefix ==# "${"
      return '${' . a:varname . '}'
    else
      return '$' . a:varname
    endif
  endif
  return expand('$' . a:varname)
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

  let l:full = l:match[0]
  let l:start = l:match[1]
  let l:end = l:start + len(l:full)
  let l:varname = s:VarNameFromMatch(l:full)
  let l:prefix = (l:full[1] ==# '{') ? "${" : "$"
  let l:expanded = s:ExpandOrKeep(l:varname, l:prefix)

  " Use strpart to avoid negative indexing issues (e.g., at start of line)
  let l:before = strpart(l:line, 0, l:start)
  let l:after = strpart(l:line, l:end)
  let l:replacement = l:before . l:expanded . l:after
  if l:replacement !=# l:line
    call setline('.', l:replacement)
  endif
endfunction


function! s:ExpandMatch(braced, bare)
  if a:braced !=# ''
    return s:ExpandOrKeep(a:braced, '${')
  endif
  return s:ExpandOrKeep(a:bare, '$')
endfunction

function! s:ExpandEnvVarsInText(text)
  " Single substitute() pass: a var's expanded VALUE is never rescanned for
  " further $VAR references, unlike two chained substitute() calls would.
  return substitute(a:text, s:VAR_PATTERN_CAPTURE,
        \ '\=s:ExpandMatch(submatch(1), submatch(2))', 'g')
endfunction


function! EnvxExpandLine()
  call s:SetLineIfChanged('.', s:ExpandEnvVarsInText(getline('.')))
endfunction


function! EnvxExpandVisual()
  let l:start_line = line("'<")
  let l:end_line = line("'>")

  for lnum in range(l:start_line, l:end_line)
    call s:SetLineIfChanged(lnum, s:ExpandEnvVarsInText(getline(lnum)))
  endfor
endfunction


function! EnvxExpandBuffer()
  let l:save_cursor = getcurpos()
  let s:suppress_warnings = 1
  let s:unset_var_count = 0

  let l:lines = getline(1, '$')
  let l:changed = 0
  for l:i in range(len(l:lines))
    let l:new = s:ExpandEnvVarsInText(l:lines[l:i])
    if l:new !=# l:lines[l:i]
      let l:lines[l:i] = l:new
      let l:changed = 1
    endif
  endfor
  if l:changed
    call setline(1, l:lines)
  endif

  let s:suppress_warnings = 0
  call setpos('.', l:save_cursor)
  if s:unset_var_count > 0
    echohl WarningMsg
    echom '⚠️ ' . s:unset_var_count . ' environment variable(s) were not defined and left unchanged'
    echohl None
  endif
endfunction

let s:env_stub_value = ""
let s:env_stub_active = 0

function! s:EnterInsertAfterMessage()
  " Guard against the 800ms timer firing after the user already left
  " Normal mode on their own (would otherwise feed "i$" as literal text).
  if mode() ==# 'n'
    call feedkeys("i$", 'n')
  endif
endfunction

function! s:ExtractToEnvStubAutoAssign()
  if !has('timers')
    echohl WarningMsg
    echom "Timers not supported in your Vim version."
    echohl None
    return
  endif

  " Save selection to register z
  normal! gv"zy
  let s:env_stub_value = @z
  let s:env_stub_active = 1

  " Delete selected text
  normal! gvd

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
  if s:env_stub_active && s:env_stub_value != ""
    let l:lnum = line('.')
    let l:varname = expand('<cword>')
    if l:varname !~# '^\w\+$'
      echohl WarningMsg
      echom '⚠️ envx: no variable name entered; extraction cancelled (use u to undo)'
      echohl None
    else
      let l:escaped_value = escape(s:env_stub_value, '\"')
      call append(l:lnum - 1, l:varname . '="' . l:escaped_value . '"')
    endif

    let s:env_stub_value = ""
    let s:env_stub_active = 0
  endif
endfunction

xnoremap <leader>evv :<C-u>call <SID>ExtractToEnvStubAutoAssign()<CR>

augroup EnvxExtract
  autocmd!
  autocmd InsertLeave * call <SID>InsertEnvAssignmentAbove()
augroup END

xnoremap <leader>ev :<C-u>call EnvxExpandVisual()<CR>
nnoremap <leader>eev :call EnvxExpandLine()<CR>
nnoremap <leader>ev :call EnvxExpandUnderCursor()<CR>

command! EnvxExpandAll call EnvxExpandBuffer()

" === Highlight $VAR / ${VAR} references that aren't set in the environment ===

highlight default link EnvxUnsetVar WarningMsg

function! s:HighlightUnsetEnvVars()
  if exists('w:envx_match_ids')
    for l:id in w:envx_match_ids
      silent! call matchdelete(l:id)
    endfor
  endif
  let w:envx_match_ids = []

  " Memoize per scan: a var referenced many times in one buffer should only
  " need one expand() lookup, not one per occurrence.
  let l:unset_cache = {}
  let l:lines = getline(1, '$')
  for l:i in range(len(l:lines))
    let l:lnum = l:i + 1
    let l:line = l:lines[l:i]
    let l:idx = 0
    while 1
      let l:match = matchstrpos(l:line, s:VAR_PATTERN, l:idx)
      if l:match[1] == -1
        break
      endif
      let l:full = l:match[0]
      let l:varname = s:VarNameFromMatch(l:full)
      if !has_key(l:unset_cache, l:varname)
        let l:unset_cache[l:varname] = s:IsVarUnset(l:varname)
      endif
      if l:unset_cache[l:varname]
        let l:pattern = '\%' . l:lnum . 'l\%' . (l:match[1] + 1) . 'c' . escape(l:full, '\.*[]^$~/')
        call add(w:envx_match_ids, matchadd('EnvxUnsetVar', l:pattern))
      endif
      let l:idx = l:match[1] + len(l:full)
    endwhile
  endfor
endfunction

augroup EnvxHighlightUnset
  autocmd!
  autocmd BufEnter,TextChanged,InsertLeave * call s:HighlightUnsetEnvVars()
augroup END
