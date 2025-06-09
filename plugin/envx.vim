" expand environment variable


function! s:ExpandOrKeep(varname, prefix)
  let l:value = expand('$' . a:varname)
  if l:value ==# ('$' . a:varname)
    echohl WarningMsg
    echom '⚠️ Environment variable $' . a:varname . ' is not defined'
    echohl None
    if a:prefix == "${"
      return '${' . a:varname . '}'
    else
      return '$' . a:varname
    endif
  endif
  return l:value
endfunction

function! ExpandEnvVarUnderCursor()
  let l:line = getline('.')
  let l:pos = col('.') - 1  " cursor index, 0-based

  " === 1. Match ${VAR} ===
  let l:match = matchstrpos(l:line, '\${\w\+}', 0)
  while l:match != ['', -1, -1]
        \ && !(l:pos >= l:match[1] && l:pos < l:match[1] + len(l:match[0]))
    let l:next_start = l:match[1] + 1
    let l:match = matchstrpos(l:line, '\${\w\+}', l:next_start)
  endwhile

  if l:match != ['', -1, -1]
    let l:full = l:match[0]
    let l:start = l:match[1]
    let l:end = l:start + len(l:full)
    let l:varname = l:full[2:-2]  " from ${VAR}
  else
    " === 2. Match $VAR ===
    let l:match = matchstrpos(l:line, '\$\w\+', 0)
    while l:match != ['', -1, -1]
          \ && !(l:pos >= l:match[1] && l:pos < l:match[1] + len(l:match[0]))
      let l:next_start = l:match[1] + 1
      let l:match = matchstrpos(l:line, '\$\w\+', l:next_start)
    endwhile

    if l:match != ['', -1, -1]
      let l:full = l:match[0]
      let l:start = l:match[1]
      let l:end = l:start + len(l:full)
      let l:varname = l:full[1:]  " from $VAR
    else
      echohl WarningMsg
      echom "No environment variable under cursor"
      echohl None
      return
    endif
  endif

  " === 3. Expand and validate ===
let l:prefix = (l:full[1] == '{') ? "${" : "$"
let l:expanded = <SID>ExpandOrKeep(l:varname, l:prefix)

  " === 4. Replace text ===
  " Use strpart to avoid negative indexing issues (e.g., at start of line)
  let l:before = strpart(l:line, 0, l:start)
  let l:after = strpart(l:line, l:end)
  let l:replacement = l:before . l:expanded . l:after
  if l:replacement !=# l:line
    call setline('.', l:replacement)
  endif
endfunction


function! ExpandAllEnvVarsInLine()
  let l:line = getline('.')

  " === Expand ${VAR} format ===
  let l:line = substitute(l:line, '\${\(\w\+\)}', '\=s:ExpandOrKeep(submatch(1), "${")', 'g')

  " === Expand $VAR format ===
  let l:line = substitute(l:line, '\$\(\w\+\)', '\=s:ExpandOrKeep(submatch(1), "$")', 'g')

  call setline('.', l:line)
endfunction


function! ExpandEnvVarsInVisual()
  let l:start_line = line("'<")
  let l:end_line = line("'>")

  for lnum in range(l:start_line, l:end_line)
    let l:line = getline(lnum)

    " Expand ${VAR}
    let l:line = substitute(l:line, '\${\(\w\+\)}',
          \ '\=<SID>ExpandOrKeep(submatch(1), "${")', 'g')

    " Expand $VAR
    let l:line = substitute(l:line, '\$\(\w\+\)',
          \ '\=<SID>ExpandOrKeep(submatch(1), "$")', 'g')

    call setline(lnum, l:line)
  endfor
endfunction

let g:env_stub_value = ""
let g:env_stub_active = 0

function! s:EnterInsertAfterMessage()
  call feedkeys("i$", 'n')
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
  let g:env_stub_value = @z
  let g:env_stub_active = 1

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
  if g:env_stub_active && g:env_stub_value != ""
    let lnum = line('.')
    let varname = expand('<cword>')
    call append(lnum - 1, varname . '="' . g:env_stub_value . '"')

    let g:env_stub_value = ""
    let g:env_stub_active = 0
  endif
endfunction

xnoremap <leader>evv :<C-u>call <SID>ExtractToEnvStubAutoAssign()<CR>
autocmd InsertLeave * call <SID>InsertEnvAssignmentAbove()

xnoremap <leader>ev :<C-u>call ExpandEnvVarsInVisual()<CR>
nnoremap <leader>eev :call ExpandAllEnvVarsInLine()<CR>
nnoremap <leader>ev :call ExpandEnvVarUnderCursor()<CR>
