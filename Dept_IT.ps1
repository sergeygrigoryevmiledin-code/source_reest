#Requires -Version 5.1
# Dept_IT — удаление записей удалённого реестра (Installer Products / ProductName). UI RU/EN WinForms.
# ps2exe → Dept_IT_Multi_Work.exe  (пример: Import-Module ps2exe; Invoke-ps2exe -inputFile .\Dept_IT.ps1 -outputFile .\Dept_IT_Multi_Work.exe -noConsole -STA -iconFile .\Dept_IT.ico -x64 -DPIAware)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
try {
    Add-Type -Namespace DeptITNative -Name ConsoleApi -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
    $ch = [DeptITNative.ConsoleApi]::GetConsoleWindow()
    if ($ch -ne [IntPtr]::Zero) { [void][DeptITNative.ConsoleApi]::ShowWindow($ch, 0) }
} catch { }

$script:BackendScript = @'
param(
    [Parameter(Mandatory)][string]$HostName,
    [string]$Domain,
    [string]$UserName,
    [string]$Password,
    [int]$UseCurrentInt = 1,
    [Parameter(Mandatory)][string]$RegPath,
    [Parameter(Mandatory)][string]$ProductName,
    [Parameter(Mandatory)][string]$LogPath
)
$ErrorActionPreference = 'Continue'
try {
    $utf8Out = New-Object System.Text.UTF8Encoding $false
    [Console]::OutputEncoding = $utf8Out
    $OutputEncoding = $utf8Out
} catch { }
function Out-Line([string]$Kind, [string]$Message) {
    $tab = [char]9
    $line = $Kind + $tab + $Message
    [Console]::Out.WriteLine($line)
}
function Write-FileLog([string]$m) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $LogPath -Value ("$ts $m") -Encoding UTF8
}

$useCur = ($UseCurrentInt -ne 0)
$ipc = "\\$HostName\IPC$"
if ((-not $useCur) -and $UserName) {
    $fullUser = if ($Domain) { "$Domain\$UserName" } else { $UserName }
    $nu = net use $ipc /user:$fullUser $Password 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        $t = [char]9
        Out-Line 'RESULT' ((Get-Date -Format 'HH:mm:ss') + $t + $HostName + $t + 'False' + $t + 'AUTH_FAIL' + $t + ($nu.Trim()))
        Write-FileLog "AUTH_FAIL $HostName"
        exit 1
    }
}

try {
    $ping = New-Object System.Net.NetworkInformation.Ping
    $pr = $ping.Send($HostName, 1000)
    if ($pr.Status -ne 'Success') {
        $t = [char]9
        Out-Line 'RESULT' ((Get-Date -Format 'HH:mm:ss') + $t + $HostName + $t + 'False' + $t + 'PING_FAIL' + $t + [string]$pr.Status)
        Write-FileLog "PING_FAIL $HostName"
        exit 1
    }
} catch {
    $t = [char]9
    Out-Line 'RESULT' ((Get-Date -Format 'HH:mm:ss') + $t + $HostName + $t + 'False' + $t + 'PING_FAIL' + $t + $_.Exception.Message)
    exit 1
}

$suffix = $RegPath.Trim()
if ($suffix -match '^(?i)HKLM\\') { $suffix = $suffix.Substring(5) }
elseif ($suffix -match '^(?i)HKEY_LOCAL_MACHINE\\') { $suffix = $suffix.Substring(18) }
$remoteRoot = "\\$HostName\HKLM\$suffix"
Out-Line 'LOG' "Query $remoteRoot for ProductName '$ProductName'"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'reg.exe'
$psi.Arguments = ('query "{0}" /s /f "{1}" /t REG_SZ' -f $remoteRoot, $ProductName.Replace('"',''))
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
$psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding $false
$p = [System.Diagnostics.Process]::Start($psi)
$stdout = $p.StandardOutput.ReadToEnd()
$stderr = $p.StandardError.ReadToEnd()
$p.WaitForExit(120000) | Out-Null

if ($stderr) { Out-Line 'LOG' $stderr.Trim() }
$paths = New-Object System.Collections.Generic.List[string]
$current = $null
foreach ($line in ($stdout -split "`r?`n")) {
    if ($line -match '^(\\\\[^\s]+|HKEY_LOCAL_MACHINE\\[^\s]+)') {
        $current = $Matches[1]
    }
    elseif ($current -and ($line -match '^\s*ProductName\s+REG_SZ\s+')) {
        $val = ($line -replace '^\s*ProductName\s+REG_SZ\s+', '').Trim()
        if ($val -like "*$ProductName*") { $paths.Add($current) }
        $current = $null
    }
}

$unique = $paths | Select-Object -Unique
if (-not $unique -or $unique.Count -eq 0) {
    $t = [char]9
    Out-Line 'RESULT' ((Get-Date -Format 'HH:mm:ss') + $t + $HostName + $t + 'True' + $t + 'NO_MATCH' + $t + 'No matching ProductName')
    Write-FileLog "NO_MATCH $HostName"
} else {
    foreach ($hp in $unique) {
        $del = $hp -replace '(?i)^HKEY_LOCAL_MACHINE', "\\$HostName\HKLM"
        Out-Line 'LOG' "Delete $del"
        $psi2 = New-Object System.Diagnostics.ProcessStartInfo
        $psi2.FileName = 'reg.exe'
        $psi2.Arguments = ('delete "{0}" /f' -f $del)
        $psi2.RedirectStandardOutput = $true
        $psi2.RedirectStandardError = $true
        $psi2.UseShellExecute = $false
        $psi2.CreateNoWindow = $true
        $psi2.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
        $psi2.StandardErrorEncoding = New-Object System.Text.UTF8Encoding $false
        $pd = [System.Diagnostics.Process]::Start($psi2)
        $eo = $pd.StandardError.ReadToEnd()
        $pd.WaitForExit(60000) | Out-Null
        if ($pd.ExitCode -ne 0) {
            $t = [char]9
            Out-Line 'RESULT' ((Get-Date -Format 'HH:mm:ss') + $t + $HostName + $t + 'False' + $t + 'DELETE_FAIL' + $t + ($eo.Trim()))
            Write-FileLog "DELETE_FAIL $del"
        } else {
            $t = [char]9
            Out-Line 'RESULT' ((Get-Date -Format 'HH:mm:ss') + $t + $HostName + $t + 'True' + $t + 'DELETED' + $t + $del)
            Write-FileLog "DELETED $del"
        }
    }
}

