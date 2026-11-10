--[[
  Controller Overlay für OBS (Windows) – Xbox-, PS5- und Switch-2-Controller
  ----------------------------------------------------------------
  Eine einzige Datei. Liest den Controller direkt aus (Xbox über XInput,
  PS5/DualSense über die HID-Schnittstelle) – auch während ein Spiel im
  Vordergrund ist – und stellt das Overlay unter http://localhost:8790 bereit.

  Einrichtung:
    1. OBS → Werkzeuge → Skripte → "+" → diese Datei auswählen.
    2. In der Szene bei "Quellen" auf "+" klicken und "Controller Overlay"
       wählen (1600 x 1120, Seitenverhältnis 10:7).
    3. Controller, Layout, Farbvariante, Leuchtfarbe, Deckkraft usw. in den
       Eigenschaften der Quelle einstellen – Änderungen wirken sofort.
       Jede Quelle hat eigene Einstellungen.

  Alternativ als Browser-Quelle mit der URL http://localhost:8790
  (dann mit Standard-Einstellungen bzw. diesen URL-Parametern):
    layout=auto|xbox|ps|ns  theme=carbon|white  accent=HEX  hint=0  bg=HEX
    pad=N  dz=0.12  opacity=10..100  face=orig

  Hinweise: Die Share-Taste des Xbox-Controllers ist über XInput nicht
  auslesbar. Unterstützte PS-Controller: DualSense und DualSense Edge
  (USB und Bluetooth). Nintendo: Switch 2 Pro Controller über USB-Kabel
  (Joy-Con 2 und Bluetooth werden von Windows nicht als Gamepad bereitgestellt).
]]

obs = obslua
local ffi = require("ffi")
local bit = require("bit")
local band, rshift = bit.band, bit.rshift

local DEFAULT_PORT = 8790

pcall(ffi.cdef, [[
typedef struct {
  uint32_t dwPacketNumber;
  uint16_t wButtons;
  uint8_t  bLeftTrigger;
  uint8_t  bRightTrigger;
  int16_t  sThumbLX; int16_t sThumbLY;
  int16_t  sThumbRX; int16_t sThumbRY;
  uint32_t dwPaddingReserved;
} XOV_XSTATE;
typedef uint32_t (__stdcall *XOV_GETSTATE)(uint32_t idx, XOV_XSTATE *st);
typedef struct { int16_t sin_family; uint16_t sin_port; uint32_t sin_addr; char sin_zero[8]; } XOV_SOCKADDR_IN;
typedef struct { uint32_t Data1; uint16_t Data2; uint16_t Data3; uint8_t Data4[8]; } XOV_GUID;
typedef struct { uint32_t cbSize; XOV_GUID InterfaceClassGuid; uint32_t Flags; uintptr_t Reserved; } XOV_SP_DID;
typedef struct { uintptr_t Internal; uintptr_t InternalHigh; uint32_t Offset; uint32_t OffsetHigh; void *hEvent; } XOV_OVERLAPPED;

void*     LoadLibraryA(const char *name);
void*     GetProcAddress(void *h, const char *name);
void*     CreateFileA(const char *name, uint32_t access, uint32_t share, void *sec, uint32_t disp, uint32_t flags, void *tmpl);
int       ReadFile(void *h, void *buf, uint32_t n, uint32_t *read, XOV_OVERLAPPED *ov);
int       GetOverlappedResult(void *h, XOV_OVERLAPPED *ov, uint32_t *n, int wait);
int       CancelIo(void *h);
int       CloseHandle(void *h);
void*     CreateEventA(void *sec, int manual, int initial, const char *name);
uint32_t  GetLastError(void);
void      Sleep(uint32_t ms);

typedef struct { int32_t PipeType; uint8_t PipeId; uint16_t MaximumPacketSize; uint8_t Interval; } XOV_PIPEINFO;
int       WinUsb_Initialize(void *dev, void **iface);
int       WinUsb_Free(void *iface);
int       WinUsb_QueryInterfaceSettings(void *iface, uint8_t alt, uint8_t *desc);
int       WinUsb_QueryPipe(void *iface, uint8_t alt, uint8_t idx, XOV_PIPEINFO *info);
int       WinUsb_SetPipePolicy(void *iface, uint8_t pipe, uint32_t type, uint32_t len, void *val);
int       WinUsb_WritePipe(void *iface, uint8_t pipe, const uint8_t *buf, uint32_t len, uint32_t *sent, void *ov);

void      HidD_GetHidGuid(XOV_GUID *g);
int       HidD_SetNumInputBuffers(void *h, uint32_t n);
int       HidD_GetPreparsedData(void *h, void **pp);
int       HidD_FreePreparsedData(void *pp);
int32_t   HidP_GetCaps(void *pp, uint16_t *caps);
void*     SetupDiGetClassDevsA(const XOV_GUID *g, const char *enumerator, void *hwnd, uint32_t flags);
int       SetupDiEnumDeviceInterfaces(void *set, void *devinfo, const XOV_GUID *g, uint32_t idx, XOV_SP_DID *d);
int       SetupDiGetDeviceInterfaceDetailA(void *set, XOV_SP_DID *d, void *detail, uint32_t size, uint32_t *req, void *devinfo);
int       SetupDiDestroyDeviceInfoList(void *set);

int       WSAStartup(uint16_t ver, void *data);
int       WSACleanup(void);
int       WSAGetLastError(void);
uintptr_t socket(int af, int type, int protocol);
int       bind(uintptr_t s, const void *name, int namelen);
int       listen(uintptr_t s, int backlog);
uintptr_t accept(uintptr_t s, void *addr, int *addrlen);
int       recv(uintptr_t s, char *buf, int len, int flags);
int       send(uintptr_t s, const char *buf, int len, int flags);
int       closesocket(uintptr_t s);
int       ioctlsocket(uintptr_t s, long cmd, unsigned long *argp);
uint16_t  htons(uint16_t v);
uint32_t  inet_addr(const char *cp);
]])

local k32 = ffi.C
local ws2 = ffi.load("ws2_32")
local hid = ffi.load("hid")
local setupapi = ffi.load("setupapi")
local winusb_ok, winusb = pcall(ffi.load, "winusb")
if not winusb_ok then winusb = nil end

-- INVALID_SOCKET / INVALID_HANDLE_VALUE sind ~0. Ein direkter cdata-Vergleich
-- ist in LuaJIT unzuverlässig, daher über int64 → Lua-Zahl prüfen.
local function is_invalid(s) return tonumber(ffi.cast("int64_t", s)) == -1 end
local function bad_handle(h) return h == nil or tonumber(ffi.cast("int64_t", ffi.cast("intptr_t", h))) == -1 end

local FIONBIO = -2147195266          -- 0x8004667E als signed long
local WSAEWOULDBLOCK = 10035
local nonblock = ffi.new("unsigned long[1]", 1)

local function log(msg) obs.script_log(obs.LOG_INFO, "[Controller Overlay] " .. msg) end
local function now_s() return obs.os_gettime_ns() / 1e9 end
local function fmt(f) return string.format("%.3f", f) end

-- Zuletzt gesehene Controller (für die Auswahlliste in den Quellen-Eigenschaften)
local pad_list = {}

local function short_hash(s)
  local h = 5381
  for k = 1, #s do h = band(h * 33 + s:byte(k), 0x7FFFFFFF) end
  return string.format("%08x", h)
end

------------------------------------------------------------------------------
-- Xbox: XInput
------------------------------------------------------------------------------
local XGetState = nil

local function init_xinput()
  for _, name in ipairs({ "xinput1_4.dll", "xinput1_3.dll", "xinput9_1_0.dll" }) do
    local h = k32.LoadLibraryA(name)
    if h ~= nil then
      -- Ordinal 100 = XInputGetStateEx (liefert zusätzlich die Xbox-Taste)
      if name ~= "xinput9_1_0.dll" then
        local p = k32.GetProcAddress(h, ffi.cast("const char*", 100))
        if p ~= nil then
          XGetState = ffi.cast("XOV_GETSTATE", p)
          return name .. " (mit Xbox-Taste)"
        end
      end
      local p = k32.GetProcAddress(h, "XInputGetState")
      if p ~= nil then
        XGetState = ffi.cast("XOV_GETSTATE", p)
        return name
      end
    end
  end
  return nil
end

-- XInput-Bit → Index im Standard-Gamepad-Layout
local XBOX_MAP = {
  { 0x1000, 0 }, { 0x2000, 1 }, { 0x4000, 2 }, { 0x8000, 3 },   -- A B X Y
  { 0x0100, 4 }, { 0x0200, 5 },                                 -- LB RB
  { 0x0020, 8 }, { 0x0010, 9 },                                 -- View Menu
  { 0x0040, 10 }, { 0x0080, 11 },                               -- LS RS
  { 0x0001, 12 }, { 0x0002, 13 }, { 0x0004, 14 }, { 0x0008, 15 }, -- D-Pad
  { 0x0400, 16 },                                               -- Xbox
}

local xslots = {}
for i = 0, 3 do xslots[i] = { connected = false, next_check = 0 } end
local xstate = ffi.new("XOV_XSTATE")

local function xaxis(v)
  local f = v / 32767
  if f < -1 then f = -1 end
  return f
end

