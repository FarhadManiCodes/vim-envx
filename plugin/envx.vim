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
  return expand('$' . a:varname) ==# ('$' . a:varname)
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
    let l:value = l:unset ? '' : expand('$' . l:ref.name)
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
  return expand('$' . l:ref.name)
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
      let l:ref = s:ParseRef(l:full)
      " A ${NAME:-default} reference has a fallback, so it's never flagged.
      if !l:ref.has_default
        if !has_key(l:unset_cache, l:ref.name)
          let l:unset_cache[l:ref.name] = s:IsVarUnset(l:ref.name)
        endif
        if l:unset_cache[l:ref.name]
          let l:pattern = '\%' . l:lnum . 'l\%' . (l:match[1] + 1) . 'c\V' . escape(l:full, '\')
          call add(w:envx_match_ids, matchadd('EnvxUnsetVar', l:pattern))
        endif
      endif
      let l:idx = l:match[1] + len(l:full)
    endwhile
  endfor
endfunction

augroup EnvxHighlightUnset
  autocmd!
  autocmd BufEnter,TextChanged,InsertLeave * call s:HighlightUnsetEnvVars()
augroup END

let &cpo = s:save_cpo
unlet s:save_cpo