if ((-not $useCur) -and $UserName) { net use $ipc /delete /y 2>&1 | Out-Null }
'@

$script:RuntimePath = Join-Path $env:TEMP 'Dept_it.ps1'
$script:LogDir = Join-Path $env:APPDATA 'Dept_IT\Logs'
if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }

$script:Lang = 'en'
$script:I18n = @{
    en = @{
        Title = 'Dept_IT'
        SearchMode = 'Search mode:'
        ModeIP = 'Find by IP'
        ModeRange = 'IP range'
        ModeSubnet = 'Subnet'
        Ip = 'IP:'
        Range = 'Range:'
        Subnet = 'Subnet:'
        RegPath = 'Registry path:'
        Product = 'Search value (ProductName):'
        Domain = 'Domain:'
        Username = 'Username:'
        Password = 'Password:'
        UseCur = 'Use current account'
        Run = 'Execute'
        Stop = 'Stop'
        CopyLog = 'Copy Log'
        OpenLogs = 'Open Logs Folder'
        Status = 'Status:'
        Ready = 'ready'
        Running = 'running…'
        Stopped = 'stopped'
        ScanResults = 'Scan Results'
        ExecLog = 'Execution Log'
        ColTime = 'Time'
        ColHost = 'Host'
        ColPass = 'Pass'
        ColStatus = 'Status'
        ColDetails = 'Details'
        Lang = 'English'
        InvalidHosts = 'Check IP, range, or subnet.'
    }
    ru = @{
        Title = 'Dept_IT'
        SearchMode = 'Режим поиска:'
        ModeIP = 'По IP'
        ModeRange = 'Диапазон IP'
        ModeSubnet = 'Подсеть'
        Ip = 'IP:'
        Range = 'Диапазон:'
        Subnet = 'Подсеть:'
        RegPath = 'Путь реестра:'
        Product = 'Искомое значение (ProductName):'
        Domain = 'Домен:'
        Username = 'Имя пользователя:'
        Password = 'Пароль:'
        UseCur = 'Текущая учётная запись'
        Run = 'ВЫПОЛНИТЬ'
        Stop = 'Стоп'
        CopyLog = 'Копировать журнал'
        OpenLogs = 'Папка журналов'
        Status = 'Статус:'
        Ready = 'готово'
        Running = 'выполняется…'
        Stopped = 'остановлено'
        ScanResults = 'Результаты сканирования'
        ExecLog = 'Журнал выполнения'
        ColTime = 'Время'
        ColHost = 'Узел'
        ColPass = 'ОК'
        ColStatus = 'Статус'
        ColDetails = 'Подробности'
        Lang = 'Русский'
        InvalidHosts = 'Проверьте IP, диапазон или подсеть.'
    }
}

function Get-I18n([string]$key) {
    $h = $script:I18n[$script:Lang]
    if (-not $h) { $h = $script:I18n['en'] }
    return [string]$h[$key]
}

function New-HairlineSeparator([int]$heightPx) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Height = $heightPx
    $p.Dock = [System.Windows.Forms.DockStyle]::Top
    $p.Margin = New-Object System.Windows.Forms.Padding(0)
    $p.Padding = New-Object System.Windows.Forms.Padding(0)
    $p.TabStop = $false
    $p.BackColor = [System.Drawing.Color]::FromArgb(203, 211, 223)
    return $p
}

$script:Ui = @{
    Canvas       = [System.Drawing.Color]::FromArgb(236, 239, 244)
    Surface      = [System.Drawing.Color]::FromArgb(245, 247, 250)
    Card         = [System.Drawing.Color]::FromArgb(255, 255, 255)
    Border       = [System.Drawing.Color]::FromArgb(203, 211, 223)
    Text         = [System.Drawing.Color]::FromArgb(36, 41, 47)
    Muted        = [System.Drawing.Color]::FromArgb(92, 98, 115)
    Input        = [System.Drawing.Color]::FromArgb(255, 255, 255)
    GridHeader   = [System.Drawing.Color]::FromArgb(241, 244, 249)
    GridAlt      = [System.Drawing.Color]::FromArgb(248, 250, 252)
    Accent       = [System.Drawing.Color]::FromArgb(0, 103, 192)
    Stop         = [System.Drawing.Color]::FromArgb(185, 48, 38)
    BtnSecondary = [System.Drawing.Color]::FromArgb(227, 232, 239)
    Hairline     = 1
}

