-- ADNaviSpec: vehicle specialization that registers configurable input
-- action events (ADNAVI_TOGGLE / ADNAVI_SETTINGS) for the local player
-- while they are controlling an enterable vehicle.
--
-- The spec is added to all enterable vehicle types at mod-load time
-- (see the registration block at the bottom of ADNavi.lua).

ADNaviSpec = {}
local ADNaviSpec_mt = Class(ADNaviSpec)

-- Only attach to vehicles the player can enter.
function ADNaviSpec.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Enterable, specializations)
end

-- Register which vehicle lifecycle events this spec listens to.
function ADNaviSpec.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad",                 ADNaviSpec)
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", ADNaviSpec)
end

-- Initialise the per-vehicle action-event ID storage.
function ADNaviSpec:onLoad(savegame)
    self.adnaviActionEvents = {}
end

-- Called by the engine when the vehicle's input context changes
-- (player enters / leaves the vehicle, or focus switches to another vehicle).
-- FS25 signature: first param is ignored (_), second param isOnActiveVehicle = true
-- when this vehicle is the one the local player controls.
function ADNaviSpec:onRegisterActionEvents(_, isOnActiveVehicle)
    if not self.isClient then return end

    -- The engine clears action events automatically on context switch;
    -- we just reset our local ID table.
    self.adnaviActionEvents = {}

    if isOnActiveVehicle then
        local ok, evId

        -- Toggle route display
        -- Use InputBinding.registerActionEvent (FS25 style, same as AutoDrive)
        ok, evId = InputBinding.registerActionEvent(
            g_inputBinding, "ADNAVI_TOGGLE", self, ADNaviSpec.onActionToggle,
            false, true, false, true)   -- triggerDown, triggerUp, triggerAlways, startActive
        if ok then
            self.adnaviActionEvents.toggle = evId
            g_inputBinding:setActionEventTextVisibility(evId, false)  -- no on-screen hint
        end

        -- Open settings dialog
        ok, evId = InputBinding.registerActionEvent(
            g_inputBinding, "ADNAVI_SETTINGS", self, ADNaviSpec.onActionSettings,
            false, true, false, true)
        if ok then
            self.adnaviActionEvents.settings = evId
            g_inputBinding:setActionEventTextVisibility(evId, false)
        end

    end
end

-- Callback: toggle route display on / off.
function ADNaviSpec.onActionToggle(self, actionName, inputValue, callbackState, isAnalog)
    ADNavi.toggle()
end

-- Callback: open the settings dialog.
function ADNaviSpec.onActionSettings(self, actionName, inputValue, callbackState, isAnalog)
    if ADNavi.settingsDialog ~= nil then
        g_gui:showDialog("ADNaviSettingsDialog")
    end
end
