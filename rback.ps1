# Setup our parameters
# TODO: Password parameter should be SecureString, and Read-Host should use AsSecureString not MaskInput
param (
    [ValidateScript({
        if(-Not ($_ | Test-Path) ){
            throw "File or folder does not exist" 
        }
        if(-Not ($_ | Test-Path -PathType Leaf) ){
            throw "The Config argument must be a file. Folder paths are not allowed."
        }
        return $true
    })]
    [Parameter(Mandatory)][System.IO.FileInfo]$Config,
    [Parameter(Mandatory)][ValidateSet("about", "check", "mount", "sync")][string]$Op,
    [Parameter(Mandatory=$false)][string]$Password,
    [Parameter(Mandatory=$false)][switch]$Shutdown,
    [Parameter(Mandatory=$false)][switch]$Hibernate
)

# Options specified in the conf file
$optExePath = "RCLONE_EXE_PATH"
$optRConfigPath = "RCLONE_CONFIG_PATH"
$optLogFilePath = "RCLONE_LOG_FILE_PATH"
$optLogLevel = "RCLONE_LOG_LEVEL"
$optFilterFile = "RCLONE_FILTER_FILE_PATH"
$optCheckers = "RCLONE_CHECKERS"
$optFileTransfers = "RCLONE_FILE_TRANSFERS"
$optLowLevelRetries = "RCLONE_LOW_LEVEL_RETRIES"
$optRetries = "RCLONE_RETRIES"
$optRetriesSleep = "RCLONE_RETRIES_SLEEP"
$optLocalPath = "RCLONE_LOCAL_PATH"
$optRemotePath = "RCLONE_REMOTE_PATH"
$optDirsToSync = "RCLONE_DIRECTORIES_TO_SYNC"
$optRCloneFlagsAbout = "RCLONE_ADDITIONAL_FLAGS_ABOUT"
$optRCloneFlagsSync = "RCLONE_ADDITIONAL_FLAGS_SYNC"
$optRCloneFlagsCheck = "RCLONE_ADDITIONAL_FLAGS_CHECK"
$optRCloneFlagsMount = "RCLONE_ADDITIONAL_FLAGS_MOUNT"
$optMountLocalDrive = "RCLONE_LOCAL_DRIVE"
$optMountVolName = "RCLONE_VOLUME_NAME"
$optMountBufSize = "RCLONE_BUFFER_SIZE"
$optMountIOIdleTimeout = "RCLONE_IO_IDLE_TIMEOUT"
$optMountConnectTimeout = "RCLONE_CONNECT_TIMEOUT"
$optMountRetriesSleep = "RCLONE_RETRIES_SLEEP_MOUNT"

filter isNumericType($x) {
    return $x -is [byte]  -or $x -is [int16]  -or $x -is [int32]  -or $x -is [int64]  `
       -or $x -is [sbyte] -or $x -is [uint16] -or $x -is [uint32] -or $x -is [uint64] `
       -or $x -is [float] -or $x -is [double] -or $x -is [decimal]
}

# Check if a value is numeric
function toNumeric($Value) {
    if (isNumericType($Value)) {
        return $Value
    }

    if ($Value -match "^[\d\.]+$") {
        return [int]$Value
    }

    throw "Value must be numeric: [$Value]"
}

# Read a config file consisting of comments beginning with `#`
# and key-value pairs
function Get-ConfContent($filePath)
{
    $data = @{}
    switch -regex -file $FilePath
    {
        "^(#.*)$" # Comment
        {
            continue
        }
        "(.+?)\s*=(.*)" # Key
        {
            $name,$value = $matches[1..2]
            $data[$name] = $value
        }
    }
    return $data
}

