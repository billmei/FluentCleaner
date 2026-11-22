using System.Diagnostics;
using FluentCleaner.Services;
using FluentCleaner.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace FluentCleaner.Views;

public sealed partial class SettingsPage : Page
{
    private bool _pageReady; // true when the page has finished loading and is ready to handle events
    private bool _navigationReady;

    public SettingsPageViewModel ViewModel { get; } = new();
    public string AppVersion => AppInfo.DisplayVersion;
    public Visibility InsiderBadgeVisibility => AppInfo.IsInsider ? Visibility.Visible : Visibility.Collapsed;

    public SettingsPage()
    {
        InitializeComponent();
        _navigationReady = true;
        ShowSettingsSection("General");
        Loaded += async (_, _) =>
        {
            _pageReady = false;
            ViewModel.Refresh();                                    //sync database toggles, paths, theme
            await LoadSchedulerSettingsAsync();

            // Translator credit: hidden when the language file leaves it empty.
            var credit = ResourceService.Get("LblTranslatorCredit");
            var hasCredit = !string.IsNullOrWhiteSpace(credit) && credit != "LblTranslatorCredit";
            lblTranslatorCredit.Text       = hasCredit ? credit : "";
            lblTranslatorCredit.Visibility = hasCredit ? Visibility.Visible : Visibility.Collapsed;

            _pageReady = true;
        };
    }