function New-CredentialColumn([string]$labelText, [int]$boxWidth) {
    $col = New-Object System.Windows.Forms.FlowLayoutPanel
    $col.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $col.WrapContents = $false
    $col.AutoSize = $true
    $col.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $col.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 0)
    $col.BackColor = [System.Drawing.Color]::Transparent
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.AutoSize = $true
    $lbl.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
    $lbl.Text = $labelText
    $lbl.ForeColor = $script:Ui.Muted
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Width = $boxWidth
    $txt.Height = 23
    $txt.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $txt.BackColor = $script:Ui.Input
    $txt.ForeColor = $script:Ui.Text
    $col.Controls.Add($lbl)
    $col.Controls.Add($txt)
    return @{ Column = $col; Label = $lbl; TextBox = $txt }
}

$script:currentProcess = $null
$script:cancelRequested = $false
$script:langComboSuppressed = $false

$form = New-Object System.Windows.Forms.Form
$form.Text = Get-I18n 'Title'
$form.Size = New-Object System.Drawing.Size(1180, 820)
$form.MinimumSize = New-Object System.Drawing.Size(900, 600)
$form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor = $script:Ui.Canvas
$form.ShowIcon = $true

try {
    $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $exeName = [System.IO.Path]::GetFileName($exePath)
    $isShell = $exeName -imatch '^(powershell|pwsh|powershell_ise)\.exe$'
    if ($exePath -match '\.(exe|EXE)$' -and -not $isShell) {
        $null = ($form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath))
    }
} catch { }
if (-not $form.Icon) {
    $here = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { $null }
    if ($here) {
        $icoPath = Join-Path $here 'Dept_IT.ico'
        if (Test-Path -LiteralPath $icoPath) {
            $null = ($form.Icon = New-Object System.Drawing.Icon ((Resolve-Path -LiteralPath $icoPath).Path))
        }
    }
}

$headerHost = New-Object System.Windows.Forms.TableLayoutPanel
$headerHost.Dock = [System.Windows.Forms.DockStyle]::Top
$headerHost.Height = 50
$headerHost.ColumnCount = 1
$headerHost.RowCount = 1
$headerHost.BackColor = $script:Ui.Surface
$headerHost.Padding = New-Object System.Windows.Forms.Padding(0)
$headerHost.Margin = New-Object System.Windows.Forms.Padding(0)
$null = $headerHost.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$null = $headerHost.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50)))

$topBar = New-Object System.Windows.Forms.TableLayoutPanel
$topBar.Dock = [System.Windows.Forms.DockStyle]::Fill
$topBar.ColumnCount = 2
$topBar.RowCount = 1
$topBar.BackColor = $script:Ui.Surface
$topBar.Padding = New-Object System.Windows.Forms.Padding(12, 6, 14, 6)
$null = $topBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$null = $topBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))

$brand = New-Object System.Windows.Forms.Label
$brand.AutoSize = $true
$brand.Text = 'Dept_IT'
$brand.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
$brand.ForeColor = $script:Ui.Accent
$brand.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
$null = $topBar.Controls.Add($brand, 0, 0)

$cmbLang = New-Object System.Windows.Forms.ComboBox
$cmbLang.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbLang.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$cmbLang.BackColor = $script:Ui.Input
$cmbLang.ForeColor = $script:Ui.Text
$cmbLang.Width = 160
$cmbLang.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
$cmbLang.Items.AddRange(@('English', 'Русский'))
$null = ($cmbLang.SelectedIndex = 0)
$null = $topBar.Controls.Add($cmbLang, 1, 0)

$null = $headerHost.Controls.Add($topBar, 0, 0)

$panelMain = New-Object System.Windows.Forms.Panel
$panelMain.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelMain.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 8)
$panelMain.BackColor = $script:Ui.Canvas

$y = 8
$lblMode = New-Object System.Windows.Forms.Label
$lblMode.AutoSize = $true
$lblMode.Location = New-Object System.Drawing.Point(12, $y)
$lblMode.Text = (Get-I18n 'SearchMode')
$lblMode.ForeColor = $script:Ui.Muted
$cmbMode = New-Object System.Windows.Forms.ComboBox
$cmbMode.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbMode.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$cmbMode.BackColor = $script:Ui.Input
$cmbMode.ForeColor = $script:Ui.Text
$cmbMode.Location = New-Object System.Drawing.Point(140, ($y - 2))
$cmbMode.Width = 200
$cmbMode.Items.AddRange(@((Get-I18n 'ModeIP'), (Get-I18n 'ModeRange'), (Get-I18n 'ModeSubnet')))
$null = ($cmbMode.SelectedIndex = 0)

$lblIp = New-Object System.Windows.Forms.Label
$lblIp.AutoSize = $true
$lblIp.Location = New-Object System.Drawing.Point(360, $y)
$lblIp.Text = (Get-I18n 'Ip')
$lblIp.ForeColor = $script:Ui.Muted
$txtIp = New-Object System.Windows.Forms.TextBox
$txtIp.Location = New-Object System.Drawing.Point(400, ($y - 2))
$txtIp.Width = 220
$txtIp.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$txtIp.BackColor = $script:Ui.Input
$txtIp.ForeColor = $script:Ui.Text
$txtIp.Text = '172.17.74.101'

$lblRange = New-Object System.Windows.Forms.Label
$lblRange.AutoSize = $true
$lblRange.Location = New-Object System.Drawing.Point(360, $y)
$lblRange.Visible = $false
$lblRange.ForeColor = $script:Ui.Muted
$txtRange = New-Object System.Windows.Forms.TextBox
$txtRange.Location = New-Object System.Drawing.Point(430, ($y - 2))
$txtRange.Width = 300
$txtRange.Visible = $false
$txtRange.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$txtRange.BackColor = $script:Ui.Input
$txtRange.ForeColor = $script:Ui.Text

