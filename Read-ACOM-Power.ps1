param(
    [Parameter(Mandatory = $true)]
    [string] $OutputFile
    ,
    [Parameter(Mandatory = $true)]
    [int] $Left
    ,
    [Parameter(Mandatory = $true)]
    [int] $Top
    ,
    [Parameter(Mandatory = $false)]
    [int] $WindowLeft = 0
    ,
    [Parameter(Mandatory = $false)]
    [int] $WindowTop = 0
    ,
    [Parameter(Mandatory = $false)]
    [int] $WindowWidth = 0
    ,
    [Parameter(Mandatory = $false)]
    [int] $WindowHeight = 0
    ,
    [switch] $DebugCapture
)

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$width = 305
$height = 23
$ocrLeft = 205
$ocrWidth = 95
$scale = 4
$tempImage = Join-Path $env:TEMP 'acom-power-ocr.png'
$debugImage = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ACOM-power-ocr-debug.png'
$rawDebugImage = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ACOM-power-raw-debug.png'
$ocrDebugImage = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ACOM-power-ocr-input.png'
$fullDebugImage = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ACOM-window-debug.png'

if ($DebugCapture -and $WindowWidth -gt 0 -and $WindowHeight -gt 0) {
    $windowBitmap = New-Object System.Drawing.Bitmap $WindowWidth, $WindowHeight
    $windowGraphics = [System.Drawing.Graphics]::FromImage($windowBitmap)
    $windowGraphics.CopyFromScreen($WindowLeft, $WindowTop, 0, 0, $windowBitmap.Size)
    $windowGraphics.Dispose()
    $windowBitmap.Save($fullDebugImage, [System.Drawing.Imaging.ImageFormat]::Png)
    $windowBitmap.Dispose()
}

$source = New-Object System.Drawing.Bitmap $width, $height
$graphics = [System.Drawing.Graphics]::FromImage($source)

if ($DebugCapture -and $WindowWidth -gt 0 -and $WindowHeight -gt 0) {
    $windowBitmap = [System.Drawing.Bitmap]::FromFile($fullDebugImage)
    $destination = [System.Drawing.Rectangle]::new(0, 0, $width, $height)
    $windowSource = [System.Drawing.Rectangle]::new(12, 318, $width, $height)
    $graphics.DrawImage($windowBitmap, $destination, $windowSource, [System.Drawing.GraphicsUnit]::Pixel)
    $windowBitmap.Dispose()
} else {
    $graphics.CopyFromScreen($left, $top, 0, 0, $source.Size)
}

$graphics.Dispose()

if ($DebugCapture) {
    $source.Save($rawDebugImage, [System.Drawing.Imaging.ImageFormat]::Png)
}

$processed = New-Object System.Drawing.Bitmap $width, $height
for ($x = 0; $x -lt $width; $x++) {
    for ($y = 0; $y -lt $height; $y++) {
        $pixel = $source.GetPixel($x, $y)
        $brightness = (0.299 * $pixel.R) + (0.587 * $pixel.G) + (0.114 * $pixel.B)
        $processed.SetPixel($x, $y, $(if ($brightness -gt 75) { [Drawing.Color]::White } else { [Drawing.Color]::Black }))
    }
}
$source.Dispose()
if ($DebugCapture) {
    $processed.Save($debugImage, [System.Drawing.Imaging.ImageFormat]::Png)
}

$ocrSource = New-Object System.Drawing.Bitmap $ocrWidth, $height
$ocrGraphics = [System.Drawing.Graphics]::FromImage($ocrSource)
$ocrGraphics.DrawImage($processed, [System.Drawing.Rectangle]::new(0, 0, $ocrWidth, $height), [System.Drawing.Rectangle]::new($ocrLeft, 0, $ocrWidth, $height), [System.Drawing.GraphicsUnit]::Pixel)
$ocrGraphics.Dispose()

$scaled = New-Object System.Drawing.Bitmap ($ocrWidth * $scale), ($height * $scale)
$scaledGraphics = [System.Drawing.Graphics]::FromImage($scaled)
$scaledGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$scaledGraphics.DrawImage($ocrSource, 0, 0, $scaled.Width, $scaled.Height)
$scaledGraphics.Dispose()
$ocrSource.Dispose()
$processed.Dispose()
$scaled.Save($tempImage, [System.Drawing.Imaging.ImageFormat]::Png)
if ($DebugCapture) {
    $scaled.Save($ocrDebugImage, [System.Drawing.Imaging.ImageFormat]::Png)
}
$scaled.Dispose()

$tesseract = 'C:\Program Files\Tesseract-OCR\tesseract.exe'
$text = & $tesseract $tempImage stdout --psm 7 -c tessedit_char_whitelist=0123456789 2>$null
$text = ($text -join ' ').Trim()
if ($text -eq '') {
    $text = (& $tesseract $tempImage stdout --psm 8 2>$null) -join ' '
}
$normalized = ($text -join ' ') -replace '[Oo]', '0'
$digits = ($normalized -replace '\D', '').Trim()

$traceFile = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ACOM-ocr-trace.txt'
if ($DebugCapture) {
    Set-Content -LiteralPath $traceFile -Value @(
        "Tesseract: [$($text -join ' ')]"
        "Normalized: [$normalized]"
        "Digits: [$digits]"
    ) -Encoding utf8
}

$temporaryOutput = "$OutputFile.tmp"
Set-Content -LiteralPath $temporaryOutput -Value $digits -Encoding ascii
Move-Item -LiteralPath $temporaryOutput -Destination $OutputFile -Force
Remove-Item -LiteralPath $tempImage -Force -ErrorAction SilentlyContinue
