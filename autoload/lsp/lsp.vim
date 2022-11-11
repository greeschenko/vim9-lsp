vim9script

# Vim9 LSP client

# Needs Vim 9.0 and higher
if v:version < 900
  finish
endif

import './options.vim' as opt
import './lspserver.vim' as lserver
import './util.vim'
import './buffer.vim' as buf
import './textedit.vim'
import './diag.vim'
import './symbol.vim'
import './outline.vim'
import './signature.vim'
import './codeaction.vim'

# LSP server information
var lspServers: list<dict<any>> = []

# filetype to LSP server map
var ftypeServerMap: dict<dict<any>> = {}

# per-filetype omni-completion enabled/disabled table
var ftypeOmniCtrlMap: dict<bool> = {}

var lspInitializedOnce = false

def LspInitOnce()
  # Signs used for LSP diagnostics
  sign_define([{name: 'LspDiagError', text: 'E>', texthl: 'ErrorMsg',
						linehl: 'MatchParen'},
		{name: 'LspDiagWarning', text: 'W>', texthl: 'Search',
						linehl: 'MatchParen'},
		{name: 'LspDiagInfo', text: 'I>', texthl: 'Pmenu',
						linehl: 'MatchParen'},
		{name: 'LspDiagHint', text: 'H>', texthl: 'Question',
						linehl: 'MatchParen'}])

  prop_type_add('LspTextRef', {'highlight': 'Search'})
  prop_type_add('LspReadRef', {'highlight': 'DiffChange'})
  prop_type_add('LspWriteRef', {'highlight': 'DiffDelete'})
  set ballooneval balloonevalterm
  lspInitializedOnce = true
enddef

# Returns the LSP server for the a specific filetype. Returns an empty dict if
# the server is not found.
def LspGetServer(ftype: string): dict<any>
  return ftypeServerMap->get(ftype, {})
enddef

# Returns the LSP server for the current buffer if it is running and is ready.
# Returns an empty dict if the server is not found or is not ready.
def CurbufGetServerChecked(): dict<any>
  var fname: string = @%
  if fname == ''
    return {}
  endif

  var lspserver: dict<any> = buf.CurbufGetServer()
  if lspserver->empty()
    util.ErrMsg($'Error: Language server not found for "{&filetype}" file type')
    return {}
  endif
  if !lspserver.running
    util.ErrMsg($'Error: Language server not running for "{&filetype}" file type')
    return {}
  endif
  if !lspserver.ready
    util.ErrMsg($'Error: Language server not ready for "{&filetype}" file type')
    return {}
  endif

  return lspserver
enddef

# Add a LSP server for a filetype
def LspAddServer(ftype: string, lspsrv: dict<any>)
  ftypeServerMap->extend({[ftype]: lspsrv})
enddef

# Returns true if omni-completion is enabled for filetype 'ftype'.
# Otherwise, returns false.
def LspOmniComplEnabled(ftype: string): bool
  return ftypeOmniCtrlMap->get(ftype, v:false)
enddef

# Enables or disables omni-completion for filetype 'fype'
def LspOmniComplSet(ftype: string, enabled: bool)
  ftypeOmniCtrlMap->extend({[ftype]: enabled})
enddef

# Enable/disable the logging of the language server protocol messages
export def ServerDebug(arg: string)
  if arg !=? 'on' && arg !=? 'off'
    util.ErrMsg($'Error: Invalid argument ("{arg}") for LSP server debug')
    return
  endif

  if arg ==? 'on'
    util.ClearTraceLogs()
    util.ServerTrace(true)
  else
    util.ServerTrace(false)
  endif
enddef

# Show information about all the LSP servers
export def ShowServers()
  for [ftype, lspserver] in ftypeServerMap->items()
    var msg = ftype .. "    "
    if lspserver.running
      msg ..= 'running'
    else
      msg ..= 'not running'
    endif
    msg ..= $'    {lspserver.path}'
    :echomsg msg
  endfor
enddef

# Get LSP server running status for filetype 'ftype'
# Return true if running, or false if not found or not running
export def ServerRunning(ftype: string): bool
  for [ft, lspserver] in ftypeServerMap->items()
    if ftype ==# ft
      return lspserver.running
    endif
  endfor
  return v:false
enddef

# Go to a definition using "textDocument/definition" LSP request
export def GotoDefinition(peek: bool, cmdmods: string)
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  lspserver.gotoDefinition(peek, cmdmods)
enddef

