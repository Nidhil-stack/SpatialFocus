; SpatialFocus: tieni premuto un tasto con la sinistra, premi un tasto della mano
; destra e il focus salta sulla finestra che si trova in quella zona dello schermo.
; I monitor sono trattati come un unico rettangolo mappato sulla griglia di tasti.

#Requires AutoHotkey v2.0
#SingleInstance Force
;@Ahk2Exe-SetName SpatialFocus
;@Ahk2Exe-SetDescription SpatialFocus
;@Ahk2Exe-SetVersion 1.0.0
;@Ahk2Exe-SetCompanyName Nidhil-stack
;@Ahk2Exe-SetCopyright Copyright 2026 Nick (Nidhil-stack)
Persistent

; DPI per-monitor v2: coordinate fisiche coerenti su monitor con scale diverse
try DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")

global APP := "SpatialFocus"
; l'exe di winget sta in una cartella che viene sostituita a ogni aggiornamento
global INI := A_IsCompiled ? A_AppData "\" APP "\" APP ".ini" : A_ScriptDir "\" APP ".ini"
global STARTUP_LNK := A_Startup "\" APP ".lnk"
global MY_PID := ProcessExist()
global Cfg := LoadConfig()
global Keys := BuildKeys()
global Labels := BuildLabels()
global Assigned := Map()   ; indice tasto -> finestra
global Active := false
global WheelMode := false  ; rotella del volume: false = frecce, true = rotella del mouse

RegisterHotkeys()
RegisterVolumeKnob()
BuildTray()

; ---------------------------------------------------------------- configurazione

