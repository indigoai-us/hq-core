' Start one .cmd file with a hidden window. wscript.exe is a GUI-subsystem
' host, so neither it nor the hidden cmd.exe shows a console.
'   wscript //B //Nologo hidden-run.vbs <C:\path\run.cmd> <wait|nowait>
' Arg 0 is a Windows path to a .cmd file written by hq-hidden-run.sh. The
' cmd.exe command line is built here, so no caller passes embedded quotes.
' With "wait" this blocks until cmd.exe exits and returns its exit code.
If WScript.Arguments.Count < 1 Then WScript.Quit 2
cmdFile = WScript.Arguments(0)
wait = False
If WScript.Arguments.Count >= 2 Then
  If LCase(WScript.Arguments(1)) = "wait" Then wait = True
End If
Set fso = CreateObject("Scripting.FileSystemObject")
If Not fso.FileExists(cmdFile) Then WScript.Quit 3
Set shell = CreateObject("WScript.Shell")
comspec = shell.ExpandEnvironmentStrings("%ComSpec%")
If comspec = "%ComSpec%" Or comspec = "" Then comspec = "cmd.exe"
' cmd /s /c removes exactly the outer pair of quotes, leaving "<path>".
line = """" & comspec & """ /d /s /c """"" & cmdFile & """"""
code = shell.Run(line, 0, wait)
If wait Then WScript.Quit code
WScript.Quit 0
