# Refactoring status: 80%
_ = require 'underscore-plus'
{selectLines} = require './utils'
{BlockwiseSelect, BlockwiseRestoreCharacterwise} = require './visual-blockwise'
{Range, CompositeDisposable, Disposable} = require 'atom'

module.exports =
class ModeManager
  mode: 'insert' # Native atom is not modal editor and its default is 'insert'

  constructor: (@vimState) ->
    {@editor, @editorElement} = @vimState
    @disposables = new CompositeDisposable

  isMode: (mode, submode=null) ->
    if submode
      submode = [submode] if _.isString(submode)
      @mode is mode and (@submode in submode)
    else
      @mode is mode

  setMode: (mode, submode=null) ->
    if mode is 'reset'
      @editor.clearSelections()
      mode = 'normal'

    switch mode
      when 'normal'
        @activateNormalMode()
      when 'insert'
        @activateInsertMode(submode)
      when 'visual'
        if @isMode('visual', submode)
          return @setMode('normal')
        @activateVisualMode(submode)
      when 'operator-pending'
        null # This is just placeholder, nothing to do without updating selector.

    @mode = mode
    @submode = submode
    @updateModeSelector(mode, submode)
    @vimState.statusBarManager.update(mode, submode)

  updateModeSelector: (newMode, newSubmode=null) ->
    for mode in ['normal', 'insert', 'visual', 'operator-pending']
      method = if mode is newMode then 'add' else 'remove'
      @editorElement.classList[method] "#{mode}-mode"

    for submode in ['characterwise', 'linewise', 'blockwise', 'replace']
      method = if submode is newSubmode then 'add' else 'remove'
      @editorElement.classList[method] "#{submode}"

  activateNormalMode: ->
    switch
      when @isMode('insert') then @deactivateInsertMode()
      when @isMode('visual') then @deactivateVisualMode()
    @editorElement.component.setInputEnabled(false)
    @vimState.reset()
    s.clear(autoscroll: false) for s in @editor.getSelections()
    @vimState.dontPutCursorsAtEndOfLine()

  # TODO: delete this in future.
  resetNormalMode: ->
    @setMode('reset')

  activateInsertMode: (submode=null) ->
    @editorElement.component.setInputEnabled(true)
    @setInsertionCheckpoint()
    if submode is 'replace'
      @activateReplaceMode()

  activateReplaceMode: ->
    @replacedCharsBySelection = {}
    @replaceModeSubscriptions ?= new CompositeDisposable

    @replaceModeSubscriptions.add @editor.onWillInsertText ({text, cancel}) =>
      cancel()
      for s in @editor.getSelections()
        for char in text.split('') ? []
          unless char is "\n"
            s.selectRight() unless s.cursor.isAtEndOfLine()
          (@replacedCharsBySelection[s.id] ?= []).push s.getText()
          s.insertText(char)

    @replaceModeSubscriptions.add new Disposable =>
      @replacedCharsBySelection = null

  replaceModeBackspace: ->
    for s in @editor.getSelections()
      char = @replacedCharsBySelection[s.id].pop()
      if char? # char maybe empty char ''.
        s.selectLeft()
        s.cursor.moveLeft() unless s.insertText(char).isEmpty()

  setInsertionCheckpoint: ->
    @insertionCheckpoint ?= @editor.createCheckpoint()

  deactivateInsertMode: ->
    @editor.groupChangesSinceCheckpoint(@insertionCheckpoint)
    changes = getChangesSinceCheckpoint(@editor.buffer, @insertionCheckpoint)
    @insertionCheckpoint = null
    if (item = @vimState.history[0]) and item.isInsert()
      item.confirmChanges(changes)
    for c in @editor.getCursors() when not c.isAtBeginningOfLine()
      c.moveLeft()

    if @isMode('insert', 'replace')
      @replaceModeSubscriptions?.dispose()
      @replaceModeSubscriptions = null

  deactivateVisualMode: ->
    {lastOperation} = @vimState
    restoreColumn = not (lastOperation?.isYank() or lastOperation?.isIndent())
    if restoreColumn and @isMode('visual', 'linewise')
      @selectCharacterwise()
    for s in @editor.getSelections() when not (s.isEmpty() or s.isReversed())
      s.cursor.moveLeft()

  activateVisualMode: (submode) ->
    oldSubmode = @submode
    # [FIXME] following operation depend operationStack
    # So @setMode at first is important since operationStack do
    # special cursor treatment depending on current mode.
    @mode = 'visual'
    @submode = submode
    switch submode
      when 'linewise' then @selectLinewise(oldSubmode)
      when 'characterwise' then @selectCharacterwise(oldSubmode)
      when 'blockwise' then @selectBlockwise(oldSubmode)

  selectLinewise: (oldSubmode) ->
    unless oldSubmode is 'characterwise'
      @selectCharacterwise()

    # Keep original range as marker's property to restore column.
    for selection in @editor.getSelections()
      originalRange = selection.getBufferRange()
      selection.marker.setProperties({originalRange})
      selectLines(selection)
    @hideCursors()

  selectCharacterwise: (oldSubmode) ->
    if @editor.getLastSelection().isEmpty()
      @editor.selectRight()
      return

    if oldSubmode is 'blockwise'
      @vimState.operationStack.push new BlockwiseRestoreCharacterwise(@vimState)
    else
      for selection in @editor.getSelections()
        {originalRange} = selection.marker.getProperties()
        if originalRange
          [startRow, endRow] = selection.getBufferRowRange()
          originalRange.start.row = startRow
          originalRange.end.row   = endRow
          selection.setBufferRange(originalRange)

  selectBlockwise: (oldSubmode) ->
    unless oldSubmode is 'characterwise'
      @selectCharacterwise()
    @vimState.operationStack.push new BlockwiseSelect(@vimState)

  hideCursors: ->
    for c in @editor.getCursors() when c.isVisible()
      c.setVisible(false)

# This uses private APIs and may break if TextBuffer is refactored.
# Package authors - copy and paste this code at your own risk.
getChangesSinceCheckpoint = (buffer, checkpoint) ->
  {history} = buffer

  if (index = history.getCheckpointIndex(checkpoint))?
    history.undoStack.slice(index)
  else
    []