LoadConfig() {
    DirCreate(A_IsCompiled ? A_AppData "\" APP : A_ScriptDir)
    if !FileExist(INI)
        WriteDefaultIni()
    c := {}
    c.Trigger := IniRead(INI, "Generale", "Attivazione", "CapsLock")
    c.Mode := IniRead(INI, "Generale", "Modalita", "hold")
    c.MoveMouse := IniRead(INI, "Generale", "SpostaMouse", "0") = "1"
    c.Timeout := Integer(IniRead(INI, "Generale", "TimeoutToggle", "4000"))
    c.Scale := Float(IniRead(INI, "Aspetto", "Scala", "1.0"))
    c.Opacity := Integer(IniRead(INI, "Aspetto", "Opacita", "235"))
    c.Rows := []
    loop {
        line := IniRead(INI, "Griglia", "Riga" A_Index, "")
        if line = ""
            break
        row := []
        for sc in StrSplit(line, " ")
            if Trim(sc) != ""
                row.Push(Trim(sc))
        if row.Length
            c.Rows.Push(row)
    }
    c.VolumeKnob := IniRead(INI, "Volume", "RotellaScorre", "1") = "1"
    c.Exclude := Map()
    c.Exclude.CaseSense := false
    for p in StrSplit(IniRead(INI, "Escludi", "Processi", ""), ",")
        if Trim(p) != ""
            c.Exclude[Trim(p)] := true
    return c
}

WriteDefaultIni() {
    text := "
(
; Impostazioni di SpatialFocus. Dopo una modifica: icona nella tray > Ricarica.

[Generale]
; Tasto (o combinazione) da premere con la mano sinistra, sintassi AutoHotkey.
; Esempi: CapsLock   !Space (Alt+Spazio)   LAlt & Space
Attivazione=CapsLock
; hold = tieni premuto, premi la lettera, rilasci
; toggle = premi una volta, poi la lettera (Esc annulla)
Modalita=hold
; 1 = sposta anche il mouse al centro della finestra scelta
SpostaMouse=0
; Solo per Modalita=toggle: millisecondi prima che l'overlay sparisca da solo
TimeoutToggle=4000

[Aspetto]
Scala=1.0
; 0-255
Opacita=235

[Griglia]
; Una riga per fila della tastiera, dall'alto in basso, tasti da sinistra a destra.
; Si usano gli scan code, cioè la posizione fisica del tasto: funziona con
; qualsiasi layout (sull'italiano SC027 è Ò e SC035 è il trattino).
; Per aggiungere la fila dei numeri: Riga1=SC007 SC008 SC009 SC00A SC00B
; e rinumera le altre.
Riga1=SC015 SC016 SC017 SC018 SC019
Riga2=SC023 SC024 SC025 SC026 SC027
Riga3=SC031 SC032 SC033 SC034 SC035

[Volume]
; 1 = la rotella del volume scorre: frecce su/giù, premendola passa a rotella del mouse.
; Con Shift premuto la rotella torna a fare volume e muto.
RotellaScorre=1

[Escludi]
; Nomi di processo da ignorare, separati da virgola. Es: Rainmeter.exe,Discord.exe
Processi=
)"
    FileAppend(text, INI, "UTF-16")
}

BuildKeys() {
    keys := []
    ; i nomi in AHK non distinguono maiuscole: nRows/nCols, non R/C accanto a r/c
    nRows := Cfg.Rows.Length
    for r, row in Cfg.Rows {
        nCols := row.Length
        for c, sc in row {
            name := GetKeyName(sc)
            keys.Push({sc: sc, cols: nCols, rows: nRows
                , cx: (c - 0.5) / nCols, cy: (r - 0.5) / nRows
                , label: name != "" ? StrUpper(name) : sc})
        }
    }
    return keys
}

; ---------------------------------------------------------------- overlay

BuildLabels() {
    labels := []
    s := Cfg.Scale
    w := Round(190 * s)
    for k in Keys {
        ; NOACTIVATE + TRANSPARENT: non ruba il focus e lascia passare i click
        g := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000020")
        g.MarginX := Round(10 * s), g.MarginY := Round(6 * s)
        g.SetFont("s" Round(24 * s) " bold", "Segoe UI")
        key := g.AddText("w" w " Center", k.label)
        g.SetFont("s" Round(9 * s) " norm", "Segoe UI")
        title := g.AddText("w" w " Center r1", "")
        g.Show("Hide AutoSize")
        WinSetTransparent(Cfg.Opacity, g)
        ; angoli arrotondati su Windows 11
        try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", g.Hwnd, "uint", 33, "int*", 2, "uint", 4)
        g.GetPos(, , &gw, &gh)
        labels.Push({gui: g, key: key, title: title, w: gw, h: gh})
    }
    return labels
}

ShowOverlay() {
    global Active, Assigned
    wins := CollectWindows()
    Assigned := AssignKeys(wins)
    activeHwnd := WinExist("A")
    placed := []
    ; le finestre in primo piano per prime: la loro etichetta resta al centro esatto
    for w in wins {
        if !w.HasOwnProp("ki")
            continue
        L := Labels[w.ki]
        L.title.Text := Shorten(w.title, 34)
        isActive := w.hwnd = activeHwnd
        L.gui.BackColor := isActive ? "2563EB" : "1E1E2E"
        L.key.SetFont("cFFFFFF")
        L.title.SetFont(isActive ? "cDBEAFE" : "cA6ADC8")
        x := Round(w.cx - L.w / 2), y := Round(w.cy - L.h / 2)
        y := FreeY(x, y, L.w, L.h, placed, w.mon)
        placed.Push({l: x, t: y, r: x + L.w, b: y + L.h})
        L.gui.Show("NA x" x " y" y)
    }
    Active := true
}

HideOverlay(*) {
    global Active := false
    SetTimer(HideOverlay, 0)
    for L in Labels
        L.gui.Hide()
}

; Sposta l'etichetta in verticale finché non si sovrappone ad altre già piazzate
FreeY(x, y, w, h, placed, mon) {
    step := h + 6
    loop 15 {
        i := A_Index - 1
        dy := (i = 0) ? 0 : (Mod(i, 2) ? 1 : -1) * Ceil(i / 2) * step
        ty := y + dy
        if ty < mon.t || ty + h > mon.b
            continue
        free := true
        for p in placed
            if x < p.r && x + w > p.l && ty < p.b && ty + h > p.t {
                free := false
                break
            }
        if free
            return ty
    }
    return y
}

Shorten(s, n) => StrLen(s) > n ? SubStr(s, 1, n - 1) "…" : s

; ---------------------------------------------------------------- finestre

Monitors() {
    mons := []
    loop MonitorGetCount() {
        MonitorGet(A_Index, &l, &t, &r, &b)
        mons.Push({l: l, t: t, r: r, b: b})
    }
    return mons
}

CollectWindows() {
    mons := Monitors()
    vb := {l: mons[1].l, t: mons[1].t, r: mons[1].r, b: mons[1].b}
    for m in mons
        vb.l := Min(vb.l, m.l), vb.t := Min(vb.t, m.t), vb.r := Max(vb.r, m.r), vb.b := Max(vb.b, m.b)
    out := []
    for hwnd in WinGetList() {          ; ordine z: prima quella in primo piano
        if !IsSwitchable(hwnd)
            continue
        r := FrameRect(hwnd)
        ; il monitor che contiene la parte più grande della finestra
        best := "", bestArea := 0
        for m in mons {
            a := Max(0, Min(r.r, m.r) - Max(r.l, m.l)) * Max(0, Min(r.b, m.b) - Max(r.t, m.t))
            if a > bestArea
                best := m, bestArea := a
        }
        if !best
            continue
        cx := (Max(r.l, best.l) + Min(r.r, best.r)) / 2
        cy := (Max(r.t, best.t) + Min(r.b, best.b)) / 2
        title := ""
        try title := WinGetTitle(hwnd)
        out.Push({hwnd: hwnd, title: title, mon: best, cx: cx, cy: cy
            , nx: (cx - vb.l) / (vb.r - vb.l), ny: (cy - vb.t) / (vb.b - vb.t)})
        if out.Length >= Keys.Length
            break
    }
    return out
}

IsSwitchable(hwnd) {
    static skipClass := Map("Progman", 1, "WorkerW", 1, "Shell_TrayWnd", 1, "Shell_SecondaryTrayWnd", 1)
    try {
        if WinGetMinMax(hwnd) = -1
            return false
        ex := WinGetExStyle(hwnd)
        appWin := ex & 0x40000                   ; WS_EX_APPWINDOW
        if ex & 0x80                             ; WS_EX_TOOLWINDOW
            return false
        if (ex & 0x08000000) && !appWin          ; WS_EX_NOACTIVATE
            return false
        if DllCall("GetWindow", "ptr", hwnd, "uint", 4, "ptr") && !appWin   ; finestre con owner
            return false
        if WinGetTitle(hwnd) = "" || skipClass.Has(WinGetClass(hwnd))
            return false
    } catch
        return false
    ; per le finestre elevate questi possono fallire: non è un motivo per escluderle
    pid := 0, exe := ""
    try pid := WinGetPID(hwnd)
    try exe := WinGetProcessName(hwnd)
    if pid = MY_PID || Cfg.Exclude.Has(exe)
        return false
    return !IsCloaked(hwnd)
}

; Finestre nascoste da DWM: altri desktop virtuali, app UWP sospese
IsCloaked(hwnd) {
    c := 0
    DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14, "uint*", &c, "uint", 4)
    return c != 0
}

; Rettangolo visibile, senza i bordi invisibili di Windows 10/11
FrameRect(hwnd) {
    rc := Buffer(16, 0)
    if DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 9, "ptr", rc, "uint", 16) = 0
        return {l: NumGet(rc, 0, "int"), t: NumGet(rc, 4, "int"), r: NumGet(rc, 8, "int"), b: NumGet(rc, 12, "int")}
    WinGetPos(&x, &y, &w, &h, hwnd)
    return {l: x, t: y, r: x + w, b: y + h}
}

