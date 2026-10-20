; SpatialFocus: tieni premuto un tasto con la sinistra, premi un tasto della mano
; destra e il focus salta sulla finestra che si trova in quella zona dello schermo.
; I monitor sono trattati come un unico rettangolo mappato sulla griglia di tasti.

#Requires AutoHotkey v2.0
#SingleInstance Force
;@Ahk2Exe-SetName SpatialFocus
;@Ahk2Exe-SetDescription SpatialFocus
;@Ahk2Exe-SetVersion 1.2.0
;@Ahk2Exe-SetCompanyName Nidhil-stack
;@Ahk2Exe-SetCopyright Copyright 2026 Nick (Nidhil-stack)
Persistent

; DPI per-monitor v2: coordinate fisiche coerenti su monitor con scale diverse
try DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")

global APP := "SpatialFocus"
; l'exe di winget sta in una cartella che viene sostituita a ogni aggiornamento
global INI := A_IsCompiled ? A_AppData "\" APP "\" APP ".ini" : A_ScriptDir "\" APP ".ini"
global STARTUP_LNK := A_Startup "\" APP ".lnk"
global MIN_TILE := Map("l", 300, "t", 250)   ; lato minimo di una finestra affiancata
global MY_PID := ProcessExist()
global Cfg := LoadConfig()
global Keys := BuildKeys()
global Labels := BuildLabels()
global Assigned := Map()   ; indice tasto -> finestra
global Active := false
global WheelMode := false  ; rotella del volume: false = frecce, true = rotella del mouse
global LastLayout := []    ; posizioni prima dell'ultimo tiling, per annullarlo

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
    c.OnlyVisible := IniRead(INI, "Generale", "SoloVisibili", "1") = "1"
    c.MinVisible := Integer(IniRead(INI, "Generale", "MinimoVisibile", "80"))
    c.FixedCorners := IniRead(INI, "Generale", "AngoliFissi", "1") = "1"
    c.MultiKeys := IniRead(INI, "Generale", "TastiMultipli", "1") = "1"
    c.TileKey := IniRead(INI, "Tiling", "Tasto", "Space")
    c.UndoKey := IniRead(INI, "Tiling", "Annulla", "SC02C")
    c.TileGap := Integer(IniRead(INI, "Tiling", "Spaziatura", "8"))
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
; 1 = lettere solo sulle finestre che si vedono almeno in parte, non su quelle
; coperte del tutto da altre finestre
SoloVisibili=1
; Lato minimo in pixel della parte visibile perché una finestra conti come visibile
MinimoVisibile=80
; 1 = i quattro tasti agli angoli della griglia vanno alle finestre più vicine agli
; angoli dell'insieme dei monitor
AngoliFissi=1
; 1 = i tasti rimasti liberi vanno alla finestra che si trova in quel punto dello
; schermo, così le finestre grandi hanno più tasti
TastiMultipli=1

[Tiling]
; Con l'overlay aperto (CapsLock tenuto): Tasto affianca le finestre visibili
; mantenendo la loro disposizione, Annulla le rimette dov'erano.
; SC02C è la Z.
Tasto=Space
Annulla=SC02C
; Pixel di spazio tra le finestre e dal bordo dello schermo
Spaziatura=8

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
    ; le finestre in primo piano per prime: la loro etichetta resta al centro esatto;
    ; i tasti in più delle finestre grandi vengono dopo, nel punto del loro tasto
    for w in wins
        if w.HasOwnProp("ki")
            ShowLabel(w.ki, w, w.cx, w.cy, w.hwnd = activeHwnd, placed)
    for w in wins
        if w.HasOwnProp("extra")
            for e in w.extra
                ShowLabel(e.ki, w, e.x, e.y, w.hwnd = activeHwnd, placed)
    Active := true
}

