using FluentCleaner.Models;
using FluentCleaner.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using System.Collections.ObjectModel;
using System.Globalization;

namespace FluentCleaner.ViewModels;

public record HistoryRow(string Date, string Amount, string Bar, string Items);

// One entry in the language dropdown. Code is the BCP-47 tag ("en-US") or "" for system default.
public record LanguageOption(string Code, string Name);

public partial class SettingsPageViewModel : ObservableObject
{
    private static string Winapp2LocalPath  => Path.Combine(AppContext.BaseDirectory, "Winapp2.ini");
    private static string Winapp3LocalPath  => Path.Combine(AppContext.BaseDirectory, "Winapp3.ini");
    private static string WinappxLocalPath  => Path.Combine(AppContext.BaseDirectory, "Winappx.ini");

    // --- Observable state -----------------------------------------------------

    // Database toggles
    [ObservableProperty] public partial bool   EnableWinapp2 { get; set; } = true;
    [ObservableProperty] public partial bool   EnableWinapp3 { get; set; }
    [ObservableProperty] public partial bool   EnableWinappx { get; set; } = true;
    [ObservableProperty] public partial bool   IsCustomSource { get; set; }      // custom path row has a saved value

    // File-info strings shown below each database row
    [ObservableProperty] public partial string Winapp2Info { get; set; } = "";
    [ObservableProperty] public partial string Winapp3Info { get; set; } = "";
    [ObservableProperty] public partial string WinappxInfo { get; set; } = "";

    // Custom database path
    [ObservableProperty] public partial string CustomPath { get; set; } = "";

    // Post-clean tasks
    [ObservableProperty] public partial bool   PostCleanEnabled  { get; set; }
    [ObservableProperty] public partial string PostCleanCommands { get; set; } = "";

    // Global exclusions;paths that are never cleaned, no matter what the INI says
    [ObservableProperty] public partial bool   GlobalExclusionsEnabled { get; set; }
    [ObservableProperty] public partial string GlobalExclusionsText    { get; set; } = "";

    // History
    [ObservableProperty] public partial bool   CleanHistoryEnabled { get; set; } = true;
    [ObservableProperty] public partial string HistorySummary { get; set; } = "";
    public ObservableCollection<HistoryRow> HistoryRows { get; } = [];

    // Shared
    [ObservableProperty] public partial string StatusText { get; set; } = "";
    [ObservableProperty] public partial int    ThemeIndex    { get; set; }

    // Language dropdown — populated at runtime from the deployed Strings\{lang}\ folders.
    public ObservableCollection<LanguageOption> Languages { get; } = [];
    [ObservableProperty] public partial LanguageOption? SelectedLanguage { get; set; }
    [ObservableProperty] public partial bool   IsPortable { get; set; }         // true when settings.json sits next to exe

    private bool _refreshing;

    public SettingsPageViewModel() => Refresh();

    // --- Theme ----------------------------------------------------------------

    partial void OnThemeIndexChanged(int value)
    {
        if (_refreshing) return;
        var theme = value switch { 1 => "Light", 2 => "Dark", _ => "" };
        AppSettings.Instance.Theme = theme;
        AppSettings.Instance.Save();
        (Microsoft.UI.Xaml.Application.Current as App)?.ApplyTheme(theme);
    }

    // --- Language -------------------------------------------------------------

    partial void OnSelectedLanguageChanged(LanguageOption? value)
    {
        if (_refreshing || value is null) return;
        AppSettings.Instance.Language = value.Code;
        AppSettings.Instance.Save();
        ResourceService.SetLanguage(value.Code); // applies PrimaryLanguageOverride; code-side strings switch immediately
        // restart prompt is shown by SettingsPage code-behind via PropertyChanged
    }

