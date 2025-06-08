" expand environment variable

function! ExpandEnvVarUnderCursor()
  let l:line = getline('.')
  let l:pos = col('.') - 1  " cursor index, 0-based

  " Try to match ${VAR} format first
  let l:match = matchstrpos(l:line, '\${\w\+}', 0)
  while l:match != ['', -1, -1]
        \ && !(l:pos >= l:match[1] && l:pos < l:match[1] + len(l:match[0]))
    " Try next match
    let l:next_start = l:match[1] + 1
    let l:match = matchstrpos(l:line, '\${\w\+}', l:next_start)
  endwhile

  if l:match != ['', -1, -1]
    let l:full = l:match[0]
    let l:start = l:match[1]
    let l:end = l:start + len(l:full)
    let l:varname = l:full[2:-2]  " extract from ${...}
  else
    " Try to match $VAR format
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
      let l:varname = l:full[1:]  " extract from $...
    else
      echo "No environment variable found under cursor"
      return
    endif
  endif

  let l:expanded = expand('$' . l:varname)
  let l:before = l:start > 0 ? l:line[0 : l:start - 1] : ''
  let l:after = l:line[l:end :]
  call setline('.', l:before . l:expanded . l:after)

endfunction

function! ExpandAllEnvVarsInLine()
  let l:line = getline('.')

  " First handle ${VAR} style
  let l:line = substitute(l:line, '\${\(\w\+\)}', '\=expand("$" . submatch(1))', 'g')

  " Then handle $VAR style, being careful not to double-expand already replaced ones
  let l:line = substitute(l:line, '\$\(\w\+\)', '\=expand("$" . submatch(1))', 'g')

  call setline('.', l:line)
endfunction

function! ExpandEnvVarsInVisual()
  " Save current selection range
  let l:start_line = line("'<")
  let l:end_line = line("'>")

  for lnum in range(l:start_line, l:end_line)
    let l:line = getline(lnum)

    " First expand ${VAR}
    let l:line = substitute(l:line, '\${\(\w\+\)}', '\=expand("$" . submatch(1))', 'g')

    " Then expand $VAR
    let l:line = substitute(l:line, '\$\(\w\+\)', '\=expand("$" . submatch(1))', 'g')

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
