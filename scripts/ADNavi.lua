local MOD_DIRECTORY = g_currentModDirectory

-- ---------------------------------------------------------------------------
-- Write a 4×4 white DXT1 DDS so createImageOverlay gets an actual white quad.
-- DXT1 is the compressed format GIANTS Engine expects; uncompressed is rejected.
-- The file is (re-)written every map load so a corrupt file from a previous run
-- is automatically replaced.
-- ---------------------------------------------------------------------------
local WHITE_DDS      = MOD_DIRECTORY .. "gui/white.dds"
local overlayFailed  = false   -- set to true once if createImageOverlay fails
                                -- so we never spam the error log again

local function writeWhiteDDS()
    local f = io.open(WHITE_DDS, "wb")
    if f == nil then
        Logging.warning("[ADNavi] Cannot write white.dds (no write access) - minimap lines disabled.")
        overlayFailed = true
        return
    end

    -- Writes a DWORD (4 bytes) in little-endian
    local function dw(n)
        f:write(string.char(
            n                       % 256,
            math.floor(n / 0x100)   % 256,
            math.floor(n / 0x10000) % 256,
            math.floor(n / 0x1000000) % 256))
    end

    -- DDS magic (4) + DDSURFACEDESC2 (124) = 128 bytes header
    f:write("DDS ")
    dw(124)           -- dwSize
    dw(0x81007)       -- dwFlags: CAPS|HEIGHT|WIDTH|PIXELFORMAT|LINEARSIZE (DXT)
    dw(4)             -- dwHeight (minimum 4 for DXT1 blocks)
    dw(4)             -- dwWidth
    dw(8)             -- dwPitchOrLinearSize = 8 bytes per DXT1 4×4 block
    dw(0)             -- dwDepth
    dw(1)             -- dwMipMapCount
    for _ = 1, 11 do dw(0) end   -- dwReserved[11]
    -- DDPIXELFORMAT (32 bytes)
    dw(32)            -- ddpf.dwSize
    dw(0x4)           -- ddpf.dwFlags: DDPF_FOURCC
    f:write("DXT1")   -- ddpf.dwFourCC = "DXT1"
    dw(0)             -- ddpf.dwRGBBitCount (unused for FourCC)
    dw(0); dw(0); dw(0); dw(0)   -- R/G/B/A bit masks (unused)
    -- DDSCAPS2 (16 bytes) + dwReserved2 (4 bytes)
    dw(0x1000)        -- ddsCaps.dwCaps1: DDSCAPS_TEXTURE
    dw(0); dw(0); dw(0); dw(0)   -- dwCaps2/3/4 + dwReserved2
    -- DXT1 block: 4×4 white pixels
    --   color0 = 0xFFFF (RGB565 white), color1 = 0x0000
    --   lookup table = 0x00000000 → all 16 pixels use color0 = white
    f:write(string.char(0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00))
    f:close()
    Logging.info("[ADNavi] Wrote white DXT1 DDS: %s", WHITE_DDS)
end

-- ============================================================
-- Settings state
-- ============================================================
local cfg = {
    mapEnabled   = true,
    mapColorIdx  = 1,
    mapLookIdx   = 12,  -- default: Full (index 12 in MAP_LOOK)
    mapThickIdx  = 2,   -- default: 3px  (index 2 in MAP_THICK)
    roadEnabled  = true,
    roadColorIdx = 1,
    roadLenIdx   = 5,   -- default: 300m (index 5 in ROAD_LEN)
    roadThickIdx = 3,   -- default: 3 lines (index 3 in ROAD_THICK_COUNTS)
    roadStartIdx = 1,   -- default: 0m   (index 1 in ROAD_START)
}

-- Shared color palette for both minimap and road line.
-- Pure RGB primaries so both drawDebugLine and overlay rendering are unambiguous.
local COLORS = {
    {key="adnavi_color_red",   r=1.0, g=0.0, b=0.0},
    {key="adnavi_color_green", r=0.0, g=1.0, b=0.0},
    {key="adnavi_color_blue",  r=0.0, g=0.0, b=1.0},
    {key="adnavi_color_white", r=1.0, g=1.0, b=1.0},
}