$lblSubnet = New-Object System.Windows.Forms.Label
$lblSubnet.AutoSize = $true
$lblSubnet.Location = New-Object System.Drawing.Point(360, $y)
$lblSubnet.Visible = $false
$lblSubnet.ForeColor = $script:Ui.Muted
$txtSubnet = New-Object System.Windows.Forms.TextBox
$txtSubnet.Location = New-Object System.Drawing.Point(430, ($y - 2))
$txtSubnet.Width = 200
$txtSubnet.Visible = $false
$txtSubnet.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$txtSubnet.BackColor = $script:Ui.Input
$txtSubnet.ForeColor = $script:Ui.Text

$y += 36
$lblReg = New-Object System.Windows.Forms.Label
$lblReg.AutoSize = $false
$lblReg.Location = New-Object System.Drawing.Point(12, $y)
$lblReg.Size = New-Object System.Drawing.Size(1050, 18)
$lblReg.Text = (Get-I18n 'RegPath')
$lblReg.ForeColor = $script:Ui.Muted
$y += 22
$txtReg = New-Object System.Windows.Forms.TextBox
$txtReg.Location = New-Object System.Drawing.Point(12, $y)
$txtReg.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$txtReg.Width = 1050
$txtReg.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$txtReg.BackColor = $script:Ui.Input
$txtReg.ForeColor = $script:Ui.Text
$txtReg.Text = 'HKLM\SOFTWARE\Classes\Installer\Products'

$y += 32
$lblProd = New-Object System.Windows.Forms.Label
$lblProd.AutoSize = $false
$lblProd.Location = New-Object System.Drawing.Point(12, $y)
$lblProd.Size = New-Object System.Drawing.Size(1050, 18)
$lblProd.Text = (Get-I18n 'Product')
$lblProd.ForeColor = $script:Ui.Muted
$y += 22
$txtProduct = New-Object System.Windows.Forms.TextBox
$txtProduct.Location = New-Object System.Drawing.Point(12, $y)
$txtProduct.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$txtProduct.Width = 1050
$txtProduct.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$txtProduct.BackColor = $script:Ui.Input
$txtProduct.ForeColor = $script:Ui.Text
$txtProduct.Text = 'ESET Management Agent'

$y += 36
$tlpCred = New-Object System.Windows.Forms.TableLayoutPanel
$tlpCred.AutoSize = $true
$tlpCred.ColumnCount = 4
$tlpCred.RowCount = 1
$tlpCred.Location = New-Object System.Drawing.Point(12, $y)
$tlpCred.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$tlpCred.Padding = New-Object System.Windows.Forms.Padding(0)
$tlpCred.Margin = New-Object System.Windows.Forms.Padding(0)
$tlpCred.BackColor = [System.Drawing.Color]::Transparent
$null = $tlpCred.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33)))
$null = $tlpCred.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33)))
$null = $tlpCred.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 34)))
$null = $tlpCred.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))

$colDomain = New-CredentialColumn (Get-I18n 'Domain') 200
$colUser = New-CredentialColumn (Get-I18n 'Username') 200
$colPass = New-CredentialColumn (Get-I18n 'Password') 200
$txtDomain = $colDomain.TextBox
$txtUser = $colUser.TextBox
$txtPass = $colPass.TextBox
$txtPass.UseSystemPasswordChar = $true

$chkUseCurrent = New-Object System.Windows.Forms.CheckBox
$chkUseCurrent.AutoSize = $true
$chkUseCurrent.Text = (Get-I18n 'UseCur')
$chkUseCurrent.ForeColor = $script:Ui.Text
$null = ($chkUseCurrent.Checked = $true)
$chkUseCurrent.Margin = New-Object System.Windows.Forms.Padding(16, 18, 0, 0)
$chkUseCurrent.Anchor = [System.Windows.Forms.AnchorStyles]::Left

$null = $tlpCred.Controls.Add($colDomain.Column, 0, 0)
$null = $tlpCred.Controls.Add($colUser.Column, 1, 0)
$null = $tlpCred.Controls.Add($colPass.Column, 2, 0)
$null = $tlpCred.Controls.Add($chkUseCurrent, 3, 0)
$tlpCred.Width = 1100

$y += 78
$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = (Get-I18n 'Run')
$btnRun.Location = New-Object System.Drawing.Point(12, $y)
$btnRun.Width = 148
$btnRun.Height = 30
$btnRun.BackColor = $script:Ui.Accent
$btnRun.ForeColor = [System.Drawing.Color]::White
$btnRun.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnRun.FlatAppearance.BorderSize = 0

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = (Get-I18n 'Stop')
$btnStop.Location = New-Object System.Drawing.Point(168, $y)
$btnStop.Width = 100
$btnStop.Height = 30
$btnStop.BackColor = $script:Ui.Stop
$btnStop.ForeColor = [System.Drawing.Color]::White
$btnStop.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnStop.FlatAppearance.BorderSize = 0
$btnStop.Enabled = $false

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = (Get-I18n 'CopyLog')
$btnCopy.Location = New-Object System.Drawing.Point(276, $y)
$btnCopy.Width = 130
$btnCopy.Height = 30
$btnCopy.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCopy.UseVisualStyleBackColor = $false
$btnCopy.BackColor = $script:Ui.BtnSecondary
$btnCopy.ForeColor = $script:Ui.Text
$btnCopy.FlatAppearance.BorderColor = $script:Ui.Border
$btnCopy.FlatAppearance.BorderSize = $script:Ui.Hairline