# Go to a declaration using "textDocument/declaration" LSP request
export def GotoDeclaration(peek: bool, cmdmods: string)
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  lspserver.gotoDeclaration(peek, cmdmods)
enddef

# Go to a type definition using "textDocument/typeDefinition" LSP request
export def GotoTypedef(peek: bool, cmdmods: string)
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  lspserver.gotoTypeDef(peek, cmdmods)
enddef

# Go to a implementation using "textDocument/implementation" LSP request
export def GotoImplementation(peek: bool, cmdmods: string)
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  lspserver.gotoImplementation(peek, cmdmods)
enddef

# Switch source header using "textDocument/switchSourceHeader" LSP request
# (Clangd specifc extension)
export def SwitchSourceHeader()
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  lspserver.switchSourceHeader()
enddef

# Show the signature using "textDocument/signatureHelp" LSP method
# Invoked from an insert-mode mapping, so return an empty string.
def g:LspShowSignature(): string
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return ''
  endif

  # first send all the changes in the current buffer to the LSP server
  listener_flush()
  lspserver.showSignature()
  return ''
enddef

# buffer change notification listener
def Bufchange_listener(bnr: number, start: number, end: number, added: number, changes: list<dict<number>>)
  var lspserver: dict<any> = buf.CurbufGetServer()
  if lspserver->empty() || !lspserver.running
    return
  endif

  lspserver.textdocDidChange(bnr, start, end, added, changes)
enddef

# A buffer is saved. Send the "textDocument/didSave" LSP notification
def LspSavedFile()
  var bnr: number = expand('<abuf>')->str2nr()
  var lspserver: dict<any> = buf.BufLspServerGet(bnr)
  if lspserver->empty() || !lspserver.running
    return
  endif

  lspserver.didSaveFile(bnr)
enddef

# Return the diagnostic text from the LSP server for the current mouse line to
# display in a balloon
var lspDiagPopupID: number = 0
var lspDiagPopupInfo: dict<any> = {}
def g:LspDiagExpr(): any
  var lspserver: dict<any> = buf.BufLspServerGet(v:beval_bufnr)
  if lspserver->empty() || !lspserver.running
    return ''
  endif

  # Display the diagnostic message only if the mouse is over the gutter for
  # the signs.
  if opt.lspOptions.noDiagHoverOnLine && v:beval_col >= 2
    return ''
  endif

  var diagInfo: dict<any> = lspserver.getDiagByLine(v:beval_bufnr,
								v:beval_lnum)
  if diagInfo->empty()
    # No diagnostic for the current cursor location
    return ''
  endif

  return diagInfo.message->split("\n")
enddef

# Called after leaving insert mode. Used to process diag messages (if any)
def LspLeftInsertMode()
  if !exists('b:LspDiagsUpdatePending')
    return
  endif
  :unlet b:LspDiagsUpdatePending

  var bnr: number = bufnr()
  var lspserver: dict<any> = buf.CurbufGetServer()
  if lspserver->empty() || !lspserver.running
    return
  endif
  diag.UpdateDiags(lspserver, bnr)
enddef

# Add buffer-local autocmds when attaching a LSP server to a buffer
def AddBufLocalAutocmds(lspserver: dict<any>, bnr: number): void
  var acmds: list<dict<any>> = []

  # file saved notification handler
  acmds->add({bufnr: bnr,
	      event: 'BufWritePost',
	      group: 'LSPBufferAutocmds',
	      cmd: 'LspSavedFile()'})

  # Update the diagnostics when insert mode is stopped
  acmds->add({bufnr: bnr,
	      event: 'InsertLeave',
	      group: 'LSPBufferAutocmds',
	      cmd: 'LspLeftInsertMode()'})

  # Insert-mode completion autocmds (if configured)
  if opt.lspOptions.autoComplete
    # Trigger 24x7 insert mode completion when text is changed
    acmds->add({bufnr: bnr,
		event: 'TextChangedI',
		group: 'LSPBufferAutocmds',
		cmd: 'LspComplete()'})
    if lspserver.completionLazyDoc
      # resolve additional documentation for a selected item
      acmds->add({bufnr: bnr,
		  event: 'CompleteChanged',
		  group: 'LSPBufferAutocmds',
		  cmd: 'LspResolve()'})
    endif
  endif

  # Execute LSP server initiated text edits after completion
  acmds->add({bufnr: bnr,
	      event: 'CompleteDone',
	      group: 'LSPBufferAutocmds',
	      cmd: 'LspCompleteDone()'})

  # Auto highlight all the occurrences of the current keyword
  if opt.lspOptions.autoHighlight &&
			lspserver.caps->has_key('documentHighlightProvider')
      acmds->add({bufnr: bnr,
		  event: 'CursorMoved',
		  group: 'LSPBufferAutocmds',
		  cmd: 'call LspDocHighlightClear() | call LspDocHighlight()'})
  endif

  autocmd_add(acmds)