; Assegna a ogni finestra il tasto libero più vicino. Le coppie (finestra, tasto)
; sono ordinate per distanza in "unità tasto"; a parità vince quella più in alto nello z-order.
AssignKeys(wins) {
    lines := ""
    for wi, w in wins
        for ki, k in Keys {
            dx := (w.nx - k.cx) * k.cols
            dy := (w.ny - k.cy) * k.rows
            lines .= Format("{:.9f}|{}|{}`n", dx * dx + dy * dy + wi * 1e-7, wi, ki)
        }
    result := Map()
    if lines = ""
        return result
    usedW := Map()
    for line in StrSplit(Sort(RTrim(lines, "`n"), "N"), "`n") {
        p := StrSplit(line, "|")
        wi := Integer(p[2]), ki := Integer(p[3])
        if usedW.Has(wi) || result.Has(ki)
            continue
        usedW[wi] := true
        result[ki] := wins[wi]
        wins[wi].ki := ki
        if usedW.Count = wins.Length
            break
    }
    return result
}

FocusWindow(w) {
    try {
        WinActivate(w.hwnd)
        if Cfg.MoveMouse
            DllCall("SetCursorPos", "int", Round(w.cx), "int", Round(w.cy))
    }
}

; ---------------------------------------------------------------- tasti

