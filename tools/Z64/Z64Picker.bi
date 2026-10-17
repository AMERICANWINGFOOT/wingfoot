' Z64Picker.bi -- reusable text-mode file picker for QB64-PE 4.5.0
'
' Drive selection + directory browsing + multi-file selection
' with checkboxes. Selection persists across directory navigation
' so the user can gather files from many folders in one session.
'
' Zero globals. Zero assumptions about SCREEN mode -- the picker
' saves whatever was on screen and restores it on exit. Any host
' program can drop this in.
'
' Usage in a host program:
'
'   Option _Explicit
'   '$Dynamic
'
'   '$INCLUDE:'Z64Picker.bi'
'
'   Dim picked$(0)
'   Dim pickedCount As Long
'
'   Z64PickFiles picked$(), pickedCount
'
'   Dim i As Long
'   For i = 0 To pickedCount
'       Print picked$(i)
'   Next i
'
'   '$INCLUDE:'Z64Picker.bm'
'
' ---------------------------------------------------------------
' Public API
' ---------------------------------------------------------------
'
'   Sub Z64PickFiles (picked$(), count As Long)
'
'     Opens the picker UI. On return:
'       * picked$(0..count) contains full absolute paths of
'         every file the user checked.
'       * count is the LAST VALID INDEX. -1 means nothing
'         was picked (user cancelled or checked nothing).
'
'     The array is ReDim'd inside the sub, so callers only need
'     to declare it (any initial size is fine).
'
'   Sub Z64PickFilesFrom (startPath$, picked$(), count As Long)
'
'     Same as Z64PickFiles but skips the drive picker and jumps
'     straight into browsing startPath$. Useful when the host
'     already knows where to start (e.g. Documents folder).
'     startPath$ MUST be an absolute path with trailing slash.
'
' ---------------------------------------------------------------
' UI keys
' ---------------------------------------------------------------
'
'   Up/Down       Move cursor
'   PgUp/PgDn     Page through directory
'   SPACE         Toggle file selection (files only, not dirs)
'   ENTER         Enter directory (on a dir) / toggle (on a file)
'   BACKSPACE     Go to parent directory
'   A             Select all files in current dir
'   N             Deselect all files in current dir
'   TAB           Finish -- return picked list to caller
'   ESC           Cancel -- return empty list to caller
'
' ---------------------------------------------------------------
' Notes for host programs
' ---------------------------------------------------------------
'
'   * The picker restores the caller's SCREEN state on exit, so
'     it's safe to call from graphical hosts. It briefly switches
'     to a text screen for its own UI.
'   * No shared globals. Safe to call from multiple contexts.
'   * Blocked Windows system dirs ($Recycle.Bin, RECYCLER,
'     System Volume Information) are hidden from the listing.
'   * All paths in picked$() are absolute with backslash
'     separators. Ready to Open For Binary directly.
