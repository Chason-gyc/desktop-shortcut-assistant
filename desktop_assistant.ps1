Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$ErrorActionPreference = "Stop"

$AppName = "桌面软件助手"
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ShortcutsDir = Join-Path $BaseDir "shortcuts"
$IconPath = Join-Path $BaseDir "assets\app.ico"
$ShortcutExtensions = @(".lnk", ".url", ".appref-ms")

if (-not (Test-Path -LiteralPath $ShortcutsDir)) {
    New-Item -ItemType Directory -Path $ShortcutsDir | Out-Null
}

function Get-DesktopDir {
    [Environment]::GetFolderPath("Desktop")
}

function Get-PublicDesktopDir {
    $public = $env:PUBLIC
    if ([string]::IsNullOrWhiteSpace($public)) {
        $public = "C:\Users\Public"
    }
    Join-Path $public "Desktop"
}

function Get-DisplayName($Path) {
    [System.IO.Path]::GetFileNameWithoutExtension($Path)
}

function Get-UniqueDestination($TargetDir, $Name) {
    $candidate = Join-Path $TargetDir $Name
    if (-not (Test-Path -LiteralPath $candidate)) {
        return $candidate
    }

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $suffix = [System.IO.Path]::GetExtension($Name)
    $index = 2
    while ($true) {
        $candidate = Join-Path $TargetDir ("{0} ({1}){2}" -f $stem, $index, $suffix)
        if (-not (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
        $index++
    }
}

function Get-ShortcutFiles {
    Get-ChildItem -LiteralPath $ShortcutsDir -File |
        Where-Object { $ShortcutExtensions -contains $_.Extension.ToLowerInvariant() } |
        Sort-Object @{ Expression = { Get-DisplayName $_.FullName } }
}

function Get-FilteredShortcutFiles {
    $query = $SearchBox.Text.Trim().ToLowerInvariant()
    @(Get-ShortcutFiles | Where-Object { (Get-DisplayName $_.FullName).ToLowerInvariant().Contains($query) })
}

function Get-PageCount($FilteredCount) {
    [Math]::Max(1, [Math]::Ceiling($FilteredCount / $script:ItemsPerPage))
}

function Get-LogicalWorkingArea($Screen) {
    $pixelArea = $Screen.WorkingArea
    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($Window)

    [pscustomobject]@{
        Left = $pixelArea.Left / $dpi.DpiScaleX
        Top = $pixelArea.Top / $dpi.DpiScaleY
        Right = $pixelArea.Right / $dpi.DpiScaleX
        Bottom = $pixelArea.Bottom / $dpi.DpiScaleY
    }
}

function Get-AnchorScreen {
    if (-not [string]::IsNullOrWhiteSpace($script:AnchorScreenDeviceName)) {
        $screen = [System.Windows.Forms.Screen]::AllScreens |
            Where-Object { $_.DeviceName -eq $script:AnchorScreenDeviceName } |
            Select-Object -First 1
        if ($null -ne $screen) {
            return $screen
        }
    }

    $screen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
    $script:AnchorScreenDeviceName = $screen.DeviceName
    $screen
}

function Set-NearestCornerAnchor {
    $cursor = [System.Windows.Forms.Cursor]::Position
    $screen = [System.Windows.Forms.Screen]::FromPoint($cursor)
    $area = $screen.WorkingArea

    $script:AnchorScreenDeviceName = $screen.DeviceName
    if ($cursor.X -lt ($area.Left + ($area.Width / 2))) {
        $script:AnchorHorizontal = "Left"
    } else {
        $script:AnchorHorizontal = "Right"
    }
    if ($cursor.Y -lt ($area.Top + ($area.Height / 2))) {
        $script:AnchorVertical = "Top"
    } else {
        $script:AnchorVertical = "Bottom"
    }

    Set-CollapsedPosition
}

function Get-ShortcutTarget($Path) {
    if ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -ne ".lnk") {
        return $Path
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        if (-not [string]::IsNullOrWhiteSpace($shortcut.TargetPath)) {
            return $shortcut.TargetPath
        }
    } catch {
        return $Path
    }
    $Path
}

function Get-AppIconSource($Path) {
    try {
        $target = Get-ShortcutTarget $Path
        if (-not (Test-Path -LiteralPath $target)) {
            $target = $Path
        }
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($target)
        if ($null -eq $icon) {
            return $null
        }
        $bitmap = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
            $icon.Handle,
            [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromWidthAndHeight(40, 40)
        )
        $bitmap.Freeze()
        return $bitmap
    } catch {
        return $null
    }
}

function Show-Info($Message) {
    [System.Windows.MessageBox]::Show($Window, $Message, $AppName, "OK", "Information") | Out-Null
}

function Show-Error($Message) {
    [System.Windows.MessageBox]::Show($Window, $Message, $AppName, "OK", "Error") | Out-Null
}

function Open-Shortcut($Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        Show-Error "这个快捷方式已经不存在。"
        Refresh-Grid
        return
    }

    try {
        Set-CollapsedPosition
        Start-Process -FilePath $Path
    } catch {
        Show-Error "无法打开：$(Get-DisplayName $Path)`n$($_.Exception.Message)"
    }
}