$btnOpenLogs = New-Object System.Windows.Forms.Button
$btnOpenLogs.Text = (Get-I18n 'OpenLogs')
$btnOpenLogs.Location = New-Object System.Drawing.Point(414, $y)
$btnOpenLogs.Width = 150
$btnOpenLogs.Height = 30
$btnOpenLogs.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnOpenLogs.UseVisualStyleBackColor = $false
$btnOpenLogs.BackColor = $script:Ui.BtnSecondary
$btnOpenLogs.ForeColor = $script:Ui.Text
$btnOpenLogs.FlatAppearance.BorderColor = $script:Ui.Border
$btnOpenLogs.FlatAppearance.BorderSize = $script:Ui.Hairline

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.AutoSize = $true
$lblStatus.Location = New-Object System.Drawing.Point(580, ($y + 8))
$lblStatus.Text = ((Get-I18n 'Status') + ' ' + (Get-I18n 'Ready'))
$lblStatus.ForeColor = $script:Ui.Muted

$splitTop = $y + 40
$panelTop = New-Object System.Windows.Forms.Panel
$panelTop.Dock = [System.Windows.Forms.DockStyle]::Top
$panelTop.Height = $splitTop
$panelTop.BackColor = $script:Ui.Canvas

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = [System.Windows.Forms.DockStyle]::Fill
$split.Orientation = [System.Windows.Forms.Orientation]::Horizontal
$split.SplitterWidth = 4
$split.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$split.BackColor = $script:Ui.Canvas
$split.Panel1MinSize = 120
$split.Panel2MinSize = 100
$split.Panel1.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 2)
$split.Panel2.Padding = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
$null = ($split.SplitterDistance = 280)

$resultsPanel = New-Object System.Windows.Forms.Panel
$resultsPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$resultsPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$resultsPanel.BackColor = $script:Ui.Card
$resultsPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$lblGrid = New-Object System.Windows.Forms.Label
$lblGrid.AutoSize = $false
$lblGrid.Height = 28
$lblGrid.Dock = [System.Windows.Forms.DockStyle]::None
$lblGrid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$lblGrid.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$lblGrid.Padding = New-Object System.Windows.Forms.Padding(8, 4, 0, 4)
$lblGrid.Text = (Get-I18n 'ScanResults')
$lblGrid.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$lblGrid.BackColor = $script:Ui.GridHeader
$lblGrid.ForeColor = $script:Ui.Text

$accentScanStrip = New-HairlineSeparator $script:Ui.Hairline
$accentScanStrip.Dock = [System.Windows.Forms.DockStyle]::None
$accentScanStrip.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = [System.Windows.Forms.DockStyle]::None
$grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.RowHeadersVisible = $false
$grid.ShowEditingIcon = $false
$grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$grid.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$grid.BackgroundColor = $script:Ui.Card
$grid.GridColor = $script:Ui.Border
$grid.CellBorderStyle = [System.Windows.Forms.DataGridViewCellBorderStyle]::Single
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersBorderStyle = [System.Windows.Forms.DataGridViewHeaderBorderStyle]::None
$grid.ColumnHeadersHeight = 32
$grid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::DisableResizing
$hdr = New-Object System.Windows.Forms.DataGridViewCellStyle
$hdr.BackColor = $script:Ui.GridHeader
$hdr.ForeColor = $script:Ui.Text
$hdr.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$hdr.SelectionBackColor = $hdr.BackColor
$hdr.SelectionForeColor = $hdr.ForeColor
$grid.ColumnHeadersDefaultCellStyle = $hdr
$cell = New-Object System.Windows.Forms.DataGridViewCellStyle
$cell.BackColor = $script:Ui.Card
$cell.ForeColor = $script:Ui.Text
$cell.SelectionBackColor = [System.Drawing.Color]::FromArgb(210, 232, 255)
$cell.SelectionForeColor = $script:Ui.Text
$grid.DefaultCellStyle = $cell
$grid.AlternatingRowsDefaultCellStyle = $cell.Clone()
$grid.AlternatingRowsDefaultCellStyle.BackColor = $script:Ui.GridAlt
$grid.Columns.Add('Time', (Get-I18n 'ColTime')) | Out-Null
$grid.Columns.Add('Host', (Get-I18n 'ColHost')) | Out-Null
$grid.Columns.Add('Pass', (Get-I18n 'ColPass')) | Out-Null
$grid.Columns.Add('Status', (Get-I18n 'ColStatus')) | Out-Null
$grid.Columns.Add('Details', (Get-I18n 'ColDetails')) | Out-Null
$grid.Columns['Pass'].FillWeight = 50
$grid.Columns['Time'].FillWeight = 80

$logPanel = New-Object System.Windows.Forms.Panel
$logPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$logPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$logPanel.BackColor = $script:Ui.Card
$logPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.AutoSize = $false
$lblLog.Height = 28
$lblLog.Dock = [System.Windows.Forms.DockStyle]::None
$lblLog.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$lblLog.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$lblLog.Padding = New-Object System.Windows.Forms.Padding(8, 4, 0, 4)
$lblLog.Text = (Get-I18n 'ExecLog')
$lblLog.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$lblLog.BackColor = $script:Ui.GridHeader
$lblLog.ForeColor = $script:Ui.Text

$rtb = New-Object System.Windows.Forms.RichTextBox
$rtb.Dock = [System.Windows.Forms.DockStyle]::None
$rtb.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$rtb.ReadOnly = $true
$rtb.Font = New-Object System.Drawing.Font('Consolas', 9)
$rtb.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$rtb.BackColor = $script:Ui.Card
$rtb.ForeColor = $script:Ui.Text

$null = $resultsPanel.Controls.Add($grid)
$null = $resultsPanel.Controls.Add($accentScanStrip)
$null = $resultsPanel.Controls.Add($lblGrid)