enddef

def BufferInit(bnr: number): void
  var lspserver: dict<any> = buf.BufLspServerGet(bnr)
  if lspserver->empty() || !lspserver.running
    return
  endif

  var ftype: string = bnr->getbufvar('&filetype')
  lspserver.textdocDidOpen(bnr, ftype)

  # add a listener to track changes to this buffer
  listener_add(Bufchange_listener, bnr)

  # set options for insert mode completion
  if opt.lspOptions.autoComplete
    if lspserver.completionLazyDoc
      setbufvar(bnr, '&completeopt', 'menuone,popuphidden,noinsert,noselect')
      setbufvar(bnr, '&completepopup', 'width:80,highlight:Pmenu,align:menu,border:off')
    else
      setbufvar(bnr, '&completeopt', 'menuone,popup,noinsert,noselect')
      setbufvar(bnr, '&completepopup', 'border:off')
    endif
    # <Enter> in insert mode stops completion and inserts a <Enter>
    if !opt.lspOptions.noNewlineInCompletion
      inoremap <expr> <buffer> <CR> pumvisible() ? "\<C-Y>\<CR>" : "\<CR>"
    endif
  else
    if LspOmniComplEnabled(ftype)
      setbufvar(bnr, '&omnifunc', 'LspOmniFunc')
    endif
  endif

  setbufvar(bnr, '&balloonexpr', 'g:LspDiagExpr()')

  # initialize signature help
  signature.SignatureInit(lspserver)

  AddBufLocalAutocmds(lspserver, bnr)

  if exists('#User#LspAttached')
    doautocmd <nomodeline> User LspAttached
  endif
enddef

# A new buffer is opened. If LSP is supported for this buffer, then add it
export def AddFile(bnr: number): void
  if buf.BufHasLspServer(bnr)
    # LSP server for this buffer is already initialized and running
    return
  endif

  # Skip remote files
  if util.LspUriRemote(bnr->bufname()->fnamemodify(":p"))
    return
  endif

  var ftype: string = bnr->getbufvar('&filetype')
  if ftype == ''
    return
  endif
  var lspserver: dict<any> = LspGetServer(ftype)
  if lspserver->empty()
    return
  endif
  if !lspserver.running
    if !lspInitializedOnce
      LspInitOnce()
    endif
    lspserver.startServer()
  endif
  buf.BufLspServerSet(bnr, lspserver)

  if lspserver.ready
    BufferInit(bnr)
  else
    augroup LSPBufferAutocmds
      exe $'autocmd User LspServerReady{lspserver.name} ++once BufferInit({bnr})'
    augroup END
  endif

enddef

# Notify LSP server to remove a file
export def RemoveFile(bnr: number): void
  var lspserver: dict<any> = buf.BufLspServerGet(bnr)
  if lspserver->empty()
    return
  endif
  if lspserver.running
    lspserver.textdocDidClose(bnr)
  endif
  diag.DiagRemoveFile(lspserver, bnr)
  buf.BufLspServerRemove(bnr)
enddef

# Stop all the LSP servers
export def StopAllServers()
  for lspserver in lspServers
    if lspserver.running
      lspserver.stopServer()
    endif
  endfor
enddef

# Add all the buffers with 'filetype' set to "ftype" to the language server.
def AddBuffersToLsp(ftype: string)
  # Add all the buffers with the same file type as the current buffer
  for binfo in getbufinfo({bufloaded: 1})
    if getbufvar(binfo.bufnr, '&filetype') == ftype
      AddFile(binfo.bufnr)
    endif
  endfor
enddef