function Restore-Shortcut($Path) {
    try {
        if (Test-Path -LiteralPath $Path) {
            $destination = Get-UniqueDestination (Get-DesktopDir) ([System.IO.Path]::GetFileName($Path))
            Move-Item -LiteralPath $Path -Destination $destination
        }
        Refresh-Grid
    } catch {
        Show-Error "无法还原：$([System.IO.Path]::GetFileName($Path))`n$($_.Exception.Message)"
    }
}

function Get-DesktopShortcutCandidates {
    $candidates = New-Object System.Collections.ArrayList
    foreach ($sourceDir in @((Get-DesktopDir), (Get-PublicDesktopDir))) {
        if (-not (Test-Path -LiteralPath $sourceDir)) {
            continue
        }

        foreach ($item in Get-ChildItem -LiteralPath $sourceDir -File) {
            if ($item.Name.ToLowerInvariant() -eq "desktop.ini") {
                continue
            }
            if ($ShortcutExtensions -contains $item.Extension.ToLowerInvariant()) {
                $candidates.Add($item) | Out-Null
            }
        }
    }

    @($candidates | Sort-Object @{ Expression = { Get-DisplayName $_.FullName } })
}

function Show-CollectSelectionDialog($Candidates) {
    $DialogXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="选择要收纳的快捷方式" Width="420" Height="520"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="#111827" FontFamily="Microsoft YaHei UI" FontSize="13">
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Text="选择要收纳的桌面快捷方式" Foreground="#F9FAFB"
                   FontSize="17" FontWeight="Bold" Margin="0,0,0,6"/>
        <CheckBox x:Name="SelectAllCheckBox" Grid.Row="1" Content="全选"
                  IsChecked="True" IsThreeState="True" Foreground="#D1D5DB" Margin="0,4,0,10"/>

        <Border Grid.Row="2" Background="#1F2937" CornerRadius="8"
                BorderBrush="#374151" BorderThickness="1">
            <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="10">
                <StackPanel x:Name="ShortcutList"/>
            </ScrollViewer>
        </Border>

        <Grid Grid.Row="3" Margin="0,14,0,0">
            <TextBlock x:Name="CountLabel" Foreground="#CBD5E1" VerticalAlignment="Center"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="CancelButton" Content="取消" Width="74" Height="30"
                        Margin="0,0,8,0" Background="#374151" Foreground="#F9FAFB"/>
                <Button x:Name="OkButton" Content="收纳" Width="74" Height="30"
                        Background="#18B957" Foreground="White"/>
            </StackPanel>
        </Grid>
    </Grid>
</Window>
"@

    $dialogReader = New-Object System.Xml.XmlNodeReader ([xml]$DialogXaml)
    $dialog = [Windows.Markup.XamlReader]::Load($dialogReader)
    $dialog.Owner = $Window
    if (Test-Path -LiteralPath $IconPath) {
        $dialog.Icon = New-Object System.Windows.Media.Imaging.BitmapImage((New-Object System.Uri($IconPath)))
    }

    $selectAllCheckBox = $dialog.FindName("SelectAllCheckBox")
    $shortcutList = $dialog.FindName("ShortcutList")
    $countLabel = $dialog.FindName("CountLabel")
    $okButton = $dialog.FindName("OkButton")
    $cancelButton = $dialog.FindName("CancelButton")
    $checkBoxes = New-Object System.Collections.ArrayList

    $updateCount = {
        $selected = @($checkBoxes | Where-Object { $_.IsChecked -eq $true }).Count
        $countLabel.Text = "已选择 $selected / $($checkBoxes.Count) 个"
        $okButton.IsEnabled = ($selected -gt 0)

        if ($selected -eq 0) {
            $selectAllCheckBox.IsChecked = $false
        } elseif ($selected -eq $checkBoxes.Count) {
            $selectAllCheckBox.IsChecked = $true
        } else {
            $selectAllCheckBox.IsChecked = $null
        }
    }

    foreach ($candidate in $Candidates) {
        $checkBox = New-Object System.Windows.Controls.CheckBox
        $checkBox.Content = Get-DisplayName $candidate.FullName
        $checkBox.ToolTip = $candidate.FullName
        $checkBox.Tag = $candidate
        $checkBox.IsChecked = $true
        $checkBox.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(243, 244, 246))
        $checkBox.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
        $checkBox.Add_Checked($updateCount)
        $checkBox.Add_Unchecked($updateCount)
        $checkBoxes.Add($checkBox) | Out-Null
        $shortcutList.Children.Add($checkBox) | Out-Null
    }

    $selectAllCheckBox.Add_Checked({
        foreach ($checkBox in $checkBoxes) {
            $checkBox.IsChecked = $true
        }
    })
    $selectAllCheckBox.Add_Unchecked({
        foreach ($checkBox in $checkBoxes) {
            $checkBox.IsChecked = $false
        }
    })
    $cancelButton.Add_Click({
        $dialog.DialogResult = $false
        $dialog.Close()
    })
    $okButton.Add_Click({
        $dialog.DialogResult = $true
        $dialog.Close()
    })

    & $updateCount
    $result = $dialog.ShowDialog()
    if ($result -ne $true) {
        return @()
    }

    @($checkBoxes | Where-Object { $_.IsChecked -eq $true } | ForEach-Object { $_.Tag })
}