# Set defaults for anything not set...
function Set-ConfDefaults($data)
{
    if (!$data.ContainsKey($optExePath)) {
        $data[$optExePath] = "rclone.exe"
    }    
    if (!$data.ContainsKey($optRConfigPath)) {
        $data[$optRConfigPath] = "rclone.conf"
    }    
    if (!$data.ContainsKey($optLogFilePath)) {
        $data[$optLogFilePath] = "rclone-sync-log.txt"
    }    
    if (!$data.ContainsKey($optLogLevel)) {
        $data[$optLogLevel] = "NOTICE"
    }    
    if (!$data.ContainsKey($optFilterFile)) {
        $data[$optFilterFile] = "rclone-filters.txt"
    }    
    if (!$data.ContainsKey($optCheckers)) {
        $data[$optCheckers] = 8
    }
    $data[$optCheckers] = toNumeric($data[$optCheckers])

    if (!$data.ContainsKey($optFileTransfers)) {
        $data[$optFileTransfers] = 4
    }
    $data[$optFileTransfers] = toNumeric($data[$optFileTransfers])

    if (!$data.ContainsKey($optLowLevelRetries)) {
        $data[$optLowLevelRetries] = 10
    }
    $data[$optLowLevelRetries] = toNumeric($data[$optLowLevelRetries])

    if (!$data.ContainsKey($optRetries)) {
        $data[$optRetries] = 10
    }
    $data[$optRetries] = toNumeric($data[$optRetries])

    if (!$data.ContainsKey($optRetriesSleep)) {
        $data[$optRetriesSleep] = "5s"
    }
  
    if (!$data.ContainsKey($optRCloneFlagsAbout)) {
        $data[$optRCloneFlagsAbout] = ""
    }
    $data[$optRCloneFlagsAbout] = $data[$optRCloneFlagsAbout].Split(" ")

    if (!$data.ContainsKey($optRCloneFlagsSync)) {
        $data[$optRCloneFlagsSync] = "--delete-excluded --progress --stats-one-line"
    }
    $data[$optRCloneFlagsSync] = $data[$optRCloneFlagsSync].Split(" ")

    if (!$data.ContainsKey($optRCloneFlagsCheck)) {
        $data[$optRCloneFlagsCheck] = "--delete-excluded"
    }
    $data[$optRCloneFlagsCheck] = $data[$optRCloneFlagsCheck].Split(" ")

    if (!$data.ContainsKey($optRCloneFlagsMount)) {
        $data[$optRCloneFlagsMount] = "--read-only"
    }
    $data[$optRCloneFlagsMount] = $data[$optRCloneFlagsMount].Split(" ")

    if (!$data.ContainsKey($optMountLocalDrive)) {
        $data[$optMountLocalDrive] = "*"
    }
    
    if (!$data.ContainsKey($optMountBufSize)) {
        $data[$optMountBufSize] = "64MB"
    }

    if (!$data.ContainsKey($optMountIOIdleTimeout)) {
        $data[$optMountIOIdleTimeout] = "5s"
    }

    if (!$data.ContainsKey($optMountConnectTimeout)) {
        $data[$optMountConnectTimeout] = "5s"
    }

    if (!$data.ContainsKey($optMountRetriesSleep)) {
        $data[$optMountRetriesSleep] = "0"
    }
}

function runRClone($rcArgs) {
    # Setup the base arguments
    $rcArgs += @(
        "--config", $confData[$optRConfigPath]
    )

    # Start rclone and wait
    $env:RCLONE_CONFIG_PASS = $Password
    Start-Process $confData[$optExePath] -NoNewWindow -Wait -ArgumentList $rcArgs
    Remove-Item Env:\RCLONE_CONFIG_PASS
}

function log($line) {
    $path = $confData[$optLogFilePath]
    $path |% { 
        If (Test-Path -Path $_) { Get-Item $_ } 
        Else { New-Item -Path $_ -Force } 
    } | Add-Content -Value "`n$(Get-Date -Format "yyyy-MM-dd\THH:mm:ss zzz");$line"
}

#############################################
# Main script
#############################################

# Read in the config
$confData = Get-ConfContent($Config.FullName)

# Set defaults for anything not set...
Set-ConfDefaults($confData)

# Require a few options to be set
if (!$confData.ContainsKey($optLocalPath)) {
    throw "$optLocalPath must be specified in $($Config.FullName)"
}
if (!$confData.ContainsKey($optRemotePath)) {
    throw "$optRemotePath must be specified in $($Config.FullName)"
}
if (!$confData.ContainsKey($optDirsToSync)) {
    throw "$optDirsToSync must be specified as a comma separated list in $($Config.FullName)"
}

# Try to parse the directories to sync
$confData[$optDirsToSync] = $confData[$optDirsToSync].Split(",")
if($confData.Count -eq 0) {
    throw "$optDirsToSync is empty in $($Config.FullName)"
}

# If the user didn't provide a password, prompt for one
if([string]::IsNullOrWhitespace($Password)) {
    $Password = Read-Host -MaskInput -Prompt '> Config password : '
}

# Can't both shutdown and hibernate
if($Shutdown -and $Hibernate) {
    throw "Unable to both shutdown AND hibernate - pick one!"
}