# Restart the LSP server for the current buffer
export def RestartServer()
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  # Stop the server
  lspserver.stopServer()

  # Remove all the buffers with the same file type as the current buffer
  var ftype: string = &filetype
  for binfo in getbufinfo()
    if getbufvar(binfo.bufnr, '&filetype') == ftype
      RemoveFile(binfo.bufnr)
    endif
  endfor

  # Start the server again
  lspserver.startServer()

  AddBuffersToLsp(ftype)
enddef

# Add the LSP server for files with 'filetype' as "ftype".
def AddServerForFiltype(lspserver: dict<any>, ftype: string, omnicompl: bool)
  LspAddServer(ftype, lspserver)
  LspOmniComplSet(ftype, omnicompl)

  # If a buffer of this file type is already present, then send it to the LSP
  # server now.
  AddBuffersToLsp(ftype)
enddef

# Register a LSP server for one or more file types
export def AddServer(serverList: list<dict<any>>)
  for server in serverList
    if !server->has_key('filetype') || !server->has_key('path')
      util.ErrMsg('Error: LSP server information is missing filetype or path')
      continue
    endif
    if !server->has_key('omnicompl')
      # Enable omni-completion by default
      server['omnicompl'] = v:true
    endif

    if !executable(server.path)
      if !opt.lspOptions.ignoreMissingServer
        util.ErrMsg($'Error: LSP server {server.path} is not found')
      endif
      return
    endif
    var args: list<string> = []
    if server->has_key('args')
      if server.args->type() != v:t_list
        util.ErrMsg($'Error: Arguments for LSP server {server.args} is not a List')
        return
      endif
      args = server.args
    else

    endif

    var initializationOptions: dict<any> = {}
    if server->has_key('initializationOptions')
      initializationOptions = server.initializationOptions
    endif

    if server.omnicompl->type() != v:t_bool
      util.ErrMsg($'Error: Setting of omnicompl {server.omnicompl} is not a Boolean')
      return
    endif

    if !server->has_key('syncInit')
      server.syncInit = v:false
    endif

    var lspserver: dict<any> = lserver.NewLspServer(server.path,
						    args,
						    server.syncInit,
						    initializationOptions)

    var ftypes = server.filetype
    if ftypes->type() == v:t_string
      lspserver.name = ftypes->substitute('\w\+', '\L\u\0', '')
      AddServerForFiltype(lspserver, ftypes, server.omnicompl)
    elseif ftypes->type() == v:t_list
      lspserver.name = ftypes[0]->substitute('\w\+', '\L\u\0', '')
      for ftype in ftypes
	AddServerForFiltype(lspserver, ftype, server.omnicompl)
      endfor
    else
      util.ErrMsg($'Error: Unsupported file type information "{ftypes->string()}" in LSP server registration')
      continue
    endif
  endfor
enddef

# The LSP server is considered ready when the server capabilities are
# received ('initialize' LSP reply message)
export def ServerReady(): bool
  var fname: string = @%
  if fname == ''
    return false
  endif

  var lspserver: dict<any> = buf.CurbufGetServer()
  if lspserver->empty()
    return false
  endif
  return lspserver.ready
enddef

# set the LSP server trace level for the current buffer
# Params: SetTraceParams
export def ServerTraceSet(traceVal: string)
  if ['off', 'messages', 'verbose']->index(traceVal) == -1
    util.ErrMsg($'Error: Unsupported LSP server trace value {traceVal}')
    return
  endif

  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  lspserver.setTrace(traceVal)
enddef

# Display the diagnostic messages from the LSP server for the current buffer
# in a quickfix list
export def ShowDiagnostics(): void
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  diag.ShowAllDiags(lspserver)
enddef

# Show the diagnostic message for the current line
export def LspShowCurrentDiag()
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  diag.ShowCurrentDiag(lspserver)
enddef

# Display the diagnostics for the current line in the status line.
export def LspShowCurrentDiagInStatusLine()
  var fname: string = @%
  if fname == ''
    return
  endif

  var lspserver: dict<any> = buf.CurbufGetServer()
  if lspserver->empty() || !lspserver.running
    return
  endif

  diag.ShowCurrentDiagInStatusLine(lspserver)
enddef

# get the count of diagnostics in the current buffer
export def ErrorCount(): dict<number>
  var res = {'Error': 0, 'Warn': 0, 'Info': 0, 'Hint': 0}
  var fname: string = @%
  if fname == ''
    return res
  endif

  var lspserver: dict<any> = buf.CurbufGetServer()
  if lspserver->empty() || !lspserver.running
    return res
  endif

  return diag.DiagsGetErrorCount(lspserver)