ShowLabel(ki, w, cx, cy, isActive, placed) {
    L := Labels[ki]
    L.title.Text := Shorten(w.title, 34)
    L.gui.BackColor := isActive ? "2563EB" : "1E1E2E"
    L.key.SetFont("cFFFFFF")
    L.title.SetFont(isActive ? "cDBEAFE" : "cA6ADC8")
    x := Round(cx - L.w / 2), y := Round(cy - L.h / 2)
    y := FreeY(x, y, L.w, L.h, placed, w.mon)
    placed.Push({l: x, t: y, r: x + L.w, b: y + L.h})
    L.gui.Show("NA x" x " y" y)
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
        MonitorGetWorkArea(A_Index, &wl, &wt, &wr, &wb)
        mons.Push({l: l, t: t, r: r, b: b, wa: {l: wl, t: wt, r: wr, b: wb}})
    }
    return mons
}

CollectWindows(limit := Keys.Length) {
    mons := Monitors()
    vb := {l: mons[1].l, t: mons[1].t, r: mons[1].r, b: mons[1].b}
    for m in mons
        vb.l := Min(vb.l, m.l), vb.t := Min(vb.t, m.t), vb.r := Max(vb.r, m.r), vb.b := Max(vb.b, m.b)
    out := []
    covered := DllCall("CreateRectRgn", "int", 0, "int", 0, "int", 0, "int", 0, "ptr")
    for hwnd in WinGetList() {          ; ordine z: prima quella in primo piano
        if !IsSwitchable(hwnd)
            continue
        r := FrameRect(hwnd)
        ; il monitor dove si vede il pezzo più grande della finestra, non coperto da
        ; quelle sopra: l'etichetta va al centro di quel pezzo
        best := "", part := "", bestArea := 0
        for m in mons {
            c := {l: Max(r.l, m.l), t: Max(r.t, m.t), r: Min(r.r, m.r), b: Min(r.b, m.b)}
            if c.r <= c.l || c.b <= c.t
                continue
            p := Cfg.OnlyVisible ? VisiblePart(c, covered) : c
            if p && (p.r - p.l) * (p.b - p.t) > bestArea
                best := m, part := p, bestArea := (p.r - p.l) * (p.b - p.t)
        }
        rgn := DllCall("CreateRectRgn", "int", r.l, "int", r.t, "int", r.r, "int", r.b, "ptr")
        DllCall("CombineRgn", "ptr", covered, "ptr", covered, "ptr", rgn, "int", 2)   ; RGN_OR
        DllCall("DeleteObject", "ptr", rgn)
        if !best
            continue
        cx := (part.l + part.r) / 2
        cy := (part.t + part.b) / 2
        title := ""
        try title := WinGetTitle(hwnd)
        out.Push({hwnd: hwnd, title: title, mon: best, cx: cx, cy: cy, rect: r, part: part, vb: vb
            , nx: (cx - vb.l) / (vb.r - vb.l), ny: (cy - vb.t) / (vb.b - vb.t)})
        if out.Length >= limit
            break
    }
    DllCall("DeleteObject", "ptr", covered)
    return out
}

