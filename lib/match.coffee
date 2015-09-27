_ = require 'underscore-plus'
{selectVisibleBy, sortRanges, getIndex} = require './utils'
settings = require './settings'

class MatchList
  index: null
  entries: null

  constructor: (@vimState, ranges, index) ->
    {@editor, @editorElement} = @vimState
    @entries = []
    return unless ranges.length

    # ranges are initially not sorted, so we sort and adjust index here.
    current = ranges[getIndex(index, ranges)]
    ranges = sortRanges(ranges)
    @index = ranges.indexOf(current)

    [first, others..., last] = ranges
    for range in ranges
      @entries.push new Match @vimState, range,
        first: range is first
        last: range is last
        current: range is current

  isEmpty: ->
    @entries.length is 0

  setIndex: (index) ->
    @index = getIndex(index, @entries)

  get: (direction=null) ->
    @entries[@index].current = false
    switch direction
      when 'next' then @setIndex(@index + 1)
      when 'prev' then @setIndex(@index - 1)
    match = @entries[@index]
    match.current = true
    match

  getVisible: ->
    selectVisibleBy @editor, @entries, (m) ->
      m.range

  getOffSetPixelHeight: (lineDelta=0) ->
    scrolloff = 2
    @editor.getLineHeightInPixels() * (2 + lineDelta)

  # make prev entry of first visible entry to bottom of screen
  scroll: (direction) ->
    switch direction
      when 'next'
        return if (match = _.last(@getVisible())).isLast()
        step = +1
        offsetPixel = @getOffSetPixelHeight()
      when 'prev'
        return if (match = _.first(@getVisible())).isFirst()
        step = -1
        offsetPixel = (@editor.getHeight() - @getOffSetPixelHeight(1))

    @setIndex (@entries.indexOf(match) + step)
    point = @editor.screenPositionForBufferPosition match.getStartPoint()
    scrollTop = @editorElement.pixelPositionForScreenPosition(point).top
    @editor.setScrollTop (scrollTop -= offsetPixel)

  show: ->
    @reset()
    for m in @getVisible()
      m.show()

  reset: ->
    m.reset() for m in @entries

  destroy: ->
    m.destroy() for m in @entries
    {@entries, @index, @editor} = {}

  showHover: ({timeout}) ->
    current = @get()
    if settings.get('enableHoverSearchCounter')
      # timeout ?= settings.get('searchCounterHoverDuration') #if @isComplete()
      @vimState.hoverSearchCounter.withTimeout current.range.start,
        text: "#{@index + 1}/#{@entries.length}"
        classList: current.getClassList()
        timeout: timeout

class Match
  first: false
  last: false
  current: false

  constructor: (@vimState, @range, {@first, @last, @current}) ->
    {@editor} = @vimState

  getClassList: ->
    # first and last is exclusive, prioritize 'first'.
    last = (not @first) and @last
    [
      @first   and 'first',
      last     and 'last',
      @current and 'current'
    ].filter (e) -> e

  isFirst: -> @first
  isLast: -> @last
  isCurrent: -> @current

  compare: (other) ->
    @range.compare(other.range)

  isEqual: (other) ->
    @range.isEqual other.range

  getStartPoint: ->
    @range.start

  visit: ->
    point = @getStartPoint()
    @editor.scrollToBufferPosition(point, center: true)
    if @editor.isFoldedAtBufferRow(point.row)
      @editor.unfoldBufferRow point.row

  flash: ({timeout}={}) ->
    @vimState.flasher.flash
      range: @range
      klass: 'vim-mode-plus-flash'
      timeout: timeout ? settings.get('flashOnSearchDurationMilliSeconds')

  show: ->
    klass  = 'vim-mode-plus-search-match'
    if s = @getClassList().join(' ')
      klass += " " + s
    @marker = @editor.markBufferRange @range,
      invalidate: 'never'
      persistent: false
    @editor.decorateMarker @marker,
      type: 'highlight'
      class: klass

  reset: ->
    @marker?.destroy()
    @marker = null

  destroy: ->
    @marker?.destroy()
    {@marker, @vimState, @range, @editor, @first, @last, @current} = {}

module.exports = {MatchList}