RegisterHotkeys() {
    HotIf((*) => Active)
    for ki, k in Keys
        Hotkey("*" k.sc, OnGridKey.Bind(ki))
    Hotkey("*Esc", HideOverlay)
    HotIf()
    Hotkey(Cfg.Trigger, Cfg.Mode = "toggle" ? OnToggle : OnHold)
    if Cfg.Trigger = "CapsLock"
        Hotkey("+CapsLock", (*) => SetCapsLockState(!GetKeyState("CapsLock", "T")))
}

OnHold(*) {
    ShowOverlay()
    KeyWait(TriggerKey())
    HideOverlay()
}

OnToggle(*) {
    if Active
        return HideOverlay()
    ShowOverlay()
    SetTimer(HideOverlay, -Cfg.Timeout)
}

OnGridKey(ki, *) {
    if !Assigned.Has(ki)
        return          ; tasto senza finestra: l'overlay resta aperto
    w := Assigned[ki]
    HideOverlay()
    FocusWindow(w)
}

; Il tasto da attendere in modalità hold: "!Space" -> "Space", "LAlt & Tab" -> "Tab"
TriggerKey() {
    t := Cfg.Trigger
    if InStr(t, "&")
        t := Trim(SubStr(t, InStr(t, "&") + 1))
    return RegExReplace(t, "^[\^!+#<>*~$]+")
}

; ---------------------------------------------------------------- rotella del volume

RegisterVolumeKnob() {
    if !Cfg.VolumeKnob
        return
    ; $ = hook: il Send dei tasti volume qui sotto non riattiva questi hotkey
    Hotkey("$Volume_Up", (*) => Send(WheelMode ? "{WheelUp}" : "{Up}"))
    Hotkey("$Volume_Down", (*) => Send(WheelMode ? "{WheelDown}" : "{Down}"))
    Hotkey("$Volume_Mute", ToggleWheelMode)
    Hotkey("$+Volume_Up", (*) => Send("{Volume_Up}"))
    Hotkey("$+Volume_Down", (*) => Send("{Volume_Down}"))
    Hotkey("$+Volume_Mute", (*) => Send("{Volume_Mute}"))
}

ToggleWheelMode(*) {
    global WheelMode := !WheelMode
    ToolTip(WheelMode ? "Rotella: scorrimento come il mouse" : "Rotella: frecce, una riga alla volta")
    SetTimer(() => ToolTip(), -1200)
}

; ---------------------------------------------------------------- tray

BuildTray() {
    A_IconTip := APP " (" Cfg.Trigger " + tasto)"
    tray := A_TrayMenu
    tray.Delete()
    tray.Add("Impostazioni", (*) => Run('notepad.exe "' INI '"'))
    tray.Add("Ricarica", (*) => Reload())
    tray.Add("Avvio con Windows", ToggleStartup)
    if FileExist(STARTUP_LNK)
        tray.Check("Avvio con Windows")
    tray.Add()
    tray.Add("Esci", (*) => ExitApp())
}

ToggleStartup(name, *) {
    if FileExist(STARTUP_LNK) {
        FileDelete(STARTUP_LNK)
        A_TrayMenu.Uncheck(name)
    } else {
        FileCreateShortcut(A_ScriptFullPath, STARTUP_LNK, A_ScriptDir)
        A_TrayMenu.Check(name)
    }
}
