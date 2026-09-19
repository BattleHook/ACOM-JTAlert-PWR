# ACOM-JTAlert-PWR

Fills JTAlert PWR Field with average TX PWR (Needs AutoHotkey and ACOM-Director-Plus).

This AutoHotkey v2 tool reads the Forward Power value shown by ACOM Director Plus using OCR, calculates the average power for a completed transmission session, and writes the result to the JTAlert PWR field.

## Tested configuration

The working test configuration was:

- Windows desktop environment.
- AutoHotkey v2.0. The script requires `#Requires AutoHotkey v2.0`.
- AutoHotkey executable: `C:\Program Files\AutoHotkey\v2\AutoHotkey.exe`.
- Optional compiler: `C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe`.
- ACOM Director Plus, with the process name `ACOM Director Plus.exe`.
- JTAlert V2, with the process name `JTAlertV2.exe`.
- Tesseract OCR 5.4.0.20240606, installed at `C:\Program Files\Tesseract-OCR\tesseract.exe`.
- PowerShell with access to `System.Drawing` and `System.Windows.Forms`.

The ACOM and JTAlert product versions were not hard-coded. The script depends on the executable names, the ACOM window layout, and the JTAlert control name described below. Updates to either application may require retesting the capture area or target control.

## Files

- `TX PWR ACOM to WSJTXLOG.ahk` - main AutoHotkey v2 script.
- `Read-ACOM-Power.ps1` - screenshot capture and Tesseract OCR helper.

Keep both files in the same directory. The AutoHotkey script starts the PowerShell helper from its own directory.

## Installation

1. Install AutoHotkey v2.
2. Install ACOM Director Plus and JTAlert V2.
3. Install Tesseract OCR. The tested installation uses the default path shown above.
4. Copy both project files to one directory.
5. Start ACOM Director Plus and JTAlert V2.
6. Arrange the ACOM Forward Power display so it is visible and readable at least once.
7. Run `TX PWR ACOM to WSJTXLOG.ahk` with AutoHotkey v2.
8. Transmit and confirm that JTAlert's PWR field is updated after the transmission ends.

The script does not use ACOM control text because the tested ACOM controls expose empty text values. It captures the displayed pixels instead.

## How it works

Every second the AutoHotkey timer attempts to start an asynchronous PowerShell OCR job. The helper:

1. Captures a 305 x 23 pixel region from the ACOM window.
2. Uses the window-relative Forward Power position at approximately x=12, y=318.
3. Thresholds the image to black and white.
4. Crops the numeric portion, scales it four times, and runs Tesseract.
5. Uses a numeric whitelist first, then a general fallback if needed.
6. Removes non-digits and writes the result through a temporary file before replacing the result file.

The AHK script validates the result as one to three digits and accepts only values from 0 through 700 W. Non-numeric OCR results and values above 700 W are rejected.

## Average calculation

JTAlert is updated once per completed transmission session, rather than once per OCR reading. A session begins when a valid nonzero reading is received.

- Valid readings are collected while the transmitter is producing power.
- A reading of zero, an empty OCR result, or an invalid result is not added to the session.
- The session ends after 2 seconds without a valid nonzero reading.
- The output is the rounded arithmetic mean of all accepted session readings:

  `average = Round(sum of accepted readings / number of accepted readings)`

- The result must be between 1 and 700 W.
- JTAlert is updated only when the new average differs from the previous value.
- A five-second quiet guard prevents an immediate stale reading from starting a new session.

This avoids repeatedly writing to JTAlert while it is displaying a live transmission value and provides a stable end-of-transmission result.

## JTAlert target

The script writes to:

- Window: `ahk_exe JTAlertV2.exe`
- Control: `Edit18`

If JTAlert changes its control layout or the PWR field is not `Edit18`, the function `WritePowerToJTAlert()` must be updated. The script uses `ControlSetText`, so JTAlert must be running and the target field must accept programmatic text changes.

## WSJT-X support

The script also supports the WSJT-X Log QSO window as a fallback/test path. It uses the client coordinates x=132, y=138 for the TX Power field. The Log QSO test hotkey enters 50 W.

When Log QSO is open it can cover the ACOM window. The script avoids starting a new ACOM capture in that situation, but lets an OCR job that is already running finish. If the WSJT-X layout or display scaling changes, the TX Power coordinates may need adjustment.

## Hotkeys

- `Ctrl+Alt+P` - run a manual ACOM OCR capture and show the result.
- `Ctrl+Alt+T` - enter the test value 50 W into the WSJT-X Log QSO TX Power field.
- `Ctrl+Alt+D` - dump accessible ACOM control values to `Desktop\ACOM-control-values.txt`.

Manual OCR creates diagnostic images on the Desktop:

- `ACOM-window-debug.png`
- `ACOM-power-raw-debug.png`
- `ACOM-power-ocr-debug.png`
- `ACOM-power-ocr-input.png`
- `ACOM-ocr-trace.txt`

Normal polling does not overwrite those debug images unless a manual diagnostic capture is requested.

## Troubleshooting

### JTAlert is not updated

Confirm that JTAlert is running, that its process is `JTAlertV2.exe`, and that the PWR field is still `Edit18`. Use `Ctrl+Alt+D` to confirm that ACOM controls are not exposing usable text; OCR is expected for the tested ACOM version.

### OCR returns an empty or incorrect value

Make sure the Forward Power digits are visible, the ACOM window is not minimized, and Windows display scaling has not changed the tested layout. Use `Ctrl+Alt+P` and inspect the Desktop debug images. Confirm that Tesseract exists at `C:\Program Files\Tesseract-OCR\tesseract.exe`.

### ACOM is covered by another window

The automatic capture is intended to be non-disruptive and does not activate ACOM during normal polling. For manual diagnostics, `Ctrl+Alt+P` activates ACOM and displays the capture position. Close or move overlapping windows while testing.

### The script does not start

Run it with AutoHotkey v2, not AutoHotkey v1. Check that the PowerShell helper is beside the `.ahk` file and that the Desktop trace file records `AHK loaded`.

## Safety and limitations

This tool only reads the displayed ACOM Forward Power value and writes text to JTAlert or the WSJT-X test field. It does not control transmitter power, change radio settings, or initiate a transmission. OCR accuracy depends on the ACOM display, Windows scaling, window position, and application versions.