function Update-ResultsLayout {
    try {
        $w = [Math]::Max(40, $resultsPanel.ClientSize.Width)
        $h = [Math]::Max(50, $resultsPanel.ClientSize.Height)
        $hdrH = 28
        $sepH = 1
        $top = $hdrH + $sepH
        $lblGrid.SetBounds(0, 0, $w, $hdrH)
        $accentScanStrip.SetBounds(0, $hdrH, $w, $sepH)
        $gh = [Math]::Max(40, $h - $top)
        $grid.SetBounds(0, $top, $w, $gh)
    } catch { }
}

$resultsPanel.Add_Resize({ $null = Update-ResultsLayout })

function Update-LogLayout {
    try {
        $w = [Math]::Max(40, $logPanel.ClientSize.Width)
        $h = [Math]::Max(40, $logPanel.ClientSize.Height)
        $hdrH = 28
        $lblLog.SetBounds(0, 0, $w, $hdrH)
        $th = [Math]::Max(24, $h - $hdrH)
        $rtb.SetBounds(0, $hdrH, $w, $th)
    } catch { }
}

$null = $logPanel.Controls.Add($rtb)
$null = $logPanel.Controls.Add($lblLog)
$logPanel.Add_Resize({ $null = Update-LogLayout })

$null = $split.Panel1.Controls.Add($resultsPanel)
$null = $split.Panel2.Controls.Add($logPanel)

$null = $panelTop.Controls.AddRange(@(
    $lblMode, $cmbMode, $lblIp, $txtIp, $lblRange, $txtRange, $lblSubnet, $txtSubnet,
    $lblReg, $txtReg, $lblProd, $txtProduct, $tlpCred,
    $btnRun, $btnStop, $btnCopy, $btnOpenLogs, $lblStatus
))
$null = $panelMain.Controls.Add($split)
$null = $panelMain.Controls.Add($panelTop)
$null = $panelTop.BringToFront()
$form.Controls.Add($panelMain)
$form.Controls.Add($headerHost)

function Sync-PanelTopLayout {
    try {
        $panelTop.SuspendLayout()
        $null = $tlpCred.PerformLayout()
        $null = $panelTop.PerformLayout()
        $gap = 12
        $credBottom = [Math]::Max($tlpCred.Bottom, $txtProduct.Bottom + 8)
        $btnY = $credBottom + $gap
        $btnRun.Top = $btnY
        $btnStop.Top = $btnY
        $btnCopy.Top = $btnY
        $btnOpenLogs.Top = $btnY
        $dy = [int]([Math]::Max(0, ($btnRun.Height - $lblStatus.Height) / 2))
        $lblStatus.Top = $btnY + $dy
        $mx = 0
        foreach ($c in $panelTop.Controls) {
            if ($c.Bottom -gt $mx) { $mx = $c.Bottom }
        }
        if ($mx -gt 0) { $panelTop.Height = $mx + 16 }
        $panelTop.ResumeLayout($true)
    } catch { }
}

function Update-CredLayout {
    try {
        $pad = $panelMain.Padding
        $inner = $panelMain.ClientSize.Width - $pad.Left - $pad.Right
        if ($inner -lt 320) {
            $fb = $form.ClientSize.Width - $pad.Left - $pad.Right - 40
            if ($fb -gt $inner) { $inner = $fb }
        }
        if ($inner -lt 400) { $inner = 960 }
        $tw = [int][Math]::Max(400, $inner)
        $tlpCred.Width = $tw
        $chkReserve = 200
        $slot = [int](($tw - $chkReserve) / 3)
        if ($slot -lt 140) { $slot = 140 }
        $colDomain.TextBox.Width = $slot
        $colUser.TextBox.Width = $slot
        $colPass.TextBox.Width = $slot
        $colDomain.Column.Width = $slot + 6
        $colUser.Column.Width = $slot + 6
        $colPass.Column.Width = $slot + 6
        $null = Sync-PanelTopLayout
    } catch { }
}

function Update-SplitLayout {
    try {
        $sw = [Math]::Max(1, $split.SplitterWidth)
        $h = $split.ClientSize.Height
        if ($h -le ($sw + 80)) { return }
        $min1 = $split.Panel1MinSize
        $min2 = $split.Panel2MinSize
        $maxD = $h - $sw - $min2
        if ($maxD -lt $min1) { return }
        $d = [int](($h - $sw) * 0.48)
        if ($d -lt $min1) { $d = $min1 }
        if ($d -gt $maxD) { $d = $maxD }
        $null = ($split.SplitterDistance = $d)
    } catch { }
}

function Update-BodyLayout {
    try {
        $null = Update-SplitLayout
        $null = Update-ResultsLayout
        $null = Update-LogLayout
    } catch { }
}

$form.Add_Shown({
    $null = Update-CredLayout
    $null = Sync-PanelTopLayout
    $null = $panelMain.PerformLayout()
    $null = $split.PerformLayout()
    $null = Update-BodyLayout
    $btnRun.BringToFront()
    $btnStop.BringToFront()
    $btnCopy.BringToFront()
    $btnOpenLogs.BringToFront()
})
$panelMain.Add_Resize({
    $null = Update-CredLayout
    $null = Update-BodyLayout
})

function Set-IdleState {
    $btnRun.Enabled = $true
    $btnStop.Enabled = $false
    $null = ($lblStatus.Text = ((Get-I18n 'Status') + ' ' + (Get-I18n 'Ready')))
}
function Set-RunningState {
    $btnRun.Enabled = $false
    $btnStop.Enabled = $true
    $null = ($lblStatus.Text = ((Get-I18n 'Status') + ' ' + (Get-I18n 'Running')))
}