    // Builds the dropdown: a "System default" entry first, then every discovered language shown in
    // its own native name (e.g. "English", "Deutsch") so the picker reads naturally for each locale
    private void BuildLanguageList()
    {
        Languages.Clear();
        Languages.Add(new LanguageOption("", ResourceService.Get("St_LangAuto")));

        foreach (var code in ResourceService.GetAvailableLanguages())
            Languages.Add(new LanguageOption(code, NativeName(code)));

        var current = AppSettings.Instance.Language ?? "";
        SelectedLanguage = Languages.FirstOrDefault(l => l.Code == current) ?? Languages[0];
    }

    // Returns the language's own name, capitalized (de-DE -> "Deutsch", en-US -> "English").
    private static string NativeName(string code)
    {
        try
        {
            var ci      = CultureInfo.GetCultureInfo(code);
            var neutral = ci.IsNeutralCulture ? ci : (ci.Parent ?? ci);
            var name    = (neutral ?? ci).NativeName;
            return string.IsNullOrEmpty(name) ? code : char.ToUpper(name[0]) + name[1..];
        }
        catch { return code; }   // unknown tag? show the raw code rather than crashing
    }

    // --- Database toggles -----------------------------------------------------

    partial void OnEnableWinapp2Changed(bool value)
    {
        if (_refreshing) return;
        AppSettings.Instance.EnableWinapp2 = value;
        AppSettings.Instance.Save();
        RefreshFileInfo();
    }

    partial void OnEnableWinapp3Changed(bool value)
    {
        if (_refreshing) return;
        AppSettings.Instance.EnableWinapp3 = value;
        AppSettings.Instance.Save();
        StatusText = value && !File.Exists(Winapp3LocalPath)
            ? ResourceService.Fmt("St_FileNotFound", Winapp3LocalPath)
            : "";
        RefreshFileInfo();
    }

    partial void OnEnableWinappxChanged(bool value)
    {
        if (_refreshing) return;
        AppSettings.Instance.EnableWinappx = value;
        AppSettings.Instance.Save();
        StatusText = value && !File.Exists(WinappxLocalPath)
            ? ResourceService.Fmt("St_FileNotFound", WinappxLocalPath)
            : "";
        RefreshFileInfo();
    }

    // --- Post-clean tasks -----------------------------------------------------

    // Auto-saves whenever the user edits the text box
    partial void OnPostCleanEnabledChanged(bool value)
    {
        if (_refreshing) return;
        AppSettings.Instance.PostCleanEnabled = value;
        AppSettings.Instance.Save();
    }

    partial void OnPostCleanCommandsChanged(string value)
    {
        if (_refreshing) return;
        AppSettings.Instance.PostCleanCommands = value;
        AppSettings.Instance.Save();
    }

    partial void OnCleanHistoryEnabledChanged(bool value)
    {
        if (_refreshing) return;
        AppSettings.Instance.CleanHistoryEnabled = value;
        AppSettings.Instance.Save();
    }

    // --- Global exclusions -------------------------------------------------------

    partial void OnGlobalExclusionsEnabledChanged(bool value)
    {
        if (_refreshing) return;
        AppSettings.Instance.GlobalExclusionsEnabled = value;
        AppSettings.Instance.Save();
    }

    partial void OnGlobalExclusionsTextChanged(string value)
    {
        if (_refreshing) return;
        AppSettings.Instance.GlobalExclusions = value
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(l => l.Contains('|') ? l : $"PATH|{l}")    // bare paths become PATH exclusions
            .ToList();
        AppSettings.Instance.Save();
    }

    // --- Junk Growth Tracker / Clean History -------------------------------------------------------------

    [RelayCommand]
    private void ClearHistory()
    {
        AppSettings.Instance.CleanHistory.Clear();
        AppSettings.Instance.Save();
        BuildHistoryRows();
    }

