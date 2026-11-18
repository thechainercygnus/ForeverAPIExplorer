$ForeverAPIExplorerOutputFileName = 'ForeverAPIExplorer.lua'
$WoWSavedVariablesFolder = 'D:\battle.net\World of Warcraft\_forever_\WTF\Account\GRUNSTAG\SavedVariables\'
$DataStoragePath = 'D:\WoW\ForeverAPIExplorer\data'

$SourceFile = Join-Path $WoWSavedVariablesFolder $ForeverAPIExplorerOutputFileName
$NewFileName = '{0}-{1}.lua' -f $ForeverAPIExplorerOutputFileName.Replace('.lua', ''), (Get-Date -Format 'yyyyMMdd-HHmmss')
$BackupName = Join-Path $DataStoragePath $NewFileName
Copy-Item $SourceFile $DataStoragePath
$ItemToRename = Get-ChildItem $DataStoragePath $ForeverAPIExplorerOutputFileName
Rename-Item $ItemToRename $BackupName