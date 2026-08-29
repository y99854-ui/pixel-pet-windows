Option Explicit

Dim shell, fileSystem, baseDirectory, scriptPath, powershellPath, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

baseDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fileSystem.BuildPath(baseDirectory, "PixelPet.ps1")
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")

If Not fileSystem.FileExists(scriptPath) Then
    MsgBox "PixelPet.ps1 was not found. Please extract the complete package first.", 16, "Pixel Pet"
    WScript.Quit 1
End If

If shell.ExpandEnvironmentStrings("%PIXEL_PET_LAUNCHER_VALIDATE%") = "1" Then
    WScript.Quit 0
End If

command = Quote(powershellPath) & _
    " -STA -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
    Quote(scriptPath) & " -EnsureShortcut"

' Window style 0 keeps the PowerShell console and its taskbar icon hidden.
shell.Run command, 0, False

Function Quote(value)
    Quote = Chr(34) & value & Chr(34)
End Function