    private void BuildHistoryRows()
    {
        var history = AppSettings.Instance.CleanHistory;
        HistoryRows.Clear();

        if (history.Count == 0)
        {
            HistorySummary = ResourceService.Get("St_HistoryNone");
            return;
        }

        var totalFreed = history.Sum(e => e.BytesFreed);
        HistorySummary = ResourceService.Fmt("St_HistorySummary", history.Count, ScanResult.FormatBytes(totalFreed));

        var maxBytes  = history.Max(e => e.BytesFreed);
        const int w   = 20;

        foreach (var e in history.OrderByDescending(e => e.Date))
        {
            var filled = maxBytes > 0 ? (int)(e.BytesFreed * w / (double)maxBytes) : 0;
            HistoryRows.Add(new HistoryRow(
                Date:   e.Date.ToString("dd.MM.yyyy  HH:mm"),
                Amount: ScanResult.FormatBytes(e.BytesFreed),
                Bar:    new string('█', filled) + new string('░', w - filled),
                Items:  ResourceService.Fmt("St_HistoryItems", e.ItemsRemoved)
            ));
        }
    }

    // --- Refresh --------------------------------------------------------------

    public void Refresh()
    {
        AppSettings.Reload();
        var s = AppSettings.Instance;

        _refreshing = true;

        EnableWinapp2       = s.EnableWinapp2;
        EnableWinapp3       = s.EnableWinapp3;
        EnableWinappx       = s.EnableWinappx;
        CustomPath          = s.CustomWinapp2Path ?? "";
        IsCustomSource      = !string.IsNullOrWhiteSpace(s.CustomWinapp2Path);
        PostCleanEnabled         = s.PostCleanEnabled;
        PostCleanCommands        = s.PostCleanCommands;
        GlobalExclusionsEnabled  = s.GlobalExclusionsEnabled;
        GlobalExclusionsText     = string.Join("\n", s.GlobalExclusions);
        CleanHistoryEnabled      = s.CleanHistoryEnabled;
        IsPortable          = AppSettings.IsPortable;
        ThemeIndex          = s.Theme    switch { "Light" => 1, "Dark"  => 2,    _ => 0 };
        BuildLanguageList();

        _refreshing = false;
        BuildHistoryRows();
        RefreshFileInfo();
    }

    // --- Custom database path -------------------------------------------------

    [RelayCommand]
    private void ApplyCustomPath()
    {
        var path = CustomPath.Trim();
        if (string.IsNullOrEmpty(path))
        {
            AppSettings.Instance.CustomWinapp2Path = null;
            AppSettings.Instance.Save();
            IsCustomSource = false;
            StatusText = "";
            return;
        }
        if (!File.Exists(path)) { StatusText = ResourceService.Fmt("St_FileNotFound", path); return; }

        AppSettings.Instance.CustomWinapp2Path = path;
        AppSettings.Instance.Save();
        IsCustomSource = true;
        StatusText = ResourceService.Get("St_CustomPathSaved");
        RefreshFileInfo();
    }

    [RelayCommand]
    private void RemoveCustomPath()
    {
        CustomPath = "";
        AppSettings.Instance.CustomWinapp2Path = null;
        AppSettings.Instance.Save();
        IsCustomSource = false;
        StatusText = "";
        RefreshFileInfo();
    }

    // --- File info helpers ----------------------------------------------------

    private void RefreshFileInfo()
    {
        Winapp2Info = BuildFileInfo(Winapp2LocalPath);
        Winapp3Info = BuildFileInfo(Winapp3LocalPath);
        WinappxInfo = BuildFileInfo(WinappxLocalPath);
    }

    private static string BuildFileInfo(string path)
    {
        try
        {
            if (!File.Exists(path)) return ResourceService.Fmt("St_FileNotFound", Path.GetFileName(path));
            var fi    = new FileInfo(path);
            var lines = File.ReadLines(path).Count(l => l.StartsWith('[') && !l.StartsWith("[Winapp2"));
            return ResourceService.Fmt("St_FileInfo", lines, fi.Length / 1024, fi.LastWriteTime.ToString("yyyy-MM-dd"));
        }
        catch { return ""; }
    }
}
