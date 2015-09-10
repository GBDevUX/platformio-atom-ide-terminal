{Task, CompositeDisposable} = require 'atom'
{$, View} = require 'atom-space-pen-views'

Pty = require.resolve './process'
Terminal = require 'term.js'

path = require 'path'
os = require 'os'

lastOpenedView = null
lastActiveElement = null

module.exports =
class TerminalPlusView extends View
  opened: false
  animating: false

  @content: () ->
    @div class: 'terminal-plus terminal-view', outlet: 'terminalPlusView', =>
      @div class: 'panel-divider', outlet: 'panelDivider'
      @div class: 'btn-toolbar', outlet:'toolbar', =>
        @button outlet: 'closeBtn', class: 'btn inline-block-tight right', click: 'destroy', =>
          @span class: 'icon icon-x', ' Close'
        @button outlet: 'hideBtn', class: 'btn inline-block-tight right', click: 'hide', =>
          @span class: 'icon icon-chevron-down', ' Hide'
        @button outlet: 'maximizeBtn', class: 'btn inline-block-tight right', click: 'maximize', =>
          @span class: 'icon icon-screen-full', ' Maximize'
      @div class: 'xterm', outlet: 'xterm'

  initialize: ->
    @subscriptions = new CompositeDisposable()

    @subscriptions.add atom.tooltips.add @closeBtn,
      title: 'Exit the terminal session.'
    @subscriptions.add atom.tooltips.add @hideBtn,
      title: 'Hide the terminal window.'
    @subscriptions.add atom.tooltips.add @maximizeBtn,
      title: 'Maximize the terminal window.'

    @prevHeight = atom.config.get('terminal-plus.style.defaultPanelHeight')
    @xterm.height 0

    @setAnimationSpeed()
    atom.config.onDidChange('terminal-plus.style.animationSpeed', @setAnimationSpeed)

    override = (event) ->
      return if event.originalEvent.dataTransfer.getData('terminal-plus') is 'true'
      event.preventDefault()
      event.stopPropagation()

    @xterm.on 'click', @focus

    @xterm.on 'dragenter', override
    @xterm.on 'dragover', override
    @xterm.on 'drop', @recieveItemOrFile

  setAnimationSpeed: =>
    @animationSpeed = atom.config.get('terminal-plus.style.animationSpeed')
    @animationSpeed = 100 if @animationSpeed is 0

    @xterm.css 'transition', "height #{0.25 / @animationSpeed}s linear"

  recieveItemOrFile: (event) =>
    event.preventDefault()
    event.stopPropagation()
    {dataTransfer} = event.originalEvent

    if dataTransfer.getData('atom-event') is 'true'
      @input "#{dataTransfer.getData('text/plain')} "
    else if path = dataTransfer.getData('initialPath')
      @input "#{path} "
    else if dataTransfer.files.length > 0
      for file in dataTransfer.files
        @input "#{file.path} "

  forkPtyProcess: (shell, args=[]) ->
    projectPath = atom.project.getPaths()[0]
    editorPath = atom.workspace.getActiveTextEditor()?.getPath()
    editorPath = path.dirname editorPath if editorPath?
    home = if process.platform is 'win32' then process.env.HOMEPATH else process.env.HOME

    switch atom.config.get('terminal-plus.core.workingDirectory')
      when 'Project' then pwd = projectPath or editorPath or home
      when 'Active File' then pwd = editorPath or projectPath or home
      else pwd = home

    Task.once Pty, path.resolve(pwd), shell, args

  displayTerminal: ->
    {cols, rows} = @getDimensions()
    shell = atom.config.get 'terminal-plus.core.shell'
    shellArguments = atom.config.get 'terminal-plus.core.shellArguments'
    args = shellArguments.split(/\s+/g).filter (arg)-> arg
    @ptyProcess = @forkPtyProcess shell, args

    @terminal = new Terminal {
      cursorBlink     : atom.config.get 'terminal-plus.toggles.cursorBlink'
      scrollback      : atom.config.get 'terminal-plus.core.scrollback'
      cols, rows
    }

    @attachListeners()
    @terminal.open @xterm.get(0)
    @applyStyle()
    @attachEvents()

  attachListeners: ->
    @ptyProcess.on 'terminal-plus:data', (data) =>
      @terminal.write data

    @ptyProcess.on 'terminal-plus:exit', =>
      @input = ->
      @resize = ->
      @destroy() if atom.config.get('terminal-plus.toggles.autoClose')

    @ptyProcess.on 'terminal-plus:title', (title) =>
      @statusIcon.updateTooltip(title)

    @ptyProcess.on 'terminal-plus:clear-title', =>
      @statusIcon.removeTooltip()

    @terminal.end = => @destroy()

    @terminal.on "data", (data) =>
      @input data

    @terminal.once "open", =>
      @focus()
      autoRunCommand = atom.config.get('terminal-plus.core.autoRunCommand')
      @input "#{autoRunCommand}#{os.EOL}" if autoRunCommand

  destroy: ->
    @subscriptions.dispose()
    @statusIcon.remove()
    @statusBar.removeTerminalView this
    @detachResizeEvents()

    if @panel.isVisible()
      @hide()
      @onTransitionEnd => @panel.destroy()
    if @statusIcon and @statusIcon.parentNode
      @statusIcon.parentNode.removeChild(@statusIcon)

    @ptyProcess?.terminate()
    @terminal?.destroy()

  maximize: ->
    @maxHeight = @prevHeight + $('atom-pane-container').height()
    @xterm.css 'height', ''
    btn = @maximizeBtn.children('span')
    @onTransitionEnd => @focus()
    if @maximized
      @xterm.height @prevHeight
      btn.text(' Maximize')
      btn.removeClass('icon-screen-normal').addClass('icon-screen-full')
      @maximized = false
    else
      @xterm.height @maxHeight
      btn.text(' Minimize')
      btn.removeClass('icon-screen-full').addClass('icon-screen-normal')
      @maximized = true

  open: =>
    lastActiveElement ?= $(document.activeElement)

    if lastOpenedView and lastOpenedView != this
      lastOpenedView.hide()
    lastOpenedView = this
    @statusBar.setActiveTerminalView this
    @statusIcon.activate()

    @onTransitionEnd =>
      if not @opened
        @opened = true
        @displayTerminal()
      else
        @focus()

    @panel.show()
    @xterm.height 0
    @animating = true
    @xterm.height if @maximized then @maxHeight else @prevHeight

  hide: =>
    @terminal?.blur()
    lastOpenedView = null
    @statusIcon.deactivate()

    @onTransitionEnd =>
      @panel.hide()
      unless lastOpenedView?
        if lastActiveElement?
          lastActiveElement.focus()
          lastActiveElement = null

    @xterm.height if @maximized then @maxHeight else @prevHeight
    @animating = true
    @xterm.height 0

  toggle: ->
    return if @animating

    if @panel.isVisible()
      @hide()
    else
      @open()

  input: (data) ->
    @terminal.stopScrolling()
    @ptyProcess.send event: 'input', text: data
    @resizeTerminalToView()
    @focusTerminal()

  resize: (cols, rows) ->
    @ptyProcess.send {event: 'resize', rows, cols}

  applyStyle: ->
    style = atom.config.get 'terminal-plus.style'

    @xterm.addClass style.theme

    fontFamily = ["monospace"]
    fontFamily.unshift style.fontFamily unless style.fontFamily is ''
    @terminal.element.style.fontFamily = fontFamily.join ', '
    @terminal.element.style.fontSize = style.fontSize + 'px'

  attachResizeEvents: ->
    @on 'focus', @focus
    $(window).on 'resize', => @resizeTerminalToView() if @panel.isVisible()
    @panelDivider.on 'mousedown', @resizeStarted.bind(this)

  detachResizeEvents: ->
    @off 'focus', @focus
    $(window).off 'resize'
    @panelDivider.off 'mousedown'

  attachEvents: ->
    @resizeTerminalToView = @resizeTerminalToView.bind this
    @resizePanel = @resizePanel.bind(this)
    @resizeStopped = @resizeStopped.bind(this)
    @attachResizeEvents()

  resizeStarted: ->
    return if @maximized
    @maxHeight = @prevHeight + $('atom-pane-container').height()
    $(document).on('mousemove', @resizePanel)
    $(document).on('mouseup', @resizeStopped)
    @xterm.css 'transition', ''

  resizeStopped: ->
    $(document).off('mousemove', @resizePanel)
    $(document).off('mouseup', @resizeStopped)
    @xterm.css 'transition', "height #{0.25 / @animationSpeed}s linear"

  resizePanel: (event) ->
    return @resizeStopped() unless event.which is 1

    mouseY = $(window).height() - event.pageY
    delta = mouseY - $('atom-panel-container.bottom').height()
    clamped = Math.min(Math.max(@xterm.height() + delta, @minHeight), @maxHeight)

    @xterm.height clamped
    $(@terminal.element).height clamped
    @prevHeight = clamped

    @resizeTerminalToView()

  copy: ->
    if  @terminal._selected  # term.js visual mode selections
      textarea = @terminal.getCopyTextarea()
      text = @terminal.grabText(
        @terminal._selected.x1, @terminal._selected.x2,
        @terminal._selected.y1, @terminal._selected.y2)
    else # fallback to DOM-based selections
      rawText = @terminal.context.getSelection().toString()
      rawLines = rawText.split(/\r?\n/g)
      lines = rawLines.map (line) ->
        line.replace(/\s/g, " ").trimRight()
      text = lines.join("\n")
    atom.clipboard.write text

  paste: ->
    @input atom.clipboard.read()

  insertSelection: ->
    return unless editor = atom.workspace.getActiveTextEditor()
    if selection = editor.getSelectedText()
      @terminal.stopScrolling()
      @ptyProcess.send event: 'input', text: "#{selection}#{os.EOL}"
    else if cursor = editor.getCursorBufferPosition()
      line = editor.lineTextForBufferRow(cursor.row)
      @terminal.stopScrolling()
      @ptyProcess.send event: 'input', text: "#{line}#{os.EOL}"
      editor.moveDown(1);

  focus: =>
    @resizeTerminalToView()
    @focusTerminal()

  focusTerminal: ->
    @terminal.focus()
    @terminal.element.focus()

  resizeTerminalToView: ->
    {cols, rows} = @getDimensions()
    return unless cols > 0 and rows > 0
    return unless @terminal
    return if @terminal.rows is rows and @terminal.cols is cols

    @resize cols, rows
    @terminal.resize cols, rows

  getDimensions: ->
    fakeRow = $("<div><span>&nbsp;</span></div>")

    if @terminal
      @find('.terminal').append fakeRow
      fakeCol = fakeRow.children().first()[0].getBoundingClientRect()
      cols = Math.floor(@xterm.width() / (fakeCol.width or 9))
      rows = Math.floor (@xterm.height() / (fakeCol.height or 20))
      @minHeight = fakeCol.height
      fakeRow.remove()
    else
      cols = Math.floor @xterm.width() / 9
      rows = Math.floor @xterm.height() / 20

    {cols, rows}

  onTransitionEnd: (callback) ->
    @xterm.one 'webkitTransitionEnd', =>
      callback()
      @animating = false
