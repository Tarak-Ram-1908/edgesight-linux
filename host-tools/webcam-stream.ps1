# Stream the laptop webcam (Windows) into the EdgeSight VM as MJPEG over TCP.
# Requires ffmpeg for Windows (winget install Gyan.FFmpeg) and a running VM (run-qemu.cmd).
#
#   powershell -ExecutionPolicy Bypass -File host-tools\webcam-stream.ps1
#   powershell -ExecutionPolicy Bypass -File host-tools\webcam-stream.ps1 -Camera "HP 5MP Camera" -Fps 15
#
# Close the Windows Camera app first: only one program can own the webcam at a time.
param(
    [string]$Camera = "",
    [int]$Fps = 15,
    [int]$Width = 640,
    [string]$Target = "tcp://127.0.0.1:5000"
)
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Error "ffmpeg not found - install with: winget install Gyan.FFmpeg (then open a new terminal)"; exit 1
}

# Is the VM's camera ingest reachable? (QEMU forwards host:5000 -> guest:5000)
$probe = New-Object System.Net.Sockets.TcpClient
try { $probe.Connect("127.0.0.1", 5000); $probe.Close() }
catch { Write-Error "Nothing is listening on 127.0.0.1:5000 - start the device first (run-qemu.cmd prod)"; exit 1 }

if ($Camera -eq "") {
    $list = & ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 | Out-String
    $m = [regex]::Match($list, '"([^"]+)" \(video\)')
    if (-not $m.Success) { Write-Error "No DirectShow camera found:`n$list"; exit 1 }
    $Camera = $m.Groups[1].Value
}
Write-Host "Streaming '$Camera' at $Fps fps, ${Width}px wide -> $Target"
Write-Host "Dashboard: http://localhost:8080   (Ctrl-C to stop; the device falls back to its sample loop)"
# No forced capture size (cameras support different modes); scale in software instead.
& ffmpeg -hide_banner -loglevel error -f dshow -rtbufsize 64M -i "video=$Camera" `
    -vf "fps=$Fps,scale=${Width}:-2" -q:v 5 -f mjpeg $Target
if ($LASTEXITCODE -ne 0) {
    Write-Host "ffmpeg exited with code $LASTEXITCODE. If the camera is busy, close the Camera app / Teams / browser tabs using it."
}
