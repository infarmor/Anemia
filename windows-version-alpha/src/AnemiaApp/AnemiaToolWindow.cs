using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;

namespace AnemiaApp;

/// <summary>App chrome for auxiliary windows. These windows close normally;
/// the dashboard is the only window that hides in the tray.</summary>
public class AnemiaToolWindow : Window
{
    public static readonly RoutedUICommand ToggleMaximizeCommand =
        new("Развернуть или восстановить окно", nameof(ToggleMaximizeCommand), typeof(AnemiaToolWindow));

    public static readonly DependencyProperty ShowCaptionTitleProperty = DependencyProperty.Register(
        nameof(ShowCaptionTitle), typeof(bool), typeof(AnemiaToolWindow), new PropertyMetadata(false));

    public bool ShowCaptionTitle
    {
        get => (bool)GetValue(ShowCaptionTitleProperty);
        set => SetValue(ShowCaptionTitleProperty, value);
    }

    public AnemiaToolWindow()
    {
        SetResourceReference(StyleProperty, "AnemiaToolWindow");
        CommandBindings.Add(new CommandBinding(SystemCommands.CloseWindowCommand,
            (_, _) => SystemCommands.CloseWindow(this)));
        CommandBindings.Add(new CommandBinding(SystemCommands.MinimizeWindowCommand,
            (_, _) => SystemCommands.MinimizeWindow(this),
            (_, args) => args.CanExecute = ResizeMode != ResizeMode.NoResize));
        CommandBindings.Add(new CommandBinding(ToggleMaximizeCommand, (_, _) =>
        {
            if (WindowState == WindowState.Maximized) SystemCommands.RestoreWindow(this);
            else SystemCommands.MaximizeWindow(this);
        }, (_, args) => args.CanExecute = ResizeMode is ResizeMode.CanResize or ResizeMode.CanResizeWithGrip));
    }

    protected override void OnSourceInitialized(EventArgs args)
    {
        base.OnSourceInitialized(args);
        if (SizeToContent is not (SizeToContent.Height or SizeToContent.WidthAndHeight)) return;

        var target = Owner ?? this;
        var handle = new WindowInteropHelper(target).Handle;
        var workArea = System.Windows.Forms.Screen.FromHandle(handle).WorkingArea;
        var workHeight = workArea.Height / VisualTreeHelper.GetDpi(target).DpiScaleY;
        // Results and QR codes can grow after the dialog has opened. Leave
        // room inside the monitor's work area and let the body scroll.
        MaxHeight = Math.Min(MaxHeight, Math.Max(MinHeight, workHeight - 40));
    }
}
