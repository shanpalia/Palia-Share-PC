#define MyAppName "Palia Share"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "PaliaWin Store"
#define MyAppExeName "palia_share_pc.exe"

[Setup]
AppId={{D8C3B3A7-5D8C-4A5A-9D7A-PALIA2026}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\Palia Share
DefaultGroupName=Palia Share
OutputDir=output
OutputBaseFilename=Palia Share Setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
Compression=lzma
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64
UninstallDisplayIcon={app}\{#MyAppExeName}

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Palia Share"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\Palia Share"; Filename: "{app}\{#MyAppExeName}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch Palia Share"; Flags: nowait postinstall skipifsilent