function Show-Desktop {
    try {
        Set-CollapsedPosition
        $shell = New-Object -ComObject Shell.Application
        $shell.ToggleDesktop()
    } catch {
        Show-Error "无法回到桌面：$($_.Exception.Message)"
    }
}

function New-AppCard($File) {
    $name = Get-DisplayName $File.FullName
    $path = $File.FullName

    $border = New-Object System.Windows.Controls.Border
    $border.Width = 56
    $border.Height = 56
    $border.Margin = New-Object System.Windows.Thickness(6)
    $border.CornerRadius = New-Object System.Windows.CornerRadius(14)
    $border.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(95, 31, 41, 55))
    $border.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(60, 148, 163, 184))
    $border.BorderThickness = New-Object System.Windows.Thickness(1)
    $border.ToolTip = $name

    $iconHost = New-Object System.Windows.Controls.Grid
    $iconHost.Margin = New-Object System.Windows.Thickness(7)
    $border.Child = $iconHost

    $iconSource = Get-AppIconSource $path
    if ($null -ne $iconSource) {
        $image = New-Object System.Windows.Controls.Image
        $image.Width = 34
        $image.Height = 34
        $image.Source = $iconSource
        $image.Stretch = "Uniform"
        $image.HorizontalAlignment = "Center"
        $image.VerticalAlignment = "Center"
        $iconHost.Children.Add($image) | Out-Null
    } else {
        $fallback = New-Object System.Windows.Controls.TextBlock
        $fallback.Text = $name.Substring(0, 1).ToUpperInvariant()
        $fallback.FontSize = 20
        $fallback.FontWeight = "Bold"
        $fallback.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(187, 247, 208))
        $fallback.HorizontalAlignment = "Center"
        $fallback.VerticalAlignment = "Center"
        $iconHost.Children.Add($fallback) | Out-Null
    }

    $menu = New-Object System.Windows.Controls.ContextMenu
    $openItem = New-Object System.Windows.Controls.MenuItem
    $openItem.Header = "打开"
    $openItem.Tag = $path
    $openItem.Add_Click({
        param($sender, $eventArgs)
        Open-Shortcut $sender.Tag
    })
    $menu.Items.Add($openItem) | Out-Null

    $restoreItem = New-Object System.Windows.Controls.MenuItem
    $restoreItem.Header = "还原到桌面"
    $restoreItem.Tag = $path
    $restoreItem.Add_Click({
        param($sender, $eventArgs)
        Restore-Shortcut $sender.Tag
    })
    $menu.Items.Add($restoreItem) | Out-Null

    $border.Tag = $path
    $border.ContextMenu = $menu
    $border.Cursor = [System.Windows.Input.Cursors]::Hand
    $border.Add_MouseLeftButtonUp({
        param($sender, $eventArgs)
        Open-Shortcut $sender.Tag
    })
    $border.Add_MouseEnter({
        param($sender, $eventArgs)
        $sender.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(170, 34, 197, 94))
        $sender.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(134, 239, 172))
    })
    $border.Add_MouseLeave({
        param($sender, $eventArgs)
        $sender.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(95, 31, 41, 55))
        $sender.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(60, 148, 163, 184))
    })

    $border
}

$Xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="桌面软件助手" Width="12" Height="68"
        WindowStartupLocation="Manual" Topmost="True" Background="Transparent"
        AllowsTransparency="True" WindowStyle="None" ResizeMode="NoResize"
        ShowInTaskbar="False" FontFamily="Microsoft YaHei UI" FontSize="13">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="10,5"/>
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Foreground" Value="#1F2937"/>
        </Style>
    </Window.Resources>
    <Grid>
        <Border x:Name="TriggerIcon" Width="12" Height="68" CornerRadius="0,10,10,0"
                Background="#9918B957" HorizontalAlignment="Left" VerticalAlignment="Center"
                BorderBrush="#6622C55E" BorderThickness="0,1,1,1"
                ToolTip="移入打开；按住拖动到屏幕角落">
            <Grid>
                <TextBlock Text="⋮" Foreground="#E8FFF0" FontSize="18" FontWeight="Bold"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
        </Border>

        <Border x:Name="MainShell" Visibility="Collapsed" Background="#B3111827"
                CornerRadius="14" BorderBrush="#4D5E6B7E" BorderThickness="1">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="44"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="32"/>
                </Grid.RowDefinitions>

                <Border Grid.Row="0" Background="#99147A43" CornerRadius="14,14,0,0">
                    <Grid Margin="10,0">
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <Border Width="24" Height="24" CornerRadius="7" Background="#8022C55E" Margin="0,0,7,0">
                                <TextBlock Text="▦" Foreground="White" FontSize="15" FontWeight="Bold"
                                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <TextBlock Text="桌面软件助手" Foreground="White" FontSize="15" FontWeight="Bold"
                                       VerticalAlignment="Center"/>
                        </StackPanel>
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                            <Button x:Name="CloseButton" Content="‹" ToolTip="收起" Width="28" Height="24"
                                    Margin="0,0,6,0" Padding="0" FontSize="18" FontWeight="Bold"
                                    Background="#8022C55E" Foreground="White"/>
                            <Button x:Name="ExitButton" Content="×" ToolTip="退出" Width="28" Height="24"
                                    Padding="0" FontSize="16" FontWeight="Bold"
                                    Background="#80374151" Foreground="White"/>
                        </StackPanel>
                    </Grid>
                </Border>

                <Border Grid.Row="1" Background="Transparent" Padding="10,8,10,7">
                    <StackPanel>
                        <Border Background="#B31F2937" CornerRadius="9" BorderBrush="#4D5E6B7E" BorderThickness="1" Padding="9,4">
                            <TextBox x:Name="SearchBox" BorderThickness="0" FontSize="14"
                                     Background="Transparent" Foreground="#F9FAFB" CaretBrush="#22C55E"
                                     VerticalContentAlignment="Center"/>
                        </Border>
                        <Grid Margin="0,8,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="42"/>
                                <ColumnDefinition Width="42"/>
                                <ColumnDefinition Width="42"/>
                            </Grid.ColumnDefinitions>
                            <Button x:Name="CollectButton" Grid.Column="0" Content="⬇" ToolTip="收纳桌面快捷方式"
                                    Height="28" Margin="0,0,7,0" FontSize="15" Background="#18B957" Foreground="White"/>
                            <Button x:Name="RefreshButton" Grid.Column="1" Content="↻" ToolTip="刷新"
                                    Width="36" Height="28" Margin="0,0,6,0" FontSize="16" Background="#991F2937" Foreground="#F9FAFB"/>
                            <Button x:Name="RestoreAllButton" Grid.Column="2" Content="↥" ToolTip="全部恢复到桌面"
                                    Width="36" Height="28" Margin="0,0,6,0" FontSize="16" Background="#991F2937" Foreground="#F9FAFB"/>
                            <Button x:Name="ShowDesktopButton" Grid.Column="3" Content="▱" ToolTip="一键回到桌面"
                                    Width="36" Height="28" FontSize="15" Background="#991F2937" Foreground="#F9FAFB"/>
                        </Grid>
                    </StackPanel>
                </Border>

                <Border x:Name="ShortcutGridHost" Grid.Row="2" Margin="10,0,10,0" Background="#66111827" CornerRadius="12"
                        BorderBrush="#4D5E6B7E" BorderThickness="1">
                    <WrapPanel x:Name="GridPanel" Margin="6" VerticalAlignment="Top"/>
                </Border>

                <Grid Grid.Row="3" Margin="12,0">
                    <TextBlock x:Name="StatusLabel" VerticalAlignment="Center"
                               Foreground="#CBD5E1" FontSize="12"/>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Button x:Name="PrevPageButton" Content="‹" ToolTip="上一页" Width="24" Height="22"
                                Margin="0,0,5,0" Padding="0" FontSize="15" FontWeight="Bold"
                                Background="#991F2937" Foreground="#F9FAFB"/>
                        <TextBlock x:Name="PageLabel" Width="44" TextAlignment="Center" VerticalAlignment="Center"
                                   Foreground="#CBD5E1" FontSize="12"/>
                        <Button x:Name="NextPageButton" Content="›" ToolTip="下一页" Width="24" Height="22"
                                Margin="5,0,0,0" Padding="0" FontSize="15" FontWeight="Bold"
                                Background="#991F2937" Foreground="#F9FAFB"/>
                    </StackPanel>
                </Grid>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
