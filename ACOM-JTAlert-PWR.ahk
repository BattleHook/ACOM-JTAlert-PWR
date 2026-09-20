#Requires AutoHotkey v2.0
#SingleInstance Force

DEBUG := false
; Script version (updated by update-version.ps1). Default placeholder.
SCRIPT_VERSION := "efc2b50-dirty"
SetTimer(CheckLogWindow, 1000)

if DEBUG
    try FileAppend("AHK loaded: " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n", EnvGet("USERPROFILE") "\\Desktop\\ACOM-ocr-trace.txt", "UTF-8")

#HotIf DEBUG
^!p::ShowPowerDiagnostic()
^!t::TestTxPowerEntry()
^!d::DumpAcomControls()
#HotIf

; Manual toggle to pause/resume polling (prevents script activity while working)
^!Pause::ToggleManualPause()

global LastPower := ""
global LastRawPower := ""
global LastLogWindow := 0
global PowerSamples := []
global OcrBusy := false
global OcrManual := false
global OcrKeepForeground := false
global OcrPreviousWindow := 0
global OcrPid := 0
global OcrStartedAt := 0
global LastJTAlertPower := ""
global LastOutputPower := ""
global FiveSecondSamples := []
global FiveSecondAverages := []
global FiveSecondStart := 0
global TxSessionSamples := []
global LastValidPowerTime := 0
global LastSessionEndTime := 0
global MinimumTransmitPower := 10

; Pause flag to avoid erratic mouse/activation when windows are missing
global PausedDueToMissingWindows := false
global ManualPaused := false

CheckLogWindow() {
    global PausedDueToMissingWindows
    global LastPower, LastRawPower, LastLogWindow, PowerSamples, OcrBusy, LastJTAlertPower
    global LastOutputPower, FiveSecondAverages, TxSessionSamples, LastValidPowerTime, LastSessionEndTime
    global MinimumTransmitPower

    acomExe := "ahk_exe ACOM Director Plus.exe"
    jtAlertExe := "ahk_exe JTAlertV2.exe"

    ; If either required window is missing, pause the main polling to avoid clicks or activation.
    if (!WinExist(acomExe) || !WinExist(jtAlertExe)) {
        PausePolling()
        return
    }

    ; If previously paused and both windows now exist, resume polling
    if (PausedDueToMissingWindows) {
        ResumePolling()
    }

    logWindow := "ahk_exe wsjtx.exe"
    logTitle := "Log QSO"
    txPowerX := 132
    txPowerY := 138

    logIsActive := WinActive(logWindow, logTitle)
    actualPower := ""
    ; Once Log QSO is open it may cover ACOM, so only finish an OCR already running.
    if (!logIsActive || OcrBusy)
        ; Normal polling must not activate ACOM or interrupt keyboard input.
        actualPower := ReadAcomPower()
    now := A_TickCount
    cutoff := now - 5000

    while (PowerSamples.Length && PowerSamples[1].time < cutoff)
        PowerSamples.RemoveAt(1)

    cleanPower := RegExReplace(actualPower, "\D")
    if (cleanPower != "") {
        LastRawPower := actualPower
        LastPower := cleanPower
        numericPower := ParsePowerDigits(cleanPower)
        PowerSamples.Push({time: now, value: numericPower})
        ; Ignore residual power and OCR results with a dropped leading digit.
        ; These values must not start or extend a transmit session.
        if (numericPower >= MinimumTransmitPower && numericPower <= 700 && (!LastSessionEndTime || now - LastSessionEndTime >= 5000)) {
            TxSessionSamples.Push(numericPower)
            AddTransmitReading(now, numericPower)
            LastValidPowerTime := now
        }
    }

    ; Do not end a session while its next OCR result is still pending. The extra
    ; margin also prevents a single slow or empty OCR cycle from splitting TX.
    if (TxSessionSamples.Length && LastValidPowerTime && !OcrBusy && now - LastValidPowerTime >= 3500) {
        FinalizeTransmitSession()
        LastValidPowerTime := 0
        LastSessionEndTime := now
    }

    if !logIsActive
        LastLogWindow := 0
}

HidePowerTip() {
    ToolTip(,,, 1)
}

ShowPowerDiagnostic() {
    traceFile := EnvGet("USERPROFILE") "\\Desktop\\ACOM-ocr-trace.txt"
    DebugTrace("Manual OCR requested: " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n", traceFile)
    ReadAcomPower(true, true)
    AcomToolTip("ACOM OCR running...", 2)
    SetTimer(HidePowerDiagnostic, -5000)
}

TestTxPowerEntry() {
    ; Test: write 50 W to JTAlert only (do not touch WSJT-X)
    jtAlertWindow := "ahk_exe JTAlertV2.exe"
    if !WinExist(jtAlertWindow) {
        ToolTip("JTAlert not running. Cannot perform test.", 10, 10, 2)
        SetTimer(HidePowerDiagnostic, -3000)
        return
    }
    if (WritePowerToJTAlert(50)) {
        ToolTip("Test value 50 W written to JTAlert.", 10, 10, 2)
    } else {
        ToolTip("Failed to write test value to JTAlert.", 10, 10, 2)
    }
    SetTimer(HidePowerDiagnostic, -3000)
}

HidePowerDiagnostic() {
    ToolTip(,,, 2)
}

AcomToolTip(text, id := 2) {
    acomWindow := "ahk_exe ACOM Director Plus.exe"
    if WinExist(acomWindow) {
        WinGetPos(&x, &y, &width, &height, acomWindow)
        ToolTip(text, x + 10, y + 10, id)
    } else {
        ToolTip(text, 10, 10, id)
    }
}

ReadAcomPower(bringToFront := false, keepForeground := false) {
    global OcrBusy, OcrManual, OcrKeepForeground, OcrPreviousWindow, OcrPid, OcrStartedAt
    acomWindow := "ahk_exe ACOM Director Plus.exe"
    outputFile := A_Temp "\\acom-power-ocr.txt"
    traceFile := EnvGet("USERPROFILE") "\\Desktop\\ACOM-ocr-trace.txt"

    if OcrBusy {
        if (OcrPid && ProcessExist(OcrPid) && !FileExist(outputFile)) {
            if (A_TickCount - OcrStartedAt < 30000)
                return ""
            ProcessClose(OcrPid)
            OcrBusy := false
            OcrPid := 0
            DebugTrace("OCR watchdog timeout`n", traceFile)
            return ""
        }

        if !FileExist(outputFile) {
            OcrBusy := false
            OcrPid := 0
            return ""
        }

        try {
            result := RegExReplace(FileRead(outputFile), "\s", "")
            FileDelete(outputFile)
        } catch {
            return ""
        }

        if !RegExMatch(result, "^\d{1,3}$") {
            DebugTrace("OCR rejected out-of-range value: [" result "]`n", traceFile)
            result := ""
        } else {
            numericResult := ParsePowerDigits(result)
            if (numericResult > 700) {
                DebugTrace("OCR rejected out-of-range value: [" result "]`n", traceFile)
                result := ""
            }
        }

        OcrBusy := false
        OcrPid := 0
        DebugTrace("OCR completed: [" result "]`n", traceFile)
        if OcrManual {
            AcomToolTip("ACOM OCR: " (result != "" ? result : "(empty)"), 2)
            SetTimer(HidePowerDiagnostic, -5000)
            DebugTrace("OCR returned: [" result "]`n", traceFile)
        }
        OcrManual := false
        return result
    }

    acomWindows := WinGetList(acomWindow)
    if !acomWindows.Length {
        DebugTrace("ACOM window not found`n", traceFile)
        if bringToFront
            ToolTip("ACOM Director Plus window not found.", 10, 10, 2)
        return ""
    }

    target := "ahk_id " acomWindows[1]
    previousWindow := WinExist()

    OcrManual := bringToFront
    OcrKeepForeground := keepForeground
    OcrPreviousWindow := previousWindow

    try {
        if FileExist(outputFile)
            FileDelete(outputFile)

        WinGetPos(&windowX, &windowY, &windowWidth, &windowHeight, target)

        if bringToFront {
            WinRestore(target)
            WinActivate(target)
            if !WinWaitActive(target,, 2)
                throw Error("Could not activate ACOM Director Plus")
            Sleep(150)
            ; Do not move the mouse. Short delay to allow activation to settle.
            Sleep(250)
            AcomToolTip("ACOM active.`nWindow: " windowX ", " windowY "`nCapture: " (windowX + 12) ", " (windowY + 318), 2)
        }

        debugFlag := bringToFront ? " -DebugCapture" : ""
        command := 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' A_ScriptDir '\\Read-ACOM-Power.ps1" -OutputFile "' outputFile '" -Left ' (windowX + 12) ' -Top ' (windowY + 318) ' -WindowLeft ' windowX ' -WindowTop ' windowY ' -WindowWidth ' windowWidth ' -WindowHeight ' windowHeight debugFlag
        if bringToFront
            DebugTrace("Running OCR helper:`n" command "`n", traceFile)

        DebugTrace("Starting OCR process`n", traceFile)
        Run(command,, "Hide", &ocrPid)
        OcrPid := ocrPid
        OcrStartedAt := A_TickCount
        OcrBusy := true
        return ""
    } catch as error {
        DebugTrace("OCR error: " error.Message "`n", traceFile)
        OcrBusy := false
        OcrPid := 0
        return ""
    } finally {
        ; Completion is handled on a later timer tick after the output file exists.
    }
}

DebugTrace(message, traceFile) {
    global DEBUG
    if DEBUG
        FileAppend(message, traceFile, "UTF-8")
}

ParsePowerDigits(text) {
    value := 0
    length := StrLen(text)
    for index, character in StrSplit(text)
        value := value * 10 + (Ord(character) - 48)
    return value
}

AddTransmitReading(now, value) {
    global FiveSecondSamples, FiveSecondAverages, FiveSecondStart
    if !FiveSecondStart
        FiveSecondStart := now

    FiveSecondSamples.Push(value)
    if (now - FiveSecondStart >= 5000) {
        FiveSecondAverages.Push({time: now, value: AverageNumbers(FiveSecondSamples)})
        while (FiveSecondAverages.Length > 12)
            FiveSecondAverages.RemoveAt(1)
        FiveSecondSamples := []
        FiveSecondStart := now
    }
    if FiveSecondSamples.Length
        return AverageNumbers(FiveSecondSamples)
    if FiveSecondAverages.Length
        return FiveSecondAverages[FiveSecondAverages.Length].value
    return 0
}

AveragePowerSamples(samples) {
    if !samples.Length
        return 0
    total := 0
    for sample in samples
        total += sample.value
    return Round(total / samples.Length)
}

RollingPowerAverage(fiveSecondAverage) {
    global FiveSecondAverages
    values := []
    for bucket in FiveSecondAverages
        values.Push(bucket.value)
    if (fiveSecondAverage > 0)
        values.Push(fiveSecondAverage)
    return AverageNumbers(values)
}

CurrentTransmitAverages() {
    global FiveSecondSamples, FiveSecondAverages

    fiveSecondValues := []
    for bucket in FiveSecondAverages
        fiveSecondValues.Push(bucket.value)

    currentFiveSecondAverage := FiveSecondSamples.Length ? AverageNumbers(FiveSecondSamples) : 0
    if (currentFiveSecondAverage > 0)
        fiveSecondValues.Push(currentFiveSecondAverage)

    while (fiveSecondValues.Length > 12)
        fiveSecondValues.RemoveAt(1)

    fifteenSecondValues := []
    group := []
    for value in fiveSecondValues {
        group.Push(value)
        if (group.Length = 3) {
            fifteenSecondValues.Push(AverageNumbers(group))
            group := []
        }
    }
    if group.Length
        fifteenSecondValues.Push(AverageNumbers(group))

    while (fifteenSecondValues.Length > 4)
        fifteenSecondValues.RemoveAt(1)

    return {
        fiveSecond: currentFiveSecondAverage,
        fifteenSecond: fifteenSecondValues.Length ? fifteenSecondValues[fifteenSecondValues.Length] : 0,
        final: AverageNumbers(fifteenSecondValues),
        fiveSecondBuckets: fiveSecondValues.Length,
        fifteenSecondBuckets: fifteenSecondValues.Length
    }
}

AverageNumbers(values) {
    if !values.Length
        return 0
    total := 0
    for value in values
        total += value
    return Round(total / values.Length)
}

FinalizeTransmitSession() {
    global TxSessionSamples, LastJTAlertPower, FiveSecondSamples, FiveSecondAverages, FiveSecondStart

    averages := CurrentTransmitAverages()
    ; Weight every accepted OCR reading equally. Averaging partially filled
    ; time buckets equally can pull the result down near the end of a TX.
    sessionPower := AverageNumbers(TxSessionSamples)
    if (sessionPower > 0 && sessionPower <= 700 && sessionPower != LastJTAlertPower && WritePowerToJTAlert(sessionPower)) {
        LastJTAlertPower := sessionPower
        AcomToolTip("Transmission ended.`n5-second average: " averages.fiveSecond " W`n15-second average: " averages.fifteenSecond " W`nJTAlert value: " sessionPower " W`nSamples: " TxSessionSamples.Length, 1)
        SetTimer(HidePowerTip, -2500)
    }
    TxSessionSamples := []
    FiveSecondSamples := []
    FiveSecondAverages := []
    FiveSecondStart := 0
}

WritePowerToJTAlert(power) {
    jtAlertWindow := "ahk_exe JTAlertV2.exe"
    if !WinExist(jtAlertWindow)
        return false

    try {
        ControlSetText(power, "Edit18", jtAlertWindow)
        return true
    } catch {
        return false
    }
}

DumpAcomControls() {
    acomWindow := "ahk_exe ACOM Director Plus.exe"
    outputFile := A_Desktop "\\ACOM-control-values.txt"
    lines := "ACOM Director Plus control values`r`n"
    lines .= "Generated: " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`r`n`r`n"

    try {
        controls := WinGetControls(acomWindow)
        for control in controls {
            try {
                value := ControlGetText(control, acomWindow)
            } catch {
                value := "<unreadable>"
            }
            lines .= control " = " (value != "" ? value : "<empty>") "`r`n"
        }
        if FileExist(outputFile)
            FileDelete(outputFile)
        FileAppend(lines, outputFile, "UTF-8")
        AcomToolTip("ACOM control scan saved to:`n" outputFile, 2)
    } catch as error {
        AcomToolTip("Could not save ACOM control scan:`n" error.Message, 2)
    }
    SetTimer(HidePowerDiagnostic, -5000)
}

; --- Pause / Resume helpers and watcher ---

PausePolling(manual := false) {
    global PausedDueToMissingWindows, ManualPaused
    if (PausedDueToMissingWindows)
        return

    PausedDueToMissingWindows := true
    if (manual)
        ManualPaused := true
    SetTimer(CheckLogWindow, 0)     ; stop active polling (0 disables the timer)
    SetTimer(CheckForWindows, 2000)     ; lightweight watcher every 2s
    ToolTip("ACOM or JTAlert missing â€” polling paused", 10, 10, 1)
    SetTimer(HidePowerTip, -3000)
}

ResumePolling(force := false) {
    global PausedDueToMissingWindows, ManualPaused
    if (!PausedDueToMissingWindows)
        return
    if (ManualPaused && !force)
        return

    PausedDueToMissingWindows := false
    ManualPaused := false
    SetTimer(CheckForWindows, 0)
    SetTimer(CheckLogWindow, 1000)      ; restore original polling rate
    ToolTip("", , , 1)                  ; clear polling tooltip
}

CheckForWindows() {
    acomExe := "ahk_exe ACOM Director Plus.exe"
    jtAlertExe := "ahk_exe JTAlertV2.exe"
    if (WinExist(acomExe) && WinExist(jtAlertExe)) {
        ; only resume automatically if user hasn't manually paused
        if (!ManualPaused)
            ResumePolling()
    }
}

ToggleManualPause() {
    global PausedDueToMissingWindows, ManualPaused
    if (PausedDueToMissingWindows) {
        ; resume forced by user
        ResumePolling(true)
        ToolTip("Polling resumed (manual)", 10, 10, 1)
        SetTimer(HidePowerTip, -3000)
    } else {
        PausePolling(true)
        ToolTip("Polling paused (manual)", 10, 10, 1)
        SetTimer(HidePowerTip, -3000)
    }
}