enddef

# jump to the next/previous/first diagnostic message in the current buffer
export def JumpToDiag(which: string): void
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  diag.LspDiagsJump(lspserver, which)
enddef

# Insert mode completion handler. Used when 24x7 completion is enabled
# (default).
def LspComplete()
  var lspserver: dict<any> = buf.CurbufGetServer()
  if lspserver->empty() || !lspserver.running || !lspserver.ready
    return
  endif

  var cur_col: number = col('.')
  var line: string = getline('.')

  if cur_col == 0 || line->empty()
    return
  endif

  # Trigger kind is 1 for 24x7 code complete or manual invocation
  var triggerKind: number = 1
  var triggerChar: string = ''

  # If the character before the cursor is not a keyword character or is not
  # one of the LSP completion trigger characters, then do nothing.
  if line[cur_col - 2] !~ '\k'
    var trigidx = lspserver.completionTriggerChars->index(line[cur_col - 2])
    if trigidx == -1
      return
    endif
    # completion triggered by one of the trigger characters
    triggerKind = 2
    triggerChar = lspserver.completionTriggerChars[trigidx]
  endif

  # first send all the changes in the current buffer to the LSP server
  listener_flush()

  # initiate a request to LSP server to get list of completions
  lspserver.getCompletion(triggerKind, triggerChar)

  return
enddef

# Lazy complete documentation handler
def LspResolve()
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  var item = v:event.completed_item
  if item->has_key('user_data') && !empty(item.user_data)
    lspserver.resolveCompletion(item.user_data)
  endif
enddef

# omni complete handler
def g:LspOmniFunc(findstart: number, base: string): any
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return -2
  endif

  if findstart
    # first send all the changes in the current buffer to the LSP server
    listener_flush()

    lspserver.omniCompletePending = v:true
    lspserver.completeItems = []
    # initiate a request to LSP server to get list of completions
    lspserver.getCompletion(1, '')

    # locate the start of the word
    var line = getline('.')
    var start = charcol('.') - 1
    while start > 0 && line[start - 1] =~ '\k'
      start -= 1
    endwhile
    return start
  else
    # Wait for the list of matches from the LSP server
    var count: number = 0
    while lspserver.omniCompletePending && count < 1000
      if complete_check()
	return v:none
      endif
      sleep 2m
      count += 1
    endwhile

    var res: list<dict<any>> = []
    for item in lspserver.completeItems
      res->add(item)
    endfor
    return res->empty() ? v:none : res
  endif
enddef

# complete done handler (LSP server-initiated actions after completion)
def LspCompleteDone()
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  if v:completed_item->type() != v:t_dict
    return
  endif

  var completionData: any = v:completed_item->get('user_data', '')
  if completionData->type() != v:t_dict
      || !completionData->has_key('additionalTextEdits')
    return
  endif

  var bnr: number = bufnr()
  textedit.ApplyTextEdits(bnr, completionData.additionalTextEdits)
enddef

# Display the hover message from the LSP server for the current cursor
# location
export def Hover()
  var lspserver: dict<any> = buf.CurbufGetServer()
  if lspserver->empty() || !lspserver.running || !lspserver.ready
    return
  endif

  lspserver.hover()
enddef

# show symbol references
export def ShowReferences(peek: bool)
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  lspserver.showReferences(peek)
enddef

# highlight all the places where a symbol is referenced
def g:LspDocHighlight()
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  lspserver.docHighlight()
enddef

# clear the symbol reference highlight
def g:LspDocHighlightClear()
  prop_remove({'type': 'LspTextRef', 'all': true}, 1, line('$'))
  prop_remove({'type': 'LspReadRef', 'all': true}, 1, line('$'))
  prop_remove({'type': 'LspWriteRef', 'all': true}, 1, line('$'))
enddef

def g:LspRequestDocSymbols()
  if outline.SkipOutlineRefresh()
    return
  endif

  var fname: string = @%
  if fname == ''
    return
  endif

  var lspserver: dict<any> = buf.CurbufGetServer()
  if lspserver->empty() || !lspserver.running || !lspserver.ready
    return
  endif

  lspserver.getDocSymbols(fname)
enddef

# open a window and display all the symbols in a file (outline)
export def Outline()
  outline.OpenOutlineWindow()
  g:LspRequestDocSymbols()