function Apply-Language {
    param([string]$LangCode)
    $script:Lang = $LangCode
    $form.Text = Get-I18n 'Title'
    $lblMode.Text = Get-I18n 'SearchMode'
    $lblIp.Text = Get-I18n 'Ip'
    $lblRange.Text = Get-I18n 'Range'
    $lblSubnet.Text = Get-I18n 'Subnet'
    $lblReg.Text = Get-I18n 'RegPath'
    $lblProd.Text = Get-I18n 'Product'
    $colDomain.Label.Text = Get-I18n 'Domain'
    $colUser.Label.Text = Get-I18n 'Username'
    $colPass.Label.Text = Get-I18n 'Password'
    $chkUseCurrent.Text = Get-I18n 'UseCur'
    $btnRun.Text = Get-I18n 'Run'
    $btnStop.Text = Get-I18n 'Stop'
    $btnCopy.Text = Get-I18n 'CopyLog'
    $btnOpenLogs.Text = Get-I18n 'OpenLogs'
    $lblGrid.Text = Get-I18n 'ScanResults'
    $lblLog.Text = Get-I18n 'ExecLog'
    $grid.Columns['Time'].HeaderText = Get-I18n 'ColTime'
    $grid.Columns['Host'].HeaderText = Get-I18n 'ColHost'
    $grid.Columns['Pass'].HeaderText = Get-I18n 'ColPass'
    $grid.Columns['Status'].HeaderText = Get-I18n 'ColStatus'
    $grid.Columns['Details'].HeaderText = Get-I18n 'ColDetails'
    $cmbMode.Items.Clear()
    $sel = $cmbMode.SelectedIndex
    if ($sel -lt 0) { $sel = 0 }
    $cmbMode.Items.AddRange(@((Get-I18n 'ModeIP'), (Get-I18n 'ModeRange'), (Get-I18n 'ModeSubnet')))
    if ($sel -ge $cmbMode.Items.Count) { $sel = 0 }
    $null = ($cmbMode.SelectedIndex = $sel)
    if (-not $btnRun.Enabled) { $null = ($lblStatus.Text = ((Get-I18n 'Status') + ' ' + (Get-I18n 'Running'))) }
    else { $null = ($lblStatus.Text = ((Get-I18n 'Status') + ' ' + (Get-I18n 'Ready'))) }
    $script:langComboSuppressed = $true
    try {
        $null = ($cmbLang.SelectedIndex = $(if ($script:Lang -eq 'ru') { 1 } else { 0 }))
    } finally {
        $script:langComboSuppressed = $false
    }
    $null = Sync-PanelTopLayout
    $null = Update-BodyLayout
}

$cmbLang.Add_SelectedIndexChanged({
    if ($script:langComboSuppressed) { return }
    if ($cmbLang.SelectedIndex -eq 1) { $null = Apply-Language 'ru' } else { $null = Apply-Language 'en' }
})

$cmbMode.Add_SelectedIndexChanged({
    $m = $cmbMode.SelectedIndex
    $null = ($lblIp.Visible = ($m -eq 0)); $null = ($txtIp.Visible = ($m -eq 0))
    $null = ($lblRange.Visible = ($m -eq 1)); $null = ($txtRange.Visible = ($m -eq 1))
    $null = ($lblSubnet.Visible = ($m -eq 2)); $null = ($txtSubnet.Visible = ($m -eq 2))
    $null = Sync-PanelTopLayout
    $null = Update-BodyLayout
})

$chkUseCurrent.Add_CheckedChanged({
    $en = -not $chkUseCurrent.Checked
    $null = ($txtDomain.Enabled = $en); $null = ($txtUser.Enabled = $en); $null = ($txtPass.Enabled = $en)
})

function Expand-IpList {
    $mode = $cmbMode.SelectedIndex
    if ($mode -eq 0) {
        $ip = $txtIp.Text.Trim()
        if ($ip) { return @($ip) }
        return @()
    }
    if ($mode -eq 1) {
        $r = $txtRange.Text.Trim()
        if ($r -match '^(\d+\.\d+\.\d+\.\d+)\s*-\s*(\d+\.\d+\.\d+\.\d+)$') {
            $a = [System.Net.IPAddress]::Parse($Matches[1]).GetAddressBytes()
            $b = [System.Net.IPAddress]::Parse($Matches[2]).GetAddressBytes()
            $n1 = [BitConverter]::ToUInt32(@($a[3], $a[2], $a[1], $a[0]), 0)
            $n2 = [BitConverter]::ToUInt32(@($b[3], $b[2], $b[1], $b[0]), 0)
            if ($n2 -lt $n1) { $t = $n1; $n1 = $n2; $n2 = $t }
            $list = New-Object System.Collections.Generic.List[string]
            for ($n = $n1; $n -le $n2; $n++) {
                $bytes = [BitConverter]::GetBytes([uint32]$n)
                $list.Add(('{0}.{1}.{2}.{3}' -f $bytes[3], $bytes[2], $bytes[1], $bytes[0]))
            }
            return $list
        }
        return @()
    }
    if ($mode -eq 2) {
        $s = $txtSubnet.Text.Trim()
        if ($s -match '^(\d+\.\d+\.\d+\.\d+)/(\d{1,2})$') {
            $baseIp = $Matches[1]
            $cidr = [int]$Matches[2]
            $bytes = [System.Net.IPAddress]::Parse($baseIp).GetAddressBytes()
            $hostBits = 32 - $cidr
            if ($hostBits -lt 0 -or $hostBits -gt 32) { return @() }
            $numHosts = [Math]::Pow(2, $hostBits) - 2
            if ($numHosts -le 0 -or $numHosts -gt 4096) { return @() }
            $baseNum = [BitConverter]::ToUInt32(@($bytes[3], $bytes[2], $bytes[1], $bytes[0]), 0)
            $mask = [uint32]([uint64]([Math]::Pow(2, 32) - [Math]::Pow(2, $hostBits)) -band [uint64]4294967295)
            $net = $baseNum -band $mask
            $list = New-Object System.Collections.Generic.List[string]
            for ($i = 1; $i -le $numHosts; $i++) {
                $addr = $net + [uint32]$i
                $bb = [BitConverter]::GetBytes($addr)
                $list.Add(('{0}.{1}.{2}.{3}' -f $bb[3], $bb[2], $bb[1], $bb[0]))
            }
            return $list
        }
        return @()
    }
    return @()
}