$Window = [Windows.Markup.XamlReader]::Load($reader)
if (Test-Path -LiteralPath $IconPath) {
    $iconUri = New-Object System.Uri($IconPath)
    $Window.Icon = New-Object System.Windows.Media.Imaging.BitmapImage($iconUri)
}

$TriggerIcon = $Window.FindName("TriggerIcon")
$MainShell = $Window.FindName("MainShell")
$SearchBox = $Window.FindName("SearchBox")
$CollectButton = $Window.FindName("CollectButton")
$RefreshButton = $Window.FindName("RefreshButton")
$RestoreAllButton = $Window.FindName("RestoreAllButton")
$ShowDesktopButton = $Window.FindName("ShowDesktopButton")
$CloseButton = $Window.FindName("CloseButton")
$ExitButton = $Window.FindName("ExitButton")
$ShortcutGridHost = $Window.FindName("ShortcutGridHost")
$GridPanel = $Window.FindName("GridPanel")
$StatusLabel = $Window.FindName("StatusLabel")
$PrevPageButton = $Window.FindName("PrevPageButton")
$NextPageButton = $Window.FindName("NextPageButton")
$PageLabel = $Window.FindName("PageLabel")
$script:CurrentPage = 0
$script:ItemsPerPage = 12
$script:AnchorScreenDeviceName = $null
$script:AnchorHorizontal = "Left"
$script:AnchorVertical = "Bottom"
$script:IsPointerDown = $false
$script:IsDragging = $false
$script:DragStartPoint = $null
$script:DragOffset = $null