local function poll_xinput(t, parts)
  if not XGetState then return end
  for i = 0, 3 do
    local s = xslots[i]
    -- Abfrage nicht verbundener Slots ist langsam → nur 1x pro Sekunde
    if s.connected or t >= s.next_check then
      if XGetState(i, xstate) == 0 then
        s.connected = true
        local b = {}
        for k = 1, 19 do b[k] = "0" end
        local w = xstate.wButtons
        for _, m in ipairs(XBOX_MAP) do
          if band(w, m[1]) ~= 0 then b[m[2] + 1] = "1" end
        end
        b[7] = fmt(xstate.bLeftTrigger / 255)
        b[8] = fmt(xstate.bRightTrigger / 255)
        pad_list[#pad_list + 1] = { id = "xbox" .. i, label = "Xbox-Controller " .. (i + 1) }
        parts[#parts + 1] = string.format('{"i":%d,"id":"xbox%d","t":"xbox","b":[%s],"a":[%s,%s,%s,%s]}', i, i,
          table.concat(b, ","),
          fmt(xaxis(xstate.sThumbLX)), fmt(-xaxis(xstate.sThumbLY)),
          fmt(xaxis(xstate.sThumbRX)), fmt(-xaxis(xstate.sThumbRY)))
      else
        s.connected = false
        s.next_check = t + 1.0
      end
    end
  end
end

------------------------------------------------------------------------------
-- PS5: DualSense über HID (USB und Bluetooth)
------------------------------------------------------------------------------
local HID_GUID = ffi.new("XOV_GUID")
hid.HidD_GetHidGuid(HID_GUID)
local DETAIL_CBSIZE = ffi.abi("64bit") and 8 or 5
local ERROR_IO_PENDING, ERROR_IO_INCOMPLETE = 997, 996

local ds_list = {}          -- geöffnete Controller (PS5 und Switch 2)
local ds_by_path = {}
local next_hid_scan = 0
local first_scan_logged = false

local KIND_NAME = { ps = "PS5-Controller", ns = "Switch 2 Pro Controller" }

------------------------------------------------------------------------------
-- Switch 2 Pro Controller: Aufwecken über die WinUSB-Schnittstelle (MI_01)
-- Der Controller sendet über USB erst Eingaben, nachdem er diese Befehle
-- erhalten hat. Windows bindet WinUSB an diese Schnittstelle automatisch,
-- ein Treiber muss nicht installiert werden.
------------------------------------------------------------------------------
local NS_WINUSB_GUID = ffi.new("XOV_GUID", 0x6F13725E, 0xEF0E, 0x4FD3, { 0xAE, 0x5F, 0xB2, 0xDE, 0x98, 0x9E, 0xC8, 0x25 })
local NS_WAKE = {
  { 0x03, 0x91, 0x00, 0x0d, 0x00, 0x08, 0x00, 0x00, 0x01, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF },
  { 0x07, 0x91, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00 },
  { 0x16, 0x91, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00 },
  { 0x03, 0x91, 0x00, 0x0a, 0x00, 0x04, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00 },
  { 0x09, 0x91, 0x00, 0x07, 0x00, 0x08, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },  -- Spieler-LED 1
}

local function is_ns_path(key)
  return key:find("vid_057e", 1, true) and key:find("pid_2069", 1, true)
end

-- Alle Gerätepfade einer Schnittstellenklasse auflisten
local function list_paths(guid, filter)
  local out = {}
  local set = setupapi.SetupDiGetClassDevsA(guid, nil, nil, 0x12)   -- PRESENT | DEVICEINTERFACE
  if bad_handle(set) then return out end
  local ifd = ffi.new("XOV_SP_DID")
  ifd.cbSize = ffi.sizeof(ifd)
  local req = ffi.new("uint32_t[1]")
  local idx = 0
  while idx < 512 and setupapi.SetupDiEnumDeviceInterfaces(set, nil, guid, idx, ifd) ~= 0 do
    idx = idx + 1
    req[0] = 0
    setupapi.SetupDiGetDeviceInterfaceDetailA(set, ifd, nil, 0, req, nil)
    if req[0] > 8 and req[0] < 4096 then
      local buf = ffi.new("uint8_t[?]", req[0])
      ffi.cast("uint32_t*", buf)[0] = DETAIL_CBSIZE
      if setupapi.SetupDiGetDeviceInterfaceDetailA(set, ifd, buf, req[0], nil, nil) ~= 0 then
        local path = ffi.string(buf + 4)
        if filter(path:lower()) then out[#out + 1] = path end
      end
    end
  end
  setupapi.SetupDiDestroyDeviceInfoList(set)
  return out
end

-- Gibt true zurück, wenn mindestens ein Controller aufgeweckt wurde
local function ns_wake()
  if not winusb then return false, "winusb.dll fehlt" end
  local paths = list_paths(NS_WINUSB_GUID, is_ns_path)
  if #paths == 0 then return false, "keine WinUSB-Schnittstelle gefunden" end
  local woke, why = false, nil
  for _, path in ipairs(paths) do
    local h = k32.CreateFileA(path, 0xC0000000, 3, nil, 3, 0x40000080, nil)   -- overlapped (für WinUSB nötig)
    if bad_handle(h) then
      why = "Schnittstelle belegt (Code " .. k32.GetLastError() .. ", evtl. durch Steam)"
    else
      local iface = ffi.new("void*[1]")
      if winusb.WinUsb_Initialize(h, iface) ~= 0 then
        local desc = ffi.new("uint8_t[16]")
        local pipe = nil
        if winusb.WinUsb_QueryInterfaceSettings(iface[0], 0, desc) ~= 0 then
          local info = ffi.new("XOV_PIPEINFO")
          for e = 0, desc[4] - 1 do
            if winusb.WinUsb_QueryPipe(iface[0], 0, e, info) ~= 0
               and info.PipeType == 2 and band(info.PipeId, 0x80) == 0 then
              pipe = info.PipeId; break
            end
          end
        end
        if pipe then
          local timeout = ffi.new("uint32_t[1]", 200)
          winusb.WinUsb_SetPipePolicy(iface[0], pipe, 0x03, 4, timeout)   -- PIPE_TRANSFER_TIMEOUT
          local sent = ffi.new("uint32_t[1]")
          local ok = true
          for _, cmd in ipairs(NS_WAKE) do
            local b = ffi.new("uint8_t[?]", #cmd, cmd)
            if winusb.WinUsb_WritePipe(iface[0], pipe, b, #cmd, sent, nil) == 0 then ok = false; break end
            k32.Sleep(20)
          end
          if ok then woke = true else why = "Senden fehlgeschlagen (Code " .. k32.GetLastError() .. ")" end
        else
          why = "kein Bulk-Ausgang gefunden"
        end
        winusb.WinUsb_Free(iface[0])
      else
        why = "WinUsb_Initialize fehlgeschlagen (Code " .. k32.GetLastError() .. ")"
      end
      k32.CloseHandle(h)
    end
  end
  return woke, why
end

local function close_ds(d)
  if d.pending then
    k32.CancelIo(d.h)
    k32.GetOverlappedResult(d.h, d.ov, d.n, 1)   -- Abbruch abwarten, bevor Puffer frei werden
    d.pending = false
  end
  k32.CloseHandle(d.h)
  if d.ov.hEvent ~= nil then k32.CloseHandle(d.ov.hEvent) end
  ds_by_path[d.key] = nil
  for k, v in ipairs(ds_list) do
    if v == d then table.remove(ds_list, k); break end
  end
end

local function open_ds(path, key, kind)
  local h = k32.CreateFileA(path, 0xC0000000, 3, nil, 3, 0x40000000, nil)   -- lesen+schreiben, geteilt, overlapped
  if bad_handle(h) then h = k32.CreateFileA(path, 0x80000000, 3, nil, 3, 0x40000000, nil) end
  if bad_handle(h) then return end
  hid.HidD_SetNumInputBuffers(h, 4)
  -- Länge eines Eingabeberichts ermitteln (USB 64, Bluetooth 78). Es wird immer
  -- genau ein Bericht pro ReadFile gelesen – ein größerer Puffer würde mehrere
  -- aufgestaute Berichte aneinandergehängt liefern.
  local replen = 64
  local pp = ffi.new("void*[1]")
  if hid.HidD_GetPreparsedData(h, pp) ~= 0 then
    local caps = ffi.new("uint16_t[32]")
    if hid.HidP_GetCaps(pp[0], caps) == 0x110000 then replen = caps[2] end
    hid.HidD_FreePreparsedData(pp[0])
  end
  if replen < 10 or replen > 256 then replen = 64 end
  local d = {
    h = h, key = key, kind = kind, id = kind .. short_hash(key), opened = now_s(), good = false, wakes = 0, next_wake = 0,
    pending = false, lastn = 0, replen = replen, bt = replen ~= 64,
    buf = ffi.new("uint8_t[256]"), last = ffi.new("uint8_t[256]"), center = {}, range = {},
    n = ffi.new("uint32_t[1]"), ov = ffi.new("XOV_OVERLAPPED"),
  }
  d.ov.hEvent = k32.CreateEventA(nil, 1, 0, nil)
  ds_list[#ds_list + 1] = d
  ds_by_path[key] = d
  if kind == "ns" then d.bt = false end
  log(KIND_NAME[kind] .. " verbunden (" .. (d.bt and "Bluetooth" or "USB") .. ", Berichtslänge " .. replen .. ")")
end

local function scan_hid()
  local paths = list_paths(HID_GUID, function(key)
    if ds_by_path[key] then return false end
    -- Sony (054c): DualSense (0ce6) und DualSense Edge (0df2)
    if key:find("054c", 1, true) and (key:find("0ce6", 1, true) or key:find("0df2", 1, true)) then return true end
    -- Nintendo (057e): Switch 2 Pro Controller (2069)
    return is_ns_path(key) and true or false
  end)
  for _, path in ipairs(paths) do
    local key = path:lower()
    open_ds(path, key, is_ns_path(key) and "ns" or "ps")
  end
end

-- Alle bereitliegenden Berichte lesen, nur den neuesten behalten (kein Rückstau)
local function drain_ds(d)
  for _ = 1, 64 do
    if not d.pending then
      if k32.ReadFile(d.h, d.buf, d.replen, d.n, d.ov) ~= 0 then
        k32.GetOverlappedResult(d.h, d.ov, d.n, 0)
        ffi.copy(d.last, d.buf, d.n[0]); d.lastn = d.n[0]
      else
        local err = k32.GetLastError()
        if err == ERROR_IO_PENDING then d.pending = true; return true end
        d.err = err
        return false                                    -- Gerät getrennt
      end
    else
      if k32.GetOverlappedResult(d.h, d.ov, d.n, 0) ~= 0 then
        d.pending = false
        ffi.copy(d.last, d.buf, d.n[0]); d.lastn = d.n[0]
      else
        local err = k32.GetLastError()
        if err == ERROR_IO_INCOMPLETE then return true end
        d.pending = false
        d.err = err
        return false
      end
    end
  end
  return true
end

local function sax(v)
  local f = (v - 128) / 127
  if f < -1 then f = -1 elseif f > 1 then f = 1 end
  return f
end

local function ds_json(d, i)
  local b, n = d.last, d.lastn
  if n < 10 then return nil end
  local id = b[0]
  local o, lx, ly, rx, ry, l2, r2, b0, b1, b2, touch
  if not d.bt and id == 0x01 and n >= 64 then o = 1   -- USB
  elseif d.bt and id == 0x31 and n >= 42 then o = 2    -- Bluetooth (voller Bericht)
  end
  if o then
    lx, ly, rx, ry, l2, r2 = b[o], b[o + 1], b[o + 2], b[o + 3], b[o + 4], b[o + 5]
    b0, b1, b2 = b[o + 7], b[o + 8], b[o + 9]
    touch = o + 32
  elseif d.bt and id == 0x01 then              -- Bluetooth (einfacher Bericht)
    lx, ly, rx, ry = b[1], b[2], b[3], b[4]
    b0, b1, b2, l2, r2 = b[5], b[6], b[7], b[8], b[9]
  else
    return nil
  end

  local bt = {}
  for k = 1, 19 do bt[k] = "0" end
  local function on(idx) bt[idx + 1] = "1" end
  if band(b0, 0x20) ~= 0 then on(0) end   -- Kreuz
  if band(b0, 0x40) ~= 0 then on(1) end   -- Kreis
  if band(b0, 0x10) ~= 0 then on(2) end   -- Quadrat
  if band(b0, 0x80) ~= 0 then on(3) end   -- Dreieck
  if band(b1, 0x01) ~= 0 then on(4) end   -- L1
  if band(b1, 0x02) ~= 0 then on(5) end   -- R1
  if band(b1, 0x10) ~= 0 then on(8) end   -- Create
  if band(b1, 0x20) ~= 0 then on(9) end   -- Options
  if band(b1, 0x40) ~= 0 then on(10) end  -- L3
  if band(b1, 0x80) ~= 0 then on(11) end  -- R3
  if band(b2, 0x01) ~= 0 then on(16) end  -- PS
  if band(b2, 0x02) ~= 0 then on(17) end  -- Touchpad-Klick
  if band(b2, 0x04) ~= 0 then on(18) end  -- Mikrofon stumm
  local hat = band(b0, 0x0F)
  if hat == 0 or hat == 1 or hat == 7 then on(12) end
  if hat >= 3 and hat <= 5 then on(13) end
  if hat >= 5 and hat <= 7 then on(14) end
  if hat >= 1 and hat <= 3 then on(15) end
  bt[7] = fmt(l2 / 255)
  bt[8] = fmt(r2 / 255)

  local tp = {}
  if touch and n >= touch + 8 then
    for f = 0, 1 do
      local p = touch + f * 4
      if band(b[p], 0x80) == 0 then
        local x = b[p + 1] + band(b[p + 2], 0x0F) * 256
        local y = rshift(b[p + 2], 4) + b[p + 3] * 16
        tp[#tp + 1] = string.format("[%s,%s]", fmt(x / 1919), fmt(y / 1079))
      end
    end
  end

  return string.format('{"i":%d,"id":"%s","t":"ps","b":[%s],"a":[%s,%s,%s,%s],"tp":[%s]}', i, d.id,
    table.concat(bt, ","), fmt(sax(lx)), fmt(sax(ly)), fmt(sax(rx)), fmt(sax(ry)), table.concat(tp, ","))
end

------------------------------------------------------------------------------
-- Switch 2 Pro Controller: Bericht auswerten
------------------------------------------------------------------------------
-- Tastenbelegung: { Byte, Bitmaske, Index }. Index nach Position wie beim
-- Standard-Gamepad: 0 unten (B), 1 rechts (A), 2 links (Y), 3 oben (X);
-- 19 = GL, 20 = GR (Rücktasten).
local NS_MAP_09 = {   -- Berichtsformat 0x09 (nach dem Aufwecken durch dieses Skript)
  { 3, 0x01, 0 }, { 3, 0x02, 1 }, { 3, 0x04, 2 }, { 3, 0x08, 3 },
  { 3, 0x10, 5 }, { 3, 0x20, 7 }, { 3, 0x40, 9 }, { 3, 0x80, 11 },
  { 4, 0x01, 13 }, { 4, 0x02, 15 }, { 4, 0x04, 14 }, { 4, 0x08, 12 },
  { 4, 0x10, 4 }, { 4, 0x20, 6 }, { 4, 0x40, 8 }, { 4, 0x80, 10 },
  { 5, 0x01, 16 }, { 5, 0x02, 17 }, { 5, 0x04, 20 }, { 5, 0x08, 19 }, { 5, 0x10, 18 },
}
local NS_MAP_ALT = {  -- anderes Berichtsformat (z. B. wenn Steam den Controller geweckt hat)
  { 5, 0x01, 2 }, { 5, 0x02, 3 }, { 5, 0x04, 0 }, { 5, 0x08, 1 }, { 5, 0x40, 5 }, { 5, 0x80, 7 },
  { 6, 0x01, 8 }, { 6, 0x02, 9 }, { 6, 0x04, 11 }, { 6, 0x08, 10 }, { 6, 0x10, 16 }, { 6, 0x20, 17 }, { 6, 0x40, 18 },
  { 7, 0x01, 13 }, { 7, 0x02, 12 }, { 7, 0x04, 15 }, { 7, 0x08, 14 }, { 7, 0x40, 4 }, { 7, 0x80, 6 },
  { 8, 0x01, 20 }, { 8, 0x02, 19 },
}

-- 12-Bit-Stickwerte, Mitte beim ersten Bericht gemessen, Bereich lernt mit
local function ns_axis(d, k, raw, invert)
  local c = d.center[k]
  if not c then
    c = (math.abs(raw - 2048) < 400) and raw or 2048
    d.center[k] = c
  end
  local off = raw - c
  local r = d.range[k] or 1350
  if math.abs(off) > r then r = math.abs(off); d.range[k] = r end
  local f = off / r
  if invert then f = -f end
  return f
end

local function ns_json(d, i)
  local b, n = d.last, d.lastn
  local map, so
  if n >= 12 and b[0] == 0x09 then map, so = NS_MAP_09, 6
  elseif n >= 17 then map, so = NS_MAP_ALT, 11
  else return nil end
  d.good = true
  local bt = {}
  for k = 1, 21 do bt[k] = "0" end
  for _, m in ipairs(map) do
    if band(b[m[1]], m[2]) ~= 0 then bt[m[3] + 1] = "1" end
  end
  local function stick(o)
    return b[o] + band(b[o + 1], 0x0F) * 256, rshift(b[o + 1], 4) + b[o + 2] * 16
  end
  local lx, ly = stick(so)
  local rx, ry = stick(so + 3)
  return string.format('{"i":%d,"id":"%s","t":"ns","b":[%s],"a":[%s,%s,%s,%s]}', i, d.id,
    table.concat(bt, ","),
    fmt(ns_axis(d, 1, lx)), fmt(ns_axis(d, 2, ly, true)),
    fmt(ns_axis(d, 3, rx)), fmt(ns_axis(d, 4, ry, true)))
end

-- Switch 2: aufwecken, solange noch keine gültigen Berichte kommen
local function ns_maybe_wake(d, t)
  -- Einmal beim Anstecken immer, danach nur, solange keine Eingaben kommen
  if d.wakes >= 5 or t < d.next_wake or (d.good and d.wakes > 0) then return end
  d.wakes = d.wakes + 1
  d.next_wake = t + 3
  local ok, why = ns_wake()
  if ok then log("Switch 2 Pro Controller aufgeweckt")
  else log("Switch 2 Pro Controller konnte nicht aufgeweckt werden: " .. tostring(why)) end
end

local function poll_ds(t, parts)
  if t >= next_hid_scan then
    local t0 = now_s()
    scan_hid()
    if not first_scan_logged then
      first_scan_logged = true
      log(string.format("Suche nach PS5-/Switch-2-Controllern dauerte %.1f ms", (now_s() - t0) * 1000))
    end
    next_hid_scan = t + (#ds_list == 0 and 3 or 10)
  end
  local lost = {}
  for k, d in ipairs(ds_list) do
    if drain_ds(d) then
      if d.kind == "ns" then ns_maybe_wake(d, t) end
      local j
      if d.kind == "ns" then j = ns_json(d, 4 + k - 1) else j = ds_json(d, 4 + k - 1) end
      if j then
        parts[#parts + 1] = j
        pad_list[#pad_list + 1] = { id = d.id, label = KIND_NAME[d.kind] .. " (" .. (d.bt and "Bluetooth" or "USB") .. ")" }
      end
    else
      lost[#lost + 1] = d
    end
  end
  for _, d in ipairs(lost) do
    close_ds(d)
    log(KIND_NAME[d.kind] .. " getrennt (Code " .. tostring(d.err) .. ")")
    next_hid_scan = t + 1          -- bald neu suchen, falls er gleich wieder da ist
  end
end

local function poll_pads(t)
  local parts = {}
  pad_list = {}
  poll_ds(t, parts)        -- PS5 zuerst (bei "Automatisch" hat er Vorrang)
  poll_xinput(t, parts)
  return '{"pads":[' .. table.concat(parts, ",") .. ']}'
end

------------------------------------------------------------------------------
-- Mini-HTTP-Server (nur 127.0.0.1) mit Server-Sent Events
------------------------------------------------------------------------------
local HTML -- weiter unten definiert
-- Kennung dieses Skriptstarts: Die Overlay-Seite lädt sich neu, wenn sie zu
-- einer älteren Skriptversion gehört (z. B. nach "Skripte neu laden").
local BUILD = tostring(os.time()) .. tostring(math.random(1000, 9999))
local html_out = nil
local listen_sock = nil
local wsa_started = false
local current_port = nil
local conns = {}
local last_json = '{"pads":[]}'
-- Einstellungen je Overlay-Quelle, Schlüssel = Quellen-Kennung (?sid=… in der URL)
local DEFAULT_CFG_JSON = '{"pad":"auto","layout":"auto","theme":"carbon","accent":"#00e5ff","hint":true,"opacity":100,"facecolors":false}'
local src_cfg = {}
local src_changed = {}
local function cfg_for(sid) return (sid and src_cfg[sid]) or DEFAULT_CFG_JSON end
local recv_buf = ffi.new("char[4096]")

local function stop_server()
  for _, c in ipairs(conns) do ws2.closesocket(c.s) end
  conns = {}
  if listen_sock then ws2.closesocket(listen_sock); listen_sock = nil end
  if wsa_started then ws2.WSACleanup(); wsa_started = false end
  current_port = nil
end

local function start_server(port)
  stop_server()
  local wsa = ffi.new("char[1024]")
  if ws2.WSAStartup(0x0202, wsa) ~= 0 then log("WSAStartup fehlgeschlagen"); return end
  wsa_started = true
  local s = ws2.socket(2, 1, 6)             -- AF_INET, SOCK_STREAM, TCP
  if is_invalid(s) then log("socket() fehlgeschlagen"); return end
  local addr = ffi.new("XOV_SOCKADDR_IN")
  addr.sin_family = 2
  addr.sin_port = ws2.htons(port)
  addr.sin_addr = ws2.inet_addr("127.0.0.1")
  if ws2.bind(s, addr, ffi.sizeof(addr)) ~= 0 then
    ws2.closesocket(s)
    log("Port " .. port .. " ist bereits belegt – bitte in den Skript-Einstellungen einen anderen Port wählen.")
    return
  end
  ws2.listen(s, 16)
  ws2.ioctlsocket(s, FIONBIO, nonblock)
  listen_sock = s
  current_port = port
  log("Overlay läuft unter http://localhost:" .. port)
end

local function handle_request(c)
  local path = c.inbuf:match("^GET%s+(%S+)")
  c.close = true
  if not path then
    c.out = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    return
  end
  c.sid = path:match("[?&]sid=(%w+)")
  path = path:gsub("%?.*$", "")
  if path == "/events" then
    c.sse, c.close = true, false
    c.out = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n" ..
            "Connection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n" ..
            "retry: 1000\n\nevent: build\ndata: " .. BUILD .. "\n\nevent: config\ndata: " .. cfg_for(c.sid) ..
            "\n\ndata: " .. last_json .. "\n\n"
  elseif path == "/" or path == "/index.html" then
    if not html_out then html_out = HTML:gsub("__BUILD__", BUILD) end
    c.out = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n" ..
            "Content-Length: " .. #html_out .. "\r\nConnection: close\r\n\r\n" .. html_out
  else
    c.out = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  end
end

local function flush(c)
  while #c.out > 0 do
    local n = ws2.send(c.s, c.out, #c.out, 0)
    if n > 0 then
      c.out = c.out:sub(n + 1)
    else
      return ws2.WSAGetLastError() == WSAEWOULDBLOCK
    end
  end
  return true
end

local function tick()
  local t = now_s()

  if listen_sock then
    for _ = 1, 16 do                          -- max. 16 neue Verbindungen pro Tick
      local cs = ws2.accept(listen_sock, nil, nil)
      if is_invalid(cs) then break end
      ws2.ioctlsocket(cs, FIONBIO, nonblock)
      conns[#conns + 1] = { s = cs, inbuf = "", out = "", sse = false, close = false, born = t, ping = t }
    end
  end

  local json = poll_pads(t)
  local changed = json ~= last_json
  last_json = json

  local keep = {}
  for _, c in ipairs(conns) do
    local alive = true
    if not c.sse and not c.close then
      local n = ws2.recv(c.s, recv_buf, 4096, 0)
      if n > 0 then
        c.inbuf = c.inbuf .. ffi.string(recv_buf, n)
        if c.inbuf:find("\r\n\r\n", 1, true) then handle_request(c)
        elseif #c.inbuf > 16384 then alive = false end
      elseif n == 0 or ws2.WSAGetLastError() ~= WSAEWOULDBLOCK then
        alive = false
      elseif t - c.born > 10 then
        alive = false
      end
    end
    if alive and c.sse then
      if c.sid and src_changed[c.sid] then c.out = c.out .. "event: config\ndata: " .. cfg_for(c.sid) .. "\n\n" end
      if changed then
        c.out = c.out .. "data: " .. json .. "\n\n"; c.ping = t
      elseif t - c.ping > 2 then
        c.out = c.out .. ": ping\n\n"; c.ping = t
      end
      if #c.out > 65536 then alive = false end   -- Client hängt
    end
    if alive then alive = flush(c) end
    if alive and c.close and c.out == "" then alive = false end
    if alive then keep[#keep + 1] = c else ws2.closesocket(c.s) end
  end
  conns = keep
  if next(src_changed) then src_changed = {} end
end

local tick_error_logged = false
local function safe_tick()
  local ok, err = pcall(tick)
  if not ok and not tick_error_logged then
    tick_error_logged = true
    log("Fehler: " .. tostring(err))
  end
end

------------------------------------------------------------------------------
-- OBS-Quelle "Controller Overlay"
-- Die Quelle enthält eine interne Browser-Quelle, die die Overlay-Seite dieses
-- Skripts anzeigt. Jede Quelle hat ihre eigenen Einstellungen; der Server
-- liefert sie der Seite über die Kennung in der URL (?sid=…).
------------------------------------------------------------------------------
local SRC_W, SRC_H = 1600, 1120
local sources = {}            -- sid -> Daten der Quelle
local sid_counter = 0

local function overlay_url(sid)
  return "http://localhost:" .. (current_port or DEFAULT_PORT) .. "/?sid=" .. sid
end

local function source_cfg_json(settings)
  local layout = obs.obs_data_get_string(settings, "layout")
  if layout ~= "xbox" and layout ~= "ps" and layout ~= "ns" then layout = "auto" end
  local theme = obs.obs_data_get_string(settings, "theme")
  if theme ~= "white" then theme = "carbon" end
  local c = obs.obs_data_get_int(settings, "accent")
  local hex = string.format("#%02x%02x%02x", band(c, 0xFF), band(rshift(c, 8), 0xFF), band(rshift(c, 16), 0xFF))
  local hint = obs.obs_data_get_bool(settings, "hint")
  local pad = obs.obs_data_get_string(settings, "pad")
  if not pad or pad == "" or not pad:match("^[%w]+$") then pad = "auto" end
  local opacity = obs.obs_data_get_int(settings, "opacity")
  if opacity < 10 or opacity > 100 then opacity = 100 end
  local facecolors = obs.obs_data_get_bool(settings, "facecolors")
  return string.format('{"pad":"%s","layout":"%s","theme":"%s","accent":"%s","hint":%s,"opacity":%d,"facecolors":%s}',
    pad, layout, theme, hex, hint and "true" or "false", opacity, facecolors and "true" or "false")
end

local function browser_settings(sid)
  local s = obs.obs_data_create()
  obs.obs_data_set_bool(s, "is_local_file", false)
  obs.obs_data_set_string(s, "url", overlay_url(sid))
  obs.obs_data_set_int(s, "width", SRC_W)
  obs.obs_data_set_int(s, "height", SRC_H)
  obs.obs_data_set_bool(s, "fps_custom", true)
  obs.obs_data_set_int(s, "fps", 60)
  obs.obs_data_set_bool(s, "shutdown", false)
  obs.obs_data_set_bool(s, "restart_when_active", false)
  obs.obs_data_set_bool(s, "reroute_audio", false)
  obs.obs_data_set_string(s, "css", "")
  return s
end

-- Nach einem Portwechsel alle Quellen auf die neue Adresse umstellen
local function retarget_sources()
  for sid, d in pairs(sources) do
    if d.browser then
      local s = obs.obs_data_create()
      obs.obs_data_set_string(s, "url", overlay_url(sid))
      obs.obs_source_update(d.browser, s)
      obs.obs_data_release(s)
    end
  end
end

local function add_source_properties(props, settings)
  -- Controller-Auswahl: alle gerade verbundenen Controller
  local padp = obs.obs_properties_add_list(props, "pad", "Controller",
    obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
  obs.obs_property_list_add_string(padp, "Automatisch (zuletzt benutzter Controller)", "auto")
  local total, nr, seen = {}, {}, {}
  for _, p in ipairs(pad_list) do total[p.label] = (total[p.label] or 0) + 1 end
  for _, p in ipairs(pad_list) do
    nr[p.label] = (nr[p.label] or 0) + 1
    local label = p.label
    if total[p.label] > 1 then label = label .. " #" .. nr[p.label] end
    obs.obs_property_list_add_string(padp, label, p.id)
    seen[p.id] = true
  end
  local chosen = settings and obs.obs_data_get_string(settings, "pad") or "auto"
  if chosen ~= "" and chosen ~= "auto" and not seen[chosen] then
    obs.obs_property_list_add_string(padp, "Gewählter Controller (gerade nicht verbunden)", chosen)
  end
  obs.obs_properties_add_button(props, "refresh", "Controller-Liste aktualisieren",
    function() return true end)

  local lay = obs.obs_properties_add_list(props, "layout", "Controller-Layout",
    obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
  obs.obs_property_list_add_string(lay, "Automatisch (erkennt den Controller)", "auto")
  obs.obs_property_list_add_string(lay, "Xbox", "xbox")
  obs.obs_property_list_add_string(lay, "PS5", "ps")
  obs.obs_property_list_add_string(lay, "Nintendo Switch 2", "ns")
  local list = obs.obs_properties_add_list(props, "theme", "Farbvariante",
    obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
  obs.obs_property_list_add_string(list, "Dunkel", "carbon")
  obs.obs_property_list_add_string(list, "Hell", "white")
  obs.obs_properties_add_color(props, "accent", "Leuchtfarbe")
  obs.obs_properties_add_bool(props, "facecolors",
    "Farbige Tasten (A/B/X/Y bzw. PS-Symbole) in ihrer Originalfarbe leuchten lassen")
  local op = obs.obs_properties_add_int_slider(props, "opacity", "Deckkraft", 10, 100, 5)
  obs.obs_property_int_set_suffix(op, " %")
  obs.obs_properties_add_bool(props, "hint", "Hinweis anzeigen, wenn kein Controller verbunden ist")
end

local overlay_source = {
  id = "controller_overlay_source",
  type = obs.OBS_SOURCE_TYPE_INPUT,
  output_flags = bit.bor(obs.OBS_SOURCE_VIDEO, obs.OBS_SOURCE_CUSTOM_DRAW),
}

overlay_source.get_name = function() return "Controller Overlay" end

overlay_source.get_defaults = function(settings)
  obs.obs_data_set_default_string(settings, "pad", "auto")
  obs.obs_data_set_default_string(settings, "layout", "auto")
  obs.obs_data_set_default_string(settings, "theme", "carbon")
  obs.obs_data_set_default_int(settings, "accent", 0xFFFFE500)   -- #00e5ff (OBS speichert 0xAABBGGRR)
  obs.obs_data_set_default_bool(settings, "hint", true)
  obs.obs_data_set_default_int(settings, "opacity", 100)
  obs.obs_data_set_default_bool(settings, "facecolors", false)
end

overlay_source.create = function(settings, source)
  sid_counter = sid_counter + 1
  local d = { source = source, sid = "s" .. BUILD .. sid_counter, showing = 0, active = 0 }
  src_cfg[d.sid] = source_cfg_json(settings)
  sources[d.sid] = d
  local bs = browser_settings(d.sid)
  d.browser = obs.obs_source_create_private("browser_source", "Controller Overlay (Browser)", bs)
  obs.obs_data_release(bs)
  if not d.browser then log("Browser-Quelle konnte nicht angelegt werden – ist das Browser-Plugin von OBS installiert?") end
  return d
end

overlay_source.destroy = function(d)
  if not d then return end
  sources[d.sid] = nil
  src_cfg[d.sid] = nil
  if d.browser then
    for _ = 1, d.showing do obs.obs_source_dec_showing(d.browser) end
    for _ = 1, d.active do obs.obs_source_dec_active(d.browser) end
    obs.obs_source_release(d.browser)
    d.browser = nil
  end
end

overlay_source.update = function(d, settings)
  local json = source_cfg_json(settings)
  if json ~= src_cfg[d.sid] then src_cfg[d.sid] = json; src_changed[d.sid] = true end
end

overlay_source.get_properties = function(d)
  local props = obs.obs_properties_create()
  local settings = d and d.source and obs.obs_source_get_settings(d.source)
  add_source_properties(props, settings)
  if settings then obs.obs_data_release(settings) end
  return props
end

overlay_source.get_width = function() return SRC_W end
overlay_source.get_height = function() return SRC_H end

overlay_source.video_render = function(d, effect)
  if d and d.browser then obs.obs_source_video_render(d.browser) end
end

overlay_source.show = function(d)
  if d and d.browser then obs.obs_source_inc_showing(d.browser); d.showing = d.showing + 1 end
end
overlay_source.hide = function(d)
  if d and d.browser and d.showing > 0 then obs.obs_source_dec_showing(d.browser); d.showing = d.showing - 1 end
end
overlay_source.activate = function(d)
  if d and d.browser then obs.obs_source_inc_active(d.browser); d.active = d.active + 1 end
end
overlay_source.deactivate = function(d)
  if d and d.browser and d.active > 0 then obs.obs_source_dec_active(d.browser); d.active = d.active - 1 end
end

------------------------------------------------------------------------------
-- OBS-Skript-Schnittstelle
------------------------------------------------------------------------------
function script_description()
  return [[<h3>Controller Overlay (Xbox, PS5 &amp; Switch 2)</h3>
<p>Zeigt den Controller mit allen Eingaben in Echtzeit – auch während ein Spiel im Vordergrund ist.</p>
<p><b>Einrichtung:</b> In der Szene bei <i>Quellen</i> auf <b>+</b> klicken und <b>Controller Overlay</b> wählen.
Aussehen und Controller stellst du in den Eigenschaften der Quelle ein – Änderungen wirken sofort.</p>
<p>Den Port musst du nur ändern, wenn das Skript-Protokoll meldet, dass er belegt ist.</p>]]
end

function script_properties()
  local props = obs.obs_properties_create()
  obs.obs_properties_add_int(props, "port", "Port", 1024, 65535, 1)
  return props
end

function script_defaults(settings)
  obs.obs_data_set_default_int(settings, "port", DEFAULT_PORT)
end

function script_update(settings)
  local port = obs.obs_data_get_int(settings, "port")
  if port ~= current_port then
    start_server(port)
    retarget_sources()
  end
end

function script_load(settings)
  local x = init_xinput()
  if x then log("XInput geladen: " .. x) else log("XInput konnte nicht geladen werden!") end
  start_server(obs.obs_data_get_int(settings, "port"))
  obs.obs_register_source(overlay_source)
  obs.timer_add(safe_tick, 10)
end

function script_unload()
  obs.timer_remove(safe_tick)
  while #ds_list > 0 do close_ds(ds_list[1]) end
  stop_server()
end

------------------------------------------------------------------------------
-- Overlay-Seite
------------------------------------------------------------------------------
HTML = [=====[<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<title>Controller Overlay</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root {
    --accent: #00e5ff;
    --body-hi: #4a4e55; --body-lo: #1a1b1e; --body-edge: #6b7078;
    --sh-hi: #3a3d43; --sh-lo: #17181b; --sh-edge: #777c84;
    --pt-hi: #34373c; --pt-lo: #060607; --pt-edge: #8a9098;
    --well: #070708; --well-edge: #2c2f34;
    --label: #e6e9ee; --sh-label: #e6e9ee;
    --abxy-hi: #2c2e32; --abxy-lo: #050505;
    --a: #5dc21e; --b: #e8322b; --x: #1f7fe0; --y: #f5c400;
    --tri: #3fd6b8; --cir: #ff4f6d; --crs: #6fa8ff; --sqr: #f58ad3;
  }
  :root[data-theme="white"] {
    --body-hi: #ffffff; --body-lo: #cfd1d4; --body-edge: #9a9ea4;
    --sh-hi: #fafafa; --sh-lo: #c4c7cb; --sh-edge: #8d9197;
    --well: #1b1c1f; --well-edge: #9a9ea4;
    --sh-label: #34373c;
    --abxy-hi: #ffffff; --abxy-lo: #d3d5d8;
  }
  html, body { margin: 0; height: 100%; background: transparent; overflow: hidden; }
  body { display: flex; align-items: center; justify-content: center; font-family: "Segoe UI", system-ui, sans-serif; }
  svg { width: 100vw; height: 100vh; display: block; shape-rendering: geometricPrecision; text-rendering: geometricPrecision; }

  .part  { fill: url(#gPart); stroke: var(--pt-edge); stroke-width: 1.6; filter: url(#shadow); }
  .shoulder .part { fill: url(#gShoulder); stroke: var(--sh-edge); }
  .face .part { fill: url(#gAbxy); stroke: var(--pt-edge); stroke-width: 1.4; }
  .lbl   { fill: var(--label); font-weight: 700; text-anchor: middle; dominant-baseline: central; pointer-events: none; }
  .shoulder .lbl { fill: var(--sh-label); }
  .ico   { fill: none; stroke: var(--label); stroke-width: 2.4; stroke-linecap: round; stroke-linejoin: round; pointer-events: none; }
  .well  { fill: var(--well); stroke: var(--well-edge); stroke-width: 1.5; }

  .on .part { fill: var(--accent); stroke: #fff; stroke-width: 2.2; filter: url(#glow); }
  .on .lbl { fill: #0b0b0b; }
  .on .ico { stroke: #0b0b0b; }

  /* Xbox-Tasten */
  .face.a .lbl { fill: var(--a); } .face.b .lbl { fill: var(--b); }
  .face.x .lbl { fill: var(--x); } .face.y .lbl { fill: var(--y); }
  /* Gedrückt: Leuchtfarbe wie alle Tasten; mit data-face="orig" in der Farbe des Controllers */
  .face.on .lbl { fill: #0b0b0b; }
  :root[data-face="orig"] .face.a.on .part { fill: var(--a); } :root[data-face="orig"] .face.b.on .part { fill: var(--b); }
  :root[data-face="orig"] .face.x.on .part { fill: var(--x); } :root[data-face="orig"] .face.y.on .part { fill: var(--y); }
  :root[data-face="orig"] .face.on .lbl { fill: #fff; }

  /* PS-Tasten */
  .sym { fill: none; stroke-width: 2.6; stroke-linecap: round; stroke-linejoin: round; pointer-events: none; }
  .face.tri .sym { stroke: var(--tri); } .face.cir .sym { stroke: var(--cir); }
  .face.crs .sym { stroke: var(--crs); } .face.sqr .sym { stroke: var(--sqr); }
  .face.on .sym { stroke: #0b0b0b; }
  :root[data-face="orig"] .face.tri.on .part { fill: var(--tri); } :root[data-face="orig"] .face.cir.on .part { fill: var(--cir); }
  :root[data-face="orig"] .face.crs.on .part { fill: var(--crs); } :root[data-face="orig"] .face.sqr.on .part { fill: var(--sqr); }
  :root[data-face="orig"] .face.on .sym { stroke: #fff; }

  /* Switch-2-Tasten */
  .face.n .lbl { fill: var(--label); }
  .face.n.on .lbl { fill: #0b0b0b; }

  .touch .part { fill: url(#gShoulder); stroke: var(--sh-edge); }
  .touch.on .part { fill: url(#gShoulder); stroke: var(--accent); stroke-width: 3; filter: url(#glow); }
  .touchpt { fill: var(--accent); stroke: #fff; stroke-width: 2; filter: url(#glow); display: none; }

  .trigfill { fill: var(--accent); opacity: .95; }
  .trig.on .part { fill: url(#gShoulder); stroke: #fff; filter: url(#glow); }
  .trig.on .lbl { fill: #fff; paint-order: stroke; stroke: #000; stroke-width: 3px; }

  .guide.on .part { fill: #ffffff; }
  .guide.on .ico { stroke: #111; }

  .layout { display: none; }
  #hint { fill: #fff; font-size: 20px; text-anchor: middle; opacity: .85; paint-order: stroke; stroke: #000; stroke-width: 4px; }
</style>
</head>
<body>
<svg viewBox="0 0 800 560" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <filter id="glow" x="-60%" y="-60%" width="220%" height="220%">
      <feGaussianBlur stdDeviation="6" result="b"/>
      <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
    <filter id="shadow" x="-30%" y="-30%" width="160%" height="170%">
      <feDropShadow dx="0" dy="3" stdDeviation="2.5" flood-color="#000" flood-opacity=".7"/>
    </filter>
    <filter id="bodyShadow" x="-10%" y="-10%" width="120%" height="125%">
      <feDropShadow dx="0" dy="8" stdDeviation="8" flood-color="#000" flood-opacity=".55"/>
    </filter>
    <radialGradient id="gBody" cx="50%" cy="30%" r="75%">
      <stop offset="0" style="stop-color:var(--body-hi)"/>
      <stop offset="1" style="stop-color:var(--body-lo)"/>
    </radialGradient>
    <linearGradient id="gShine" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity=".18"/>
      <stop offset=".35" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="gShoulder" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" style="stop-color:var(--sh-hi)"/>
      <stop offset="1" style="stop-color:var(--sh-lo)"/>
    </linearGradient>
    <radialGradient id="gPart" cx="40%" cy="30%" r="80%">
      <stop offset="0" style="stop-color:var(--pt-hi)"/>
      <stop offset="1" style="stop-color:var(--pt-lo)"/>
    </radialGradient>
    <radialGradient id="gAbxy" cx="40%" cy="30%" r="80%">
      <stop offset="0" style="stop-color:var(--abxy-hi)"/>
      <stop offset="1" style="stop-color:var(--abxy-lo)"/>
    </radialGradient>
    <radialGradient id="gWell" cx="50%" cy="60%" r="60%">
      <stop offset="0" stop-color="#000" stop-opacity="0"/>
      <stop offset=".8" stop-color="#000" stop-opacity="0"/>
      <stop offset="1" stop-color="#000" stop-opacity=".8"/>
    </radialGradient>
    <clipPath id="clipLT"><rect x="150" y="18" width="130" height="58" rx="18"/></clipPath>
    <clipPath id="clipRT"><rect x="520" y="18" width="130" height="58" rx="18"/></clipPath>
    <path id="xboxBody" d="M250 118 C180 118 122 138 96 200 C60 290 28 420 54 482 C74 528 132 532 166 492 C200 452 232 402 292 397 L508 397 C568 402 600 452 634 492 C668 532 726 528 746 482 C772 420 740 290 704 200 C678 138 620 118 550 118 C500 118 470 134 400 134 C330 134 300 118 250 118 Z"/>
    <path id="nsBody" d="M236 122 C172 122 122 142 98 200 C62 290 30 420 56 482 C76 528 134 532 168 492 C202 452 234 404 294 399 L506 399 C566 404 598 452 632 492 C666 532 724 528 744 482 C770 420 738 290 702 200 C678 142 628 122 564 122 L236 122 Z"/>
    <path id="psBody" d="M175 126 C125 126 98 156 88 198 C68 280 40 400 58 472 C72 524 136 532 168 490 C198 450 218 410 262 402 L538 402 C582 410 602 450 632 490 C664 532 728 524 742 472 C760 400 732 280 712 198 C702 156 675 126 625 126 L566 126 C548 126 540 136 522 136 L278 136 C260 136 252 126 234 126 Z"/>
  </defs>

  <!-- ============================ XBOX ============================ -->
  <g id="xbox" class="layout">
    <g class="shoulder trig lt">
      <rect class="part" x="150" y="18" width="130" height="58" rx="18"/>
      <rect class="trigfill" x="150" y="76" width="130" height="0" clip-path="url(#clipLT)"/>
      <text class="lbl" x="215" y="47" font-size="22">LT</text>
    </g>
    <g class="shoulder trig rt">
      <rect class="part" x="520" y="18" width="130" height="58" rx="18"/>
      <rect class="trigfill" x="520" y="76" width="130" height="0" clip-path="url(#clipRT)"/>
      <text class="lbl" x="585" y="47" font-size="22">RT</text>
    </g>
    <g class="btn shoulder" data-i="4">
      <path class="part" d="M118 130 C138 98 190 84 250 84 L320 86 C332 86 336 96 331 104 L322 118 C300 114 260 112 230 114 C180 118 145 128 118 130 Z"/>
      <text class="lbl" x="235" y="100" font-size="16">LB</text>
    </g>
    <g class="btn shoulder" data-i="5">
      <path class="part" d="M682 130 C662 98 610 84 550 84 L480 86 C468 86 464 96 469 104 L478 118 C500 114 540 112 570 114 C620 118 655 128 682 130 Z"/>
      <text class="lbl" x="565" y="100" font-size="16">RB</text>
    </g>

    <use href="#xboxBody" fill="url(#gBody)" stroke="var(--body-edge)" stroke-width="3" filter="url(#bodyShadow)"/>
    <use href="#xboxBody" fill="url(#gShine)"/>

    <circle class="well" cx="230" cy="232" r="52"/><circle cx="230" cy="232" r="52" fill="url(#gWell)"/>
    <circle class="well" cx="492" cy="330" r="48"/><circle cx="492" cy="330" r="48" fill="url(#gWell)"/>
    <circle class="well" cx="308" cy="330" r="52"/><circle cx="308" cy="330" r="52" fill="url(#gWell)"/>

    <g class="btn guide" data-i="16">
      <circle class="part" cx="400" cy="178" r="26"/>
      <circle class="ico" cx="400" cy="178" r="13" stroke-width="3"/>
      <path class="ico" d="M393 171 l14 14 M407 171 l-14 14" stroke-width="2.6"/>
    </g>
    <g class="btn" data-i="8">
      <circle class="part" cx="345" cy="238" r="15"/>
      <rect class="ico" x="337" y="231" width="11" height="9" rx="1.5" stroke-width="2"/>
      <rect class="ico" x="342" y="235" width="11" height="9" rx="1.5" stroke-width="2"/>
    </g>
    <g class="btn" data-i="9">
      <circle class="part" cx="455" cy="238" r="15"/>
      <path class="ico" d="M447 232h16M447 238h16M447 244h16"/>
    </g>
    <g class="btn" data-i="17">
      <rect class="part" x="388" y="261" width="24" height="14" rx="7"/>
      <path class="ico" d="M400 265 v6 M397 268 l3 -3 l3 3" stroke-width="1.6"/>
    </g>

    <g class="btn" data-i="10">
      <g class="ls">
        <circle class="part" cx="230" cy="232" r="36"/>
        <circle cx="230" cy="232" r="25" fill="none" stroke="#000" stroke-opacity=".6" stroke-width="3"/>
        <circle cx="230" cy="232" r="25" fill="none" stroke="var(--pt-edge)" stroke-opacity=".5" stroke-width="1"/>
        <text class="lbl" x="230" y="232" font-size="14">LS</text>
      </g>
    </g>
    <g class="btn" data-i="11">
      <g class="rs">
        <circle class="part" cx="492" cy="330" r="33"/>
        <circle cx="492" cy="330" r="23" fill="none" stroke="#000" stroke-opacity=".6" stroke-width="3"/>
        <circle cx="492" cy="330" r="23" fill="none" stroke="var(--pt-edge)" stroke-opacity=".5" stroke-width="1"/>
        <text class="lbl" x="492" y="330" font-size="14">RS</text>
      </g>
    </g>

    <g class="btn" data-i="12"><path class="part" d="M296 288 h24 v30 l-12 12 l-12 -12 Z"/><path class="ico" d="M302 304 l6 -7 l6 7"/></g>
    <g class="btn" data-i="13"><path class="part" d="M296 372 h24 v-30 l-12 -12 l-12 12 Z"/><path class="ico" d="M302 356 l6 7 l6 -7"/></g>
    <g class="btn" data-i="14"><path class="part" d="M266 318 v24 h30 l12 -12 l-12 -12 Z"/><path class="ico" d="M282 324 l-7 6 l7 6"/></g>
    <g class="btn" data-i="15"><path class="part" d="M350 318 v24 h-30 l-12 -12 l12 -12 Z"/><path class="ico" d="M334 324 l7 6 l-7 6"/></g>

    <g class="btn face y" data-i="3"><circle class="part" cx="570" cy="186" r="23"/><text class="lbl" x="570" y="187" font-size="23">Y</text></g>
    <g class="btn face b" data-i="1"><circle class="part" cx="616" cy="232" r="23"/><text class="lbl" x="616" y="233" font-size="23">B</text></g>
    <g class="btn face x" data-i="2"><circle class="part" cx="524" cy="232" r="23"/><text class="lbl" x="524" y="233" font-size="23">X</text></g>
    <g class="btn face a" data-i="0"><circle class="part" cx="570" cy="278" r="23"/><text class="lbl" x="570" y="279" font-size="23">A</text></g>
  </g>

  <!-- ============================= PS5 ============================= -->
  <g id="ps" class="layout">
    <g class="shoulder trig lt">
      <rect class="part" x="150" y="18" width="130" height="58" rx="18"/>
      <rect class="trigfill" x="150" y="76" width="130" height="0" clip-path="url(#clipLT)"/>
      <text class="lbl" x="215" y="47" font-size="22">L2</text>
    </g>
    <g class="shoulder trig rt">
      <rect class="part" x="520" y="18" width="130" height="58" rx="18"/>
      <rect class="trigfill" x="520" y="76" width="130" height="0" clip-path="url(#clipRT)"/>
      <text class="lbl" x="585" y="47" font-size="22">R2</text>
    </g>
    <g class="btn shoulder" data-i="4">
      <path class="part" d="M112 134 C128 100 172 88 230 88 L278 90 C290 90 293 99 289 107 L281 122 C258 118 230 116 206 118 C166 122 138 131 112 134 Z"/>
      <text class="lbl" x="208" y="103" font-size="16">L1</text>
    </g>
    <g class="btn shoulder" data-i="5">
      <path class="part" d="M688 134 C672 100 628 88 570 88 L522 90 C510 90 507 99 511 107 L519 122 C542 118 570 116 594 118 C634 122 662 131 688 134 Z"/>
      <text class="lbl" x="592" y="103" font-size="16">R1</text>
    </g>

    <use href="#psBody" fill="url(#gBody)" stroke="var(--body-edge)" stroke-width="3" filter="url(#bodyShadow)"/>
    <use href="#psBody" fill="url(#gShine)"/>

    <!-- Touchpad (Klick = Taste 17) mit Fingerpositionen -->
    <g class="btn touch" data-i="17">
      <path class="part" d="M292 140 L508 140 Q518 140 517 150 L509 236 Q507 250 493 250 L307 250 Q293 250 291 236 L283 150 Q282 140 292 140 Z"/>
    </g>
    <circle class="touchpt" r="10" cx="0" cy="0"/>
    <circle class="touchpt" r="10" cx="0" cy="0"/>

    <circle class="well" cx="195" cy="245" r="54"/><circle cx="195" cy="245" r="54" fill="url(#gWell)"/>
    <circle class="well" cx="298" cy="335" r="48"/><circle cx="298" cy="335" r="48" fill="url(#gWell)"/>
    <circle class="well" cx="502" cy="335" r="48"/><circle cx="502" cy="335" r="48" fill="url(#gWell)"/>

    <!-- Create / Options -->
    <g class="btn" data-i="8"><rect class="part" x="254" y="146" width="13" height="27" rx="6.5"/></g>
    <g class="btn" data-i="9"><rect class="part" x="533" y="146" width="13" height="27" rx="6.5"/></g>

    <!-- PS-Taste und Stummschalten -->
    <g class="btn guide" data-i="16">
      <circle class="part" cx="400" cy="318" r="17"/>
      <circle class="ico" cx="400" cy="318" r="7" stroke-width="2.4"/>
    </g>
    <g class="btn" data-i="18">
      <rect class="part" x="386" y="350" width="28" height="11" rx="5.5"/>
    </g>

    <!-- Steuerkreuz (vier einzelne Tasten) -->
    <g class="btn" data-i="12"><path class="part" d="M182 202 h26 v22 l-13 13 l-13 -13 Z"/><path class="ico" d="M189 216 l6 -6 l6 6"/></g>
    <g class="btn" data-i="13"><path class="part" d="M182 288 h26 v-22 l-13 -13 l-13 13 Z"/><path class="ico" d="M189 274 l6 6 l6 -6"/></g>
    <g class="btn" data-i="14"><path class="part" d="M152 232 v26 h22 l13 -13 l-13 -13 Z"/><path class="ico" d="M166 239 l-6 6 l6 6"/></g>
    <g class="btn" data-i="15"><path class="part" d="M238 232 v26 h-22 l-13 -13 l13 -13 Z"/><path class="ico" d="M224 239 l6 6 l-6 6"/></g>

    <!-- Sticks -->
    <g class="btn" data-i="10">
      <g class="ls">
        <circle class="part" cx="298" cy="335" r="33"/>
        <circle cx="298" cy="335" r="23" fill="none" stroke="#000" stroke-opacity=".6" stroke-width="3"/>
        <circle cx="298" cy="335" r="23" fill="none" stroke="var(--pt-edge)" stroke-opacity=".5" stroke-width="1"/>
        <text class="lbl" x="298" y="335" font-size="14">L3</text>
      </g>
    </g>
    <g class="btn" data-i="11">
      <g class="rs">
        <circle class="part" cx="502" cy="335" r="33"/>
        <circle cx="502" cy="335" r="23" fill="none" stroke="#000" stroke-opacity=".6" stroke-width="3"/>
        <circle cx="502" cy="335" r="23" fill="none" stroke="var(--pt-edge)" stroke-opacity=".5" stroke-width="1"/>
        <text class="lbl" x="502" y="335" font-size="14">R3</text>
      </g>
    </g>

    <!-- Symboltasten -->
    <g class="btn face tri" data-i="3"><circle class="part" cx="605" cy="200" r="23"/><path class="sym" d="M605 189 L615.5 207 L594.5 207 Z"/></g>
    <g class="btn face cir" data-i="1"><circle class="part" cx="651" cy="245" r="23"/><circle class="sym" cx="651" cy="245" r="10"/></g>
    <g class="btn face crs" data-i="0"><circle class="part" cx="605" cy="290" r="23"/><path class="sym" d="M597 282 l16 16 M613 282 l-16 16"/></g>
    <g class="btn face sqr" data-i="2"><circle class="part" cx="559" cy="245" r="23"/><rect class="sym" x="550" y="236" width="18" height="18" rx="1"/></g>
  </g>

  <!-- ======================= NINTENDO SWITCH 2 ======================= -->
  <g id="ns" class="layout">
    <g class="shoulder trig lt">
      <rect class="part" x="150" y="18" width="130" height="58" rx="18"/>
      <rect class="trigfill" x="150" y="76" width="130" height="0" clip-path="url(#clipLT)"/>
      <text class="lbl" x="215" y="47" font-size="22">ZL</text>
    </g>
    <g class="shoulder trig rt">
      <rect class="part" x="520" y="18" width="130" height="58" rx="18"/>
      <rect class="trigfill" x="520" y="76" width="130" height="0" clip-path="url(#clipRT)"/>
      <text class="lbl" x="585" y="47" font-size="22">ZR</text>
    </g>
    <g class="btn shoulder" data-i="4">
      <path class="part" d="M118 132 C136 100 184 88 240 88 L318 89 C330 89 334 99 329 107 L320 121 C298 117 262 115 232 117 C182 121 146 130 118 132 Z"/>
      <text class="lbl" x="232" y="103" font-size="16">L</text>
    </g>
    <g class="btn shoulder" data-i="5">
      <path class="part" d="M682 132 C664 100 616 88 560 88 L482 89 C470 89 466 99 471 107 L480 121 C502 117 538 115 568 117 C618 121 654 130 682 132 Z"/>
      <text class="lbl" x="568" y="103" font-size="16">R</text>
    </g>

    <use href="#nsBody" fill="url(#gBody)" stroke="var(--body-edge)" stroke-width="3" filter="url(#bodyShadow)"/>
    <use href="#nsBody" fill="url(#gShine)"/>

    <circle class="well" cx="230" cy="232" r="52"/><circle cx="230" cy="232" r="52" fill="url(#gWell)"/>
    <circle class="well" cx="492" cy="330" r="48"/><circle cx="492" cy="330" r="48" fill="url(#gWell)"/>
    <circle class="well" cx="308" cy="330" r="52"/><circle cx="308" cy="330" r="52" fill="url(#gWell)"/>

    <!-- Minus / Plus -->
    <g class="btn" data-i="8"><circle class="part" cx="338" cy="180" r="14"/><path class="ico" d="M331 180 h14"/></g>
    <g class="btn" data-i="9"><circle class="part" cx="462" cy="180" r="14"/><path class="ico" d="M455 180 h14 M462 173 v14"/></g>
    <!-- Aufnahme / HOME / C -->
    <g class="btn" data-i="17"><rect class="part" x="340" y="220" width="24" height="24" rx="5"/><circle class="ico" cx="352" cy="232" r="5.5" stroke-width="2.2"/></g>
    <g class="btn guide" data-i="16">
      <circle class="part" cx="448" cy="232" r="17"/>
      <path class="ico" d="M440 233 l8 -8 l8 8 M442.5 231 v8 h11 v-8" stroke-width="2.2"/>
    </g>
    <g class="btn" data-i="18"><circle class="part" cx="400" cy="276" r="14"/><text class="lbl" x="400" y="277" font-size="15">C</text></g>

    <g class="btn" data-i="10">
      <g class="ls">
        <circle class="part" cx="230" cy="232" r="36"/>
        <circle cx="230" cy="232" r="25" fill="none" stroke="#000" stroke-opacity=".6" stroke-width="3"/>
        <circle cx="230" cy="232" r="25" fill="none" stroke="var(--pt-edge)" stroke-opacity=".5" stroke-width="1"/>
        <text class="lbl" x="230" y="232" font-size="14">LS</text>
      </g>
    </g>
    <g class="btn" data-i="11">
      <g class="rs">
        <circle class="part" cx="492" cy="330" r="33"/>
        <circle cx="492" cy="330" r="23" fill="none" stroke="#000" stroke-opacity=".6" stroke-width="3"/>
        <circle cx="492" cy="330" r="23" fill="none" stroke="var(--pt-edge)" stroke-opacity=".5" stroke-width="1"/>
        <text class="lbl" x="492" y="330" font-size="14">RS</text>
      </g>
    </g>

    <g class="btn" data-i="12"><path class="part" d="M296 288 h24 v30 l-12 12 l-12 -12 Z"/><path class="ico" d="M302 304 l6 -7 l6 7"/></g>
    <g class="btn" data-i="13"><path class="part" d="M296 372 h24 v-30 l-12 -12 l-12 12 Z"/><path class="ico" d="M302 356 l6 7 l6 -7"/></g>
    <g class="btn" data-i="14"><path class="part" d="M266 318 v24 h30 l12 -12 l-12 -12 Z"/><path class="ico" d="M282 324 l-7 6 l7 6"/></g>
    <g class="btn" data-i="15"><path class="part" d="M350 318 v24 h-30 l-12 -12 l12 -12 Z"/><path class="ico" d="M334 324 l7 6 l-7 6"/></g>

    <!-- Nintendo-Anordnung: X oben, A rechts, B unten, Y links -->
    <g class="btn face n" data-i="3"><circle class="part" cx="570" cy="186" r="23"/><text class="lbl" x="570" y="187" font-size="23">X</text></g>
    <g class="btn face n" data-i="1"><circle class="part" cx="616" cy="232" r="23"/><text class="lbl" x="616" y="233" font-size="23">A</text></g>
    <g class="btn face n" data-i="2"><circle class="part" cx="524" cy="232" r="23"/><text class="lbl" x="524" y="233" font-size="23">Y</text></g>
    <g class="btn face n" data-i="0"><circle class="part" cx="570" cy="278" r="23"/><text class="lbl" x="570" y="279" font-size="23">B</text></g>

    <!-- Rücktasten GL / GR -->
    <g class="btn" data-i="19"><rect class="part" x="82" y="432" width="48" height="24" rx="12"/><text class="lbl" x="106" y="444" font-size="13">GL</text></g>
    <g class="btn" data-i="20"><rect class="part" x="670" y="432" width="48" height="24" rx="12"/><text class="lbl" x="694" y="444" font-size="13">GR</text></g>
  </g>

  <text id="hint" x="400" y="548">Controller verbinden &amp; eine Taste drücken …</text>
</svg>

<script>
(() => {
  const q = new URLSearchParams(location.search);
  const hex = v => /^[0-9a-f]{3,8}$/i.test(v || '') ? '#' + v : null;
  const root = document.documentElement;
  if (q.get('theme') === 'white') root.dataset.theme = 'white';
  if (hex(q.get('accent'))) root.style.setProperty('--accent', hex(q.get('accent')));
  if (hex(q.get('bg')))     document.body.style.background = hex(q.get('bg'));
  if (q.get('face') === 'orig') root.dataset.face = 'orig';
  const padIdx = q.has('pad') ? parseInt(q.get('pad'), 10) : null;
  let showHint = q.get('hint') !== '0';
  let layoutPref = q.get('layout') || 'auto';
  const DZ = parseFloat(q.get('dz')) || 0.12;
  // Deckkraft des ganzen Overlays in Prozent (10–100)
  const svgEl = document.querySelector('svg');
  const setOpacity = v => { v = Math.min(100, Math.max(10, Number(v) || 100)); svgEl.style.opacity = v / 100; };
  if (q.has('opacity')) setOpacity(q.get('opacity'));
  const STICK_RANGE = 18;
  const BTN_THRESHOLD = 0.1;

  // Einstellungen aus den Quellen-Eigenschaften (URL-Parameter haben Vorrang)
  function applyConfig(c) {
    if (!q.has('face')) { if (c.facecolors) root.dataset.face = 'orig'; else delete root.dataset.face; }
    if (!q.has('theme')) { if (c.theme === 'white') root.dataset.theme = 'white'; else delete root.dataset.theme; }
    if (!q.has('accent') && /^#[0-9a-f]{6}$/i.test(c.accent || '')) root.style.setProperty('--accent', c.accent);
    if (!q.has('hint')) showHint = c.hint !== false;
    if (!q.has('opacity') && c.opacity !== undefined) setOpacity(c.opacity);
    if (!q.has('layout') && c.layout) layoutPref = c.layout;
    if (c.pad) padPref = c.pad;
  }
  let padPref = 'auto';

  // "Automatisch": der Controller, an dem zuletzt etwas gedrückt/bewegt wurde
  let lastActiveId = null;
  const prevSig = {};
  function signature(r) {
    let s = '';
    for (let k = 0; k < r.b.length; k++) s += r.b[k] > 0.5 ? '1' : '0';
    for (const a of r.a) s += a > 0.5 ? '+' : a < -0.5 ? '-' : '0';
    return s + (r.tp ? r.tp.length : 0);
  }
  function trackActivity(pads) {
    for (const r of pads) {
      const sig = signature(r);
      const idle = !/[1+\-]/.test(sig.slice(0, -1)) && sig.slice(-1) === '0';
      if (prevSig[r.id] !== undefined && sig !== prevSig[r.id] && !idle) lastActiveId = r.id;
      prevSig[r.id] = sig;
    }
  }
  function pickRemote(pads) {
    if (padIdx !== null) return pads.find(p => p.i === padIdx);
    if (padPref !== 'auto') {
      const fixed = pads.find(p => p.id === padPref);
      if (fixed) return fixed;
    }
    return pads.find(p => p.id === lastActiveId) || pads[0];
  }

  // Daten vom OBS-Skript (funktioniert auch, wenn das Spiel im Vordergrund ist)
  let remote = null, remoteOK = false;
  if (location.protocol.startsWith('http')) {
    const sid = /^\w+$/.test(q.get('sid') || '') ? q.get('sid') : '';
    const es = new EventSource('/events' + (sid ? '?sid=' + sid : ''));
    es.onmessage = e => { try { remote = JSON.parse(e.data); remoteOK = true; trackActivity(remote.pads || []); } catch (_) {} };
    const BUILD = '__BUILD__';
    es.addEventListener('build', e => { if (e.data !== BUILD) location.reload(); });
    es.addEventListener('config', e => { try { applyConfig(JSON.parse(e.data)); } catch (_) {} });
    es.onerror = () => { remoteOK = false; };
  }

  // Elemente je Layout
  const layouts = {};
  for (const id of ['xbox', 'ps', 'ns']) {
    const g = document.getElementById(id);
    const L = {
      id, g, btn: {},
      ls: g.querySelector('.ls'), rs: g.querySelector('.rs'),
      ltg: g.querySelector('.lt'), rtg: g.querySelector('.rt'),
      touch: Array.from(g.querySelectorAll('.touchpt')),
    };
    L.ltf = L.ltg.querySelector('.trigfill');
    L.rtf = L.rtg.querySelector('.trigfill');
    g.querySelectorAll('.btn').forEach(el => L.btn[el.dataset.i] = el);
    layouts[id] = L;
  }
  const hint = document.getElementById('hint');

  let active = null;
  let state = {};
  function setLayout(id) {
    if (active === layouts[id]) return;
    for (const k in layouts) {
      layouts[k].g.style.display = k === id ? 'inline' : 'none';
      layouts[k].g.querySelectorAll('.on').forEach(el => el.classList.remove('on'));
    }
    active = layouts[id];
    state = {};
  }

  const dz = v => Math.abs(v) < DZ ? 0 : (v - Math.sign(v) * DZ) / (1 - DZ);
  function setOn(key, el, on) {
    if (state[key] === on) return;
    state[key] = on;
    el.classList.toggle('on', on);
  }
  function setTrigger(fill, g, key, v) {
    const h = Math.round(58 * v);
    fill.setAttribute('y', 76 - h);
    fill.setAttribute('height', h);
    setOn(key, g, v > BTN_THRESHOLD);
  }
  function moveStick(el, x, y) {
    el.setAttribute('transform', `translate(${(dz(x) * STICK_RANGE).toFixed(1)} ${(dz(y) * STICK_RANGE).toFixed(1)})`);
  }

  const isPsId = id => /054c|dualsense|wireless controller/i.test(id || '');
  const isNsId = id => /057e|nintendo|pro controller/i.test(id || '');
  function getPad() {
    if (remoteOK && remote && remote.pads) {
      const r = pickRemote(remote.pads);
      if (r) return { type: r.t, buttons: r.b.map(v => ({ pressed: v > 0.5, value: v })), axes: r.a, tp: r.tp || [] };
    }
    // Rückfall: Gamepad-API des Browsers (nur solange OBS aktiv ist)
    const pads = navigator.getGamepads ? navigator.getGamepads() : [];
    let p = null;
    if (padIdx !== null) p = pads[padIdx] || null;
    else for (const x of pads) if (x && x.connected) { p = x; break; }
    if (!p) return null;
    return { type: isPsId(p.id) ? 'ps' : isNsId(p.id) ? 'ns' : 'xbox', buttons: Array.from(p.buttons), axes: Array.from(p.axes), tp: [] };
  }

  function loop() {
    const p = getPad();
    let want;
    if (layouts[layoutPref]) want = layoutPref;                                  // fest eingestellt
    else if (p) want = layouts[p.type] ? p.type : 'xbox';                        // passend zum Controller
    else want = active ? active.id : 'xbox';                                     // kein Controller: bleiben
    setLayout(want);
    const L = active;
    if (p) {
      hint.style.display = 'none';
      p.buttons.forEach((b, i) => {
        if (i === 6 || i === 7) return;
        const el = L.btn[i];
        if (el) setOn('b' + i, el, b.pressed || b.value > BTN_THRESHOLD);
      });
      setTrigger(L.ltf, L.ltg, 'lt', p.buttons[6] ? p.buttons[6].value : 0);
      setTrigger(L.rtf, L.rtg, 'rt', p.buttons[7] ? p.buttons[7].value : 0);
      moveStick(L.ls, p.axes[0] || 0, p.axes[1] || 0);
      moveStick(L.rs, p.axes[2] || 0, p.axes[3] || 0);
      L.touch.forEach((c, k) => {
        const t = p.tp[k];
        if (t) {
          c.setAttribute('cx', (292 + t[0] * 216).toFixed(1));
          c.setAttribute('cy', (143 + t[1] * 104).toFixed(1));
          c.style.display = 'inline';
        } else c.style.display = 'none';
      });
    } else {
      hint.style.display = showHint ? '' : 'none';
      L.touch.forEach(c => c.style.display = 'none');
    }
    requestAnimationFrame(loop);
  }
  requestAnimationFrame(loop);
})();
</script>
</body>
</html>
]=====]