    // The settings page has one local navigator and one content surface. Keeping the
    // sections here avoids a second Frame/router while still killing the long one-pager.
    private void SettingsNav_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_navigationReady || SettingsNav.SelectedItem is not ListViewItem item) return;
        ShowSettingsSection(item.Tag as string ?? "General");
    }

    private void ShowSettingsSection(string section)
    {
        AppearanceSection.Visibility = DatabaseSection.Visibility =
            section == "General" ? Visibility.Visible : Visibility.Collapsed;
        CookiesSection.Visibility = section == "Cookies" ? Visibility.Visible : Visibility.Collapsed;
        ExclusionsSection.Visibility = section == "Exclusions" ? Visibility.Visible : Visibility.Collapsed;
        PostCleanSection.Visibility = section == "Tasks" ? Visibility.Visible : Visibility.Collapsed;
        HistorySection.Visibility = section == "History" ? Visibility.Visible : Visibility.Collapsed;
        SchedulerSection.Visibility = section == "Scheduler" ? Visibility.Visible : Visibility.Collapsed;
        BackupSection.Visibility = AboutSection.Visibility =
            section == "About" ? Visibility.Visible : Visibility.Collapsed;
        SettingsScroll.ChangeView(null, 0, null, true);
    }

    private async void LangCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_pageReady) return;

        var result = await new ContentDialog
        {
            XamlRoot          = XamlRoot,
            RequestedTheme    = ActualTheme,
            Title             = ResourceService.Get("DlgRestartTitle"),
            Content           = ResourceService.Get("DlgRestartMessage"),
            PrimaryButtonText = ResourceService.Get("DlgRestartNow"),
            CloseButtonText   = ResourceService.Get("DlgRestartLater"),
            DefaultButton     = ContentDialogButton.Primary
        }.ShowAsync();

        if (result == ContentDialogResult.Primary)
        {
            Process.Start(Environment.ProcessPath!);
            Application.Current.Exit();
        }
    }

    private async Task LoadSchedulerSettingsAsync()
    {
        SchedulerFrequencyBox.ItemsSource = new[]
        {
            ResourceService.Get("Scheduler_FreqDaily"),
            ResourceService.Get("Scheduler_FreqWeekly"),
            ResourceService.Get("Scheduler_FreqLogon"),
        };

        var settings = AppSettings.Instance;
        SchedulerFrequencyBox.SelectedIndex = settings.ModernSchedulerFrequency switch
        {
            "Weekly" => 1,
            "Logon"  => 2,
            _        => 0,
        };

        SchedulerTimePicker.Time = TimeSpan.TryParse(settings.ModernSchedulerTime, out var time)
            ? time
            : new TimeSpan(3, 0, 0);
        SchedulerShutdownCheck.IsChecked = settings.ModernSchedulerShutdownAfter;

        var exists = await Task.Run(TaskSchedulerService.Exists);
        SchedulerEnabledToggle.IsOn = exists;
        SetSchedulerStatus(exists);
        SchedulerResultText.Text = "";
        UpdateSchedulerControls();
    }

    private void SchedulerEnabled_Toggled(object sender, RoutedEventArgs e)
    {
        if (_pageReady)
            UpdateSchedulerControls();
    }

    private void SchedulerFrequency_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_pageReady)
            UpdateSchedulerControls();
    }

    private void UpdateSchedulerControls()
    {
        var enabled = SchedulerEnabledToggle.IsOn;
        SchedulerFrequencyBox.IsEnabled = enabled;
        SchedulerTimePicker.IsEnabled = enabled && SchedulerFrequencyBox.SelectedIndex != 2;
        SchedulerShutdownCheck.IsEnabled = enabled;
    }

    private void SaveSchedulerSettings()
    {
        var settings = AppSettings.Instance;
        settings.ModernSchedulerFrequency = SchedulerFrequencyBox.SelectedIndex switch
        {
            1 => "Weekly",
            2 => "Logon",
            _ => "Daily",
        };
        settings.ModernSchedulerTime = SchedulerTimePicker.Time.ToString(@"hh\:mm");
        settings.ModernSchedulerShutdownAfter = SchedulerShutdownCheck.IsChecked == true;
        settings.Save();
    }

    private void SetSchedulerStatus(bool active) =>
        SchedulerStatusText.Text = ResourceService.Get(
            active ? "Scheduler_StatusActive" : "Scheduler_StatusInactive");

    private async void SchedulerApply_Click(object sender, RoutedEventArgs e)
    {
        SaveSchedulerSettings();
        SchedulerApplyButton.IsEnabled = false;
        SchedulerResultText.Text = ResourceService.Get("Scheduler_Applying");

        (bool Ok, string Message) result;
        if (!SchedulerEnabledToggle.IsOn)
        {
            result = await Task.Run(TaskSchedulerService.Delete);
        }
        else
        {
            var frequency = SchedulerFrequencyBox.SelectedIndex switch
            {
                1 => SchedulerFrequency.Weekly,
                2 => SchedulerFrequency.Logon,
                _ => SchedulerFrequency.Daily,
            };
            var scheduledTime = SchedulerTimePicker.Time;
            var shutdownAfter = SchedulerShutdownCheck.IsChecked == true;
            result = await Task.Run(() => TaskSchedulerService.CreateOrUpdate(
                frequency,
                scheduledTime,
                shutdownAfter));
        }

        SchedulerResultText.Text = $"{(result.Ok ? "✓" : "✗")} {result.Message}";
        SetSchedulerStatus(await Task.Run(TaskSchedulerService.Exists));
        SchedulerApplyButton.IsEnabled = true;
    }

    private void SchedulerOpen_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo("taskschd.msc") { UseShellExecute = true });
        }
        catch { }
    }

    private async void BrowseButton_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.Downloads };
        picker.FileTypeFilter.Add(".ini");

        var hwnd = WindowNative.GetWindowHandle((Application.Current as App)?.MainWindow);
        InitializeWithWindow.Initialize(picker, hwnd);

        var file = await picker.PickSingleFileAsync();
        if (file is not null)
            ViewModel.CustomPath = file.Path;
    }

    // Shows the built-in protected paths read-only;these are always skipped, no matter what the database says
    private async void ProtectedPaths_Click(object sender, RoutedEventArgs e)
    {
        var list = new TextBox
        {
            Text            = string.Join("\n", CleaningService.ProtectedPaths),
            IsReadOnly      = true,
            FontFamily      = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"),
            FontSize        = 12,
            TextWrapping    = TextWrapping.NoWrap,
            AcceptsReturn   = true,
            BorderThickness = new Thickness(0)
        };

        await new ContentDialog
        {
            XamlRoot        = XamlRoot,
            RequestedTheme  = ActualTheme,
            Title           = ResourceService.Get("DlgProtectedTitle"),
            Content         = new StackPanel
            {
                Spacing  = 10,
                Children =
                {
                    new TextBlock { Text = ResourceService.Get("DlgProtectedDesc"), TextWrapping = TextWrapping.Wrap },
                    list
                }
            },
            CloseButtonText = ResourceService.Get("DlgExplainClose")
        }.ShowAsync();
    }

    // --- Export / Import settings -----------------------------------------

    private async void ExportSettings_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileSavePicker { SuggestedStartLocation = PickerLocationId.Desktop, SuggestedFileName = "settings" };
        picker.FileTypeChoices.Add("JSON", [".json"]);

        var hwnd = WindowNative.GetWindowHandle((Application.Current as App)?.MainWindow);
        InitializeWithWindow.Initialize(picker, hwnd);

        var file = await picker.PickSaveFileAsync();
        if (file is null) return;

        try
        {
            AppSettings.ExportTo(file.Path);
            ViewModel.StatusText = ResourceService.Fmt("St_ExportSuccess", file.Name);
        }
        catch (Exception ex) { ViewModel.StatusText = ResourceService.Fmt("St_ExportFailed", ex.Message); }
    }

    private async void ImportSettings_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.Desktop };
        picker.FileTypeFilter.Add(".json");

        var hwnd = WindowNative.GetWindowHandle((Application.Current as App)?.MainWindow);
        InitializeWithWindow.Initialize(picker, hwnd);

        var file = await picker.PickSingleFileAsync();
        if (file is null) return;

        try
        {
            AppSettings.ImportFrom(file.Path);
            ViewModel.Refresh();
            CookiesSection.ReloadSettings();
            ViewModel.StatusText = ResourceService.Fmt("St_ImportSuccess", file.Name);
        }
        catch (Exception ex) { ViewModel.StatusText = ResourceService.Fmt("St_ImportFailed", ex.Message); }
    }
}