function Set-CollapsedPosition {
    $workingArea = Get-LogicalWorkingArea (Get-AnchorScreen)
    $Window.Width = 12
    $Window.Height = 68
    if ($script:AnchorHorizontal -eq "Right") {
        $Window.Left = $workingArea.Right - $Window.Width
        $TriggerIcon.CornerRadius = [System.Windows.CornerRadius]::new(10, 0, 0, 10)
        $TriggerIcon.BorderThickness = [System.Windows.Thickness]::new(1, 1, 0, 1)
    } else {
        $Window.Left = $workingArea.Left
        $TriggerIcon.CornerRadius = [System.Windows.CornerRadius]::new(0, 10, 10, 0)
        $TriggerIcon.BorderThickness = [System.Windows.Thickness]::new(0, 1, 1, 1)
    }
    if ($script:AnchorVertical -eq "Top") {
        $Window.Top = $workingArea.Top + 12
    } else {
        $Window.Top = $workingArea.Bottom - $Window.Height - 12
    }
    $MainShell.Visibility = "Collapsed"
    $TriggerIcon.Visibility = "Visible"
}

function Set-ExpandedPosition {
    $workingArea = Get-LogicalWorkingArea (Get-AnchorScreen)
    $Window.Width = 340
    $Window.Height = 370
    if ($script:AnchorHorizontal -eq "Right") {
        $Window.Left = $workingArea.Right - $Window.Width
    } else {
        $Window.Left = $workingArea.Left
    }
    if ($script:AnchorVertical -eq "Top") {
        $Window.Top = $workingArea.Top + 10
    } else {
        $Window.Top = $workingArea.Bottom - $Window.Height - 10
    }
    $TriggerIcon.Visibility = "Collapsed"
    $MainShell.Visibility = "Visible"
    Refresh-Grid
    $Window.Activate() | Out-Null
}

function Set-PageState($FilteredCount, $TotalCount) {
    $pageCount = Get-PageCount $FilteredCount
    if ($script:CurrentPage -ge $pageCount) {
        $script:CurrentPage = $pageCount - 1
    }
    if ($script:CurrentPage -lt 0) {
        $script:CurrentPage = 0
    }

    $PrevPageButton.IsEnabled = ($script:CurrentPage -gt 0)
    $NextPageButton.IsEnabled = ($script:CurrentPage -lt ($pageCount - 1))
    $PageLabel.Text = "$($script:CurrentPage + 1)/$pageCount"

    if ($FilteredCount -eq 0 -or $pageCount -le 1) {
        $PrevPageButton.Visibility = "Collapsed"
        $NextPageButton.Visibility = "Collapsed"
        $PageLabel.Visibility = "Collapsed"
    } else {
        $PrevPageButton.Visibility = "Visible"
        $NextPageButton.Visibility = "Visible"
        $PageLabel.Visibility = "Visible"
    }

    if ($SearchBox.Text.Trim().Length -gt 0) {
        $StatusLabel.Text = "已收纳 $TotalCount 个，匹配 $FilteredCount 个"
    } else {
        $StatusLabel.Text = "已收纳 $TotalCount 个快捷方式"
    }
}