function Write-RuntimeBackend {
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    $null = [System.IO.File]::WriteAllText($script:RuntimePath, $script:BackendScript, $utf8Bom)
}

function Quote-PsSingle([string]$a) {
    if ($null -eq $a) { return "''" }
    return "'" + ($a -replace "'", "''") + "'"
}

function Append-Log([string]$s) {
    $null = $rtb.AppendText($s + "`r`n")
}

$btnCopy.Add_Click({
    if ($rtb.TextLength -gt 0) {
        $null = [System.Windows.Forms.Clipboard]::SetText($rtb.Text)
    }
})
$btnOpenLogs.Add_Click({
    if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
    $null = Start-Process explorer.exe $script:LogDir
})

$btnStop.Add_Click({
    $script:cancelRequested = $true
    if ($script:currentProcess -and -not $script:currentProcess.HasExited) {
        try { $script:currentProcess.Kill() } catch { }
    }
    $null = ($lblStatus.Text = ((Get-I18n 'Status') + ' ' + (Get-I18n 'Stopped')))
})

$btnRun.Add_Click({
    $hosts = Expand-IpList
    if ($hosts.Count -eq 0) {
        $null = ($lblStatus.Text = ((Get-I18n 'Status') + ' ' + (Get-I18n 'InvalidHosts')))
        return
    }
    $grid.Rows.Clear()
    $rtb.Clear()
    $script:cancelRequested = $false
    $null = Write-RuntimeBackend
    $sessionLog = Join-Path $script:LogDir ("session_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
    $null = Set-RunningState
    $regPath = $txtReg.Text.Trim()
    $product = $txtProduct.Text.Trim()
    $useCur = $chkUseCurrent.Checked
    $dom = $txtDomain.Text.Trim()
    $usr = $txtUser.Text.Trim()
    $pwdPlain = $txtPass.Text

    foreach ($h in $hosts) {
        if ($script:cancelRequested) { break }
        $perHostLog = Join-Path $script:LogDir ("host_{0}_{1:yyyyMMdd_HHmmss}.log" -f ($h -replace '\.', '_'), (Get-Date))
        $uc = if ($useCur) { '1' } else { '0' }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = (
            '-NoProfile -ExecutionPolicy Bypass -File ' + (Quote-PsSingle $script:RuntimePath) +
            ' -HostName ' + (Quote-PsSingle $h) +
            ' -Domain ' + (Quote-PsSingle $dom) +
            ' -UserName ' + (Quote-PsSingle $usr) +
            ' -Password ' + (Quote-PsSingle $pwdPlain) +
            ' -UseCurrentInt ' + $uc +
            ' -RegPath ' + (Quote-PsSingle $regPath) +
            ' -ProductName ' + (Quote-PsSingle $product) +
            ' -LogPath ' + (Quote-PsSingle $perHostLog)
        )
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        try {
            $proc = [System.Diagnostics.Process]::Start($psi)
            $script:currentProcess = $proc
            while (-not $proc.StandardOutput.EndOfStream) {
                if ($script:cancelRequested) { try { $proc.Kill() } catch { }; break }
                $line = $proc.StandardOutput.ReadLine()
                if (-not $line) { continue }
                $parts = $line -split "`t", 6
                if ($parts[0] -eq 'RESULT' -and $parts.Length -ge 6) {
                    $null = $grid.Rows.Add($parts[1], $parts[2], $parts[3], $parts[4], $parts[5])
                }
                elseif ($parts[0] -eq 'LOG') {
                    $tab = [char]9
                    Append-Log ($line -replace ('^LOG' + $tab), '')
                }
            }
            $errRest = $proc.StandardError.ReadToEnd()
            if ($errRest) { Append-Log $errRest.Trim() }
            $proc.WaitForExit(180000) | Out-Null
        } catch {
            Append-Log $_.Exception.Message
        }
        $script:currentProcess = $null
    }
    $null = Add-Content -LiteralPath $sessionLog -Value $rtb.Text -Encoding UTF8
    $null = Set-IdleState
})

$form.Add_Resize({
    $null = Update-CredLayout
    $w = $panelMain.ClientSize.Width - 24
    if ($w -gt 200) {
        $null = ($txtReg.Width = $w)
        $null = ($txtProduct.Width = $w)
        $null = ($lblReg.Width = $w)
        $null = ($lblProd.Width = $w)
    }
    $null = Update-BodyLayout
})

$null = ($chkUseCurrent.Checked = $true)
$null = Set-IdleState
$null = $form.PerformLayout()
$null = Update-CredLayout
$null = Sync-PanelTopLayout
$null = $panelMain.PerformLayout()
$null = $split.PerformLayout()
$null = Update-BodyLayout
[void]$form.ShowDialog()