# What mode are we in?
switch($Op) {
    "about" {
        $abtArgs = @(
            $Op,
            $confData[$optRemotePath]
        )

        # Additional flags?
        if ($confData.ContainsKey($optRCloneFlagsAbout)) {
            $abtArgs += $confData[$optRCloneFlagsAbout]
        }    

        Write-Host "quota information:"
        runRClone($abtArgs)

        # Never shutdown or hibernate after a mount
        $Shutdown = $false
        $Hibernate = $false
        break
    }
    "check" {
        # Common check args
        $baseCheckArgs = @(
            "--filter-from", $confData[$optFilterFile],
            "--log-file", $confData[$optLogFilePath],
            "--log-level", $confData[$optLogLevel],
            "--transfers", $confData[$optFileTransfers],
            "--checkers", $confData[$optCheckers],
            "--low-level-retries", $confData[$optLowLevelRetries],
            "--retries", $confData[$optRetries],
            "--retries-sleep", $confData[$optRetriesSleep]
        )

        # Additional flags?
        if ($confData.ContainsKey($optRCloneFlagsCheck)) {
            $baseCheckArgs += $confData[$optRCloneFlagsCheck]
        }    

        Write-Host "> Check :"
        foreach ($dir in $confData[$optDirsToSync]) {
            $checkArgs = @(
                "cryptcheck",
                ($confData[$optLocalPath] + $dir),
                ($confData[$optRemotePath] + $dir)
            ) + $baseCheckArgs
            
            Write-Host "$($confData[$optLocalPath] + $dir) <--CHECK--> $($confData[$optRemotePath] + $dir)"
            log("$dir;start")
            runRClone($checkArgs)
            log("$dir;end")
        }

        break        
    }
    "mount" {
        $mntArgs = @(
            $Op,
            $confData[$optRemotePath],
            $confData[$optMountLocalDrive],
            "--buffer-size", $confData[$optMountBufSize],
            "--timeout", $confData[$optMountIOIdleTimeout],
            "--contimeout", $confData[$optMountConnectTimeout],
            "--low-level-retries", $confData[$optLowLevelRetries],
            "--retries", $confData[$optRetries],
            "--retries-sleep", $confData[$optMountRetriesSleep]
        )

        # Volume name option?
        if ($confData.ContainsKey($optMountVolName)) {
            $mntArgs += @("--volname", $confData[$optMountVolName])
        }    

        # Additional flags?
        if ($confData.ContainsKey($optRCloneFlagsMount)) {
            $mntArgs += $confData[$optRCloneFlagsMount]
        }    

        Write-Host "$($confData[$optRemotePath]) mounted on $($confData[$optMountLocalDrive])"

        # Run rclone
        runRClone($mntArgs)

        Write-Host "$($confData[$optRemotePath]) unmounted on $($confData[$optMountLocalDrive])"

        # Never shutdown or hibernate after a mount
        $Shutdown = $false
        $Hibernate = $false
        break
    }
    "sync" {
        # Common sync args
        $baseSyncArgs = @(
            "--filter-from", $confData[$optFilterFile],
            "--log-file", $confData[$optLogFilePath],
            "--log-level", $confData[$optLogLevel],
            "--transfers", $confData[$optFileTransfers],
            "--checkers", $confData[$optCheckers],
            "--low-level-retries", $confData[$optLowLevelRetries],
            "--retries", $confData[$optRetries],
            "--retries-sleep", $confData[$optRetriesSleep]
        )

        # Additional flags?
        if ($confData.ContainsKey($optRCloneFlagsSync)) {
            $baseSyncArgs += $confData[$optRCloneFlagsSync]
        }    

        Write-Host "> Sync :"
        foreach ($dir in $confData[$optDirsToSync]) {
            $syncArgs = @(
                $Op,
                ($confData[$optLocalPath] + $dir),
                ($confData[$optRemotePath] + $dir)
            ) + $baseSyncArgs
            
            Write-Host "$($confData[$optLocalPath] + $dir) --> $($confData[$optRemotePath] + $dir)"
            log("$dir;start")
            runRClone($syncArgs)
            log("$dir;end")
        }

        break
    }
    default {
        throw "Unknown Op: $Op"
    }
}

if($Shutdown) {
    Write-Host "Shutting down..."
    shutdown -s -f
}

if($Hibernate) {
    Write-Host "Hibernating..."
    shutdown -h
}