; Il rettangolo visibile più grande di c fuori da covered, oppure "" se ne resta
; troppo poco per essere cliccato o riconosciuto
VisiblePart(c, covered) {
    rgn := DllCall("CreateRectRgn", "int", c.l, "int", c.t, "int", c.r, "int", c.b, "ptr")
    DllCall("CombineRgn", "ptr", rgn, "ptr", rgn, "ptr", covered, "int", 4)   ; RGN_DIFF
    size := DllCall("GetRegionData", "ptr", rgn, "uint", 0, "ptr", 0, "uint")
    best := "", bestArea := Cfg.MinVisible * Cfg.MinVisible
    if size {
        buf := Buffer(size)
        DllCall("GetRegionData", "ptr", rgn, "uint", size, "ptr", buf, "uint")
        loop NumGet(buf, 8, "uint") {               ; RGNDATAHEADER.nCount
            o := 32 + (A_Index - 1) * 16
            q := {l: NumGet(buf, o, "int"), t: NumGet(buf, o + 4, "int"), r: NumGet(buf, o + 8, "int"), b: NumGet(buf, o + 12, "int")}
            a := (q.r - q.l) * (q.b - q.t)
            if a >= bestArea && q.r - q.l >= Cfg.MinVisible && q.b - q.t >= Cfg.MinVisible
                best := q, bestArea := a
        }
    }
    DllCall("DeleteObject", "ptr", rgn)
    return best
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

; Assegna i tasti in tre passi:
; 1. i tasti agli angoli della griglia vanno alla finestra il cui pezzo visibile è più
;    vicino a quell'angolo dell'insieme dei monitor (AngoliFissi)
; 2. ogni finestra prende anche il tasto libero più vicino, al suo centro. Le coppie
;    (finestra, tasto) sono ordinate per distanza in "unità tasto"; a parità vince
;    quella più in alto nello z-order
; 3. i tasti rimasti liberi vanno alla finestra visibile nel punto dello schermo che
;    corrisponde al tasto (TastiMultipli)
; Assigned tiene tasto -> finestra; w.ki è il tasto con l'etichetta al centro della
; finestra, w.extra gli altri con la loro posizione.
AssignKeys(wins) {
    result := Map()
    if !wins.Length
        return result
    vb := wins[1].vb
    for w in wins
        w.extra := []
    if Cfg.FixedCorners {
        last := Keys.Length, lastRow := Cfg.Rows[Cfg.Rows.Length].Length
        corners := Map(1, ["l", "t"], Cfg.Rows[1].Length, ["r", "t"], last - lastRow + 1, ["l", "b"], last, ["r", "b"])
        for ki, cn in corners {
            best := "", bestD := 0
            for w in wins {
                dx := w.part.%cn[1]% - vb.%cn[1]%, dy := w.part.%cn[2]% - vb.%cn[2]%
                if !best || dx * dx + dy * dy < bestD
                    best := w, bestD := dx * dx + dy * dy
            }
            result[ki] := best
            AddKey(best, ki)
        }
    }
    lines := ""
    for wi, w in wins
        for ki, k in Keys {
            if result.Has(ki)
                continue
            dx := (w.nx - k.cx) * k.cols
            dy := (w.ny - k.cy) * k.rows
            lines .= Format("{:.9f}|{}|{}`n", dx * dx + dy * dy + wi * 1e-7, wi, ki)
        }
    if lines != "" {
        for line in StrSplit(Sort(RTrim(lines, "`n"), "N"), "`n") {
            p := StrSplit(line, "|")
            wi := Integer(p[2]), ki := Integer(p[3])
            if wins[wi].HasOwnProp("ki") || result.Has(ki)
                continue
            result[ki] := wins[wi]
            wins[wi].ki := ki
        }
    }
    ; i tasti d'angolo restano etichette agli angoli; solo se per una finestra non è
    ; rimasto nessun tasto libero, il suo primo tasto d'angolo va al centro
    for w in wins
        if !w.HasOwnProp("ki") && w.extra.Length
            w.ki := w.extra.RemoveAt(1).ki
    if Cfg.MultiKeys
        for ki, k in Keys {
            if result.Has(ki)
                continue
            px := vb.l + k.cx * (vb.r - vb.l), py := vb.t + k.cy * (vb.b - vb.t)
            for w in wins                       ; ordine z: la prima che contiene il punto
                if px >= w.rect.l && px < w.rect.r && py >= w.rect.t && py < w.rect.b {
                    if px >= w.mon.l && px < w.mon.r && py >= w.mon.t && py < w.mon.b {
                        result[ki] := w
                        AddKey(w, ki, px, py)
                    }
                    break
                }
        }
    return result
}

; Tasto in più per la finestra w: l'etichetta va nel punto (x, y) tenuto dentro il
; pezzo visibile della finestra, o all'angolo corrispondente se manca il punto
AddKey(w, ki, x := "", y := "") {
    L := Labels[ki], p := w.part, k := Keys[ki]
    if x = ""
        x := k.cx < 0.5 ? p.l : p.r, y := k.cy < 0.5 ? p.t : p.b
    x := Max(p.l + L.w / 2, Min(p.r - L.w / 2, x))
    y := Max(p.t + L.h / 2, Min(p.b - L.h / 2, y))
    w.extra.Push({ki: ki, x: x, y: y})
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
    Hotkey("*" Cfg.TileKey, TileVisible)
    Hotkey("*" Cfg.UndoKey, UndoTile)
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

; ---------------------------------------------------------------- tiling

; Affianca le finestre visibili di ogni monitor senza sovrapposizioni, cercando di
; lasciarle dov'erano: l'area di lavoro viene tagliata ricorsivamente nel punto
; che separa meglio le finestre, all'altezza dei loro bordi originali.
TileVisible(*) {
    global LastLayout := []
    Critical            ; un CapsLock premuto nel frattempo aspetta la fine
    SetWinDelay(-1)     ; il ritardo di 100 ms dopo ogni WinMove rendeva lento il tiling
    HideOverlay()
    groups := Map()
    for w in CollectWindows(1000) {
        ; le finestre a dimensione fissa (senza bordo ridimensionabile) restano dove sono
        style := 0x40000
        try style := WinGetStyle(w.hwnd)
        if !(style & 0x40000)
            continue
        r := FrameRect(w.hwnd)
        mm := 0
        try mm := WinGetMinMax(w.hwnd)
        LastLayout.Push({hwnd: w.hwnd, rect: r, max: mm = 1})
        if !groups.Has(w.mon)
            groups[w.mon] := []
        groups[w.mon].Push({hwnd: w.hwnd, l: r.l, t: r.t, r: r.r, b: r.b, min: Map("l", 0, "t", 0)})
    }
    g := Cfg.TileGap
    for mon, items in groups
        ; una finestra con una dimensione minima più grande del suo spazio la rifiuta:
        ; ne prendo nota e rifaccio il monitor tenendone conto
        loop 5 {
            SplitArea(items, {l: mon.wa.l + g, t: mon.wa.t + g, r: mon.wa.r - g, b: mon.wa.b - g})
            again := false
            for it in items {
                f := FrameRect(it.hwnd), a := it.target
                if f.r - f.l > a.r - a.l + 4
                    it.min["l"] := f.r - f.l, again := true
                if f.b - f.t > a.b - a.t + 4
                    it.min["t"] := f.b - f.t, again := true
            }
            if !again
                break
        }
    ; se lo spazio proprio non basta, almeno nessuna finestra esce dallo schermo
    for mon, items in groups
        for it in items
            try {
                f := FrameRect(it.hwnd), wa := mon.wa
                dx := Max(0, wa.l - f.l) - Max(0, f.r - wa.r)
                dy := Max(0, wa.t - f.t) - Max(0, f.b - wa.b)
                if dx || dy {
                    WinGetPos(&x, &y, , , it.hwnd)
                    WinMove(x + dx, y + dy, , , it.hwnd)
                }
            }
}

UndoTile(*) {
    Critical
    SetWinDelay(-1)
    HideOverlay()
    for s in LastLayout {
        PlaceWindow(s.hwnd, s.rect)
        if s.max
            try WinMaximize(s.hwnd)
    }
}

SplitArea(items, area) {
    if items.Length = 1 {
        items[1].target := area
        return PlaceWindow(items[1].hwnd, area)
    }
    best := BestSplit(items, area)
    lo := best.lo, hi := best.hi
    dim := area.%hi% - area.%lo%
    ; ogni lato deve avere spazio per le sue finestre; se non c'è, taglio in
    ; proporzione a quello che chiedono
    g := Cfg.TileGap
    minA := Need(best.a)[lo], minB := Need(best.b)[lo]
    if minA + minB + g > dim
        cut := Round(area.%lo% + dim * minA / (minA + minB))
    else
        cut := Round(Max(area.%lo% + minA + g // 2, Min(area.%hi% - minB - g // 2, best.cut)))
    a := area.Clone(), b := area.Clone()
    a.%hi% := cut - g // 2
    b.%lo% := cut + g - g // 2
    SplitArea(best.a, a)
    SplitArea(best.b, b)
}

; Il taglio che separa meglio le finestre di items dentro area: asse, posizione e i
; due gruppi, ordinati lungo l'asse
BestSplit(items, area) {
    best := ""
    longest := Max(area.r - area.l, area.b - area.t)
    for axis in ["x", "y"] {
        lo := axis = "x" ? "l" : "t", hi := axis = "x" ? "r" : "b"
        dim := area.%hi% - area.%lo%
        sorted := SortBy(items, (it) => it.%lo% + it.%hi%)
        n := sorted.Length
        loop n - 1 {
            k := A_Index
            endA := -1e9, startB := 1e9
            loop k
                endA := Max(endA, sorted[A_Index].%hi%)
            loop n - k
                startB := Min(startB, sorted[k + A_Index].%lo%)
            ; > 0: tra i due gruppi c'è spazio; < 0: si sovrappongono
            sep := (startB - endA) / dim
            ; uno spazio vero tra i gruppi vince sempre; se si sovrappongono meglio
            ; dividere a metà, lungo il lato lungo, che lasciare strisce sottili
            score := sep > 0 ? 1 + sep : sep - 0.6 * Abs(2 * k - n) / n - 0.3 * (1 - dim / longest)
            if !best || score > best.score
                best := {score: score, lo: lo, hi: hi, k: k, n: n, cut: (endA + startB) / 2
                    , a: Slice(sorted, 1, k), b: Slice(sorted, k + 1, n)}
        }
    }
    return best
}

; WinMove lavora sul rettangolo con i bordi invisibili di Windows 10/11: li aggiungo
PlaceWindow(hwnd, a) {
    try {
        if WinGetMinMax(hwnd) != 0
            WinRestore(hwnd)
        WinGetPos(&x, &y, &w, &h, hwnd)
        f := FrameRect(hwnd)
        WinMove(a.l - (f.l - x), a.t - (f.t - y)
            , (a.r - a.l) + (f.l - x) + (x + w - f.r)
            , (a.b - a.t) + (f.t - y) + (y + h - f.b), hwnd)
    }
}

; Larghezza ("l") e altezza ("t") minime per affiancare items con gli stessi tagli di
; SplitArea: per ogni finestra MIN_TILE o la sua dimensione minima, se più grande
Need(items) {
    if items.Length = 1
        return Map("l", Max(MIN_TILE["l"], items[1].min["l"]), "t", Max(MIN_TILE["t"], items[1].min["t"]))
    bb := {l: 1e9, t: 1e9, r: -1e9, b: -1e9}
    for it in items
        bb.l := Min(bb.l, it.l), bb.t := Min(bb.t, it.t), bb.r := Max(bb.r, it.r), bb.b := Max(bb.b, it.b)
    s := BestSplit(items, bb)
    na := Need(s.a), nb := Need(s.b)
    other := s.lo = "l" ? "t" : "l"
    return Map(s.lo, na[s.lo] + nb[s.lo] + Cfg.TileGap, other, Max(na[other], nb[other]))
}

SortBy(arr, key) {
    out := []
    for it in arr {
        i := out.Length + 1
        while i > 1 && key(out[i - 1]) > key(it)
            i--
        out.InsertAt(i, it)
    }
    return out
}

Slice(arr, from, to) {
    out := []
    loop to - from + 1
        out.Push(arr[from + A_Index - 1])
    return out
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
