param(
  [Parameter(Mandatory)][int]$TargetPid,
  [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class ViewerProofWin32 {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }

    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll")] public static extern IntPtr GetThreadDesktop(uint threadId);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder data, int bytes, out int needed);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hwnd, ref Point point);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, uint attr, out uint value, uint bytes);

    public static string Name(IntPtr handle) {
        var name = new StringBuilder(256);
        return handle != IntPtr.Zero && GetUserObjectInformation(handle, 2, name, 512, out _)
            ? name.ToString() : "unavailable";
    }
}
'@

function Not-Visible([string]$Reason) {
  Write-Output "WEBVIEW2_PROOF_PIXELS_INCONCLUSIVE: $Reason"
  exit 20
}

$process = Get-Process -Id $TargetPid
$self = Get-Process -Id $PID
$station = [ViewerProofWin32]::Name([ViewerProofWin32]::GetProcessWindowStation())
$threadDesktop = [ViewerProofWin32]::Name([ViewerProofWin32]::GetThreadDesktop([ViewerProofWin32]::GetCurrentThreadId()))
$inputDesktopHandle = [ViewerProofWin32]::OpenInputDesktop(0, $false, 1)
try { $inputDesktop = [ViewerProofWin32]::Name($inputDesktopHandle) }
finally { if ($inputDesktopHandle -ne [IntPtr]::Zero) { [void][ViewerProofWin32]::CloseDesktop($inputDesktopHandle) } }
Write-Output "WebView2 proof desktop: targetSession=$($process.SessionId) captureSession=$($self.SessionId) station=$station desktop=$threadDesktop input=$inputDesktop"
if ($process.SessionId -eq 0 -or $process.SessionId -ne $self.SessionId -or
    $station -ne 'WinSta0' -or $threadDesktop -ne 'Default' -or $inputDesktop -ne 'Default') {
  Not-Visible 'No shared interactive input desktop.'
}

$hwnd = $process.MainWindowHandle
$foreground = [ViewerProofWin32]::GetAncestor([ViewerProofWin32]::GetForegroundWindow(), 2)
$cloaked = [uint32]0
if ($hwnd -eq [IntPtr]::Zero -or $foreground -ne $hwnd -or
    -not [ViewerProofWin32]::IsWindowVisible($hwnd) -or [ViewerProofWin32]::IsIconic($hwnd) -or
    [ViewerProofWin32]::DwmGetWindowAttribute($hwnd, 14, [ref]$cloaked, 4) -ne 0 -or $cloaked -ne 0) {
  Not-Visible 'Fixture window is not visible in the foreground.'
}

Add-Type -AssemblyName System.Drawing
$dpi = [ViewerProofWin32]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
if ($dpi -eq [IntPtr]::Zero) { Not-Visible 'Could not verify physical-pixel window coordinates.' }
try {
  $rect = [ViewerProofWin32+Rect]::new()
  $corner = [ViewerProofWin32+Point]::new()
  if (-not [ViewerProofWin32]::GetClientRect($hwnd, [ref]$rect) -or
      -not [ViewerProofWin32]::ClientToScreen($hwnd, [ref]$corner)) {
    Not-Visible 'Could not locate the fixture client window.'
  }
  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  if ($width -lt 100 -or $height -lt 150) { Not-Visible 'Fixture client window is too small.' }
  $bitmap = [System.Drawing.Bitmap]::new($width, $height)
  try {
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
      $deadline = [Diagnostics.Stopwatch]::StartNew()
      do {
        if ([ViewerProofWin32]::GetAncestor([ViewerProofWin32]::GetForegroundWindow(), 2) -ne $hwnd) {
          Not-Visible 'Fixture lost the foreground before capture.'
        }
        $graphics.CopyFromScreen($corner.X, $corner.Y, 0, 0, $bitmap.Size)
        $markerPixels = 0
        foreach ($fraction in @(0.4, 0.5, 0.6)) {
          $pixel = $bitmap.GetPixel([int]($width * $fraction), [int]($height * 0.65))
          if ([Math]::Abs([int]$pixel.R - 55) -le 3 -and
              [Math]::Abs([int]$pixel.G - 189) -le 3 -and
              [Math]::Abs([int]$pixel.B - 106) -le 3) { $markerPixels++ }
        }
        if ($markerPixels -eq 3) {
          $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
          Write-Output 'WEBVIEW2_PROOF_VISIBLE_PIXELS_OK: 3 composited viewer markers.'
          exit 0
        }
        Start-Sleep -Milliseconds 100
      } while ($deadline.Elapsed.TotalSeconds -lt 4)
      Not-Visible 'The actual desktop capture did not contain the viewer color markers.'
    } finally { $graphics.Dispose() }
  } finally { $bitmap.Dispose() }
} finally { [void][ViewerProofWin32]::SetThreadDpiAwarenessContext($dpi) }