function Refresh-Grid {
    $GridPanel.Children.Clear()
    $files = @(Get-FilteredShortcutFiles)
    $total = @(Get-ShortcutFiles).Count
    Set-PageState $files.Count $total

    if ($files.Count -eq 0) {
        $empty = New-Object System.Windows.Controls.StackPanel
        $empty.Width = 280
        $empty.Height = 150
        $empty.HorizontalAlignment = "Center"
        $empty.VerticalAlignment = "Center"

        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = "这里还没有快捷方式"
        $title.FontSize = 16
        $title.FontWeight = "Bold"
        $title.TextAlignment = "Center"
        $title.Margin = New-Object System.Windows.Thickness(0, 36, 0, 8)
        $title.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(243, 244, 246))
        $empty.Children.Add($title) | Out-Null

        $hint = New-Object System.Windows.Controls.TextBlock
        $hint.Text = "点击一键收纳桌面，把快捷方式整理到这里。"
        $hint.TextAlignment = "Center"
        $hint.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(203, 213, 225))
        $empty.Children.Add($hint) | Out-Null

        $GridPanel.Children.Add($empty) | Out-Null
    } else {
        $pageFiles = @($files | Select-Object -Skip ($script:CurrentPage * $script:ItemsPerPage) -First $script:ItemsPerPage)
        foreach ($file in $pageFiles) {
            $GridPanel.Children.Add((New-AppCard $file)) | Out-Null
        }
    }
}

function Move-Page($Delta) {
    $files = @(Get-FilteredShortcutFiles)
    $pageCount = Get-PageCount $files.Count
    $targetPage = $script:CurrentPage + $Delta

    if ($targetPage -lt 0 -or $targetPage -ge $pageCount) {
        return $false
    }

    $script:CurrentPage = $targetPage
    Refresh-Grid
    return $true
}

$CollectButton.Add_Click({
    $candidates = @(Get-DesktopShortcutCandidates)
    if ($candidates.Count -eq 0) {
        Refresh-Grid
        $StatusLabel.Text = "桌面上没有新的快捷方式"
        return
    }

    $selectedItems = @(Show-CollectSelectionDialog $candidates)
    if ($selectedItems.Count -eq 0) {
        $StatusLabel.Text = "已取消收纳"
        return
    }

    $moved = 0
    foreach ($item in $selectedItems) {
        if (-not (Test-Path -LiteralPath $item.FullName)) {
            continue
        }

        try {
            $destination = Get-UniqueDestination $ShortcutsDir $item.Name
            Move-Item -LiteralPath $item.FullName -Destination $destination
            $moved++
        } catch {
            Show-Error "无法移动：$($item.Name)`n$($_.Exception.Message)"
        }
    }

    Refresh-Grid
    if ($moved -eq 0) {
        $StatusLabel.Text = "桌面上没有新的快捷方式"
    } else {
        $StatusLabel.Text = "已收纳 $moved 个桌面快捷方式"
    }
})

$RefreshButton.Add_Click({ Refresh-Grid })
$ShowDesktopButton.Add_Click({ Show-Desktop })
$SearchBox.Add_TextChanged({
    $script:CurrentPage = 0
    Refresh-Grid
})
$PrevPageButton.Add_Click({
    Move-Page -1 | Out-Null
})
$NextPageButton.Add_Click({
    Move-Page 1 | Out-Null
})
$ShortcutGridHost.Add_PreviewMouseWheel({
    param($sender, $eventArgs)

    if ($eventArgs.Delta -lt 0) {
        $moved = Move-Page 1
    } elseif ($eventArgs.Delta -gt 0) {
        $moved = Move-Page -1
    } else {
        $moved = $false
    }

    if ($moved) {
        $eventArgs.Handled = $true
    }
})
$script:AutoCollapseTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:AutoCollapseTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$script:AutoCollapseTimer.Add_Tick({
    $script:AutoCollapseTimer.Stop()
    if (
        $MainShell.Visibility -eq "Visible" -and
        -not $Window.IsMouseOver -and
        $Window.OwnedWindows.Count -eq 0
    ) {
        Set-CollapsedPosition
    }
})

