
' =====================================================================
'  Notepad - QB64-PE Edition (core + menu bar + file browser)
'  QB64-PE 4.5.0
' ---------------------------------------------------------------------
'  A keyboard+mouse text editor with a hand-built dropdown menu bar AND
'  a hand-built file-open/save browser. No Win32 controls: the buffer,
'  caret, scrolling, rendering, menus and the file dialog are all done
'  here by hand.
'
'  WHAT ACTUALLY WORKS:
'    - Typing, Enter (split line), Backspace, Delete (incl. line joins)
'    - Arrow keys, Home, End, PageUp, PageDown
'    - Vertical + horizontal scrolling that follows the caret
'    - Load / Save that move real bytes (binary read, CRLF write)
'    - Live status bar: filename, dirty (*), Ln/Col
'    - Save-changes prompt via _MESSAGEBOX before New/Open/Quit
'    - DROPDOWN MENU BAR: real hit-tested menus, mouse + keyboard driven
'    - FILE BROWSER for Open / Save As: navigable directory listing,
'      folders-first, ".." up-row, scroll, typed filename field, mouse
'      + keyboard, overwrite confirm. Returns absolute paths.
'    - UNDO / REDO: coalesced snapshot stacks (200 levels), Ctrl+Z /
'      Ctrl+Y; Edit-menu items grey out when their stack is empty.
'    - WORD WRAP (Format menu): Notepad-style soft wrap at the window
'      edge; no newline bytes added. Off = horizontal scroll.
'    - FIND (Ctrl+F): modal search bar, Find Next/Prev, Match Case,
'      wrap-around; the current match is highlighted in the document.
'    - REPLACE (Ctrl+R): same panel with a replacement field; Replace
'      (one match) and Replace All (whole document, single undo step).
'    - SELECTION + CLIPBOARD: click to place the caret, drag to select
'      (auto-scrolls at the edges); Ctrl+A select all, Ctrl+C copy,
'      Ctrl+X cut, Ctrl+V paste via the OS clipboard (_CLIPBOARD$).
'    - RIGHT-CLICK MENU: Cut / Copy / Paste / Select All, greyed by
'      state (needs a selection / a non-empty clipboard).
'    - VERTICAL SCROLLBAR: proportional thumb, click-to-page, drag,
'      hidden when the whole document fits. Works in both wrap modes.
'
'  Keys:  Ctrl+N new   Ctrl+O open   Ctrl+S save   Ctrl+Q / Esc quit
'         Ctrl+Z undo   Ctrl+Y redo   Ctrl+F find   Ctrl+R replace
'         Ctrl+A all    Ctrl+C copy   Ctrl+X cut    Ctrl+V paste
'         F10 activates the menu bar (arrows + Enter, Esc closes)
'         Mouse: left click/drag = caret/selection; right click = menu
'
'  DELIBERATELY NOT BUILT (surfaced as greyed-out menu items):
'    - Font picker
'    - Shift+arrow selection (needs _KEYDOWN, not InKey$)
'  These are honest gaps. The Edit menu shows them disabled on purpose.
'
'  SCROLLBAR INTEGRATION NOTES (fixes applied during the merge):
'   1. Const SCROLLBAR_WIDTH As Integer = 15  ->  Const SCROLLBAR_WIDTH = 15
'      (QB64-PE Const does not take an As clause.)
'   2. suppressSnap flag added. EnsureCaretVisible runs every frame and
'      used to snap the view back to the caret, which made the scrollbar
'      useless (any scroll away from the caret was undone next frame).
'      Scrollbar actions set suppressSnap = -1; a keypress, a caret
'      placement, undo/redo or a find step clears it, restoring normal
'      follow-the-caret behaviour.
'   3. Division-by-zero guard in the word-wrap scrollbar math when
'      visCount = visRows exactly.
'   4. Drag capture: the thumb keeps responding even if the pointer
'      strays out of the 15px scrollbar column mid-drag, and a drag in
'      progress no longer leaks clicks into the text area.
' =====================================================================

' ---- menu command IDs --------------------------------------------
Const CMD_SEP = 0 ' draw a separator line, not selectable
Const CMD_DISABLED = -1 ' greyed-out, not selectable (honest gap)
Const CMD_NEW = 1
Const CMD_OPEN = 2
Const CMD_SAVE = 3
Const CMD_SAVEAS = 4
Const CMD_QUIT = 5
Const CMD_ABOUT = 6
Const CMD_UNDO = 7
Const CMD_REDO = 8
Const CMD_WRAP = 9
Const CMD_FIND = 10
Const CMD_REPLACE = 11
Const CMD_CUT = 12
Const CMD_COPY = 13
Const CMD_PASTE = 14
Const CMD_SELALL = 15
Const CMD_THEME_DEFAULT = 16
Const CMD_THEME_AMBER = 17
Const CMD_THEME_GREEN = 18
Const CMD_THEME_LIGHT = 19
Const CMD_THEME_BLUE = 20
Const CMD_MERGE_TOP = 22 ' File > Merge at Top...      prepend a file
Const CMD_MERGE_BOTTOM = 23 ' File > Merge at Bottom...   append a file

Const NUM_MENUS = 4 ' File, Edit, Format, Help

Const FD_OPEN = 0 ' file-dialog modes
Const FD_SAVE = 1

' ---- undo edit kinds (consecutive same-kind edits coalesce) -------
Const KIND_NONE = 0
Const KIND_TYPE = 1
Const KIND_NEWLINE = 2
Const KIND_BACKSPACE = 3
Const KIND_DELETE = 4
Const KIND_REPLACE = 5

' find-panel modes
Const FIND_MODE = 0
Const REPL_MODE = 1

Const UNDO_MAX = 200 ' deepest undo/redo history kept

' ---- shared state -------------------------------------------------
ReDim Shared docLine$(0 To 63) ' the buffer: one string per line
Dim Shared lineCount As Long ' lines in use
Dim Shared caretRow As Long ' 0-based current line
Dim Shared caretCol As Long ' 0-based column within the line
Dim Shared topLine As Long ' first visible line  (vertical scroll)
Dim Shared leftCol As Long ' first visible column (horiz scroll)
Dim Shared currentFile As String
Dim Shared isDirty As Integer
Dim Shared quitFlag As Integer
Dim Shared PSEP As String ' path separator for this OS

Dim Shared fw As Integer ' font cell width
Dim Shared fh As Integer ' font cell height
Dim Shared winW As Integer
Dim Shared winH As Integer
Dim Shared visRows As Integer ' text rows that fit on screen
Dim Shared visCols As Integer ' text cols that fit on screen (adjusted for scrollbar)
Dim Shared SBHEIGHT As Integer ' status bar height in pixels
Dim Shared MBHEIGHT As Integer ' menu bar height in pixels

' ---- Scrollbar state ----------------------------------------------
Const SCROLLBAR_WIDTH = 15 ' Width of the scrollbar in pixels
Dim Shared scrollbarVisible As Integer ' -1 if scrollbar should be drawn
Dim Shared scrollbarY As Integer ' Y position of scrollbar top
Dim Shared scrollbarHeight As Integer ' Height of the scrollbar thumb
Dim Shared scrollbarMaxY As Integer ' Maximum Y position the thumb can be dragged to
Dim Shared scrollbarDragging As Integer ' -1 if currently dragging the thumb
Dim Shared scrollbarDragOffset As Integer ' Offset within the thumb where drag started
Dim Shared suppressSnap As Integer ' -1 while the user has scrolled away from the caret

' ---- theme (editor palette) ---------------------------------------
Dim Shared themeBG As _Unsigned Long ' editor background
Dim Shared themeFG As _Unsigned Long ' body text
Dim Shared themeSel As _Unsigned Long ' selection background
Dim Shared themeSelFG As _Unsigned Long ' selection text
Dim Shared themeMatch As _Unsigned Long ' find-match background
Dim Shared themeCaret As _Unsigned Long ' caret
Dim Shared currentTheme As Integer ' 0=Default, 1=Amber, 2=Green Phosphor, 3=Light, 4=Blue

' ---- menu state ---------------------------------------------------
Dim Shared menuTitle$(0 To NUM_MENUS - 1)
Dim Shared menuX(0 To NUM_MENUS - 1) As Integer ' x pixel of each title
Dim Shared menuW(0 To NUM_MENUS - 1) As Integer ' clickable width
Dim Shared itemText$(0 To NUM_MENUS - 1, 0 To 9)
Dim Shared itemCmd(0 To NUM_MENUS - 1, 0 To 9) As Integer
Dim Shared itemCount(0 To NUM_MENUS - 1) As Integer
Dim Shared menuOpen As Integer ' -1 if a dropdown is showing
Dim Shared activeMenu As Integer ' which menu index is open (-1 none)
Dim Shared hoverItem As Integer ' highlighted item in open menu (-1 none)
Dim Shared ddX As Integer, ddY As Integer ' current dropdown box origin
Dim Shared ddW As Integer, ddH As Integer ' current dropdown box size

' ---- file-dialog state --------------------------------------------
Dim Shared fdEntry$(0 To 2047) ' directory entries (".." + dirs + files)
Dim Shared fdIsDir(0 To 2047) As Integer ' parallel: is entry a folder?
Dim Shared fdCount As Long ' entries in use
Dim Shared fdSel As Long ' highlighted entry
Dim Shared fdTop As Long ' first visible entry (scroll)
Dim Shared fdRows As Integer ' visible list rows
Dim Shared fdMode As Integer ' FD_OPEN or FD_SAVE
Dim Shared fdFocus As Integer ' 0 = list, 1 = filename field
Dim Shared fdName As String ' filename field contents
Dim Shared fdResult As String ' chosen path ("" = cancelled)
Dim Shared fdDone As Integer ' loop sentinel
Dim Shared fdArmed As Integer ' ignore clicks until button released once
' dialog geometry (set in FileDialog$)
Dim Shared fdPX As Integer, fdPY As Integer, fdPW As Integer, fdPH As Integer
Dim Shared fdListX As Integer, fdListY As Integer, fdListW As Integer
Dim Shared fdFieldY As Integer, fdBtnY As Integer
Dim Shared fdOKx1 As Integer, fdOKx2 As Integer
Dim Shared fdCANx1 As Integer, fdCANx2 As Integer
Dim Shared fdOKtext As String, fdCANtext As String

' ---- drive-select state (Windows only) ---------------------------
Dim Shared fdDrives$(0 To 25) ' letters that exist (A..Z)
Dim Shared fdDriveX(0 To 25) As Integer ' hit-box x1 per drive button
Dim Shared fdDriveW(0 To 25) As Integer ' hit-box width per drive button
Dim Shared fdDriveCount As Integer ' drives available
Dim Shared fdDriveY As Integer ' y of drive row (0 when hidden)
Dim Shared fdHasDrives As Integer ' -1 on Windows -> show the row

' ---- undo / redo state --------------------------------------------
Dim Shared undoBlob$(0 To UNDO_MAX - 1) ' each level = whole doc serialized
Dim Shared undoRow(0 To UNDO_MAX - 1) As Long ' caret row at that level
Dim Shared undoCol(0 To UNDO_MAX - 1) As Long ' caret col at that level
Dim Shared undoSP As Long ' undo stack depth
Dim Shared redoBlob$(0 To UNDO_MAX - 1)
Dim Shared redoRow(0 To UNDO_MAX - 1) As Long
Dim Shared redoCol(0 To UNDO_MAX - 1) As Long
Dim Shared redoSP As Long ' redo stack depth
Dim Shared undoLastKind As Integer ' kind of the current coalescing group
Dim Shared undoBreak As Integer ' -1 = next edit starts a new group
Dim Shared savedBlob As String ' doc as last saved/loaded (for the dirty star)

' ---- word-wrap state (soft wrap; no bytes added to the buffer) -----
Dim Shared wordWrap As Integer ' -1 = wrap on (Notepad-style)
Dim Shared topVis As Long ' top visible VISUAL row when wrapping
Dim Shared wrapDirty As Integer ' -1 = visual map needs rebuilding
Dim Shared visCount As Long ' number of visual rows in the map
ReDim Shared visLogRow(0 To 1023) As Long ' visual row -> logical line
ReDim Shared visStart(0 To 1023) As Long ' visual row -> start column in that line
ReDim Shared visLen(0 To 1023) As Long ' visual row -> length of this segment

' ---- find state ---------------------------------------------------
Dim Shared findQuery As String ' current search text
Dim Shared findCase As Integer ' -1 = match case
Dim Shared matchRow As Long ' current match: logical line (-1 = none)
Dim Shared matchCol As Long ' current match: start column (0-based)
Dim Shared matchLen As Long ' current match: length
Dim Shared fpDone As Integer ' find-panel loop sentinel
Dim Shared fpArmed As Integer ' swallow the launching click until released
Dim Shared fpMsg As String ' "" or "Not found"
Dim Shared fpX As Integer, fpY As Integer, fpW As Integer, fpH As Integer
Dim Shared fpFieldY As Integer, fpBtnY As Integer
Dim Shared fpNX1 As Integer, fpNX2 As Integer ' Find button hit-box
Dim Shared fpPX1 As Integer, fpPX2 As Integer ' Prev button
Dim Shared fpCX1 As Integer, fpCX2 As Integer ' Match-case checkbox
Dim Shared fpXX1 As Integer, fpXX2 As Integer ' Close button
Dim Shared findReplace As String ' replacement text (replace mode)
Dim Shared fpMode As Integer ' FIND_MODE or REPL_MODE
Dim Shared fpFocus As Integer ' 0 = find field, 1 = replace field
Dim Shared fpField2Y As Integer ' replace-field y (replace mode)
Dim Shared fpHintY As Integer ' hint line y
Dim Shared fpRX1 As Integer, fpRX2 As Integer ' Replace button
Dim Shared fpAX1 As Integer, fpAX2 As Integer ' Replace All button

' ---- selection + context-menu state -------------------------------
Dim Shared selActive As Integer ' -1 = a selection exists
Dim Shared anchorRow As Long ' fixed end of the selection (row)
Dim Shared anchorCol As Long ' fixed end of the selection (col)
Dim Shared ctxOpen As Integer ' -1 = right-click menu showing
Dim Shared ctxX As Integer, ctxY As Integer ' context-menu origin
Dim Shared ctxW As Integer, ctxH As Integer ' context-menu size
Dim Shared ctxHover As Integer ' highlighted item (-1 none)
Dim Shared ctxHasSel As Integer ' cached at open: is there a selection?
Dim Shared ctxCanPaste As Integer ' cached at open: is the clipboard non-empty?
Dim Shared ctxLabel$(0 To 3)
Dim Shared ctxCmd(0 To 3) As Integer

' ---- setup --------------------------------------------------------
winW = 800
winH = 640
Screen _NewImage(winW, winH, 32)
_Title "Notepad - QB64-PE Edition"
$ExeIcon:'./icon\Icon.ico'
_Font 16 ' built-in 8x16 monospace
_PrintMode _KeepBackground
fw = _FontWidth
fh = _FontHeight
SBHEIGHT = fh + 6
MBHEIGHT = fh + 6
visRows = (winH - SBHEIGHT - MBHEIGHT) \ fh
visCols = (winW - SCROLLBAR_WIDTH) \ fw ' recomputed each frame in EnsureCaretVisible