enddef

# Format the entire file
export def TextDocFormat(range_args: number, line1: number, line2: number)
  if !&modifiable
    util.ErrMsg('Error: Current file is not a modifiable file')
    return
  endif

  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  var fname: string = @%
  if range_args > 0
    lspserver.textDocFormat(fname, true, line1, line2)
  else
    lspserver.textDocFormat(fname, false, 0, 0)
  endif
enddef

# TODO: Add support for textDocument.onTypeFormatting?
# Will this slow down Vim?

# Display all the locations where the current symbol is called from.
# Uses LSP "callHierarchy/incomingCalls" request
export def IncomingCalls()
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  lspserver.incomingCalls(@%)
enddef

# Display all the symbols used by the current symbol.
# Uses LSP "callHierarchy/outgoingCalls" request
export def OutgoingCalls()
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  lspserver.outgoingCalls(@%)
enddef

# Rename a symbol
# Uses LSP "textDocument/rename" request
export def Rename()
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  var sym: string = expand('<cword>')
  var newName: string = input($"Rename symbol '{sym}' to: ", sym)
  if newName == ''
    return
  endif

  # clear the input prompt
  echo "\r"

  lspserver.renameSymbol(newName)
enddef

# Perform a code action
# Uses LSP "textDocument/codeAction" request
export def CodeAction(line1: number, line2: number)
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  var fname: string = @%
  lspserver.codeAction(fname, line1, line2)
enddef

# Perform a workspace wide symbol lookup
# Uses LSP "workspace/symbol" request
export def SymbolSearch(queryArg: string)
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  var query: string = queryArg
  if query == ''
    query = input("Lookup symbol: ", expand('<cword>'))
    if query == ''
      return
    endif
  endif
  redraw!

  lspserver.workspaceQuery(query)
enddef

# Display the list of workspace folders
export def ListWorkspaceFolders()
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  echomsg $'Workspace Folders: {lspserver.workspaceFolders->string()}'
enddef

# Add a workspace folder. Default is to use the current folder.
export def AddWorkspaceFolder(dirArg: string)
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  var dirName: string = dirArg
  if dirName == ''
    dirName = input("Add Workspace Folder: ", getcwd(), 'dir')
    if dirName == ''
      return
    endif
  endif
  :redraw!
  if !dirName->isdirectory()
    util.ErrMsg($'Error: {dirName} is not a directory')
    return
  endif

  lspserver.addWorkspaceFolder(dirName)
enddef

# Remove a workspace folder. Default is to use the current folder.
export def RemoveWorkspaceFolder(dirArg: string)
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  var dirName: string = dirArg
  if dirName == ''
    dirName = input("Remove Workspace Folder: ", getcwd(), 'dir')
    if dirName == ''
      return
    endif
  endif
  :redraw!
  if !dirName->isdirectory()
    util.ErrMsg($'Error: {dirName} is not a directory')
    return
  endif

  lspserver.removeWorkspaceFolder(dirName)
enddef

# expand the previous selection or start a new selection
export def SelectionExpand()
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  lspserver.selectionExpand()
enddef

# shrink the previous selection or start a new selection
export def SelectionShrink()
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  lspserver.selectionShrink()
enddef

# fold the entire document
export def FoldDocument()
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  if &foldmethod != 'manual'
    util.ErrMsg("Error: Only works when 'foldmethod' is 'manual'")
    return
  endif

  var fname: string = @%
  lspserver.foldRange(fname)
enddef

# Enable diagnostic highlighting for all the buffers
export def DiagHighlightEnable()
  diag.DiagsHighlightEnable()
enddef

# Disable diagnostic highlighting for all the buffers
export def DiagHighlightDisable()
  diag.DiagsHighlightDisable()
enddef

# Display the LSP server capabilities
export def ShowServerCapabilities()
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return
  endif

  lspserver.showCapabilities()
enddef

# Function to use with the 'tagfunc' option.
export def TagFunc(pat: string, flags: string, info: dict<any>): any
  var lspserver: dict<any> = CurbufGetServerChecked()
  if lspserver->empty()
    return v:null
  endif

  return lspserver.tagFunc(pat, flags, info)
enddef

export def RegisterCmdHandler(cmd: string, Handler: func)
  codeaction.RegisterCmdHandler(cmd, Handler)
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2