$script:ExpandTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ExpandTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:ExpandTimer.Add_Tick({
    $script:ExpandTimer.Stop()
    if (
        $TriggerIcon.Visibility -eq "Visible" -and
        $TriggerIcon.IsMouseOver -and
        -not $script:IsPointerDown
    ) {
        Set-ExpandedPosition
    }
})

$TriggerIcon.Add_MouseEnter({
    $script:AutoCollapseTimer.Stop()
    if (-not $script:IsPointerDown) {
        $script:ExpandTimer.Stop()
        $script:ExpandTimer.Start()
    }
})
$TriggerIcon.Add_MouseLeave({
    if (-not $script:IsPointerDown) {
        $script:ExpandTimer.Stop()
    }
})
$TriggerIcon.Add_PreviewMouseLeftButtonDown({
    param($sender, $eventArgs)

    $script:ExpandTimer.Stop()
    $script:AutoCollapseTimer.Stop()
    $script:IsPointerDown = $true
    $script:IsDragging = $false
    $script:DragStartPoint = [System.Windows.Forms.Cursor]::Position
    $script:DragOffset = $eventArgs.GetPosition($Window)
    [System.Windows.Input.Mouse]::Capture($TriggerIcon) | Out-Null
    $eventArgs.Handled = $true
})
$TriggerIcon.Add_PreviewMouseMove({
    param($sender, $eventArgs)

    if (
        -not $script:IsPointerDown -or
        $eventArgs.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed
    ) {
        return
    }

    $cursor = [System.Windows.Forms.Cursor]::Position
    if (-not $script:IsDragging) {
        $distance = [Math]::Max(
            [Math]::Abs($cursor.X - $script:DragStartPoint.X),
            [Math]::Abs($cursor.Y - $script:DragStartPoint.Y)
        )
        if ($distance -lt 4) {
            return
        }
        $script:IsDragging = $true
    }

    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($Window)
    $Window.Left = ($cursor.X / $dpi.DpiScaleX) - $script:DragOffset.X
    $Window.Top = ($cursor.Y / $dpi.DpiScaleY) - $script:DragOffset.Y
    $eventArgs.Handled = $true
})
$TriggerIcon.Add_PreviewMouseLeftButtonUp({
    param($sender, $eventArgs)

    if (-not $script:IsPointerDown) {
        return
    }

    $wasDragging = $script:IsDragging
    $script:IsPointerDown = $false
    $script:IsDragging = $false
    $TriggerIcon.ReleaseMouseCapture()

    if ($wasDragging) {
        Set-NearestCornerAnchor
    } else {
        Set-ExpandedPosition
    }
    $eventArgs.Handled = $true
})
$Window.Add_MouseEnter({ $script:AutoCollapseTimer.Stop() })
$Window.Add_MouseLeave({
    if ($MainShell.Visibility -eq "Visible" -and -not $script:IsDragging) {
        $script:AutoCollapseTimer.Stop()
        $script:AutoCollapseTimer.Start()
    }
})
$Window.Add_Deactivated({
    if ($MainShell.Visibility -eq "Visible") {
        $script:AutoCollapseTimer.Stop()
        $script:AutoCollapseTimer.Start()
    }
})
$CloseButton.Add_Click({ Set-CollapsedPosition })
$ExitButton.Add_Click({ $Window.Close() })

$RestoreAllButton.Add_Click({
    $files = @(Get-ShortcutFiles)
    if ($files.Count -eq 0) {
        $StatusLabel.Text = "没有需要恢复的快捷方式"
        return
    }

    $restored = 0
    foreach ($file in $files) {
        try {
            $destination = Get-UniqueDestination (Get-DesktopDir) $file.Name
            Move-Item -LiteralPath $file.FullName -Destination $destination
            $restored++
        } catch {
            Show-Error "无法还原：$($file.Name)`n$($_.Exception.Message)"
        }
    }

    Refresh-Grid
    $StatusLabel.Text = "已恢复 $restored 个快捷方式到桌面"
})

$Window.Add_ContentRendered({
    Refresh-Grid
    Set-CollapsedPosition
})
$Window.ShowDialog() | Out-Null