-- Minimap lookahead: last entry is math.huge (= "Full")
local MAP_LOOK = {100,150,200,250,300,350,400,450,500,550,600,math.huge}
local MAP_LOOK_K = {}
for _, v in ipairs(MAP_LOOK) do
    MAP_LOOK_K[#MAP_LOOK_K+1] = (v == math.huge) and "adnavi_vis_full"
                                                   or ("adnavi_vis_" .. v .. "m")
end

-- Minimap line thickness in pixels (starts at 2, 1px was too thin)
local MAP_THICK  = {2, 3, 4, 5, 6}
local MAP_THICK_K = {}
for _, v in ipairs(MAP_THICK) do
    MAP_THICK_K[#MAP_THICK_K+1] = "adnavi_thick_" .. v .. "px"
end

-- Road line length ahead
local ROAD_LEN   = {50, 100, 150, 200, 300, 500}
local ROAD_LEN_K = {}
for _, v in ipairs(ROAD_LEN) do
    ROAD_LEN_K[#ROAD_LEN_K+1] = "adnavi_road_len_" .. v .. "m"
end

-- Road line count (visual width); 1-2-3 single-gap variants + 5 and 9 band variants
local ROAD_THICK_COUNTS = {1, 2, 3, 5, 9}
local ROAD_THICK_K      = {}
for _, v in ipairs(ROAD_THICK_COUNTS) do
    ROAD_THICK_K[#ROAD_THICK_K+1] = "adnavi_road_lines_" .. v
end
-- All line-count variants are spread evenly across this fixed total width.
-- 1 line → single centred; 2 lines → -0.10/+0.10; 5 lines → -0.10…+0.10; etc.
local ROAD_TOTAL_WIDTH = 0.20   -- metres

-- Road line start offset (metres skipped ahead of current waypoint)
local ROAD_START   = {0, 5, 10, 20, 30, 50}
local ROAD_START_K = {}
for _, v in ipairs(ROAD_START) do
    ROAD_START_K[#ROAD_START_K+1] = "adnavi_road_start_" .. v .. "m"
end

-- ============================================================
-- Settings persistence (XML, stored in user profile modSettings folder)
-- Must be declared AFTER all cfg / lookup-table locals so the closures
-- can capture them correctly.
-- ============================================================
local SETTINGS_FILE = nil   -- absolute path; set in ADNavi.onLoadMap

local function loadSettings()
    if SETTINGS_FILE == nil then return end
    local xmlFile = XMLFile.loadIfExists("ADNaviSettings", SETTINGS_FILE, "adnavi")
    if xmlFile == nil then return end   -- file simply doesn't exist yet

    local function clampIdx(val, arr)
        if val == nil then return nil end
        val = math.floor(val + 0.5)
        if val < 1 or val > #arr then return nil end
        return val
    end

    local b
    b = xmlFile:getBool("adnavi.minimap#enabled", nil)
    if b ~= nil then cfg.mapEnabled = b end
    local v = clampIdx(xmlFile:getInt("adnavi.minimap#colorIdx", nil), COLORS)
    if v then cfg.mapColorIdx = v end
    v = clampIdx(xmlFile:getInt("adnavi.minimap#thickIdx", nil), MAP_THICK)
    if v then cfg.mapThickIdx = v end
    v = clampIdx(xmlFile:getInt("adnavi.minimap#lookIdx",  nil), MAP_LOOK)
    if v then cfg.mapLookIdx  = v end

    b = xmlFile:getBool("adnavi.road#enabled", nil)
    if b ~= nil then cfg.roadEnabled = b end
    v = clampIdx(xmlFile:getInt("adnavi.road#colorIdx", nil), COLORS)
    if v then cfg.roadColorIdx = v end
    v = clampIdx(xmlFile:getInt("adnavi.road#lenIdx",   nil), ROAD_LEN)
    if v then cfg.roadLenIdx   = v end
    v = clampIdx(xmlFile:getInt("adnavi.road#thickIdx", nil), ROAD_THICK_COUNTS)
    if v then cfg.roadThickIdx = v end
    v = clampIdx(xmlFile:getInt("adnavi.road#startIdx", nil), ROAD_START)
    if v then cfg.roadStartIdx = v end

    xmlFile:delete()
    Logging.info("[ADNavi] Settings loaded from %s", SETTINGS_FILE)
end

local function saveSettings()
    if SETTINGS_FILE == nil then return end
    local xmlFile = XMLFile.create("ADNaviSettings", SETTINGS_FILE, "adnavi")
    if xmlFile == nil then
        Logging.warning("[ADNavi] Cannot create settings file: %s", SETTINGS_FILE)
        return
    end

    xmlFile:setBool("adnavi.minimap#enabled",  cfg.mapEnabled)
    xmlFile:setInt( "adnavi.minimap#colorIdx", cfg.mapColorIdx)
    xmlFile:setInt( "adnavi.minimap#thickIdx", cfg.mapThickIdx)
    xmlFile:setInt( "adnavi.minimap#lookIdx",  cfg.mapLookIdx)

    xmlFile:setBool("adnavi.road#enabled",     cfg.roadEnabled)
    xmlFile:setInt( "adnavi.road#colorIdx",    cfg.roadColorIdx)
    xmlFile:setInt( "adnavi.road#lenIdx",      cfg.roadLenIdx)
    xmlFile:setInt( "adnavi.road#thickIdx",    cfg.roadThickIdx)
    xmlFile:setInt( "adnavi.road#startIdx",    cfg.roadStartIdx)

    xmlFile:save()
    xmlFile:delete()
    Logging.info("[ADNavi] Settings saved to %s", SETTINGS_FILE)
end

-- ============================================================
-- Menu definitions (rebuilt on each dialog open)
-- ============================================================
local settingsOpen = false
local activeTab    = 1   -- 1 = Minimap, 2 = Strasse
local MENU_MINIMAP = {}
local MENU_ROAD    = {}

local function buildMenus()
    local function add(t, label_key, getVal, doPrev, doNext)
        table.insert(t, {label_key=label_key, get=getVal, prev=doPrev, next=doNext})
    end
    local function cycleIdx(key, arr, dir)
        cfg[key] = ((cfg[key] - 1 + dir) % #arr) + 1
    end

    MENU_MINIMAP = {}
    add(MENU_MINIMAP, "adnavi_display",
        function() return g_i18n:getText(cfg.mapEnabled and "adnavi_on" or "adnavi_off") end,
        function() cfg.mapEnabled = not cfg.mapEnabled end,
        function() cfg.mapEnabled = not cfg.mapEnabled end)
    add(MENU_MINIMAP, "adnavi_color",
        function() return g_i18n:getText(COLORS[cfg.mapColorIdx].key) end,
        function() cycleIdx("mapColorIdx", COLORS, -1) end,
        function() cycleIdx("mapColorIdx", COLORS,  1) end)
    add(MENU_MINIMAP, "adnavi_thickness",
        function() return g_i18n:getText(MAP_THICK_K[cfg.mapThickIdx]) end,
        function() cycleIdx("mapThickIdx", MAP_THICK, -1) end,
        function() cycleIdx("mapThickIdx", MAP_THICK,  1) end)
    add(MENU_MINIMAP, "adnavi_visibility",
        function() return g_i18n:getText(MAP_LOOK_K[cfg.mapLookIdx]) end,
        function() cycleIdx("mapLookIdx", MAP_LOOK, -1) end,
        function() cycleIdx("mapLookIdx", MAP_LOOK,  1) end)

    MENU_ROAD = {}
    add(MENU_ROAD, "adnavi_display",
        function() return g_i18n:getText(cfg.roadEnabled and "adnavi_on" or "adnavi_off") end,
        function() cfg.roadEnabled = not cfg.roadEnabled end,
        function() cfg.roadEnabled = not cfg.roadEnabled end)
    add(MENU_ROAD, "adnavi_color",
        function() return g_i18n:getText(COLORS[cfg.roadColorIdx].key) end,
        function() cycleIdx("roadColorIdx", COLORS, -1) end,
        function() cycleIdx("roadColorIdx", COLORS,  1) end)
    add(MENU_ROAD, "adnavi_length",
        function() return g_i18n:getText(ROAD_LEN_K[cfg.roadLenIdx]) end,
        function() cycleIdx("roadLenIdx", ROAD_LEN, -1) end,
        function() cycleIdx("roadLenIdx", ROAD_LEN,  1) end)
    add(MENU_ROAD, "adnavi_thickness",
        function() return g_i18n:getText(ROAD_THICK_K[cfg.roadThickIdx]) end,
        function() cycleIdx("roadThickIdx", ROAD_THICK_COUNTS, -1) end,
        function() cycleIdx("roadThickIdx", ROAD_THICK_COUNTS,  1) end)
    add(MENU_ROAD, "adnavi_start",
        function() return g_i18n:getText(ROAD_START_K[cfg.roadStartIdx]) end,
        function() cycleIdx("roadStartIdx", ROAD_START, -1) end,
        function() cycleIdx("roadStartIdx", ROAD_START,  1) end)
end

local function activeMenu()
    return activeTab == 1 and MENU_MINIMAP or MENU_ROAD
end

-- ============================================================
-- Settings Dialog class
-- ============================================================
ADNaviSettingsDialog = {}
local ADNaviSettingsDialog_mt = Class(ADNaviSettingsDialog, DialogElement)

function ADNaviSettingsDialog.new(target)
    local self = DialogElement.new(target, ADNaviSettingsDialog_mt)
    return self
end

function ADNaviSettingsDialog:onOpen()
    ADNaviSettingsDialog:superClass().onOpen(self)
    settingsOpen = true
    activeTab = 1
    buildMenus()
    self.settingsList:setDataSource(self)
    self.settingsList:reloadData()
    self:refreshTabButtons()
end

function ADNaviSettingsDialog:onClose()
    settingsOpen = false
    saveSettings()
    ADNaviSettingsDialog:superClass().onClose(self)
end

function ADNaviSettingsDialog:refreshTabButtons()
    local mTxt = g_i18n:getText("adnavi_tab_minimap")
    local rTxt = g_i18n:getText("adnavi_tab_road")
    self.tabMinimapBtn:setText(mTxt)
    self.tabRoadBtn:setText(rTxt)
    -- setSelected(true) applies imageSelectedColor (FS25 green) from the profile;
    -- setSelected(false) reverts to imageColor (grey). Correct method name in FS25
    -- is setSelected, not setIsSelected.
    self.tabMinimapBtn:setSelected(activeTab == 1)
    self.tabRoadBtn:setSelected(   activeTab == 2)
end

function ADNaviSettingsDialog:onClickTabMinimap()
    activeTab = 1
    self:refreshTabButtons()
    self.settingsList:reloadData()
end

function ADNaviSettingsDialog:onClickTabRoad()
    activeTab = 2
    self:refreshTabButtons()
    self.settingsList:reloadData()
end

function ADNaviSettingsDialog:getNumberOfItemsInSection(list, section)
    return #activeMenu()
end

function ADNaviSettingsDialog:populateCellForItemInSection(list, section, index, cell)
    local item = activeMenu()[index]
    cell.attributes.labelText:setText(g_i18n:getText(item.label_key))
    cell.attributes.valueText:setText(item.get())
end

function ADNaviSettingsDialog:onClickPrev()
    local i    = self.settingsList:getSelectedIndexInSection()
    local item = activeMenu()[i]
    if item and item.prev then
        item.prev()
        self.settingsList:reloadData()
    end
end

function ADNaviSettingsDialog:onClickNext()
    local i    = self.settingsList:getSelectedIndexInSection()
    local item = activeMenu()[i]
    if item and item.next then
        item.next()
        self.settingsList:reloadData()
    end
end

-- Intercept key events at the dialog level so Enter/Space cannot accidentally
-- activate a tab button that still has keyboard focus despite focusActive=false.
function ADNaviSettingsDialog:onKeyEvent(unicode, sym, modifier, isDown)
    if isDown and sym == Input.KEY_return then
        return true   -- consume; prevent any focused button from firing
    end
    return ADNaviSettingsDialog:superClass().onKeyEvent(self, unicode, sym, modifier, isDown)
end

function ADNaviSettingsDialog:onEscPressed()
    self:onClickBack()
end

-- ============================================================
-- ADNavi main table
-- ============================================================
ADNavi = {}
ADNavi.overlayId         = nil
ADNavi.isActive          = false
ADNavi.capturedWayPoints = nil
ADNavi.hookedVehicles    = {}
ADNavi.lastRecalcTime    = 0
ADNavi.settingsDialog    = nil

local RECALC_INTERVAL  = 5.0
local DEVIATION_THRESH = 30.0
local ROAD_Y_OFFSET    = 0.3

-- ---------------------------------------------------------------------------
-- Helper: find an AD-equipped vehicle the player has entered.
-- ---------------------------------------------------------------------------
local function getADVehicle()
    if g_currentMission == nil or g_currentMission.vehicleSystem == nil then
        return nil
    end
    for _, v in pairs(g_currentMission.vehicleSystem.vehicles) do
        if v.ad ~= nil
            and v.ad.stateModule ~= nil
            and v.spec_enterable ~= nil
            and v.spec_enterable.isEntered
        then
            return v
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Hook drivePathModule so we auto-capture waypoints whenever AD sets a route.
-- ---------------------------------------------------------------------------
local function hookVehicle(vehicle)
    if ADNavi.hookedVehicles[vehicle] then return end
    local dm = vehicle.ad.drivePathModule
    if dm == nil then return end

    ADNavi.hookedVehicles[vehicle] = true

    local origSetPathTo = dm.setPathTo
    dm.setPathTo = function(self, wayPointId)
        origSetPathTo(self, wayPointId)
        if self.wayPoints ~= nil and #self.wayPoints > 0 then
            ADNavi.capturedWayPoints = self.wayPoints
            Logging.info("[ADNavi] Captured %d waypoints via setPathTo.", #self.wayPoints)
        end
    end

    local origSetWayPoints = dm.setWayPoints
    dm.setWayPoints = function(self, wps)
        origSetWayPoints(self, wps)
        if self.wayPoints ~= nil and #self.wayPoints > 0 then
            ADNavi.capturedWayPoints = self.wayPoints
            Logging.info("[ADNavi] Captured %d waypoints via setWayPoints.", #self.wayPoints)
        end
    end

    Logging.info("[ADNavi] drivePathModule hooked.")
end

-- ---------------------------------------------------------------------------
-- Coordinate conversion: world -> ingame minimap screen position.
-- Out-of-world-bounds waypoints are clipped to nil to prevent edge stacking.
-- ---------------------------------------------------------------------------
local function worldToMinimapPos(worldX, worldZ)
    local ingameMap = g_currentMission.hud.ingameMap
    if ingameMap == nil or ingameMap.layout == nil then return nil, nil end
    local mapX = (worldX + ingameMap.worldCenterOffsetX) / ingameMap.worldSizeX * 0.5 + 0.25
    local mapZ = (worldZ + ingameMap.worldCenterOffsetZ) / ingameMap.worldSizeZ * 0.5 + 0.25
    -- Clip: coordinates outside [0.25, 0.75] are beyond the world border;
    -- getMapObjectPosition would clamp them to the edge, causing stacking.
    if mapX < 0.25 or mapX > 0.75 or mapZ < 0.25 or mapZ > 0.75 then return nil, nil end
    return ingameMap.layout:getMapObjectPosition(mapX, mapZ, 0, 0, 0, true)
end

-- ---------------------------------------------------------------------------
-- Coordinate conversion: world -> menu map screen position.
-- ---------------------------------------------------------------------------
local function worldToMenuMapPos(worldX, worldZ)
    if g_inGameMenu == nil or g_inGameMenu.baseIngameMap == nil then return nil, nil end
    local map = g_inGameMenu.baseIngameMap
    if map.layout == nil then return nil, nil end
    local mapX = (worldX + map.worldCenterOffsetX) / map.worldSizeX * 0.5 + 0.25
    local mapZ = (worldZ + map.worldCenterOffsetZ) / map.worldSizeZ * 0.5 + 0.25
    if mapX < 0.25 or mapX > 0.75 or mapZ < 0.25 or mapZ > 0.75 then return nil, nil end
    return map.layout:getMapObjectPosition(mapX, mapZ, 0, 0, 0, true)
end

-- ---------------------------------------------------------------------------
-- Find index of waypoint closest to (worldX, worldZ); also returns distance.
-- ---------------------------------------------------------------------------
local function findClosestWaypoint(WPs, worldX, worldZ)
    local minDistSq = math.huge
    local minIdx    = 1
    for i, wp in ipairs(WPs) do
        local dx = wp.x - worldX
        local dz = wp.z - worldZ
        local dSq = dx * dx + dz * dz
        if dSq < minDistSq then
            minDistSq = dSq
            minIdx    = i
        end
    end
    return minIdx, math.sqrt(minDistSq)
end

-- ---------------------------------------------------------------------------
-- Get vehicle root position in world space.
-- ---------------------------------------------------------------------------
local function getVehicleWorldPos(vehicle)
    local node = vehicle.rootNode
        or (vehicle.components and vehicle.components[1] and vehicle.components[1].node)
    if node == nil then return 0, 0 end
    local x, _, z = getWorldTranslation(node)
    return x, z
end

-- ---------------------------------------------------------------------------
-- Recalculate route to vehicle's first AD marker; updates capturedWayPoints.
-- ---------------------------------------------------------------------------
local function recalcRoute(vehicle)
    local marker = vehicle.ad.stateModule:getFirstMarker()
    if marker == nil or marker.id == nil or marker.id < 1 then return end
    local dm = vehicle.ad.drivePathModule
    dm:setPathTo(marker.id)
    dm:reset()
    Logging.info("[ADNavi] Route recalculated: %d waypoints.",
        ADNavi.capturedWayPoints and #ADNavi.capturedWayPoints or 0)
end

-- ---------------------------------------------------------------------------
-- Toggle (RightShift + N)
-- ---------------------------------------------------------------------------
function ADNavi.toggle()
    ADNavi.isActive = not ADNavi.isActive

    if not ADNavi.isActive then
        ADNavi.capturedWayPoints = nil
        Logging.info("[ADNavi] Display OFF. Cache cleared.")
        return
    end

    local vehicle = getADVehicle()
    if vehicle == nil then
        Logging.warning("[ADNavi] Display ON but no entered AD vehicle found.")
        return
    end

    hookVehicle(vehicle)

    if ADNavi.capturedWayPoints ~= nil then
        Logging.info("[ADNavi] Display ON. Reusing %d cached waypoints.",
            #ADNavi.capturedWayPoints)
        return
    end

    local marker = vehicle.ad.stateModule:getFirstMarker()
    if marker == nil or marker.id == nil or marker.id < 1 then
        Logging.warning("[ADNavi] Display ON but no destination set in AutoDrive HUD.")
        return
    end

    Logging.info("[ADNavi] Calculating route to '%s' (id %d)...",
        tostring(marker.name), marker.id)
    recalcRoute(vehicle)

    if ADNavi.capturedWayPoints ~= nil then
        Logging.info("[ADNavi] Display ON. Route has %d waypoints.",
            #ADNavi.capturedWayPoints)
    else
        Logging.warning("[ADNavi] Route calculation returned no waypoints.")
    end
end

-- ---------------------------------------------------------------------------
-- 3D road projection: draws route as debug lines on the road surface.
-- ROAD_THICK_COUNTS parallel lines at ROAD_THICK_SPACING produce a solid band.
-- roadStartIdx skips N metres of route before drawing, so the line
-- doesn't appear directly behind/at the vehicle.
-- ---------------------------------------------------------------------------
local function drawRoute3D(WPs, currentWp)
    local terrain      = g_currentMission.terrainRootNode
    local lastWp       = nil
    local drawnDist    = 0.0
    local skippedDist  = 0.0
    local lookahead    = ROAD_LEN[cfg.roadLenIdx]
    local startSkip    = ROAD_START[cfg.roadStartIdx]
    local col          = COLORS[cfg.roadColorIdx]
    local count        = ROAD_THICK_COUNTS[cfg.roadThickIdx]

    local function safeY(wp)
        if wp.y ~= nil and wp.y ~= -1 then return wp.y end
        return getTerrainHeightAtWorldPos(terrain, wp.x, 1, wp.z)
    end

    for index, wp in ipairs(WPs) do
        if lastWp ~= nil and index >= currentWp then
            local dx     = wp.x - lastWp.x
            local dz     = wp.z - lastWp.z
            local segLen = MathUtil.vector2Length(dx, dz)

            if skippedDist < startSkip then
                -- still in the skip zone; advance without drawing
                skippedDist = skippedDist + segLen
            else
                drawnDist = drawnDist + segLen
                if drawnDist > lookahead then break end

                if segLen > 0.001 then
                    local nx = -dz / segLen   -- perpendicular unit vector
                    local nz =  dx / segLen
                    for t = 1, count do
                        -- Distribute lines evenly across ROAD_TOTAL_WIDTH regardless of count.
                        -- count=1 → off=0; count=2 → -0.10/+0.10; count=5 → -0.10…+0.10
                        local off = count > 1
                            and ((t - 1) / (count - 1) - 0.5) * ROAD_TOTAL_WIDTH
                            or 0
                        drawDebugLine(
                            lastWp.x + nx*off, safeY(lastWp) + ROAD_Y_OFFSET, lastWp.z + nz*off,
                            col.r, col.g, col.b,
                            wp.x   + nx*off, safeY(wp)     + ROAD_Y_OFFSET, wp.z   + nz*off,
                            col.r, col.g, col.b)
                    end
                end
            end
        end
        lastWp = wp
    end
end

-- ---------------------------------------------------------------------------
-- Core 2D drawing: solid line route on minimap or menu map.
-- The "Sichtweite" setting is respected on all minimap states;
-- the menu map always passes math.huge from its caller.
-- posFunc maps (worldX, worldZ) -> (screenX, screenY) or (nil, nil).
-- ---------------------------------------------------------------------------
local function drawRoute(WPs, currentWp, lookaheadDist, posFunc)
    -- One-time overlay creation; also guards against the case where
    -- createImageOverlay returns 0 (GIANTS error sentinel, not nil).
    if overlayFailed then return end
    if ADNavi.overlayId == nil then
        local id = createImageOverlay(WHITE_DDS)
        if id == nil or id == 0 then
            overlayFailed = true
            Logging.warning("[ADNavi] createImageOverlay returned %s for '%s' - minimap lines disabled.",
                tostring(id), WHITE_DDS)
            return
        end
        ADNavi.overlayId = id
    end

    local col       = COLORS[cfg.mapColorIdx]
    local thickness = MAP_THICK[cfg.mapThickIdx] / g_screenHeight
    local lastWp    = nil
    local drawnDist = 0.0

    setOverlayColor(ADNavi.overlayId, col.r, col.g, col.b, 1.0)

    for index, wp in ipairs(WPs) do
        if lastWp ~= nil and index >= currentWp then
            local segWorld = MathUtil.vector2Length(wp.x - lastWp.x, wp.z - lastWp.z)
            drawnDist = drawnDist + segWorld
            if drawnDist > lookaheadDist then break end

            local startX, startY = posFunc(lastWp.x, lastWp.z)
            local endX,   endY   = posFunc(wp.x,     wp.z)

            if startX ~= nil and endX ~= nil then
                local dx2D   = endX - startX
                -- aspect-ratio correction so the angle matches the rotating minimap
                local dy2D   = (endY - startY) / g_screenAspectRatio
                local segLen = MathUtil.vector2Length(dx2D, dy2D)
                if segLen > 0.0001 then
                    local rotation = math.atan2(dy2D, dx2D)
                    setOverlayRotation(ADNavi.overlayId, rotation, 0, 0)
                    renderOverlay(ADNavi.overlayId, startX, startY, segLen, thickness)
                    setOverlayRotation(ADNavi.overlayId, 0, 0, 0)
                end
            end
        end
        lastWp = wp
    end
end

-- ---------------------------------------------------------------------------
-- Shared: resolve WPs + currentWp, run deviation check.
-- ---------------------------------------------------------------------------
local function resolveRoute(vehicle, usingLiveRoute, WPs, currentWp, vx, vz)
    if WPs == nil or #WPs == 0 then return nil, nil end

    if not usingLiveRoute or currentWp == nil then
        currentWp = findClosestWaypoint(WPs, vx, vz)
    end

    if not usingLiveRoute and vehicle ~= nil then
        local now = g_currentMission.time * 0.001
        if (now - ADNavi.lastRecalcTime) >= RECALC_INTERVAL then
            ADNavi.lastRecalcTime = now
            local _, dist = findClosestWaypoint(WPs, vx, vz)
            if dist > DEVIATION_THRESH then
                local prevCount = #WPs
                recalcRoute(vehicle)
                if ADNavi.capturedWayPoints ~= nil
                    and #ADNavi.capturedWayPoints ~= prevCount
                then
                    WPs       = ADNavi.capturedWayPoints
                    currentWp = findClosestWaypoint(WPs, vx, vz)
                end
            end
        end
    end

    return WPs, currentWp
end

-- ---------------------------------------------------------------------------
-- Shared: collect vehicle, WPs and vehicle position.
-- ---------------------------------------------------------------------------
local function collectState()
    local vehicle = getADVehicle()
    if vehicle ~= nil then hookVehicle(vehicle) end

    local WPs, currentWp
    local usingLiveRoute = false
    if vehicle ~= nil and vehicle.ad.drivePathModule ~= nil then
        WPs, currentWp = vehicle.ad.drivePathModule:getWayPoints()
        if WPs ~= nil and #WPs > 0 then usingLiveRoute = true end
    end
    if not usingLiveRoute then
        WPs       = ADNavi.capturedWayPoints
        currentWp = nil
    end

    local vx, vz = 0, 0
    if vehicle ~= nil then vx, vz = getVehicleWorldPos(vehicle) end

    return vehicle, WPs, currentWp, usingLiveRoute, vx, vz
end

-- ---------------------------------------------------------------------------
-- HUD draw: minimap + 3D road. Hooked into BaseMission.draw.
-- "Sichtweite" applies to ALL minimap states (no automatic math.huge override).
-- Skips when any full-screen GUI is open (g_gui.currentGui ~= nil covers vehicle
-- settings pages, dialogs, etc. that are separate from g_inGameMenu).
-- ---------------------------------------------------------------------------
function ADNavi.drawHUD()
    if not ADNavi.isActive then return end
    if g_inGameMenu ~= nil and g_inGameMenu.isOpen then return end
    if settingsOpen then return end
    if g_gui ~= nil and g_gui.currentGui ~= nil then return end

    local vehicle, WPs, currentWp, usingLiveRoute, vx, vz = collectState()
    WPs, currentWp = resolveRoute(vehicle, usingLiveRoute, WPs, currentWp, vx, vz)
    if WPs == nil then return end

    if cfg.mapEnabled then
        -- Minimap states: 0=off, 2=small round, 3=small square, 4=large square.
        -- Length/Sichtweite applies to states 2 (round) and 3 (small square).
        -- State 4 (large square) always shows the full route (math.huge).
        local ingameMap    = g_currentMission.hud ~= nil and g_currentMission.hud.ingameMap
        local minimapState = (ingameMap ~= nil) and (ingameMap.state or ingameMap.stateIndex or 0) or 0
        local lookahead    = (minimapState == 4) and math.huge or MAP_LOOK[cfg.mapLookIdx]
        drawRoute(WPs, currentWp, lookahead, worldToMinimapPos)
    end
    if cfg.roadEnabled then
        drawRoute3D(WPs, currentWp)
    end
end

-- ---------------------------------------------------------------------------
-- Menu map draw: large map route. Always uses math.huge (full route visible).
-- ---------------------------------------------------------------------------
function ADNavi.drawMenuMap()
    if not ADNavi.isActive then return end
    if not cfg.mapEnabled then return end

    local map = g_inGameMenu ~= nil and g_inGameMenu.baseIngameMap
    if map == nil or map.layout == nil then return end
    if map.fullScreenLayout == nil then return end
    if map.layout ~= map.fullScreenLayout then return end

    local vehicle, WPs, currentWp, usingLiveRoute, vx, vz = collectState()
    WPs, currentWp = resolveRoute(vehicle, usingLiveRoute, WPs, currentWp, vx, vz)
    if WPs == nil then return end

    drawRoute(WPs, currentWp, math.huge, worldToMenuMapPos)
end

-- ---------------------------------------------------------------------------
-- Key event: dialog navigation only.
-- Global shortcuts (toggle / open settings) are now handled by ADNaviSpec
-- via the FS25 vehicle specialization action event system — fully configurable
-- in the Controls menu.
--
-- When the settings dialog is open:
--   Q / E   → switch tab (Minimap / Road)
--   ↑ / ↓   → move list selection up / down
--             (WASD unavailable – InputManager consumes them at C++ level)
--   ← / A   → previous option value
--   → / D   → next option value
-- ---------------------------------------------------------------------------
function ADNavi.keyEvent(self, unicode, sym, modifier, isDown, used)
    if isDown and settingsOpen and ADNavi.settingsDialog ~= nil then
        local dlg = ADNavi.settingsDialog

        if sym == Input.KEY_q then
            if activeTab == 2 then dlg:onClickTabMinimap() end
            return true
        elseif sym == Input.KEY_e then
            if activeTab == 1 then dlg:onClickTabRoad() end
            return true
        elseif sym == Input.KEY_up then
            local cur = dlg.settingsList:getSelectedIndexInSection()
            if cur > 1 then dlg.settingsList:scrollTo(1, cur - 1, false) end
            return true
        elseif sym == Input.KEY_down then
            local cur   = dlg.settingsList:getSelectedIndexInSection()
            local count = #activeMenu()
            if cur < count then dlg.settingsList:scrollTo(1, cur + 1, false) end
            return true
        elseif sym == Input.KEY_a or sym == Input.KEY_left then
            dlg:onClickPrev(); return true
        elseif sym == Input.KEY_d or sym == Input.KEY_right then
            dlg:onClickNext(); return true
        elseif sym == Input.KEY_return then
            return true   -- consume – prevent focused button from firing
        end
    end
    return used
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
function ADNavi.onLoadMap()
    writeWhiteDDS()   -- ensure white overlay texture exists before any draw call

    -- Set up settings persistence path and load saved values.
    local profilePath = getUserProfileAppPath()
    local settingsDir = profilePath .. "modSettings"
    createFolder(settingsDir)
    SETTINGS_FILE = settingsDir .. "/FS25_ADNavi.xml"
    loadSettings()

    g_gui:loadProfiles(MOD_DIRECTORY .. "gui/guiProfiles.xml")
    ADNavi.settingsDialog = ADNaviSettingsDialog.new()
    g_gui:loadGui(MOD_DIRECTORY .. "gui/ADNaviSettingsDialog.xml",
                  "ADNaviSettingsDialog", ADNavi.settingsDialog)

    BaseMission.draw     = Utils.appendedFunction(BaseMission.draw,     ADNavi.drawHUD)
    BaseMission.keyEvent = Utils.appendedFunction(BaseMission.keyEvent, ADNavi.keyEvent)

    if InGameMenu ~= nil and InGameMenu.draw ~= nil then
        InGameMenu.draw = Utils.appendedFunction(InGameMenu.draw, ADNavi.drawMenuMap)
        Logging.info("[ADNavi] Menu map hook registered via InGameMenu.draw.")
    else
        Logging.warning("[ADNavi] InGameMenu.draw not found; menu map disabled.")
    end

    Logging.info("[ADNavi] Initialized.")
end

Mission00.loadMap = Utils.appendedFunction(Mission00.loadMap, ADNavi.onLoadMap)

-- ---------------------------------------------------------------------------
-- Vehicle specialization registration.
-- Follows AutoDrive's register.lua pattern exactly:
--   1. Register the spec class with g_specializationManager (once, at mod load)
--   2. Iterate g_vehicleTypeManager.types and add the spec to every vehicle
--      type whose prerequisitesPresent check passes (Enterable required).
-- This runs at module level — g_vehicleTypeManager.types is already populated
-- when mod Lua scripts execute (confirmed from AutoDrive source).
-- ---------------------------------------------------------------------------
local ADNaviSpecFullName = g_currentModName .. ".adnaviSpec"

if g_specializationManager:getSpecializationByName("adnaviSpec") == nil then
    g_specializationManager:addSpecialization(
        "adnaviSpec", "ADNaviSpec",
        Utils.getFilename("scripts/ADNaviSpec.lua", g_currentModDirectory), nil)
end

local specCount = 0
for vehicleType, typeDef in pairs(g_vehicleTypeManager.types) do
    if typeDef ~= nil
       and typeDef.specializationsByName[ADNaviSpecFullName] == nil
       and ADNaviSpec.prerequisitesPresent(typeDef.specializations)
    then
        g_vehicleTypeManager:addSpecialization(vehicleType, ADNaviSpecFullName)
        specCount = specCount + 1
    end
end
Logging.info("[ADNavi] ADNaviSpec added to %d vehicle types.", specCount)