' Detect the path separator at runtime (no metacommand needed):
' a Windows _CWD$ always carries at least one backslash (the drive).
PSEP = "/"
If InStr(_CWD$, "\") > 0 Then PSEP = "\"

Call InitMenus
menuOpen = 0
activeMenu = -1
hoverItem = -1

Call SetTheme(0) ' start on the Default palette

Call ResetBuffer
currentFile = ""
isDirty = 0
quitFlag = 0
savedBlob = "" ' empty doc is the initial "saved" baseline
Call UndoReset
wordWrap = 0 ' horizontal scroll by default
topVis = 0
wrapDirty = -1
findQuery = ""
findCase = 0 ' case-insensitive by default (like Notepad)
matchRow = -1
findReplace = ""
fpFocus = 0
selActive = 0
anchorRow = 0
anchorCol = 0
ctxOpen = 0
ctxHover = -1

' Initialize scrollbar state
scrollbarVisible = 0
scrollbarY = MBHEIGHT
scrollbarHeight = visRows * fh ' Default, will be updated
scrollbarMaxY = 0
scrollbarDragging = 0
scrollbarDragOffset = 0
suppressSnap = 0

' ---- main loop ----------------------------------------------------
Dim kkey As String
Do
    Call HandleMouse
    kkey = InKey$
    If Len(kkey) > 0 Then Call HandleKey(kkey)
    Call EnsureCaretVisible ' also updates visCols and the scrollbar state
    Call Render
    _Limit 60
Loop Until quitFlag

System

' =====================================================================
'  KEYBOARD
' =====================================================================
Sub HandleKey (kkey As String)
    Dim c As Integer, ext As Integer

    ' If the right-click menu or a dropdown is open, keys drive it.
    If ctxOpen Then
        Call CtxKey(kkey)
        Exit Sub
    End If

    If menuOpen Then
        Call MenuKey(kkey)
        Exit Sub
    End If

    suppressSnap = 0 ' any editor keystroke puts the caret back in charge
    matchRow = -1 ' any editor keystroke clears the find highlight

    If Len(kkey) = 2 Then
        ext = Asc(kkey, 2)
        Select Case ext
            Case 72: Call NavKey(ext) ' Up
            Case 80: Call NavKey(ext) ' Down
            Case 75: Call NavKey(ext) ' Left
            Case 77: Call NavKey(ext) ' Right
            Case 71: Call NavKey(ext) ' Home
            Case 79: Call NavKey(ext) ' End
            Case 73: Call NavKey(ext) ' PgUp
            Case 81: Call NavKey(ext) ' PgDn

            Case 83 ' Delete
                If ShiftDown% Then
                    Call DoCut ' Shift+Del = cut  (mirror of Shift+Ins paste)
                Else
                    Call DeleteForward ' plain Del (selection-aware)
                End If


            Case 82 ' Insert
                If ShiftDown% Then Call DoPaste

            Case 68: undoBreak = -1: selActive = 0: Call OpenMenu(0): Call MenuMove(1) ' F10
        End Select
        Exit Sub
    End If

    c = Asc(kkey)
    Select Case c
        Case 13: Call InsertNewline ' Enter
        Case 8: Call Backspace ' Backspace
        Case 9: Call InsertText(Space$(4)) ' Tab -> soft tab
        Case 14: Call DoNew ' Ctrl+N
        Case 15: Call DoOpen ' Ctrl+O
        Case 19: Call DoSave ' Ctrl+S
        Case 26: Call DoUndo ' Ctrl+Z
        Case 25: Call DoRedo ' Ctrl+Y
        Case 6: Call DoFind ' Ctrl+F
        Case 18: Call DoReplace ' Ctrl+R  (Ctrl+H is Backspace here)
        Case 1: Call DoSelectAll ' Ctrl+A
        Case 3: Call DoCopy ' Ctrl+C
        Case 22: Call DoPaste ' Ctrl+V
        Case 24: Call DoCut ' Ctrl+X
        Case 17: Call DoQuit ' Ctrl+Q
        Case 27: Call DoQuit ' Esc
        Case 32 To 126: Call InsertText(kkey) ' printable
        Case Else: ' ignore other control codes
    End Select
End Sub

' =====================================================================
'  CARET MOVEMENT
' =====================================================================
Sub MoveLeft
    If caretCol > 0 Then
        caretCol = caretCol - 1
    ElseIf caretRow > 0 Then
        caretRow = caretRow - 1
        caretCol = Len(docLine$(caretRow))
    End If
End Sub

Sub MoveRight
    If caretCol < Len(docLine$(caretRow)) Then
        caretCol = caretCol + 1
    ElseIf caretRow < lineCount - 1 Then
        caretRow = caretRow + 1
        caretCol = 0
    End If
End Sub

Sub MoveUp
    Dim vRow As Long, vCol As Long
    If wordWrap Then
        Call BuildWrap
        Call CaretToVis(vRow, vCol)
        If vRow > 0 Then Call VisToCaret(vRow - 1, vCol)
    Else
        If caretRow > 0 Then
            caretRow = caretRow - 1
            If caretCol > Len(docLine$(caretRow)) Then caretCol = Len(docLine$(caretRow))
        End If
    End If
End Sub

Sub MoveDown
    Dim vRow As Long, vCol As Long
    If wordWrap Then
        Call BuildWrap
        Call CaretToVis(vRow, vCol)
        If vRow < visCount - 1 Then Call VisToCaret(vRow + 1, vCol)
    Else
        If caretRow < lineCount - 1 Then
            caretRow = caretRow + 1
            If caretCol > Len(docLine$(caretRow)) Then caretCol = Len(docLine$(caretRow))
        End If
    End If
End Sub

Sub PageUp
    Dim vRow As Long, vCol As Long
    If wordWrap Then
        Call BuildWrap
        Call CaretToVis(vRow, vCol)
        Call VisToCaret(vRow - visRows, vCol)
    Else
        caretRow = caretRow - visRows
        If caretRow < 0 Then caretRow = 0
        If caretCol > Len(docLine$(caretRow)) Then caretCol = Len(docLine$(caretRow))
    End If
End Sub

Sub PageDown
    Dim vRow As Long, vCol As Long
    If wordWrap Then
        Call BuildWrap
        Call CaretToVis(vRow, vCol)
        Call VisToCaret(vRow + visRows, vCol)
    Else
        caretRow = caretRow + visRows
        If caretRow > lineCount - 1 Then caretRow = lineCount - 1
        If caretCol > Len(docLine$(caretRow)) Then caretCol = Len(docLine$(caretRow))
    End If
End Sub

' Home/End act on the VISUAL line when wrapping, the logical line otherwise.
Sub MoveHome
    Dim vRow As Long, vCol As Long
    If wordWrap Then
        Call BuildWrap
        Call CaretToVis(vRow, vCol)
        caretCol = visStart(vRow)
    Else
        caretCol = 0
    End If
End Sub

Sub MoveEnd
    Dim vRow As Long, vCol As Long, e As Long, lastSeg As Integer, s As String
    If wordWrap Then
        Call BuildWrap
        Call CaretToVis(vRow, vCol)
        e = visStart(vRow) + visLen(vRow)
        lastSeg = (vRow = visCount - 1)
        If Not lastSeg Then lastSeg = (visLogRow(vRow + 1) <> caretRow)
        If Not lastSeg Then ' trim the wrapped space so End stays on this row
            s = docLine$(caretRow)
            Do While e > visStart(vRow)
                If Mid$(s, e, 1) = " " Then e = e - 1 Else Exit Do
            Loop
        End If
        caretCol = e
    Else
        caretCol = Len(docLine$(caretRow))
    End If
End Sub

' =====================================================================
'  EDITING
' =====================================================================
Sub InsertText (t As String)
    Call BeginEdit(KIND_TYPE)
    Call RawInsertText(t)
End Sub

Sub InsertNewline
    Call BeginEdit(KIND_NEWLINE)
    Call RawInsertNewline
End Sub

Sub Backspace
    Dim s As String, prevLen As Long
    If HasSelection% Then
        undoBreak = -1
        Call UndoCheckpoint(KIND_DELETE)
        Call RemoveSelSpan
        Exit Sub
    End If
    If caretCol > 0 Then
        Call UndoCheckpoint(KIND_BACKSPACE)
        s = docLine$(caretRow)
        docLine$(caretRow) = Left$(s, caretCol - 1) + Mid$(s, caretCol + 1)
        caretCol = caretCol - 1
        isDirty = -1
    ElseIf caretRow > 0 Then
        Call UndoCheckpoint(KIND_BACKSPACE)
        prevLen = Len(docLine$(caretRow - 1))
        docLine$(caretRow - 1) = docLine$(caretRow - 1) + docLine$(caretRow)
        Call RemoveLineAt(caretRow)
        caretRow = caretRow - 1
        caretCol = prevLen
        isDirty = -1
    End If
End Sub

Sub DeleteForward
    Dim s As String
    If HasSelection% Then
        undoBreak = -1
        Call UndoCheckpoint(KIND_DELETE)
        Call RemoveSelSpan
        Exit Sub
    End If
    s = docLine$(caretRow)
    If caretCol < Len(s) Then
        Call UndoCheckpoint(KIND_DELETE)
        docLine$(caretRow) = Left$(s, caretCol) + Mid$(s, caretCol + 2)
        isDirty = -1
    ElseIf caretRow < lineCount - 1 Then
        Call UndoCheckpoint(KIND_DELETE)
        docLine$(caretRow) = s + docLine$(caretRow + 1)
        Call RemoveLineAt(caretRow + 1)
        isDirty = -1
    End If
End Sub

' =====================================================================
'  BUFFER PRIMITIVES
' =====================================================================
Sub ResetBuffer
    ReDim docLine$(0 To 63)
    lineCount = 1
    docLine$(0) = ""
    caretRow = 0
    caretCol = 0
    topLine = 0
    leftCol = 0
End Sub

Sub EnsureCapacity (n As Long)
    ' make room for n elements (indices 0..n-1)
    If n > UBound(docLine$) + 1 Then
        ReDim _Preserve docLine$(0 To n * 2)
    End If
End Sub

Sub AppendLine (txt As String)
    Call EnsureCapacity(lineCount + 1)
    docLine$(lineCount) = txt
    lineCount = lineCount + 1
End Sub

Sub InsertLineAt (idx As Long, txt As String)
    Dim j As Long
    Call EnsureCapacity(lineCount + 1)
    For j = lineCount To idx + 1 Step -1
        docLine$(j) = docLine$(j - 1)
    Next j
    docLine$(idx) = txt
    lineCount = lineCount + 1
End Sub

Sub RemoveLineAt (idx As Long)
    Dim j As Long
    For j = idx To lineCount - 2
        docLine$(j) = docLine$(j + 1)
    Next j
    lineCount = lineCount - 1
    If lineCount < 1 Then
        lineCount = 1
        docLine$(0) = ""
    End If
End Sub

' =====================================================================
'  SCROLLING
'  Runs every frame: recomputes visCols (the scrollbar eats 15px),
'  snaps the view to the caret unless suppressSnap says the user has
'  scrolled away with the scrollbar, and refreshes the thumb geometry.
' =====================================================================
Sub EnsureCaretVisible
    Dim vRow As Long, vCol As Long
    Dim totalTextHeight As Long
    Dim maxScroll As Long
    Dim scrollRatio As Double

    ' Calculate visCols accounting for scrollbar
    visCols = (winW - SCROLLBAR_WIDTH) \ fw
    If visCols < 1 Then visCols = 1 ' Safety check

    If wordWrap Then
        Call BuildWrap
        If Not suppressSnap Then ' snap only when the caret is driving the view
            Call CaretToVis(vRow, vCol)
            If vRow < topVis Then topVis = vRow
            If vRow > topVis + visRows - 1 Then topVis = vRow - visRows + 1
        End If
        If topVis > visCount - visRows Then topVis = visCount - visRows
        If topVis < 0 Then topVis = 0
        leftCol = 0 ' wrapped text never scrolls sideways

        ' Update scrollbar for word wrap
        totalTextHeight = visCount
        If totalTextHeight > 0 And visRows > 0 Then
            scrollbarVisible = -1
            scrollbarHeight = visRows * fh * (visRows / totalTextHeight)
            If scrollbarHeight < 20 Then scrollbarHeight = 20 ' Minimum thumb size
            If scrollbarHeight > visRows * fh Then scrollbarHeight = visRows * fh
            If totalTextHeight > visRows Then ' guard: no divide-by-zero when content just fits
                scrollRatio = CSng(topVis) / CSng(totalTextHeight - visRows)
            Else
                scrollRatio = 0
            End If
            If totalTextHeight <= visRows Then
                scrollbarY = MBHEIGHT
                scrollbarVisible = 0 ' Hide if content fits
            Else
                scrollbarY = MBHEIGHT + scrollRatio * (visRows * fh - scrollbarHeight)
            End If
            scrollbarMaxY = MBHEIGHT + visRows * fh - scrollbarHeight
        Else
            scrollbarVisible = 0
        End If

    Else ' No word wrap
        If Not suppressSnap Then ' snap only when the caret is driving the view
            If caretRow < topLine Then topLine = caretRow
            If caretRow > topLine + visRows - 1 Then topLine = caretRow - visRows + 1

            ' Horizontal scrolling logic remains the same
            If caretCol < leftCol Then leftCol = caretCol
            If caretCol > leftCol + visCols - 1 Then leftCol = caretCol - visCols + 1
        End If
        If topLine < 0 Then topLine = 0
        If leftCol < 0 Then leftCol = 0

        ' Update scrollbar for line-based scrolling
        totalTextHeight = lineCount
        If totalTextHeight > 0 And visRows > 0 Then
            scrollbarVisible = -1
            scrollbarHeight = visRows * fh * (visRows / totalTextHeight)
            If scrollbarHeight < 20 Then scrollbarHeight = 20 ' Minimum thumb size
            If scrollbarHeight > visRows * fh Then scrollbarHeight = visRows * fh

            maxScroll = totalTextHeight - visRows
            If maxScroll < 0 Then maxScroll = 0

            If maxScroll > 0 Then
                scrollRatio = CSng(topLine) / CSng(maxScroll)
            Else
                scrollRatio = 0
            End If

            If totalTextHeight <= visRows Then
                scrollbarY = MBHEIGHT
                scrollbarVisible = 0 ' Hide if content fits
            Else
                scrollbarY = MBHEIGHT + scrollRatio * (visRows * fh - scrollbarHeight)
            End If
            scrollbarMaxY = MBHEIGHT + visRows * fh - scrollbarHeight
        Else
            scrollbarVisible = 0
        End If
    End If
End Sub

' =====================================================================
'  RENDERING  (manual _DISPLAY = flicker-free)
'  Render = PaintEditor + _Display. The file dialog reuses PaintEditor
'  to redraw a fresh editor frame underneath its dim+panel each loop.
' =====================================================================
Sub Render
    Call PaintEditor
    _Display
End Sub

Sub PaintEditor
    Dim i As Integer, rowIdx As Long, y As Integer, s As String, k As Long

    Cls , themeBG
    Color themeFG

    If matchRow >= 0 Then Call DrawMatch ' find-match box behind the text

    If wordWrap Then
        Call BuildWrap
        For i = 0 To visRows - 1
            k = topVis + i
            If k >= visCount Then Exit For
            s = Mid$(docLine$(visLogRow(k)), visStart(k) + 1, visLen(k))
            y = MBHEIGHT + i * fh
            _PrintString (0, y), s
        Next i
    Else
        For i = 0 To visRows - 1
            rowIdx = topLine + i
            If rowIdx >= lineCount Then Exit For
            s = docLine$(rowIdx)
            If leftCol > 0 Then
                If Len(s) > leftCol Then s = Mid$(s, leftCol + 1) Else s = ""
            End If
            y = MBHEIGHT + i * fh
            _PrintString (0, y), s
        Next i
    End If

    If selActive Then Call DrawSelection ' reverse-video overlay, on top of the text
    Call DrawCaret
    Call DrawStatusBar
    Call DrawMenuBar
    If menuOpen Then Call DrawDropdown ' drawn last so it sits on top
    If ctxOpen Then Call DrawContext ' right-click menu on very top

    ' Draw the scrollbar if needed
    If scrollbarVisible Then Call DrawScrollBar
End Sub

Sub DrawCaret
    Dim cx As Integer, cy As Integer, vRow As Long, vCol As Long
    If menuOpen Then Exit Sub ' hide caret while a menu is up
    ' blink ~every half second
    If (Int(Timer * 2) Mod 2) <> 0 Then Exit Sub
    If wordWrap Then
        Call CaretToVis(vRow, vCol)
        If vRow < topVis Or vRow >= topVis + visRows Then Exit Sub
        cx = vCol * fw
        cy = MBHEIGHT + (vRow - topVis) * fh
    Else
        If caretRow < topLine Or caretRow >= topLine + visRows Then Exit Sub
        cx = (caretCol - leftCol) * fw
        cy = MBHEIGHT + (caretRow - topLine) * fh
    End If
    If cx < 0 Or cx > winW Then Exit Sub
    Line (cx, cy)-(cx, cy + fh - 1), themeCaret
End Sub

Sub DrawStatusBar
    Dim y As Integer, nm As String, star As String, info As String
    y = winH - SBHEIGHT
    Line (0, y)-(winW - 1, winH - 1), _RGB32(45, 45, 48), BF
    Color _RGB32(230, 230, 230)
    If Len(currentFile) = 0 Then nm = "Untitled" Else nm = currentFile
    If isDirty Then star = " *" Else star = ""
    info = " " + nm + star + "   Ln " + LTrim$(Str$(caretRow + 1)) + ", Col " + LTrim$(Str$(caretCol + 1))
    If wordWrap Then info = info + "   [Wrap]"
    If HasSelection% Then info = info + "   [Sel]"
    _PrintString (0, y + 3), info
End Sub

' ---- Draw the vertical scrollbar ----
Sub DrawScrollBar
    Dim trackX As Integer
    trackX = winW - SCROLLBAR_WIDTH

    ' Draw scrollbar track (background)
    Line (trackX, MBHEIGHT)-(winW - 1, winH - SBHEIGHT - 1), _RGB32(50, 50, 55), BF

    ' Draw scrollbar thumb
    If scrollbarDragging Then
        Line (trackX, scrollbarY)-(winW - 1, scrollbarY + scrollbarHeight - 1), _RGB32(100, 150, 220), BF ' Highlighted while dragging
    Else
        Line (trackX, scrollbarY)-(winW - 1, scrollbarY + scrollbarHeight - 1), _RGB32(80, 80, 90), BF
    End If

    ' Draw a simple border around the thumb
    Line (trackX, scrollbarY)-(winW - 1, scrollbarY + scrollbarHeight - 1), _RGB32(120, 120, 130), B
End Sub

' =====================================================================
'  MENU BAR  (hand-built dropdown windows)
' =====================================================================
Sub InitMenus
    Dim i As Integer, x As Integer

    menuTitle$(0) = "File"
    menuTitle$(1) = "Edit"
    menuTitle$(2) = "Format"
    menuTitle$(3) = "Help"

    ' clickable title rectangles (8px pad each side)
    x = 0
    For i = 0 To NUM_MENUS - 1
        menuW(i) = (Len(menuTitle$(i)) * fw) + 16
        menuX(i) = x
        x = x + menuW(i)
    Next i

    ' --- File ---
    itemCount(0) = 8
    itemText$(0, 0) = "New          Ctrl+N": itemCmd(0, 0) = CMD_NEW
    itemText$(0, 1) = "Open...      Ctrl+O": itemCmd(0, 1) = CMD_OPEN
    itemText$(0, 2) = "Merge at Top...": itemCmd(0, 2) = CMD_MERGE_TOP
    itemText$(0, 3) = "Merge at Bottom...": itemCmd(0, 3) = CMD_MERGE_BOTTOM
    itemText$(0, 4) = "Save         Ctrl+S": itemCmd(0, 4) = CMD_SAVE
    itemText$(0, 5) = "Save As...": itemCmd(0, 5) = CMD_SAVEAS
    itemText$(0, 6) = "-": itemCmd(0, 6) = CMD_SEP
    itemText$(0, 7) = "Quit         Ctrl+Q": itemCmd(0, 7) = CMD_QUIT

    ' --- Edit ---
    itemCount(1) = 5
    itemText$(1, 0) = "Undo         Ctrl+Z": itemCmd(1, 0) = CMD_UNDO
    itemText$(1, 1) = "Redo         Ctrl+Y": itemCmd(1, 1) = CMD_REDO
    itemText$(1, 2) = "-": itemCmd(1, 2) = CMD_SEP
    itemText$(1, 3) = "Find...      Ctrl+F": itemCmd(1, 3) = CMD_FIND
    itemText$(1, 4) = "Replace...   Ctrl+R": itemCmd(1, 4) = CMD_REPLACE

    ' --- Format ---  (two leading spaces reserve room for the check glyph)
    itemCount(2) = 7
    itemText$(2, 0) = "  Word Wrap": itemCmd(2, 0) = CMD_WRAP
    itemText$(2, 1) = "-": itemCmd(2, 1) = CMD_SEP
    itemText$(2, 2) = "  Default": itemCmd(2, 2) = CMD_THEME_DEFAULT
    itemText$(2, 3) = "  Amber": itemCmd(2, 3) = CMD_THEME_AMBER
    itemText$(2, 4) = "  Green Phosphor": itemCmd(2, 4) = CMD_THEME_GREEN
    itemText$(2, 5) = "  Light": itemCmd(2, 5) = CMD_THEME_LIGHT
    itemText$(2, 6) = "  Blue": itemCmd(2, 6) = CMD_THEME_BLUE

    ' --- Help ---
    itemCount(3) = 1
    itemText$(3, 0) = "About Notepad": itemCmd(3, 0) = CMD_ABOUT

    ' --- right-click context menu ---
    ctxLabel$(0) = "Cut": ctxCmd(0) = CMD_CUT
    ctxLabel$(1) = "Copy": ctxCmd(1) = CMD_COPY
    ctxLabel$(2) = "Paste": ctxCmd(2) = CMD_PASTE
    ctxLabel$(3) = "Select All": ctxCmd(3) = CMD_SELALL
End Sub

Sub DrawMenuBar
    Dim i As Integer
    Line (0, 0)-(winW - 1, MBHEIGHT - 1), _RGB32(45, 45, 48), BF
    For i = 0 To NUM_MENUS - 1
        If menuOpen And activeMenu = i Then
            Line (menuX(i), 0)-(menuX(i) + menuW(i) - 1, MBHEIGHT - 1), _RGB32(0, 90, 160), BF
        End If
        Color _RGB32(230, 230, 230)
        _PrintString (menuX(i) + 8, 3), menuTitle$(i)
    Next i
End Sub

Sub DrawDropdown
    Dim i As Integer, iy As Integer, usable As Integer
    ' box + border (geometry computed in OpenMenu)
    Line (ddX, ddY)-(ddX + ddW - 1, ddY + ddH - 1), _RGB32(60, 60, 65), BF
    Line (ddX, ddY)-(ddX + ddW - 1, ddY + ddH - 1), _RGB32(120, 120, 130), B
    For i = 0 To itemCount(activeMenu) - 1
        iy = ddY + 4 + i * fh
        If itemCmd(activeMenu, i) = CMD_SEP Then
            Line (ddX + 4, iy + fh \ 2)-(ddX + ddW - 5, iy + fh \ 2), _RGB32(100, 100, 110)
        Else
            usable = ItemUsable%(itemCmd(activeMenu, i))
            If i = hoverItem And usable Then
                Line (ddX + 2, iy)-(ddX + ddW - 3, iy + fh - 1), _RGB32(0, 90, 160), BF
            End If
            If usable Then
                Color _RGB32(235, 235, 235)
            Else
                Color _RGB32(130, 130, 130)
            End If
            _PrintString (ddX + 10, iy), itemText$(activeMenu, i)
            If itemCmd(activeMenu, i) = CMD_WRAP And wordWrap Then
                _PrintString (ddX + 10, iy), Chr$(251) ' check mark over the leading space
            ElseIf itemCmd(activeMenu, i) >= CMD_THEME_DEFAULT And itemCmd(activeMenu, i) <= CMD_THEME_BLUE Then
                If (itemCmd(activeMenu, i) - CMD_THEME_DEFAULT) = currentTheme Then
                    _PrintString (ddX + 10, iy), Chr$(251)
                End If
            End If
        End If
    Next i
End Sub

Sub OpenMenu (mi As Integer)
    Dim i As Integer, maxLen As Integer
    activeMenu = mi
    menuOpen = -1
    hoverItem = -1
    ' size the dropdown to its widest item
    maxLen = 0
    For i = 0 To itemCount(mi) - 1
        If Len(itemText$(mi, i)) > maxLen Then maxLen = Len(itemText$(mi, i))
    Next i
    ddW = maxLen * fw + 24
    ddX = menuX(mi)
    If ddX + ddW > winW Then ddX = winW - ddW ' keep it on-screen
    ddY = MBHEIGHT
    ddH = itemCount(mi) * fh + 8
End Sub

Sub CloseMenu
    menuOpen = 0
    activeMenu = -1
    hoverItem = -1
End Sub

Sub ActivateItem (mi As Integer, it As Integer)
    Dim cmdId As Integer
    cmdId = itemCmd(mi, it)
    If Not ItemUsable%(cmdId) Then Exit Sub
    Call CloseMenu
    Select Case cmdId
        Case CMD_NEW: Call DoNew
        Case CMD_OPEN: Call DoOpen
        Case CMD_MERGE_TOP: Call DoMergeTop
        Case CMD_MERGE_BOTTOM: Call DoMergeBottom
        Case CMD_SAVE: Call DoSave
        Case CMD_SAVEAS: Call DoSaveAs
        Case CMD_QUIT: Call DoQuit
        Case CMD_ABOUT: Call DoAbout
        Case CMD_UNDO: Call DoUndo
        Case CMD_REDO: Call DoRedo
        Case CMD_WRAP: Call DoToggleWrap
        Case CMD_FIND: Call DoFind
        Case CMD_REPLACE: Call DoReplace
        Case CMD_THEME_DEFAULT: Call SetTheme(0)
        Case CMD_THEME_AMBER: Call SetTheme(1)
        Case CMD_THEME_GREEN: Call SetTheme(2)
        Case CMD_THEME_LIGHT: Call SetTheme(3)
        Case CMD_THEME_BLUE: Call SetTheme(4)
    End Select
End Sub

' Is a menu command currently actionable? Separators and disabled gaps
' never are; Undo/Redo only when their stacks hold something.
Function ItemUsable% (cmdId As Integer)
    Select Case cmdId
        Case CMD_SEP: ItemUsable% = 0
        Case CMD_DISABLED: ItemUsable% = 0
        Case CMD_UNDO: ItemUsable% = (undoSP > 0)
        Case CMD_REDO: ItemUsable% = (redoSP > 0)
        Case Else: ItemUsable% = -1
    End Select
End Function

' ---- mouse: drives the bar; left untouched it costs nothing ----------
Sub HandleMouse
    Static prevL As Integer, prevR As Integer
    Static lastMX As Integer, lastMY As Integer
    Static dragging As Integer
    Dim mx As Integer, my As Integer, ld As Integer, rd As Integer
    Dim mi As Integer, it As Integer, h As Integer, ey As Integer
    Dim maxTop As Long, menuWasOpen As Integer
    Dim newScrollPos As Integer
    Dim totalTextHeight As Long
    Dim maxScroll As Long
    Dim scrollRatio As Double

    While _MouseInput: Wend ' drain the queue this frame
    mx = _MouseX
    my = _MouseY
    ld = (_MouseButton(1) <> 0)
    rd = (_MouseButton(2) <> 0)
    menuWasOpen = menuOpen

    ' --- Scrollbar Handling ---
    ' (drag keeps capture even if the pointer strays out of the 15px column)
    If scrollbarVisible And (mx >= winW - SCROLLBAR_WIDTH Or scrollbarDragging) Then
        If ld And Not prevL And Not scrollbarDragging Then
            ' Check if clicked on the thumb
            If my >= scrollbarY And my < scrollbarY + scrollbarHeight Then
                scrollbarDragging = -1
                scrollbarDragOffset = my - scrollbarY
                ' Check if clicked above or below the thumb
            ElseIf my < scrollbarY Then
                ' Scroll up one page
                suppressSnap = -1 ' user is scrolling away from the caret
                If wordWrap Then
                    topVis = topVis - visRows
                    If topVis < 0 Then topVis = 0
                Else
                    topLine = topLine - visRows
                    If topLine < 0 Then topLine = 0
                End If
                Call EnsureCaretVisible ' Update scrollbar position
            ElseIf my >= scrollbarY + scrollbarHeight Then
                ' Scroll down one page
                suppressSnap = -1 ' user is scrolling away from the caret
                If wordWrap Then
                    topVis = topVis + visRows
                    If topVis > visCount - visRows Then topVis = visCount - visRows
                    If topVis < 0 Then topVis = 0
                Else
                    topLine = topLine + visRows
                    maxScroll = lineCount - visRows
                    If maxScroll < 0 Then maxScroll = 0
                    If topLine > maxScroll Then topLine = maxScroll
                End If
                Call EnsureCaretVisible ' Update scrollbar position
            End If
        End If

        If scrollbarDragging And ld Then
            suppressSnap = -1 ' user is scrolling away from the caret
            newScrollPos = my - scrollbarDragOffset
            If newScrollPos < MBHEIGHT Then newScrollPos = MBHEIGHT
            If newScrollPos > scrollbarMaxY Then newScrollPos = scrollbarMaxY

            ' Convert scrollbar position to document position
            If wordWrap Then
                totalTextHeight = visCount
                maxScroll = totalTextHeight - visRows
            Else
                totalTextHeight = lineCount
                maxScroll = totalTextHeight - visRows
            End If
            If maxScroll < 0 Then maxScroll = 0

            If visRows * fh - scrollbarHeight > 0 Then
                scrollRatio = CSng(newScrollPos - MBHEIGHT) / CSng(visRows * fh - scrollbarHeight)
            Else
                scrollRatio = 0
            End If

            If wordWrap Then
                topVis = scrollRatio * maxScroll
                If topVis > visCount - visRows Then topVis = visCount - visRows
                If topVis < 0 Then topVis = 0
            Else
                topLine = scrollRatio * maxScroll
                If topLine > maxScroll Then topLine = maxScroll
                If topLine < 0 Then topLine = 0
            End If
        End If

        If Not ld Then
            scrollbarDragging = 0
            scrollbarDragOffset = 0
        End If
    End If

    ' --- the right-click menu captures all input while it is open ---
    If ctxOpen Then
        If mx <> lastMX Or my <> lastMY Then ctxHover = CtxItemAt%(mx, my)
        If ld And Not prevL Then
            it = CtxItemAt%(mx, my)
            If it >= 0 Then Call ActivateCtx(it) Else ctxOpen = 0
        ElseIf rd And Not prevR Then
            ctxOpen = 0
        End If
        prevL = ld: prevR = rd: lastMX = mx: lastMY = my
        Exit Sub
    End If

    ' --- menu bar / dropdown ---
    If menuOpen Then
        If mx <> lastMX Or my <> lastMY Then
            h = ItemAt%(mx, my)
            If h >= 0 Then hoverItem = h
        End If
    End If
    If ld And Not prevL Then
        mi = MenuTitleAt%(mx, my)
        If mi >= 0 Then
            If menuOpen And activeMenu = mi Then
                Call CloseMenu
            Else
                Call OpenMenu(mi)
            End If
        ElseIf menuOpen Then
            it = ItemAt%(mx, my)
            If it >= 0 Then Call ActivateItem(activeMenu, it) Else Call CloseMenu
        End If
    End If
    If menuOpen Then
        mi = MenuTitleAt%(mx, my)
        If mi >= 0 And mi <> activeMenu Then Call OpenMenu(mi)
    End If

    ' --- document mouse (only when no dropdown is / was open this frame) ---
    ' Exclude scrollbar area, and never leak clicks in mid-drag
    If (Not menuWasOpen) And (Not menuOpen) And (Not scrollbarDragging) And mx < winW - SCROLLBAR_WIDTH Then
        ' left press: place the caret and start a drag
        If ld And Not prevL Then
            If InTextArea%(mx, my) Then
                Call PointToCaret(mx, my)
                anchorRow = caretRow: anchorCol = caretCol
                selActive = 0
                matchRow = -1
                dragging = -1
            End If
        ElseIf ld And dragging Then
            ' drag: extend the selection, auto-scrolling at the edges
            ey = my
            If ey < MBHEIGHT Then
                ey = MBHEIGHT
                If wordWrap Then
                    If topVis > 0 Then topVis = topVis - 1
                ElseIf topLine > 0 Then
                    topLine = topLine - 1
                End If
            ElseIf ey >= winH - SBHEIGHT Then
                ey = winH - SBHEIGHT - 1
                If wordWrap Then
                    If topVis < visCount - visRows Then topVis = topVis + 1
                Else
                    maxTop = lineCount - visRows
                    If topLine < maxTop Then topLine = topLine + 1
                End If
            End If
            Call PointToCaret(mx, ey)
            If caretRow <> anchorRow Or caretCol <> anchorCol Then selActive = -1 Else selActive = 0
        End If
        If (Not ld) And prevL Then dragging = 0 ' released

        ' right press: open the context menu at the cursor
        If rd And Not prevR Then
            If InTextArea%(mx, my) Then
                If Not PointInSelection%(mx, my) Then
                    Call PointToCaret(mx, my)
                    selActive = 0
                End If
                Call OpenContext(mx, my)
            End If
        End If
    End If

    prevL = ld: prevR = rd: lastMX = mx: lastMY = my
End Sub

Function MenuTitleAt% (mx As Integer, my As Integer)
    Dim i As Integer
    MenuTitleAt% = -1
    If my < 0 Or my >= MBHEIGHT Then Exit Function
    For i = 0 To NUM_MENUS - 1
        If mx >= menuX(i) And mx < menuX(i) + menuW(i) Then
            MenuTitleAt% = i
            Exit Function
        End If
    Next i
End Function

Function ItemAt% (mx As Integer, my As Integer)
    Dim i As Integer, iy As Integer
    ItemAt% = -1
    If activeMenu < 0 Then Exit Function
    If mx < ddX Or mx >= ddX + ddW Then Exit Function
    For i = 0 To itemCount(activeMenu) - 1
        iy = ddY + 4 + i * fh
        If my >= iy And my < iy + fh Then
            ItemAt% = i
            Exit Function
        End If
    Next i
End Function

' ---- keyboard navigation while a dropdown is open -------------------
Sub MenuKey (kkey As String)
    Dim ext As Integer, c As Integer
    If Len(kkey) = 2 Then
        ext = Asc(kkey, 2)
        Select Case ext
            Case 75: Call MenuPrev ' Left  -> previous menu
            Case 77: Call MenuNext ' Right -> next menu
            Case 72: Call MenuMove(-1) ' Up
            Case 80: Call MenuMove(1) ' Down
        End Select
        Exit Sub
    End If
    c = Asc(kkey)
    If c = 27 Then ' Esc closes
        Call CloseMenu
    ElseIf c = 13 Then ' Enter runs the highlighted item
        If hoverItem >= 0 Then Call ActivateItem(activeMenu, hoverItem)
    End If
End Sub

Sub MenuMove (dir As Integer)
    Dim n As Integer, i As Integer, guard As Integer
    n = itemCount(activeMenu)
    i = hoverItem
    guard = 0
    Do
        i = i + dir
        If i < 0 Then i = n - 1
        If i >= n Then i = 0
        guard = guard + 1
        If guard > n Then Exit Do ' all items unselectable (e.g. Edit)
    Loop Until ItemUsable%(itemCmd(activeMenu, i))
    hoverItem = i
End Sub

Sub MenuNext
    Dim mi As Integer
    mi = activeMenu + 1
    If mi >= NUM_MENUS Then mi = 0
    Call OpenMenu(mi)
    Call MenuMove(1) ' land on first selectable item
End Sub

Sub MenuPrev
    Dim mi As Integer
    mi = activeMenu - 1
    If mi < 0 Then mi = NUM_MENUS - 1
    Call OpenMenu(mi)
    Call MenuMove(1)
End Sub

' =====================================================================
'  FILE COMMANDS  (now backed by the hand-built browser)
' =====================================================================
Sub DoNew
    If Not ConfirmDiscard% Then Exit Sub
    Call ResetBuffer
    currentFile = ""
    isDirty = 0
    savedBlob = ""
    Call UndoReset
    wrapDirty = -1
    matchRow = -1
End Sub

Sub DoOpen
    If Not ConfirmDiscard% Then Exit Sub
    Dim fn As String
    fn = FileDialog$(FD_OPEN, currentFile)
    If Len(fn) = 0 Then Exit Sub
    Call LoadFromDisk(fn)
End Sub

' Merge at Top: prepend a picked file to the whole document.
' Uses the paste pipeline for one-step undo, but the caret is parked at
' (0,0) first so InsertMultiline lands the blob before every
' existing line. If the picked file doesn't already end in a newline
' we add one, so the current top line doesn't get glued to the tail
' of the merged content.
Sub DoMergeTop
    Dim fn As String, ff As Integer, sz As Long, blob As String, ig As Long
    fn = FileDialog$(FD_OPEN, currentFile)
    If Len(fn) = 0 Then Exit Sub
    If _FileExists(fn) = 0 Then
        ig = _MessageBox("Notepad", "File not found:" + Chr$(10) + fn, "ok", "error")
        Exit Sub
    End If
    ff = FreeFile
    Open fn For Binary As #ff
    sz = LOF(ff)
    blob = Space$(sz)
    If sz > 0 Then Get #ff, 1, blob
    Close #ff
    If Len(blob) = 0 Then Exit Sub ' empty file = nothing to merge, no undo noise

    ' Ensure a clean line break between the merged content and the
    ' existing top line. (StripCR$ strips \r during insertion, so the
    ' check is against \n only.)
    If Right$(blob, 1) <> Chr$(10) Then blob = blob + Chr$(10)

    ' Drop any selection and park the caret at the very top before
    ' the undo checkpoint fires. BeginEdit(KIND_TYPE) then just
    ' snapshots the doc (no RemoveSelSpan) and InsertMultiline
    ' streams the blob in.
    selActive = 0
    caretRow = 0
    caretCol = 0
    undoBreak = -1
    Call BeginEdit(KIND_TYPE)
    Call InsertMultiline(blob)
    undoBreak = -1
    matchRow = -1
    suppressSnap = 0
    Call EnsureCaretVisible
End Sub

' Merge at Bottom: append a picked file to the whole document.
' Caret is parked at end-of-last-line; if that line is non-empty a
' leading \n is prepended to the blob so appended content starts on
' its own row. Otherwise the doc already ends with a blank line and
' no separator is needed.
Sub DoMergeBottom
    Dim fn As String, ff As Integer, sz As Long, blob As String, ig As Long
    Dim lastRow As Long
    fn = FileDialog$(FD_OPEN, currentFile)
    If Len(fn) = 0 Then Exit Sub
    If _FileExists(fn) = 0 Then
        ig = _MessageBox("Notepad", "File not found:" + Chr$(10) + fn, "ok", "error")
        Exit Sub
    End If
    ff = FreeFile
    Open fn For Binary As #ff
    sz = LOF(ff)
    blob = Space$(sz)
    If sz > 0 Then Get #ff, 1, blob
    Close #ff
    If Len(blob) = 0 Then Exit Sub ' empty file = nothing to merge, no undo noise

    ' Drop any selection and drive the caret to the very end of the
    ' document. lineCount is always >= 1 (the buffer keeps at least
    ' one line) but guard anyway.
    selActive = 0
    lastRow = lineCount - 1
    If lastRow < 0 Then lastRow = 0
    caretRow = lastRow
    caretCol = Len(docLine$(lastRow))

    ' If the existing final line still has text on it, start the
    ' merged content on a fresh row so it doesn't get glued to the
    ' tail of that line.
    If Len(docLine$(lastRow)) > 0 Then blob = Chr$(10) + blob

    undoBreak = -1
    Call BeginEdit(KIND_TYPE)
    Call InsertMultiline(blob)
    undoBreak = -1
    matchRow = -1
    suppressSnap = 0
    Call EnsureCaretVisible
End Sub

' Quick-save: writes straight to the known file; only browses if untitled.
Sub DoSave
    Dim fn As String
    If Len(currentFile) = 0 Then
        fn = FileDialog$(FD_SAVE, "")
        If Len(fn) = 0 Then Exit Sub
        currentFile = fn
    End If
    Call SaveToDisk(currentFile)
End Sub

' Always browses, even when a file is already named (true "Save As").
Sub DoSaveAs
    Dim fn As String
    fn = FileDialog$(FD_SAVE, currentFile)
    If Len(fn) = 0 Then Exit Sub
    currentFile = fn
    Call SaveToDisk(currentFile)
End Sub

Sub DoQuit
    If Not ConfirmDiscard% Then Exit Sub
    quitFlag = -1
End Sub

' =====================================================================
'  FILE COMMANDS  (now backed by the hand-built browser)
' =====================================================================
' ... (existing code) ...

Sub DoAbout
    Dim ig As Long
    ' --- Original simple message box ---
    ' ig = _MessageBox("Notepad", "Notepad - QB64-PE Edition" + Chr$(10) + "A hand-built text editor with hand-built menus.", "info", "info")

    ' --- New: Custom Help/About Dialog ---
    Dim kk As String
    Dim helpDone As Integer
    Dim helpX As Integer, helpY As Integer, helpW As Integer, helpH As Integer
    Dim textY As Integer
    Dim infoText$(1 To 10) ' Adjust size as needed
    Dim i As Integer
    Dim linkY As Integer
    Dim mx As Integer, my As Integer, ld As Integer

    ' Define help text
    infoText$(1) = "Notepad - QB64-PE Edition"
    infoText$(2) = "=========================="
    infoText$(3) = "A hand-built text editor with hand-built menus."
    infoText$(4) = ""
    infoText$(5) = "Features:"
    infoText$(6) = "- Typing, Enter, Backspace, Delete"
    infoText$(7) = "- Arrow keys, Home, End, Page Up/Down"
    infoText$(8) = "- Undo/Redo (Ctrl+Z/Y)"
    infoText$(9) = "- Find/Replace (Ctrl+F/R)"
    infoText$(10) = "- Word Wrap, Themes, File Browser"

    ' Calculate dimensions based on text
    helpW = 500 ' Fixed width for simplicity
    helpH = UBound(infoText$) * fh + fh * 4 ' Text lines + padding + link
    helpX = (winW - helpW) \ 2
    helpY = (winH - helpH) \ 2

    helpDone = 0
    linkY = helpY + helpH - fh - 10 ' Position for the link

    Do

        ' Handle input
        While _MouseInput: Wend
        mx = _MouseX
        my = _MouseY
        ld = (_MouseButton(1) <> 0)
        kk = InKey$

        ' Check for link click (simple area check)
        If ld And my >= linkY And my <= linkY + fh And mx >= helpX + 10 And mx <= helpX + 10 + 20 * fw Then
            ' Simulate clicking a link - could open a browser or show more info
            ' For now, just close the dialog or indicate action
            ' Let's just close it for simplicity
            helpDone = -1
        End If

        ' Check for Escape key
        If kk = Chr$(27) Then helpDone = -1 ' Esc key

        ' Render the editor background
        Call PaintEditor
        _Display ' Needed to see the editor background

        ' Draw the help panel (dim background is part of PaintEditor's dimming if done correctly,
        ' but here we draw over it)
        Line (helpX, helpY)-(helpX + helpW - 1, helpY + helpH - 1), _RGB32(40, 40, 46), BF ' Background
        Line (helpX, helpY)-(helpX + helpW - 1, helpY + helpH - 1), _RGB32(120, 120, 135), B ' Border

        ' Print the info text
        Color _RGB32(235, 235, 235) ' Light text color
        For i = 1 To UBound(infoText$)
            If Len(infoText$(i)) > 0 Then ' Don't print empty lines if used for spacing logic
                _PrintString (helpX + 10, helpY + 10 + (i - 1) * fh), infoText$(i)
            End If
        Next i

        ' Print a "link-like" text for more info or credits
        Color _RGB32(100, 150, 255) ' Blue-ish color for link
        _PrintString (helpX + 10, linkY), "Press ESC or Click Here to Close"
        ' Underline the link text (optional visual cue)
        Line (helpX + 10, linkY + fh - 1)-(helpX + 10 + 32 * fw, linkY + fh - 1), _RGB32(100, 150, 255)


        _Display
        _Limit 60
    Loop Until helpDone

    ' Optionally consume remaining key events after closing
    While Len(InKey$): Wend

End Sub

' ... (rest of existing code) ...

' Returns -1 to proceed, 0 to cancel the pending action.
' QB64's _MESSAGEBOX returns only 1/0, so this is a 2-way (not 3-way)
' prompt: Yes = discard, No = save first (and proceed only if it saves).
Function ConfirmDiscard% ()
    Dim r As Long
    If Not isDirty Then ConfirmDiscard% = -1: Exit Function
    r = _MessageBox("Notepad", "Discard unsaved changes?" + Chr$(10) + "(No = save first)", "yesno", "question")
    If r = 1 Then
        ConfirmDiscard% = -1
    Else
        Call DoSave
        If isDirty Then ConfirmDiscard% = 0 Else ConfirmDiscard% = -1
    End If
End Function

' =====================================================================
'  FILE BROWSER  (modal dialog for Open / Save As)
'  Reads the current directory via _FILES$, separates folders from
'  files with _DIREXISTS, and navigates with ChDir. Returns an absolute
'  path (built from _CWD$) or "" if cancelled.
' =====================================================================
Function FileDialog$ (modeFlag As Integer, startPath As String)
    Dim kk As String, sep As Long, dpart As String, bpart As String

    fdMode = modeFlag
    fdResult = ""
    fdDone = 0
    fdName = ""
    fdSel = 0
    fdTop = 0
    fdArmed = 0 ' swallow the click that launched us until released

    Call FDScanDrives ' populate fdDrives$ / fdHasDrives

    ' --- panel geometry (window size is fixed, so compute once) ---
    fdPW = 560: fdPH = 420
    fdPX = (winW - fdPW) \ 2: fdPY = (winH - fdPH) \ 2
    fdListX = fdPX + 8
    If fdHasDrives Then
        fdDriveY = fdPY + 6 + fh + 6 ' drive row under the title
        fdListY = fdPY + 6 + fh * 3 + 12 ' path + list shift down one row
    Else
        fdDriveY = 0
        fdListY = fdPY + 6 + fh * 2 + 6
    End If
    fdListW = fdPW - 16
    fdFieldY = fdPY + fdPH - fh * 2 - 14
    fdBtnY = fdPY + fdPH - fh - 6
    fdRows = (fdFieldY - fdListY) \ fh

    If fdMode = FD_SAVE Then fdOKtext = " Save " Else fdOKtext = " Open "
    fdCANtext = " Cancel "
    fdCANx2 = fdPX + fdPW - 10
    fdCANx1 = fdCANx2 - Len(fdCANtext) * fw
    fdOKx2 = fdCANx1 - 10
    fdOKx1 = fdOKx2 - Len(fdOKtext) * fw

    ' --- seed location / filename from startPath ---
    If Len(startPath) > 0 Then
        sep = LastSep&(startPath)
        If sep > 0 Then
            dpart = Left$(startPath, sep - 1)
            bpart = Mid$(startPath, sep + 1)
            If Len(dpart) > 0 Then
                If _DirExists(dpart) Then ChDir dpart
            End If
            fdName = bpart
        Else
            fdName = startPath
        End If
    End If

    If fdMode = FD_SAVE Then fdFocus = 1 Else fdFocus = 0 ' Save starts in the name field
    Call FDScan
    Call FDEnsureVisible

    Do
        Call FDHandleMouse
        kk = InKey$
        If Len(kk) > 0 Then Call FDHandleKey(kk)
        Call PaintEditor ' fresh editor frame underneath
        Call FDRender ' dim + panel on top
        _Display
        _Limit 60
    Loop Until fdDone

    FileDialog$ = fdResult
End Function

' Populate fdDrives$ with existing Windows drives. No-op on Linux/macOS.
' Uses _DirExists on each letter's root; that's a Win32 call under the hood
' but never touches drive contents, so it stays fast for A:..Z:.
Sub FDScanDrives
    Dim i As Integer, dLetter As String
    fdDriveCount = 0
    If PSEP <> "\" Then
        fdHasDrives = 0
        Exit Sub
    End If
    fdHasDrives = -1
    For i = 0 To 25
        dLetter = Chr$(65 + i)
        If _DirExists(dLetter + ":\") Then
            fdDrives$(fdDriveCount) = dLetter
            fdDriveCount = fdDriveCount + 1
        End If
    Next i
End Sub

' Switch drive: chdir to root, then rescan the dialog listing.
Sub FDSetDrive (dLetter As String)
    Dim root As String
    root = dLetter + ":\"
    If Not _DirExists(root) Then Exit Sub ' guard: drive vanished
    ChDir root
    Call FDScan
    fdSel = 0
    fdTop = 0
End Sub

' Draw the drive-button strip and record hit-boxes for the mouse handler.
Sub FDDrawDrives
    Dim i As Integer, x As Integer, w As Integer
    Dim dLetter As String, curDrive As String, isCur As Integer
    If Not fdHasDrives Then Exit Sub
    curDrive = UCase$(Left$(_CWD$, 1))
    Color _RGB32(210, 210, 210)
    _PrintString (fdPX + 8, fdDriveY), "Drive:"
    x = fdPX + 8 + 7 * fw ' start just after the "Drive:" label
    w = 3 * fw + 6 ' each button ~= "C:" + padding
    For i = 0 To fdDriveCount - 1
        dLetter = fdDrives$(i)
        isCur = (dLetter = curDrive)
        fdDriveX(i) = x
        fdDriveW(i) = w
        If isCur Then
            Line (x, fdDriveY - 2)-(x + w - 1, fdDriveY + fh + 1), _RGB32(0, 90, 160), BF
            Color _RGB32(255, 255, 255)
        Else
            Line (x, fdDriveY - 2)-(x + w - 1, fdDriveY + fh + 1), _RGB32(70, 70, 80), BF
            Color _RGB32(225, 225, 225)
        End If
        _PrintString (x + 3, fdDriveY), dLetter + ":"
        x = x + w + 4
    Next i
End Sub

' Read the current directory into fdEntry$/fdIsDir: ".." then folders
' (alphabetical) then files (alphabetical).
Sub FDScan
    Dim nm As String, i As Long
    Dim dlist$(0 To 2047), flist$(0 To 2047)
    Dim nd As Long, nf As Long
    nd = 0: nf = 0

    nm = _Files$("*")
    Do While Len(nm) > 0
        If nm <> "." And nm <> ".." Then
            If _DirExists(nm) Then
                If nd <= UBound(dlist$) Then dlist$(nd) = nm: nd = nd + 1
            Else
                If nf <= UBound(flist$) Then flist$(nf) = nm: nf = nf + 1
            End If
        End If
        nm = _Files$
    Loop

    Call FDSortCI(dlist$(), nd)
    Call FDSortCI(flist$(), nf)

    fdCount = 0
    fdEntry$(fdCount) = "..": fdIsDir(fdCount) = -1: fdCount = fdCount + 1
    For i = 0 To nd - 1
        fdEntry$(fdCount) = dlist$(i): fdIsDir(fdCount) = -1: fdCount = fdCount + 1
    Next i
    For i = 0 To nf - 1
        fdEntry$(fdCount) = flist$(i): fdIsDir(fdCount) = 0: fdCount = fdCount + 1
    Next i

    If fdSel >= fdCount Then fdSel = fdCount - 1
    If fdSel < 0 Then fdSel = 0
End Sub

' Case-insensitive insertion sort of a$(0..n-1).
Sub FDSortCI (a$(), n As Long)
    Dim i As Long, j As Long, kS As String, kU As String
    For i = 1 To n - 1
        kS = a$(i): kU = UCase$(kS)
        j = i - 1
        Do While j >= 0
            If UCase$(a$(j)) <= kU Then Exit Do
            a$(j + 1) = a$(j)
            j = j - 1
        Loop
        a$(j + 1) = kS
    Next i
End Sub

Sub FDRender
    Dim r As Integer, idx As Long, ry As Integer, s As String, pth As String, maxc As Integer
    Dim cur As String

    ' dim the editor behind the dialog
    Line (0, 0)-(winW - 1, winH - 1), _RGBA32(0, 0, 0, 130), BF
    ' panel
    Line (fdPX, fdPY)-(fdPX + fdPW - 1, fdPY + fdPH - 1), _RGB32(40, 40, 46), BF
    Line (fdPX, fdPY)-(fdPX + fdPW - 1, fdPY + fdPH - 1), _RGB32(120, 120, 135), B

    ' title
    Color _RGB32(235, 235, 235)
    If fdMode = FD_SAVE Then
        _PrintString (fdPX + 8, fdPY + 6), "Save File As"
    Else
        _PrintString (fdPX + 8, fdPY + 6), "Open File"
    End If

    ' drive-select row (Windows only) sits between the title and the path
    If fdHasDrives Then Call FDDrawDrives

    ' current path (truncated from the left if too long)
    Color _RGB32(150, 180, 220)
    pth = _CWD$
    maxc = (fdPW - 16) \ fw
    If Len(pth) > maxc Then pth = "..." + Right$(pth, maxc - 3)
    If fdHasDrives Then
        _PrintString (fdPX + 8, fdPY + 6 + fh * 2 + 6), pth
    Else
        _PrintString (fdPX + 8, fdPY + 6 + fh), pth
    End If

    ' list
    Line (fdListX, fdListY)-(fdListX + fdListW - 1, fdListY + fdRows * fh - 1), _RGB32(28, 28, 32), BF
    For r = 0 To fdRows - 1
        idx = fdTop + r
        If idx >= fdCount Then Exit For
        ry = fdListY + r * fh
        If idx = fdSel Then
            Line (fdListX, ry)-(fdListX + fdListW - 1, ry + fh - 1), _RGB32(0, 90, 160), BF
        End If
        If fdIsDir(idx) Then
            Color _RGB32(245, 220, 140) ' folders: warm
            s = "[" + fdEntry$(idx) + "]"
        Else
            Color _RGB32(225, 225, 225)
            s = fdEntry$(idx)
        End If
        maxc = (fdListW - 12) \ fw
        If Len(s) > maxc Then s = Left$(s, maxc)
        _PrintString (fdListX + 6, ry), s
    Next r

    ' filename field
    Color _RGB32(210, 210, 210)
    _PrintString (fdListX, fdFieldY + fh * 2 - 3), "File name:"
    Line (fdListX, fdFieldY)-(fdListX + fdListW - 1, fdFieldY + fh + 3), _RGB32(20, 20, 24), BF
    If fdFocus = 1 Then
        Line (fdListX, fdFieldY)-(fdListX + fdListW - 1, fdFieldY + fh + 3), _RGB32(90, 140, 210), B
    Else
        Line (fdListX, fdFieldY)-(fdListX + fdListW - 1, fdFieldY + fh + 3), _RGB32(70, 70, 80), B
    End If
    Color _RGB32(255, 255, 255)
    cur = ""
    If fdFocus = 1 And (Int(Timer * 2) Mod 2) = 0 Then cur = "_"
    _PrintString (fdListX + 4, fdFieldY + 2), fdName + cur

    ' buttons
    Call FDDrawButton(fdOKx1, fdBtnY, fdOKtext, -1)
    Call FDDrawButton(fdCANx1, fdBtnY, fdCANtext, 0)
End Sub

Sub FDDrawButton (x1 As Integer, y As Integer, label As String, primary As Integer)
    Dim x2 As Integer
    x2 = x1 + Len(label) * fw
    If primary Then
        Line (x1, y - 2)-(x2, y + fh + 1), _RGB32(0, 90, 160), BF
        Color _RGB32(255, 255, 255)
    Else
        Line (x1, y - 2)-(x2, y + fh + 1), _RGB32(70, 70, 80), BF
        Color _RGB32(225, 225, 225)
    End If
    _PrintString (x1, y), label
End Sub

Sub FDHandleKey (kk As String)
    Dim ext As Integer, c As Integer
    If Len(kk) = 2 Then
        ext = Asc(kk, 2)
        Select Case ext ' arrows move the list regardless of focus
            Case 72: Call FDMoveSel(-1) ' Up
            Case 80: Call FDMoveSel(1) ' Down
            Case 73: Call FDMoveSel(-fdRows) ' PgUp
            Case 81: Call FDMoveSel(fdRows) ' PgDn
            Case 71: fdSel = 0: Call FDEnsureVisible ' Home
            Case 79: fdSel = fdCount - 1: Call FDEnsureVisible ' End
        End Select
        Exit Sub
    End If

    c = Asc(kk)
    Select Case c
        Case 27 ' Esc -> cancel
            fdResult = "": fdDone = -1
        Case 9 ' Tab -> toggle list / field focus
            fdFocus = 1 - fdFocus
        Case 13 ' Enter
            Call FDEnter
        Case 8 ' Backspace (field only)
            If fdFocus = 1 Then
                If Len(fdName) > 0 Then fdName = Left$(fdName, Len(fdName) - 1)
            End If
        Case 32 To 126 ' type into the field (field focus only)
            If fdFocus = 1 Then fdName = fdName + kk
    End Select
End Sub

Sub FDHandleMouse
    Static prevDown As Integer
    Static lastClickIdx As Long, lastClickT As Double
    Dim mx As Integer, my As Integer, down As Integer, wheel As Integer
    Dim r As Integer, idx As Long, di As Integer

    wheel = 0
    While _MouseInput: wheel = wheel + _MouseWheel: Wend
    mx = _MouseX: my = _MouseY
    down = (_MouseButton(1) <> 0)

    ' Ignore input until the launching click is released once.
    If Not fdArmed Then
        If Not down Then fdArmed = -1
        prevDown = down
        Exit Sub
    End If

    ' wheel scroll over the list
    If wheel <> 0 Then
        fdTop = fdTop + wheel * 3
        If fdTop > fdCount - fdRows Then fdTop = fdCount - fdRows
        If fdTop < 0 Then fdTop = 0
    End If

    If down And Not prevDown Then
        ' drive-select strip (Windows only) -- test before the buttons/list
        If fdHasDrives And my >= fdDriveY - 2 And my <= fdDriveY + fh + 1 Then
            For di = 0 To fdDriveCount - 1
                If mx >= fdDriveX(di) And mx <= fdDriveX(di) + fdDriveW(di) - 1 Then
                    Call FDSetDrive(fdDrives$(di))
                    prevDown = down: Exit Sub
                End If
            Next di
        End If

        ' buttons
        If my >= fdBtnY - 2 And my <= fdBtnY + fh + 1 Then
            If mx >= fdOKx1 And mx <= fdOKx2 Then
                Call FDClickOK
                prevDown = down: Exit Sub
            ElseIf mx >= fdCANx1 And mx <= fdCANx2 Then
                fdResult = "": fdDone = -1
                prevDown = down: Exit Sub
            End If
        End If

        If my >= fdFieldY And my <= fdFieldY + fh + 3 And mx >= fdListX And mx <= fdListX + fdListW Then
            fdFocus = 1 ' clicked the filename field
        ElseIf my >= fdListY And my < fdListY + fdRows * fh And mx >= fdListX And mx <= fdListX + fdListW Then
            r = (my - fdListY) \ fh
            idx = fdTop + r
            If idx >= 0 And idx < fdCount Then
                fdFocus = 0
                fdSel = idx
                If Not fdIsDir(idx) Then fdName = fdEntry$(idx) ' clicking a file points the name at it
                If idx = lastClickIdx And (Timer - lastClickT) < 0.4 Then Call FDActivate(idx)
                lastClickIdx = idx
                lastClickT = Timer
            End If
        ElseIf my < fdPY Or my > fdPY + fdPH Or mx < fdPX Or mx > fdPX + fdPW Then
            fdResult = "": fdDone = -1 ' clicked outside the panel -> cancel
        End If
    End If

    prevDown = down
End Sub

Sub FDMoveSel (d As Long)
    fdSel = fdSel + d
    If fdSel < 0 Then fdSel = 0
    If fdSel > fdCount - 1 Then fdSel = fdCount - 1
    Call FDEnsureVisible
End Sub

Sub FDEnsureVisible
    If fdSel < fdTop Then fdTop = fdSel
    If fdSel > fdTop + fdRows - 1 Then fdTop = fdSel - fdRows + 1
    If fdTop > fdCount - fdRows Then fdTop = fdCount - fdRows
    If fdTop < 0 Then fdTop = 0
End Sub

Sub FDEnter
    If fdFocus = 0 Then
        If fdSel >= 0 And fdSel < fdCount Then Call FDActivate(fdSel)
    Else
        Call FDAccept
    End If
End Sub

Sub FDClickOK
    ' OK with nothing typed but a file highlighted -> use that file.
    If Len(fdName) = 0 And fdFocus = 0 And fdSel >= 0 And fdSel < fdCount Then
        If Not fdIsDir(fdSel) Then fdName = fdEntry$(fdSel)
    End If
    Call FDAccept
End Sub

Sub FDActivate (idx As Long)
    If fdIsDir(idx) Then
        Call FDNavigate(fdEntry$(idx))
    Else
        fdName = fdEntry$(idx)
        Call FDAccept
    End If
End Sub

Sub FDNavigate (target As String)
    If _DirExists(target) Then ChDir target
    Call FDScan
    fdSel = 0
    fdTop = 0
End Sub

Sub FDAccept
    Dim chosen As String, r As Long
    If Len(fdName) = 0 Then Exit Sub ' nothing to accept yet

    If LastSep&(fdName) > 0 Then ' user typed a path of their own
        chosen = fdName
    Else
        chosen = JoinPath$(_CWD$, fdName)
    End If

    If fdMode = FD_SAVE Then
        If _FileExists(chosen) Then
            r = _MessageBox("Notepad", "Overwrite existing file?" + Chr$(10) + chosen, "yesno", "question")
            If r <> 1 Then Exit Sub
        End If
    End If

    fdResult = chosen
    fdDone = -1
End Sub

' =====================================================================
'  PATH HELPERS
' =====================================================================
' Position of the last \ or / in p (0 if none).
Function LastSep& (p As String)
    Dim i As Long, ch As String
    LastSep& = 0
    For i = Len(p) To 1 Step -1
        ch = Mid$(p, i, 1)
        If ch = "\" Or ch = "/" Then
            LastSep& = i
            Exit Function
        End If
    Next i
End Function

' Join a directory and a filename with exactly one separator.
Function JoinPath$ (d As String, f As String)
    Dim dd As String
    dd = d
    If Len(dd) > 0 Then
        If Right$(dd, 1) <> "\" And Right$(dd, 1) <> "/" Then dd = dd + PSEP
    End If
    JoinPath$ = dd + f
End Function

' =====================================================================
'  SELECTION, CLIPBOARD & CONTEXT MENU
'  Selection is an anchor (fixed end) plus the caret (moving end); the
'  normalised span between them is the selection. A mouse click places
'  the caret and sets the anchor; dragging extends. Cut/Copy/Paste use
'  the OS clipboard via _CLIPBOARD$. Editing ops replace the selection
'  as one undo step. The right-click menu is a small floating dropdown.
' =====================================================================
Function HasSelection% ()
    If Not selActive Then HasSelection% = 0: Exit Function
    If anchorRow = caretRow And anchorCol = caretCol Then HasSelection% = 0 Else HasSelection% = -1
End Function

' Normalised selection bounds: (sr,sc) <= (er,ec) in document order.
Sub SelBounds (sr As Long, sc As Long, er As Long, ec As Long)
    If anchorRow < caretRow Or (anchorRow = caretRow And anchorCol <= caretCol) Then
        sr = anchorRow: sc = anchorCol: er = caretRow: ec = caretCol
    Else
        sr = caretRow: sc = caretCol: er = anchorRow: ec = anchorCol
    End If
End Sub

' The selected text, lines joined with CRLF ("" if no selection).
Function SelectedText$ ()
    Dim sr As Long, sc As Long, er As Long, ec As Long, res As String, r As Long
    If Not HasSelection% Then SelectedText$ = "": Exit Function
    Call SelBounds(sr, sc, er, ec)
    If sr = er Then
        SelectedText$ = Mid$(docLine$(sr), sc + 1, ec - sc)
        Exit Function
    End If
    res = Mid$(docLine$(sr), sc + 1)
    For r = sr + 1 To er - 1
        res = res + Chr$(13) + Chr$(10) + docLine$(r)
    Next r
    res = res + Chr$(13) + Chr$(10) + Left$(docLine$(er), ec)
    SelectedText$ = res
End Function

' Delete the selection from the buffer (no undo checkpoint of its own).
Sub RemoveSelSpan
    Dim sr As Long, sc As Long, er As Long, ec As Long, i As Long
    If Not HasSelection% Then Exit Sub
    Call SelBounds(sr, sc, er, ec)
    If sr = er Then
        docLine$(sr) = Left$(docLine$(sr), sc) + Mid$(docLine$(sr), ec + 1)
    Else
        docLine$(sr) = Left$(docLine$(sr), sc) + Mid$(docLine$(er), ec + 1)
        For i = 1 To er - sr
            Call RemoveLineAt(sr + 1)
        Next i
    End If
    caretRow = sr: caretCol = sc
    selActive = 0
    isDirty = -1
    wrapDirty = -1
End Sub

' Checkpoint undo, and replace the selection (if any) so the edit that
' follows lands as one undo step at the collapsed caret.
Sub BeginEdit (kind As Integer)
    If HasSelection% Then
        undoBreak = -1
        Call UndoCheckpoint(kind)
        Call RemoveSelSpan
    Else
        Call UndoCheckpoint(kind)
    End If
End Sub

' Raw single-line insert at the caret (no checkpoint, no selection).
Sub RawInsertText (t As String)
    Dim s As String
    s = docLine$(caretRow)
    docLine$(caretRow) = Left$(s, caretCol) + t + Mid$(s, caretCol + 1)
    caretCol = caretCol + Len(t)
    isDirty = -1
    wrapDirty = -1
End Sub

' Raw line split at the caret (no checkpoint, no selection).
Sub RawInsertNewline
    Dim s As String, restStr As String
    s = docLine$(caretRow)
    restStr = Mid$(s, caretCol + 1)
    docLine$(caretRow) = Left$(s, caretCol)
    Call InsertLineAt(caretRow + 1, restStr)
    caretRow = caretRow + 1
    caretCol = 0
    isDirty = -1
    wrapDirty = -1
End Sub

' Insert possibly-multiline text (split on LF, CR stripped).
Sub InsertMultiline (txt As String)
    Dim nlPos As Long, startPos As Long
    startPos = 1
    Do
        nlPos = InStr(startPos, txt, Chr$(10))
        If nlPos = 0 Then
            Call RawInsertText(StripCR$(Mid$(txt, startPos)))
            Exit Do
        Else
            Call RawInsertText(StripCR$(Mid$(txt, startPos, nlPos - startPos)))
            Call RawInsertNewline
            startPos = nlPos + 1
        End If
    Loop
End Sub

Sub DoCopy
    If Not HasSelection% Then Exit Sub
    _Clipboard$ = SelectedText$
End Sub

Sub DoCut
    If Not HasSelection% Then Exit Sub
    _Clipboard$ = SelectedText$
    undoBreak = -1
    Call UndoCheckpoint(KIND_DELETE)
    Call RemoveSelSpan
    undoBreak = -1
    suppressSnap = 0
    Call EnsureCaretVisible
End Sub

Sub DoPaste
    Dim clip As String
    clip = _Clipboard$
    If Len(clip) = 0 Then Exit Sub
    undoBreak = -1
    Call BeginEdit(KIND_TYPE)
    Call InsertMultiline(clip)
    undoBreak = -1
    suppressSnap = 0
    Call EnsureCaretVisible
End Sub

Sub DoSelectAll
    If lineCount = 0 Then Exit Sub
    anchorRow = 0: anchorCol = 0
    caretRow = lineCount - 1
    caretCol = Len(docLine$(caretRow))
    selActive = -1
    matchRow = -1
    suppressSnap = 0
    Call EnsureCaretVisible
End Sub

' ---- mouse -> document position ------------------------------------
Function InTextArea% (mx As Integer, my As Integer)
    If my >= MBHEIGHT And my < winH - SBHEIGHT And mx >= 0 And mx < winW Then
        InTextArea% = -1
    Else
        InTextArea% = 0
    End If
End Function

Sub PointToDoc (mx As Integer, my As Integer, pr As Long, pc As Long)
    Dim srow As Integer, rc As Long, k As Long
    srow = (my - MBHEIGHT) \ fh
    If srow < 0 Then srow = 0
    If wordWrap Then
        Call BuildWrap
        k = topVis + srow
        If k < 0 Then k = 0
        If k > visCount - 1 Then k = visCount - 1
        pr = visLogRow(k)
        rc = visStart(k) + (mx + fw \ 2) \ fw
        If rc < visStart(k) Then rc = visStart(k)
        If rc > visStart(k) + visLen(k) Then rc = visStart(k) + visLen(k)
        If rc > Len(docLine$(pr)) Then rc = Len(docLine$(pr))
        pc = rc
    Else
        pr = topLine + srow
        If pr < 0 Then pr = 0
        If pr > lineCount - 1 Then pr = lineCount - 1
        rc = leftCol + (mx + fw \ 2) \ fw
        If rc < 0 Then rc = 0
        If rc > Len(docLine$(pr)) Then rc = Len(docLine$(pr))
        pc = rc
    End If
End Sub

Sub PointToCaret (mx As Integer, my As Integer)
    Dim pr As Long, pc As Long
    Call PointToDoc(mx, my, pr, pc)
    caretRow = pr: caretCol = pc
    suppressSnap = 0 ' the caret is driving the view again
End Sub

Function PointInSelection% (mx As Integer, my As Integer)
    Dim pr As Long, pc As Long, sr As Long, sc As Long, er As Long, ec As Long
    PointInSelection% = 0
    If Not HasSelection% Then Exit Function
    Call PointToDoc(mx, my, pr, pc)
    Call SelBounds(sr, sc, er, ec)
    If pr < sr Or pr > er Then Exit Function
    If pr = sr And pc < sc Then Exit Function
    If pr = er And pc >= ec Then Exit Function
    PointInSelection% = -1
End Function

' Selection shown as reverse video (swap fg/bg), wrap-aware and multi-line.
' Drawn AFTER the text pass: a light bar covers the normal glyphs, then the
' selected characters are redrawn in the background colour on top of it.
Sub DrawSelection
    Dim sr As Long, sc As Long, er As Long, ec As Long
    Dim i As Integer, rowIdx As Long, cA As Long, cB As Long, sy As Integer, xx As Integer
    Dim k As Long, segA As Long, segB As Long, iA As Long, iB As Long
    If Not HasSelection% Then Exit Sub
    Call SelBounds(sr, sc, er, ec)
    If wordWrap Then
        For k = topVis To topVis + visRows - 1
            If k >= 0 And k < visCount Then
                rowIdx = visLogRow(k)
                If rowIdx >= sr And rowIdx <= er Then
                    If rowIdx = sr Then cA = sc Else cA = 0
                    If rowIdx = er Then cB = ec Else cB = Len(docLine$(rowIdx))
                    segA = visStart(k): segB = visStart(k) + visLen(k)
                    iA = cA: If iA < segA Then iA = segA
                    iB = cB: If iB > segB Then iB = segB
                    If iB > iA Then
                        sy = MBHEIGHT + (k - topVis) * fh
                        xx = (iA - segA) * fw
                        Line (xx, sy)-(xx + (iB - iA) * fw - 1, sy + fh - 1), themeSel, BF
                        Color themeSelFG
                        _PrintString (xx, sy), Mid$(docLine$(rowIdx), iA + 1, iB - iA)
                    End If
                End If
            End If
        Next k
    Else
        For i = 0 To visRows - 1
            rowIdx = topLine + i
            If rowIdx > er Then Exit For
            If rowIdx >= sr And rowIdx < lineCount Then
                If rowIdx = sr Then cA = sc Else cA = 0
                If rowIdx = er Then cB = ec Else cB = Len(docLine$(rowIdx))
                If cA < leftCol Then cA = leftCol
                If cB > leftCol + visCols Then cB = leftCol + visCols
                If cB > cA Then
                    sy = MBHEIGHT + i * fh
                    xx = (cA - leftCol) * fw
                    Line (xx, sy)-(xx + (cB - cA) * fw - 1, sy + fh - 1), themeSel, BF
                    Color themeSelFG
                    _PrintString (xx, sy), Mid$(docLine$(rowIdx), cA + 1, cB - cA)
                End If
            End If
        Next i
    End If
End Sub

' ---- right-click context menu --------------------------------------
Sub OpenContext (mx As Integer, my As Integer)
    Dim i As Integer, maxLen As Integer
    ctxHasSel = HasSelection% ' cache enable-state at open time
    ctxCanPaste = (Len(_Clipboard$) > 0)
    maxLen = 0
    For i = 0 To 3
        If Len(ctxLabel$(i)) > maxLen Then maxLen = Len(ctxLabel$(i))
    Next i
    ctxW = maxLen * fw + 20
    ctxH = 4 * fh + 8
    ctxX = mx: ctxY = my
    If ctxX + ctxW > winW Then ctxX = winW - ctxW
    If ctxY + ctxH > winH Then ctxY = winH - ctxH
    If ctxX < 0 Then ctxX = 0
    If ctxY < 0 Then ctxY = 0
    ctxHover = -1
    ctxOpen = -1
End Sub

Function CtxUsable% (cmd As Integer)
    Select Case cmd
        Case CMD_CUT: CtxUsable% = ctxHasSel
        Case CMD_COPY: CtxUsable% = ctxHasSel
        Case CMD_PASTE: CtxUsable% = ctxCanPaste
        Case CMD_SELALL: CtxUsable% = -1
        Case Else: CtxUsable% = 0
    End Select
End Function

Sub DrawContext
    Dim i As Integer, iy As Integer, usable As Integer
    Line (ctxX, ctxY)-(ctxX + ctxW - 1, ctxY + ctxH - 1), _RGB32(60, 60, 65), BF
    Line (ctxX, ctxY)-(ctxX + ctxW - 1, ctxY + ctxH - 1), _RGB32(120, 120, 130), B
    For i = 0 To 3
        iy = ctxY + 4 + i * fh
        usable = CtxUsable%(ctxCmd(i))
        If i = ctxHover And usable Then
            Line (ctxX + 2, iy)-(ctxX + ctxW - 3, iy + fh - 1), _RGB32(0, 90, 160), BF
        End If
        If usable Then Color _RGB32(235, 235, 235) Else Color _RGB32(130, 130, 130)
        _PrintString (ctxX + 10, iy), ctxLabel$(i)
    Next i
End Sub

Function CtxItemAt% (mx As Integer, my As Integer)
    Dim i As Integer, iy As Integer
    CtxItemAt% = -1
    If mx < ctxX Or mx >= ctxX + ctxW Then Exit Function
    For i = 0 To 3
        iy = ctxY + 4 + i * fh
        If my >= iy And my < iy + fh Then
            CtxItemAt% = i
            Exit Function
        End If
    Next i
End Function

Sub ActivateCtx (idx As Integer)
    Dim cmd As Integer
    cmd = ctxCmd(idx)
    If Not CtxUsable%(cmd) Then Exit Sub
    ctxOpen = 0
    Select Case cmd
        Case CMD_CUT: Call DoCut
        Case CMD_COPY: Call DoCopy
        Case CMD_PASTE: Call DoPaste
        Case CMD_SELALL: Call DoSelectAll
    End Select
End Sub

Sub CtxKey (kkey As String)
    Dim ext As Integer, c As Integer
    If Len(kkey) = 2 Then
        ext = Asc(kkey, 2)
        If ext = 72 Then Call CtxMove(-1)
        If ext = 80 Then Call CtxMove(1)
        Exit Sub
    End If
    c = Asc(kkey)
    If c = 27 Then
        ctxOpen = 0
    ElseIf c = 13 Then
        If ctxHover >= 0 Then Call ActivateCtx(ctxHover)
    End If
End Sub

Sub CtxMove (dir As Integer)
    Dim i As Integer, guard As Integer
    i = ctxHover
    guard = 0
    Do
        i = i + dir
        If i < 0 Then i = 3
        If i > 3 Then i = 0
        guard = guard + 1
        If guard > 4 Then Exit Do
    Loop Until CtxUsable%(ctxCmd(i))
    ctxHover = i
End Sub

' =====================================================================
'  FIND  (modal search bar; Notepad-style, explicit Find Next)
'  A compact panel in the top-right corner with its own input loop.
'  PaintEditor is drawn behind it (no full-screen dim) so the highlighted
'  match stays visible while you step through hits. The search runs over
'  the logical buffer, so it is wrap-agnostic; DrawMatch maps the match
'  onto visual rows when wrapping is on.
' =====================================================================
Sub DoFind
    fpMode = FIND_MODE
    Call FindPanel
End Sub

Sub DoReplace
    fpMode = REPL_MODE
    Call FindPanel
End Sub

' Shared modal panel for both Find (Ctrl+F) and Replace (Ctrl+R).
Sub FindPanel
    Dim kk As String

    fpDone = 0
    fpArmed = 0
    fpMsg = ""
    fpFocus = 0

    ' geometry: compact panel, top-right so the document stays visible
    If fpMode = REPL_MODE Then fpW = 540 Else fpW = 470
    fpX = winW - fpW - 12
    fpY = MBHEIGHT + 8
    fpFieldY = fpY + fh + 8
    If fpMode = REPL_MODE Then
        fpField2Y = fpFieldY + fh + 8
        fpBtnY = fpField2Y + fh + 14
    Else
        fpField2Y = fpFieldY
        fpBtnY = fpFieldY + fh + 14
    End If
    fpHintY = fpBtnY + fh + 6
    fpH = (fpHintY + fh + 6) - fpY

    ' button hit-boxes, laid out right-to-left
    fpXX2 = fpX + fpW - 10: fpXX1 = fpXX2 - Len(" Close ") * fw
    If fpMode = REPL_MODE Then
        fpAX2 = fpXX1 - 8: fpAX1 = fpAX2 - Len(" Repl All ") * fw
        fpRX2 = fpAX1 - 8: fpRX1 = fpRX2 - Len(" Replace ") * fw
        fpNX2 = fpRX1 - 8: fpNX1 = fpNX2 - Len(" Find ") * fw
    Else
        fpPX2 = fpXX1 - 8: fpPX1 = fpPX2 - Len(" Prev ") * fw
        fpNX2 = fpPX1 - 8: fpNX1 = fpNX2 - Len(" Find ") * fw
    End If
    fpCX1 = fpX + 8: fpCX2 = fpCX1 + Len("[x] Match case") * fw

    Do
        Call FindHandleMouse
        kk = InKey$
        If Len(kk) > 0 Then Call FindHandleKey(kk)
        Call PaintEditor ' editor + current match highlight behind
        Call FindRender ' the panel on top
        _Display
        _Limit 60
    Loop Until fpDone
End Sub

Sub FindRender
    Dim s As String, cur As String, cb As String, maxc As Integer, hint As String
    ' panel (opaque; no full-screen dim so matches stay visible)
    Line (fpX, fpY)-(fpX + fpW - 1, fpY + fpH - 1), _RGB32(45, 45, 52), BF
    Line (fpX, fpY)-(fpX + fpW - 1, fpY + fpH - 1), _RGB32(120, 120, 140), B
    ' title + message
    Color _RGB32(235, 235, 235)
    If fpMode = REPL_MODE Then _PrintString (fpX + 8, fpY + 4), "Replace" Else _PrintString (fpX + 8, fpY + 4), "Find"
    If Len(fpMsg) > 0 Then
        Color _RGB32(240, 180, 90)
        _PrintString (fpX + 8 + 9 * fw, fpY + 4), fpMsg
    End If

    ' find-what field
    Call FindDrawField(fpFieldY, findQuery, (fpFocus = 0))
    ' replace-with field (replace mode)
    If fpMode = REPL_MODE Then Call FindDrawField(fpField2Y, findReplace, (fpFocus = 1))

    ' blinking caret in the focused field
    Color _RGB32(255, 255, 255)
    If (Int(Timer * 2) Mod 2) = 0 Then
        If fpMode = REPL_MODE And fpFocus = 1 Then
            s = findReplace
        Else
            s = findQuery
        End If
        maxc = (fpW - 24) \ fw - 1
        If Len(s) > maxc Then s = Right$(s, maxc)
        If fpFocus = 1 Then
            _PrintString (fpX + 12 + Len(s) * fw, fpField2Y + 2), "_"
        Else
            _PrintString (fpX + 12 + Len(s) * fw, fpFieldY + 2), "_"
        End If
    End If

    ' match-case checkbox
    If findCase Then cb = "[x] Match case" Else cb = "[ ] Match case"
    Color _RGB32(210, 210, 210)
    _PrintString (fpCX1, fpBtnY), cb

    ' buttons
    Call FDDrawButton(fpNX1, fpBtnY, " Find ", -1)
    If fpMode = REPL_MODE Then
        Call FDDrawButton(fpRX1, fpBtnY, " Replace ", 0)
        Call FDDrawButton(fpAX1, fpBtnY, " Repl All ", 0)
    Else
        Call FDDrawButton(fpPX1, fpBtnY, " Prev ", 0)
    End If
    Call FDDrawButton(fpXX1, fpBtnY, " Close ", 0)

    ' hint line
    Color _RGB32(140, 140, 150)
    If fpMode = REPL_MODE Then
        hint = "Tab=field  Enter=find  F2=case  F3=replace  F4=all  Esc=close"
    Else
        hint = "Enter=find  Up=prev  Tab=case  Esc=close"
    End If
    _PrintString (fpX + 8, fpHintY), hint
End Sub

' Draw one text field with its value, focused or not.
Sub FindDrawField (fy As Integer, vval As String, focused As Integer)
    Dim s As String, maxc As Integer
    Line (fpX + 8, fy)-(fpX + fpW - 9, fy + fh + 3), _RGB32(20, 20, 24), BF
    If focused Then
        Line (fpX + 8, fy)-(fpX + fpW - 9, fy + fh + 3), _RGB32(90, 140, 210), B
    Else
        Line (fpX + 8, fy)-(fpX + fpW - 9, fy + fh + 3), _RGB32(70, 70, 80), B
    End If
    Color _RGB32(255, 255, 255)
    s = vval
    maxc = (fpW - 24) \ fw - 1
    If Len(s) > maxc Then s = Right$(s, maxc) ' keep the tail visible
    _PrintString (fpX + 12, fy + 2), s
End Sub

Sub FindHandleKey (kk As String)
    Dim ext As Integer, c As Integer
    If Len(kk) = 2 Then
        ext = Asc(kk, 2)
        Select Case ext
            Case 72: Call FindStep(0) ' Up  = Find Prev
            Case 80: Call FindStep(-1) ' Down = Find Next
            Case 60: findCase = Not findCase: fpMsg = "" ' F2 = Match case
            Case 61: If fpMode = REPL_MODE Then Call ReplaceOne ' F3 = Replace
            Case 62: If fpMode = REPL_MODE Then Call ReplaceAll ' F4 = Replace All
        End Select
        Exit Sub
    End If
    c = Asc(kk)
    Select Case c
        Case 27: fpDone = -1 ' Esc  = close
        Case 13: Call FindStep(-1) ' Enter = Find Next
        Case 9 ' Tab
            If fpMode = REPL_MODE Then
                fpFocus = 1 - fpFocus
            Else
                findCase = Not findCase
                fpMsg = ""
            End If
        Case 8 ' Backspace edits the focused field
            If fpMode = REPL_MODE And fpFocus = 1 Then
                If Len(findReplace) > 0 Then findReplace = Left$(findReplace, Len(findReplace) - 1)
            Else
                If Len(findQuery) > 0 Then findQuery = Left$(findQuery, Len(findQuery) - 1)
            End If
            fpMsg = ""
        Case 32 To 126 ' type into the focused field
            If fpMode = REPL_MODE And fpFocus = 1 Then
                findReplace = findReplace + kk
            Else
                findQuery = findQuery + kk
            End If
            fpMsg = ""
    End Select
End Sub

Sub FindHandleMouse
    Static prevDown As Integer
    Dim mx As Integer, my As Integer, down As Integer
    While _MouseInput: Wend
    mx = _MouseX: my = _MouseY
    down = (_MouseButton(1) <> 0)

    If Not fpArmed Then ' ignore the launching click until released
        If Not down Then fpArmed = -1
        prevDown = down: Exit Sub
    End If

    If down And Not prevDown Then
        ' click a field to focus it (replace mode)
        If fpMode = REPL_MODE And my >= fpFieldY And my <= fpFieldY + fh + 3 Then
            fpFocus = 0
        ElseIf fpMode = REPL_MODE And my >= fpField2Y And my <= fpField2Y + fh + 3 Then
            fpFocus = 1
        ElseIf my >= fpBtnY - 2 And my <= fpBtnY + fh + 1 Then
            If mx >= fpNX1 And mx <= fpNX2 Then
                Call FindStep(-1)
            ElseIf mx >= fpXX1 And mx <= fpXX2 Then
                fpDone = -1
            ElseIf mx >= fpCX1 And mx <= fpCX2 Then
                findCase = Not findCase: fpMsg = ""
            ElseIf fpMode = REPL_MODE And mx >= fpRX1 And mx <= fpRX2 Then
                Call ReplaceOne
            ElseIf fpMode = REPL_MODE And mx >= fpAX1 And mx <= fpAX2 Then
                Call ReplaceAll
            ElseIf fpMode = FIND_MODE And mx >= fpPX1 And mx <= fpPX2 Then
                Call FindStep(0)
            End If
        End If
    End If

    prevDown = down
End Sub

' Replace the current match (if it still matches) then find the next one;
' if there is no current match, just find the next occurrence.
Sub ReplaceOne
    Dim s As String, sseg As String, hit As Integer
    If Len(findQuery) = 0 Then fpMsg = "": Exit Sub
    hit = 0
    If matchRow >= 0 Then
        s = docLine$(matchRow)
        If matchCol + matchLen <= Len(s) Then
            sseg = Mid$(s, matchCol + 1, matchLen)
            If findCase Then
                If sseg = findQuery Then hit = -1
            Else
                If UCase$(sseg) = UCase$(findQuery) Then hit = -1
            End If
        End If
    End If
    If hit Then
        undoBreak = -1
        Call UndoCheckpoint(KIND_REPLACE)
        s = docLine$(matchRow)
        docLine$(matchRow) = Left$(s, matchCol) + findReplace + Mid$(s, matchCol + matchLen + 1)
        isDirty = -1
        wrapDirty = -1
        caretRow = matchRow
        caretCol = matchCol + Len(findReplace)
        matchRow = -1
        suppressSnap = 0
        Call EnsureCaretVisible
        Call FindStep(-1) ' select the next occurrence
    Else
        Call FindStep(-1) ' nothing selected yet -> find first/next
    End If
End Sub

' Replace every occurrence in one pass, as a single undo step.
Sub ReplaceAll
    Dim r As Long, cnt As Long, s As String, hay As String, qq As String
    Dim ppos As Long, fromPos As Long
    If Len(findQuery) = 0 Then fpMsg = "": Exit Sub
    qq = findQuery
    If Not findCase Then qq = UCase$(qq)
    undoBreak = -1
    Call UndoCheckpoint(KIND_REPLACE) ' one checkpoint for the whole batch
    cnt = 0
    For r = 0 To lineCount - 1
        fromPos = 1
        Do
            s = docLine$(r)
            hay = s
            If Not findCase Then hay = UCase$(hay)
            ppos = InStr(fromPos, hay, qq)
            If ppos = 0 Then Exit Do
            docLine$(r) = Left$(s, ppos - 1) + findReplace + Mid$(s, ppos + Len(findQuery))
            fromPos = ppos + Len(findReplace) ' resume past the replacement
            cnt = cnt + 1
        Loop
    Next r
    If cnt > 0 Then
        isDirty = -1
        wrapDirty = -1
    Else
        If undoSP > 0 Then undoSP = undoSP - 1 ' pop the no-op checkpoint
    End If
    matchRow = -1
    fpMsg = "Replaced" + Str$(cnt)
End Sub

' forward = -1 -> Find Next, 0 -> Find Prev.
Sub FindStep (forward As Integer)
    Dim sRow As Long, sCol As Long, ok As Integer
    If Len(findQuery) = 0 Then fpMsg = "": Exit Sub
    If forward Then
        If matchRow >= 0 Then
            sRow = matchRow: sCol = matchCol + 1
        Else
            sRow = caretRow: sCol = caretCol
        End If
    Else
        If matchRow >= 0 Then
            sRow = matchRow: sCol = matchCol
        Else
            sRow = caretRow: sCol = caretCol
        End If
    End If
    ok = SearchFrom%(sRow, sCol, forward)
    If ok Then
        caretRow = matchRow: caretCol = matchCol
        undoBreak = -1
        suppressSnap = 0 ' reveal the match even after a scrollbar scroll
        Call EnsureCaretVisible
        fpMsg = ""
    Else
        fpMsg = "Not found"
    End If
End Sub

' Set matchRow/Col/Len to the next occurrence of findQuery from (sRow,sCol),
' wrapping around the document. Returns -1 found, 0 not found.
Function SearchFrom% (sRow As Long, sCol As Long, forward As Integer)
    Dim qq As String, ooff As Long, r As Long, hay As String, ppos As Long
    SearchFrom% = 0
    If Len(findQuery) = 0 Then Exit Function
    qq = findQuery
    If Not findCase Then qq = UCase$(qq)

    For ooff = 0 To lineCount
        If forward Then
            r = (sRow + ooff) Mod lineCount
        Else
            r = ((sRow - ooff) Mod lineCount + lineCount) Mod lineCount
        End If
        hay = docLine$(r)
        If Not findCase Then hay = UCase$(hay)

        If forward Then
            If ooff = 0 Then
                ppos = FirstOccFrom&(hay, qq, sCol)
            ElseIf ooff = lineCount Then ' wrapped to start line: only the head
                ppos = FirstOccFrom&(hay, qq, 0)
                If ppos >= sCol Then ppos = -1
            Else
                ppos = FirstOccFrom&(hay, qq, 0)
            End If
        Else
            If ooff = 0 Then ' matches starting before sCol
                ppos = LastOccIn&(hay, qq, 0, sCol - 1)
            ElseIf ooff = lineCount Then ' wrapped to start line: the tail
                ppos = LastOccIn&(hay, qq, sCol, Len(hay))
            Else
                ppos = LastOccIn&(hay, qq, 0, Len(hay))
            End If
        End If

        If ppos >= 0 Then
            matchRow = r: matchCol = ppos: matchLen = Len(findQuery)
            SearchFrom% = -1
            Exit Function
        End If
    Next ooff
End Function

' First occurrence of qq in hay with 0-based start >= lo (-1 if none).
Function FirstOccFrom& (hay As String, qq As String, lo As Long)
    Dim p As Long
    p = InStr(lo + 1, hay, qq)
    If p = 0 Then FirstOccFrom& = -1 Else FirstOccFrom& = p - 1
End Function

' Last occurrence of qq in hay with 0-based start in [lo,hi] (-1 if none).
Function LastOccIn& (hay As String, qq As String, lo As Long, hi As Long)
    Dim p As Long, best As Long, startPos As Long
    best = -1
    If hi < lo Then LastOccIn& = -1: Exit Function
    startPos = lo + 1
    Do
        p = InStr(startPos, hay, qq)
        If p = 0 Then Exit Do
        If (p - 1) > hi Then Exit Do
        best = p - 1
        startPos = p + 1
    Loop
    LastOccIn& = best
End Function

' Highlight the current match (selection-blue box behind the text). Draws
' one box per visual row the match spans, in either display mode.
Sub DrawMatch
    Dim a As Long, b As Long, sy As Integer, c1 As Long, c2 As Long
    Dim k As Long, segA As Long, segB As Long, iA As Long, iB As Long
    If matchRow < 0 Or matchLen <= 0 Then Exit Sub
    a = matchCol
    b = matchCol + matchLen
    If wordWrap Then
        For k = topVis To topVis + visRows - 1
            If k >= 0 And k < visCount Then
                If visLogRow(k) = matchRow Then
                    segA = visStart(k)
                    segB = visStart(k) + visLen(k)
                    iA = a: If iA < segA Then iA = segA
                    iB = b: If iB > segB Then iB = segB
                    If iB > iA Then
                        sy = MBHEIGHT + (k - topVis) * fh
                        Line ((iA - segA) * fw, sy)-((iB - segA) * fw - 1, sy + fh - 1), themeMatch, BF
                    End If
                End If
            End If
        Next k
    Else
        If matchRow >= topLine And matchRow < topLine + visRows Then
            c1 = a - leftCol
            c2 = b - leftCol
            If c1 < 0 Then c1 = 0
            If c2 > visCols Then c2 = visCols
            If c2 > c1 Then
                sy = MBHEIGHT + (matchRow - topLine) * fh
                Line (c1 * fw, sy)-(c2 * fw - 1, sy + fh - 1), themeMatch, BF
            End If
        End If
    End If
End Sub

' =====================================================================
'  WORD WRAP  (soft wrap; the buffer is never modified)
'  When wordWrap is on, BuildWrap flattens the document into a list of
'  VISUAL rows -- each a (logical line, start column, length) slice that
'  fits the window width, broken at spaces where possible. Rendering,
'  the caret, vertical movement and Home/End all consult this map; the
'  buffer itself (docLine$, caretRow, caretCol) is untouched, so save,
'  load and undo neither know nor care that wrapping is on.
'
'  The map is cached: BuildWrap only rebuilds when wrapDirty is set
'  (any edit, undo/redo, load/new, or a wrap toggle). For very large
'  files you could rebuild only the visible span instead.
' =====================================================================
' =====================================================================
'  THEME  (editor palette, Format menu)
'  Each theme sets six colours: background, text, selection bg/fg,
'  find-match bg, caret. Only the text area is themed; the menu bar,
'  status bar, dialog panels and scrollbar keep their neutral chrome
'  so they read the same in every palette.
' =====================================================================
' Pick a readable text colour to lay on top of `c`: pure black on light
' backgrounds, pure white on dark ones. Uses a Rec.709 luminance weighting
' so saturated hues (bright green, warm amber, cyan) all get the right
' choice; a strict RGB complement (255-R,255-G,255-B) would technically be
' the "complement" but looks garish on saturated colours -- e.g. amber
' would flip to blue instead of black. This gives maximum readability
' automatically, so any themeSel value picks a matching themeSelFG with
' no hand-tuning.
Function Complement~& (c As _Unsigned Long)
    Dim r As Long, g As Long, b As Long, lum As Long
    r = _Red32(c)
    g = _Green32(c)
    b = _Blue32(c)
    ' Rec.709 luminance (integer arithmetic; weights sum to 10000)
    lum = (r * 2126 + g * 7152 + b * 722) \ 10000
    If lum > 128 Then
        Complement~& = _RGB32(100, 0, 100)
    Else
        Complement~& = _RGB32(255, 255, 255)
    End If
End Function

Sub SetTheme (id As Integer)
    Select Case id
        Case 1 ' Amber -- monochrome CRT
            themeBG = _RGB32(10, 5, 0)
            themeFG = _RGB32(255, 180, 50)
            themeSel = _RGB32(255, 180, 50) ' inverse video
            themeMatch = _RGB32(140, 90, 20)
            themeCaret = _RGB32(255, 180, 50)
        Case 2 ' Green Phosphor -- monochrome CRT
            themeBG = _RGB32(0, 15, 0)
            themeFG = _RGB32(60, 220, 60)
            themeSel = _RGB32(60, 220, 60) ' inverse video
            themeMatch = _RGB32(140, 140, 0) ' olive so it isn't more green
            themeCaret = _RGB32(60, 220, 60)
        Case 3 ' Light -- paper
            themeBG = _RGB32(30, 30, 30)
            themeFG = _RGB32(250, 250, 245)
            themeSel = _RGB32(130, 130, 130) ' inverse video
            themeMatch = _RGB32(255, 235, 100) ' highlighter yellow
            themeCaret = _RGB32(130, 130, 130)
        Case 4 ' Blue -- deep navy
            themeBG = _RGB32(10, 20, 60)
            themeFG = _RGB32(200, 220, 255)
            themeSel = _RGB32(200, 220, 255) ' inverse video (C64-ish)

            themeMatch = _RGB32(200, 180, 60) ' amber highlighter
            themeCaret = _RGB32(200, 220, 255)
        Case Else ' 0 = Default -- dark gray
            themeBG = _RGB32(30, 30, 30)
            themeFG = _RGB32(220, 220, 220)
            themeSel = _RGB32(220, 220, 220) ' inverse video
            themeMatch = _RGB32(40, 140, 60)
            themeCaret = _RGB32(255, 255, 255)
            id = 0
    End Select
    themeSelFG = Complement~&(themeSel) ' pick a readable text colour for the sel bg
    currentTheme = id
End Sub

Sub DoToggleWrap
    wordWrap = Not wordWrap
    wrapDirty = -1
    leftCol = 0
    topVis = 0
    suppressSnap = 0
    Call EnsureCaretVisible
End Sub

Sub WrapEmit (r As Long, st As Long, ln As Long)
    If visCount > UBound(visLogRow) Then
        ReDim _Preserve visLogRow(0 To (visCount + 1) * 2) As Long
        ReDim _Preserve visStart(0 To (visCount + 1) * 2) As Long
        ReDim _Preserve visLen(0 To (visCount + 1) * 2) As Long
    End If
    visLogRow(visCount) = r
    visStart(visCount) = st
    visLen(visCount) = ln
    visCount = visCount + 1
End Sub

' Rebuild the visual-row map for the whole document at the window width.
Sub BuildWrap
    Dim r As Long, L As Long, st As Long, w As Long, c As Long, nextSt As Long
    Dim s As String
    If Not wrapDirty Then Exit Sub
    w = visCols
    If w < 1 Then w = 1
    visCount = 0
    For r = 0 To lineCount - 1
        s = docLine$(r)
        L = Len(s)
        st = 0
        Do
            If L - st <= w Then
                Call WrapEmit(r, st, L - st)
                Exit Do
            End If
            ' break no later than column st+w; prefer the last space in the window
            nextSt = st + w ' default: hard break a long word
            For c = st + w - 1 To st Step -1
                If Mid$(s, c + 1, 1) = " " Then
                    nextSt = c + 1 ' the space stays at the end of this segment
                    Exit For
                End If
            Next c
            If nextSt <= st Then nextSt = st + w ' safety: always make progress
            Call WrapEmit(r, st, nextSt - st)
            st = nextSt
            If st >= L Then Exit Do ' line ended exactly on a break
        Loop
    Next r
    If visCount = 0 Then Call WrapEmit(0, 0, 0)
    wrapDirty = 0
End Sub

' Caret (caretRow, caretCol) -> visual row index + column within that row.
Sub CaretToVis (vRow As Long, vCol As Long)
    Dim k As Long, segEnd As Long, isLastSeg As Integer
    vRow = 0: vCol = 0
    For k = 0 To visCount - 1
        If visLogRow(k) = caretRow Then
            segEnd = visStart(k) + visLen(k)
            isLastSeg = (k = visCount - 1)
            If Not isLastSeg Then isLastSeg = (visLogRow(k + 1) <> caretRow)
            If caretCol >= visStart(k) And (caretCol < segEnd Or (isLastSeg And caretCol <= segEnd)) Then
                vRow = k
                vCol = caretCol - visStart(k)
                Exit Sub
            End If
        End If
    Next k
    ' fallback: last segment belonging to the caret's logical line
    For k = visCount - 1 To 0 Step -1
        If visLogRow(k) = caretRow Then
            vRow = k
            vCol = caretCol - visStart(k)
            If vCol > visLen(k) Then vCol = visLen(k)
            Exit Sub
        End If
    Next k
End Sub

' Target visual row + goal column -> buffer caret (clamped to that row).
Sub VisToCaret (tRow As Long, gCol As Long)
    Dim col As Long, maxCol As Long, rr As Long
    rr = tRow
    If rr < 0 Then rr = 0
    If rr > visCount - 1 Then rr = visCount - 1
    caretRow = visLogRow(rr)
    col = visStart(rr) + gCol
    maxCol = visStart(rr) + visLen(rr)
    If col > maxCol Then col = maxCol
    If col > Len(docLine$(caretRow)) Then col = Len(docLine$(caretRow))
    caretCol = col
End Sub


'  A checkpoint stores the whole document serialized to one string
'  (lines joined by Chr$(10)) plus the caret. Consecutive edits of the
'  same KIND_* coalesce into one undo step, so a typed run reverts in a
'  single Ctrl+Z instead of one char at a time. A caret move sets
'  undoBreak so the next edit opens a fresh group. Redo is symmetric:
'  undo pushes the current state onto the redo stack and vice versa.
' =====================================================================
Sub UndoReset
    undoSP = 0
    redoSP = 0
    undoLastKind = KIND_NONE
    undoBreak = -1 ' force the first edit to checkpoint
End Sub

' Whole document -> one string (Chr$(10) between lines).
Function SerializeDoc$
    Dim i As Long, blob As String
    blob = ""
    For i = 0 To lineCount - 1
        blob = blob + docLine$(i)
        If i < lineCount - 1 Then blob = blob + Chr$(10)
    Next i
    SerializeDoc$ = blob
End Function

' One string -> document buffer (caller sets the caret afterwards).
Sub RestoreDoc (blob As String)
    Dim startPos As Long, nlPos As Long
    wrapDirty = -1 ' buffer replaced -> rebuild the wrap map
    matchRow = -1 ' and drop any stale find highlight
    Call ResetBuffer ' clears buffer + caret/scroll
    lineCount = 0
    startPos = 1
    Do
        nlPos = InStr(startPos, blob, Chr$(10))
        If nlPos = 0 Then
            Call AppendLine(Mid$(blob, startPos))
            Exit Do
        Else
            Call AppendLine(Mid$(blob, startPos, nlPos - startPos))
            startPos = nlPos + 1
        End If
    Loop
    If lineCount = 0 Then lineCount = 1: docLine$(0) = ""
End Sub

Sub ClampCaret
    If caretRow < 0 Then caretRow = 0
    If caretRow > lineCount - 1 Then caretRow = lineCount - 1
    If caretCol < 0 Then caretCol = 0
    If caretCol > Len(docLine$(caretRow)) Then caretCol = Len(docLine$(caretRow))
End Sub

' Push the CURRENT document+caret onto the undo stack (drop oldest if full).
Sub PushUndoState
    Dim i As Long
    If undoSP >= UNDO_MAX Then
        For i = 1 To UNDO_MAX - 1
            undoBlob$(i - 1) = undoBlob$(i)
            undoRow(i - 1) = undoRow(i)
            undoCol(i - 1) = undoCol(i)
        Next i
        undoSP = UNDO_MAX - 1
    End If
    undoBlob$(undoSP) = SerializeDoc$
    undoRow(undoSP) = caretRow
    undoCol(undoSP) = caretCol
    undoSP = undoSP + 1
End Sub

Sub PushRedoState
    Dim i As Long
    If redoSP >= UNDO_MAX Then
        For i = 1 To UNDO_MAX - 1
            redoBlob$(i - 1) = redoBlob$(i)
            redoRow(i - 1) = redoRow(i)
            redoCol(i - 1) = redoCol(i)
        Next i
        redoSP = UNDO_MAX - 1
    End If
    redoBlob$(redoSP) = SerializeDoc$
    redoRow(redoSP) = caretRow
    redoCol(redoSP) = caretCol
    redoSP = redoSP + 1
End Sub

' Called at the top of every mutating edit, BEFORE the change lands.
' Pushes the pre-edit state only when a new group begins.
Sub UndoCheckpoint (kind As Integer)
    wrapDirty = -1 ' any edit invalidates the visual-wrap map
    If (kind <> undoLastKind) Or undoBreak Then
        Call PushUndoState
        redoSP = 0 ' a fresh edit invalidates the redo branch
    End If
    undoLastKind = kind
    undoBreak = 0
End Sub

Sub DoUndo
    If undoSP = 0 Then Exit Sub
    Call PushRedoState ' remember where we are so Redo can return
    undoSP = undoSP - 1
    Call RestoreDoc(undoBlob$(undoSP))
    caretRow = undoRow(undoSP)
    caretCol = undoCol(undoSP)
    Call ClampCaret
    If SerializeDoc$ = savedBlob Then isDirty = 0 Else isDirty = -1
    undoBreak = -1
    suppressSnap = 0 ' undo should reveal the caret wherever it lands
End Sub

Sub DoRedo
    If redoSP = 0 Then Exit Sub
    Call PushUndoState ' so the redo can itself be undone
    redoSP = redoSP - 1
    Call RestoreDoc(redoBlob$(redoSP))
    caretRow = redoRow(redoSP)
    caretCol = redoCol(redoSP)
    Call ClampCaret
    If SerializeDoc$ = savedBlob Then isDirty = 0 Else isDirty = -1
    undoBreak = -1
    suppressSnap = 0 ' redo should reveal the caret wherever it lands
End Sub

' =====================================================================
'  DISK I/O  (these actually move bytes)
' =====================================================================
Sub LoadFromDisk (fn As String)
    Dim ff As Integer, sz As Long, blob As String, ig As Long
    If _FileExists(fn) = 0 Then
        ig = _MessageBox("Notepad", "File not found:" + Chr$(10) + fn, "ok", "error")
        Exit Sub
    End If
    ff = FreeFile
    Open fn For Binary As #ff
    sz = LOF(ff)
    blob = Space$(sz)
    If sz > 0 Then Get #ff, 1, blob
    Close #ff
    Call ResetBuffer
    Call SplitIntoLines(blob)
    currentFile = fn
    isDirty = 0
    savedBlob = SerializeDoc$ ' loaded content is the new clean baseline
    Call UndoReset
    wrapDirty = -1
    matchRow = -1
    suppressSnap = 0
End Sub

Sub SplitIntoLines (blob As String)
    Dim startPos As Long, nlPos As Long
    lineCount = 0
    startPos = 1
    Do
        nlPos = InStr(startPos, blob, Chr$(10))
        If nlPos = 0 Then
            Call AppendLine(StripCR$(Mid$(blob, startPos)))
            Exit Do
        Else
            Call AppendLine(StripCR$(Mid$(blob, startPos, nlPos - startPos)))
            startPos = nlPos + 1
        End If
    Loop
    If lineCount = 0 Then lineCount = 1: docLine$(0) = ""
End Sub

Function StripCR$ (s As String)
    If Len(s) > 0 Then
        If Right$(s, 1) = Chr$(13) Then
            StripCR$ = Left$(s, Len(s) - 1)
            Exit Function
        End If
    End If
    StripCR$ = s
End Function

Sub SaveToDisk (fn As String)
    Dim ff As Integer, i As Long, blob As String
    blob = ""
    For i = 0 To lineCount - 1
        blob = blob + docLine$(i)
        If i < lineCount - 1 Then blob = blob + Chr$(13) + Chr$(10)
    Next i
    ff = FreeFile
    Open fn For Output As #ff ' truncate / create
    Close #ff
    Open fn For Binary As #ff
    If Len(blob) > 0 Then Put #ff, 1, blob
    Close #ff
    isDirty = 0
    savedBlob = SerializeDoc$ ' this content is now the clean baseline
End Sub

' =====================================================================
'  INLINE TEXT PROMPT  (kept for reuse; Open/Save now use FileDialog$)
' =====================================================================
Function PromptLine$ (promptTxt As String, dflt As String)
    Dim buf As String, kkey As String, c As Integer, sdone As Integer, y As Integer
    buf = dflt
    sdone = 0
    Do
        y = winH - SBHEIGHT
        Line (0, y)-(winW - 1, winH - 1), _RGB32(20, 40, 70), BF
        Color _RGB32(255, 255, 255)
        _PrintString (0, y + 3), " " + promptTxt + " " + buf + "_"
        _Display
        kkey = InKey$
        If Len(kkey) = 1 Then
            c = Asc(kkey)
            If c = 13 Then
                sdone = -1
            ElseIf c = 27 Then
                buf = ""
                sdone = -1
            ElseIf c = 8 Then
                If Len(buf) > 0 Then buf = Left$(buf, Len(buf) - 1)
            ElseIf c >= 32 And c <= 126 Then
                buf = buf + kkey
            End If
        End If
        _Limit 60
    Loop Until sdone
    PromptLine$ = buf
End Function

Function ShiftDown% ()
    ShiftDown% = (_KeyDown(100304) Or _KeyDown(100303)) ' L / R Shift
End Function
Sub NavKey (scan As Integer)
    Dim shifted As Integer
    shifted = ShiftDown%
    If shifted Then
        ' First shift+move? Plant the anchor where the caret is now.
        If Not selActive Then anchorRow = caretRow: anchorCol = caretCol
    Else
        selActive = 0 ' plain arrow -> drop any selection
    End If
    undoBreak = -1
    Select Case scan
        Case 72: Call MoveUp
        Case 80: Call MoveDown
        Case 75: Call MoveLeft
        Case 77: Call MoveRight
        Case 71: Call MoveHome
        Case 79: Call MoveEnd
        Case 73: Call PageUp
        Case 81: Call PageDown
    End Select
    If shifted Then
        ' Turn the selection on only if we actually moved off the anchor,
        ' so Shift+End at end-of-line doesn't leave a phantom selection.
        If caretRow <> anchorRow Or caretCol <> anchorCol Then
            selActive = -1
        Else
            selActive = 0
        End If
    End If
End Sub

' =====================================================================
'  NOTE ON UNDO (now implemented)
'  Each checkpoint snapshots the whole document into one string. The
'  per-keystroke cost the earlier note warned about is avoided by
'  COALESCING: same-kind consecutive edits share one checkpoint, so a
'  typed run is a single undo. For source-sized files this is cheap and
'  bullet-proof, and it yields Redo for free as a mirror stack.
'
'  If you ever edit very large files and want O(edit) memory instead of
'  O(doc) per level, swap PushUndoState/RestoreDoc for an inverse edit-
'  log: push {op, row, col, text} records in the Insert*/Delete*/
'  Backspace subs and replay them in reverse. The UndoCheckpoint seam
'  and the Ctrl+Z/Y + menu wiring would stay exactly as they are.
'
'  Known simplification: the dirty (*) flag is recomputed exactly only
'  on undo/redo (compare against savedBlob). Normal edits just set it.
'  So "type then manually delete back to saved" may still show * until
'  you undo. Make it exact everywhere by setting
'  isDirty = (SerializeDoc$ <> savedBlob) at the end of each edit.
' =====================================================================




