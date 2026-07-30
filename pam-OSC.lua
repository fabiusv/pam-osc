-- pam-OSC. It allows to controll GrandMA3 with Midi Devices over Open Stage Controll and allows for Feedback from MA.
-- Copyright (C) 2024  xxpasixx
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>. 
local executorsToWatch = {}
local oldValues = {}
local oldButtonValues = {}
local oldColorValues = {}
local oldNameValues = {}
local oldExpandedTimecode = false
local oldSelectedFeatureGroup = ""
local olsMasterEnabledValue = {
    highlight = false,
    lowlight = false,
    solo = false,
    blind = false
}
local oldTimecodes = {}
local oldDeskLockedStatus = false

local oscEntry = 2

-- Native grandMA3 screen-encoder handling. Open Stage Control calls this
-- component with "pamEncoderRotate,<encoder>,<amount>" or
-- "pamEncoderClick,<encoder>", so the separate MIDI Encoders plugin and its
-- generated DataPool 128 macros are no longer required.
local ENCODER_DISPLAY_INDEX = 1
local ENCODER_WHEEL_CENTER_OFFSET_X = 35
local ENCODER_TOUCH_RADIUS = 20
local ENCODER_TOUCH_ANGLE_STEP = 0.28
local ENCODER_TOUCH_MAX_ANGLE = 3.05433
local ENCODER_MAX_AMOUNT = 10

local function getDisplaySafe(displayIndex)
    if type(GetDisplayByIndex) == "function" then
        local display = GetDisplayByIndex(displayIndex)
        if display ~= nil then
            return display
        end
    end

    local graphicsRoot = Root().GraphicsRoot
    if graphicsRoot ~= nil and graphicsRoot.PultCollect ~= nil then
        local pult = graphicsRoot.PultCollect:Ptr(1)
        if pult ~= nil and pult.DisplayCollect ~= nil then
            return pult.DisplayCollect:Ptr(displayIndex)
        end
    end
end

local function getObjectRect(object)
    if object == nil then
        return nil
    end

    local success, rect = pcall(function()
        return object:Get("AbsClientRect")
    end)
    if success then
        return rect
    end
end

local function getObjectClass(object)
    if object == nil then
        return nil
    end

    local success, className = pcall(function()
        return object:GetClass()
    end)
    if success then
        return className
    end
end

local function getEncoderBarLocation()
    local display = getDisplaySafe(ENCODER_DISPLAY_INDEX)
    if display ~= nil and display.EncoderBarContainer ~= nil and
            display.EncoderBarContainer.visible == true then
        local container = display.EncoderBarContainer
        local encoderBar = container.EncoderBar
        if container.EncoderBarGrid ~= nil and container.EncoderBarGrid.EncoderBar ~= nil then
            encoderBar = container.EncoderBarGrid.EncoderBar
        end

        if encoderBar ~= nil then
            return {
                display = display,
                encoderBar = encoderBar,
                isWindow = false,
                isBandFader = false
            }
        end
    end

    -- Also support a detached Encoder Bar window.
    for displayIndex = 1, 7 do
        local currentDisplay = getDisplaySafe(displayIndex)
        if currentDisplay ~= nil then
            local success, location = pcall(function()
                local uiScreen = currentDisplay.ScreenContainer.ScrollIndicatorBox.ScreenScroll.ScrollBox.UiScreen
                local encoderBarWindow = uiScreen:FindWild("WindowEncoderBar*")
                if encoderBarWindow == nil then
                    return nil
                end

                return {
                    display = currentDisplay,
                    encoderBar = encoderBarWindow.Frame.EncoderBarContainer.Middle.EncoderBarSlot.PlaceHolder,
                    isWindow = true,
                    isBandFader = encoderBarWindow[1].fadeEncoder == true,
                    windowHeight = encoderBarWindow:Get("AbsClientRect").h
                }
            end)

            if success and location ~= nil then
                return location
            end
        end
    end
end

local function getPresetEncoderRect(presetBar, encoderNumber)
    local encoderPlace = presetBar.EncodersArea[
            "EncoderPlace" .. tostring((encoderNumber - 1) % 5 + 1)]
    if encoderPlace == nil then
        return nil
    end

    local encoderGrid = encoderPlace["UILayoutGrid 3"]
    if encoderGrid == nil then
        return nil
    end

    -- The fifth encoder can be the dedicated screen encoder.
    if encoderNumber == 5 and CurrentProfile().screenEncoder == true then
        local screenEncoder = encoderGrid[3]
        if getObjectClass(screenEncoder) == "ScreenEncoderControl" then
            return {
                rect = getObjectRect(screenEncoder),
                type = "encoder"
            }
        end
    end

    local encoderControl = encoderGrid[5]
    local encoderClass = getObjectClass(encoderControl)
    if encoderClass == "PresetEncoderControl" then
        if presetBar.fadeEncoder == true then
            local faderControl = encoderGrid[6]
            if faderControl ~= nil then
                return {
                    rect = getObjectRect(faderControl),
                    type = "bandFader"
                }
            end
        end

        return {
            rect = getObjectRect(encoderControl),
            type = "encoder"
        }
    end

    -- Fallback for versions that expose the wheel as the third grid child.
    local screenEncoder = encoderGrid[3]
    if getObjectClass(screenEncoder) == "ScreenEncoderControl" then
        return {
            rect = getObjectRect(screenEncoder),
            type = "encoder"
        }
    end
end

local function getArrangementEncoderRect(innerBoxLower, encoderNumber)
    if innerBoxLower == nil then
        return nil
    end

    if encoderNumber == 5 then
        return getObjectRect(innerBoxLower.Encoder5aScr)
    end

    local encoderIndex = encoderNumber % 5
    local arrangement = innerBoxLower["Arrangement" .. tostring(encoderIndex)]
    if arrangement ~= nil and arrangement:Get("visible") == true then
        return getObjectRect(arrangement)
    end

    if encoderIndex <= 3 then
        return getObjectRect(innerBoxLower[
                "ArrangementSplitInner" .. tostring(encoderIndex)])
    end
end

local LAYOUT_ENCODER_NAMES = {
    [1] = "TransX",
    [2] = "TransY",
    [3] = "ScaleAll",
    [4] = "RotZ",
    [5] = "Encoder5aScr"
}

local function getEncoderRect(encoderBar, encoderNumber)
    local presetBar = encoderBar["PresetBar 3"]
    if presetBar ~= nil then
        return getPresetEncoderRect(presetBar, encoderNumber)
    end

    local layoutBar = encoderBar["LayoutBar 3"]
    if layoutBar ~= nil then
        local lower = layoutBar.InnerBox.Lower
        local selectedMode = layoutBar.InnerBox.EncoderFunction:Get("SELECTEDITEMIDX")
        if selectedMode == 0 then
            return {
                rect = getObjectRect(lower[LAYOUT_ENCODER_NAMES[encoderNumber]]),
                type = "encoder"
            }
        end
        return {
            rect = getArrangementEncoderRect(lower, encoderNumber),
            type = "encoder"
        }
    end

    local stageViewBar = encoderBar["StageViewBar 3"]
    if stageViewBar ~= nil then
        return {
            rect = getArrangementEncoderRect(stageViewBar.InnerBox.Lower, encoderNumber),
            type = "encoder"
        }
    end

    local timecodeBar = encoderBar["TimecodeBar 3"]
    if timecodeBar ~= nil then
        local lower = timecodeBar.InnerBox.Lower
        local encoderName = encoderNumber == 5 and "Encoder5aScr" or
                "Encoder" .. tostring(encoderNumber % 5) .. "a"
        return {
            rect = getObjectRect(lower[encoderName]),
            type = "encoder"
        }
    end
end

local function locateEncoder(encoderNumber)
    local encoderBarLocation = getEncoderBarLocation()
    if encoderBarLocation == nil then
        return nil
    end

    local encoderData = getEncoderRect(
        encoderBarLocation.encoderBar,
        encoderNumber
    )
    if encoderData == nil or encoderData.rect == nil then
        return nil
    end

    if encoderData.type == "bandFader" and encoderBarLocation.windowHeight ~= nil and
            encoderBarLocation.windowHeight < 275 then
        return nil
    end
    if encoderData.type == "encoder" and encoderBarLocation.windowHeight ~= nil and
            encoderBarLocation.windowHeight < 175 then
        return nil
    end

    encoderData.display = encoderBarLocation.display
    return encoderData
end

local function withRotateEncoderStyle(callback)
    local profile = CurrentProfile()
    local oldStyle
    local styleChanged = false

    if profile ~= nil and Enums ~= nil and Enums.EncoderUIStyle ~= nil then
        oldStyle = profile:Get("encoderUIStyle")
        if oldStyle ~= "Rotate" then
            styleChanged = pcall(function()
                profile:Set("encoderUIStyle", Enums.EncoderUIStyle.Rotate)
            end)
        end
    end

    local success, result = pcall(callback)

    if styleChanged then
        pcall(function()
            local restoreStyle = oldStyle == "Drag" and
                    Enums.EncoderUIStyle.Drag or Enums.EncoderUIStyle.None
            profile:Set("encoderUIStyle", restoreStyle)
        end)
    end

    if not success then
        Printf("PAM OSC encoder error: " .. tostring(result))
        return false
    end
    return result
end

local function rotateEncoder(encoderNumber, amount)
    local encoderData = locateEncoder(encoderNumber)
    if encoderData == nil then
        Printf("PAM OSC: active encoder " .. tostring(encoderNumber) .. " was not found")
        return false
    end

    amount = math.max(-ENCODER_MAX_AMOUNT, math.min(ENCODER_MAX_AMOUNT, amount))
    if amount == 0 then
        return true
    end

    return withRotateEncoderStyle(function()
        local rect = encoderData.rect
        local center = {
            x = rect.x + ENCODER_WHEEL_CENTER_OFFSET_X,
            y = rect.y + rect.h / 2
        }
        local touchId = encoderNumber

        if encoderData.type == "bandFader" then
            local destination = {
                x = center.x,
                y = center.y - amount * 20.1
            }
            Touch(encoderData.display.index, "press", touchId, center.x, center.y)
            Touch(encoderData.display.index, "move", touchId, destination.x, destination.y)
            Touch(encoderData.display.index, "release", touchId, destination.x, destination.y)
            return true
        end

        local angle = math.max(
            -ENCODER_TOUCH_MAX_ANGLE,
            math.min(ENCODER_TOUCH_MAX_ANGLE, amount * ENCODER_TOUCH_ANGLE_STEP)
        )
        local startPosition = {
            x = center.x + ENCODER_TOUCH_RADIUS,
            y = center.y
        }
        local endPosition = {
            x = center.x + math.cos(angle) * ENCODER_TOUCH_RADIUS,
            y = center.y + math.sin(angle) * ENCODER_TOUCH_RADIUS
        }

        Touch(encoderData.display.index, "press", touchId, center.x, center.y)
        Touch(encoderData.display.index, "move", touchId, startPosition.x, startPosition.y)
        Touch(encoderData.display.index, "move", touchId, endPosition.x, endPosition.y)
        Touch(encoderData.display.index, "release", touchId, endPosition.x, endPosition.y)
        return true
    end)
end

local function clickEncoder(encoderNumber)
    local encoderData = locateEncoder(encoderNumber)
    if encoderData == nil then
        Printf("PAM OSC: active encoder " .. tostring(encoderNumber) .. " was not found")
        return false
    end

    local rect = encoderData.rect
    local centerX = rect.x + rect.w / 2
    local centerY = rect.y + rect.h / 2
    local touchId = encoderNumber + 10
    Touch(encoderData.display.index, "press", touchId, centerX, centerY)
    Touch(encoderData.display.index, "release", touchId, centerX, centerY)
    return true
end

local function handleEncoderArgument(argument)
    if type(argument) ~= "string" then
        return false
    end

    local encoder, amount = string.match(
        argument,
        "^pamEncoderRotate,(%d+),([%+%-]?[%d%.]+)$"
    )
    if encoder ~= nil and amount ~= nil then
        encoder = tonumber(encoder)
        amount = tonumber(amount)
        if encoder ~= nil and encoder >= 1 and encoder <= 5 and amount ~= nil then
            rotateEncoder(encoder, amount)
        else
            Printf("PAM OSC: invalid encoder rotate argument: " .. argument)
        end
        return true
    end

    encoder = string.match(argument, "^pamEncoderClick,(%d+)$")
    if encoder ~= nil then
        encoder = tonumber(encoder)
        if encoder ~= nil and encoder >= 1 and encoder <= 5 then
            clickEncoder(encoder)
        else
            Printf("PAM OSC: invalid encoder click argument: " .. argument)
        end
        return true
    end

    return false
end

-- Configure here, what executors you want to watch:
for i = 101, 122 do
    executorsToWatch[#executorsToWatch + 1] = i
end

for i = 201, 222 do
    executorsToWatch[#executorsToWatch + 1] = i
end

for i = 301, 322 do
    executorsToWatch[#executorsToWatch + 1] = i
end

for i = 401, 422 do
    executorsToWatch[#executorsToWatch + 1] = i
end

for i = 191, 198 do
    executorsToWatch[#executorsToWatch + 1] = i
end

for i = 291, 298 do
    executorsToWatch[#executorsToWatch + 1] = i
end

-- set the default Values
for _, number in ipairs(executorsToWatch) do
    oldValues[number] = "000"
    oldButtonValues[number] = false
    oldColorValues[number] = "0,0,0,0"
    oldNameValues[number] = ";"
end

-- the Speed to check executors
local tick = 1 / 10 -- 1/10
local resendTick = 0

local function getApereanceColor(sequence)
	local apper = sequence["APPEARANCE"]
	local returnText

	local function checkSquenceAppearance(apperH)
		if apperH ~= nil then
            if apperH['BACKR'] == 0 and apperH['BACKG'] == 0 and apperH['BACKB'] == 0 and apperH['BACKALPHA'] == 0 then
                returnText =  "255,255,255,255"
			else
				returnText =  apperH['BACKR'] .. "," ..  apperH['BACKG'] .. "," ..  apperH['BACKB'] .. "," .. apperH['BACKALPHA']
			end
		else
			returnText = "255,255,255,255"
		end
	end


    checkSquenceAppearance(apper)

	if (sequence.preferCueAppearance == true and sequence:CurrentChild()) then
        if (sequence:CurrentChild()[1].Appearance) then
            checkSquenceAppearance(sequence:CurrentChild()[1].Appearance)
        end
    end

  return returnText
end

local function getName(sequence)
    if sequence["CUENAME"] ~= nil then
        return sequence["NAME"] .. ";" .. sequence["CUENAME"]
    end
    return sequence["NAME"] .. ";"
end

local function getMasterEnabled(masterName)
    if MasterPool()['Grand'][masterName]['FADERENABLED'] then
        return true
    else
        return false
    end
end

local function main(displayHandle, argument)
    if handleEncoderArgument(argument) then
        return
    end

    local automaticResendButtons = GetVar(GlobalVars(), "automaticResendButtons") or false
    local sendColors = GetVar(GlobalVars(), "sendColors") or false
    local sendNames = GetVar(GlobalVars(), "sendNames") or false
    local sendTimecode = GetVar(GlobalVars(), "sendTimecode") or false
    local fixedPageNr = GetVar(GlobalVars(), "fixedPageNr") or 0
    local expandedTimecode = GetVar(GlobalVars(), "expandTimecode") or false

    Printf("start pam OSC main()")
    Printf("automaticResendButtons: " .. (automaticResendButtons and "true" or "false"))
    Printf("sendColors: " .. (sendColors and "true" or "false"))
    Printf("sendNames: " .. (sendNames and "true" or "false"))
    Printf("sendTimecode: " .. (sendTimecode and "true" or "false"))
    Printf("fixedPageNr: " .. fixedPageNr)
    Printf("expandedTimecode: " .. (expandedTimecode and "true" or "false"))

    local destPage = 1
    local forceReload = true
    local forceReloadButtons = false

    if GetVar(GlobalVars(), "opdateOSC") ~= nil then
        SetVar(GlobalVars(), "opdateOSC", not GetVar(GlobalVars(), "opdateOSC"))
    else
        SetVar(GlobalVars(), "opdateOSC", true)
    end

    while (GetVar(GlobalVars(), "opdateOSC")) do
        local currentDeskLocked = DeskLocked()
        if currentDeskLocked ~= oldDeskLockedStatus then
            oldDeskLockedStatus = currentDeskLocked
            forceReload = true
        end

        if GetVar(GlobalVars(), "forceReload") == true then
            forceReload = true
            automaticResendButtons = GetVar(GlobalVars(), "automaticResendButtons") or false
            sendColors = GetVar(GlobalVars(), "sendColors") or false
            sendNames = GetVar(GlobalVars(), "sendNames") or false
            sendTimecode = GetVar(GlobalVars(), "sendTimecode") or false
            fixedPageNr = GetVar(GlobalVars(), "fixedPageNr") or 0
            expandedTimecode = GetVar(GlobalVars(), "expandTimecode") or false
            SetVar(GlobalVars(), "forceReload", false)
        end

        if automaticResendButtons then
            resendTick = resendTick + 1
        end
        if resendTick >= 15 then
            forceReloadButtons = true
            resendTick = 0
        end

        -- Check Master Enabled Values
        for masterKey, masterValue in pairs(olsMasterEnabledValue) do
            local currValue = getMasterEnabled(masterKey)
            if currValue ~= masterValue then
                Cmd('SendOSC ' .. oscEntry .. ' "/masterEnabled/' .. masterKey .. ',i,' ..
                        (currValue and 1 or 0) .. '"')
                olsMasterEnabledValue[masterKey] = currValue
            end
        end

        -- Check Page
        local myPage = CurrentExecPage()
        if fixedPageNr ~= nil and tostring(fixedPageNr) ~= "" and tonumber(fixedPageNr) and tonumber(fixedPageNr) ~= 0 then
            local Pages = DataPool().Pages
            local FixedPageRef = tonumber(fixedPageNr)

            if Pages[FixedPageRef] then
            myPage = Pages[FixedPageRef]
            end
        end

        if myPage.index ~= destPage then
            destPage = myPage.index
            for maKey, maValue in pairs(oldValues) do
                oldValues[maKey] = 000
            end
            for maKey, maValue in pairs(oldButtonValues) do
                oldButtonValues[maKey] = false
            end
            forceReload = true
        end

        if forceReload == true then
            Cmd('SendOSC ' .. oscEntry .. ' "/updatePage/current,i,' .. destPage .. '"')
            Cmd('SendOSC ' .. oscEntry .. ' "/status/deskLocked,' ..
                    (currentDeskLocked and "T" or "F") .. '"')
        end

        -- Get all Executors
        local executors = DataPool().Pages[destPage]:Children()

        for listKey, listValue in pairs(executorsToWatch) do
            local faderValue = 0
            local buttonValue = false
            local colorValue = "0,0,0,0"
            local nameValue = ";"
            local isFlash = false

            -- Set Fader & button Values
            for maKey, maValue in pairs(executors) do
                if maValue.No == listValue then
                    local faderOptions = {}
                    faderOptions.value = faderEnd
                    faderOptions.token = "FaderMaster"
                    faderOptions.faderDisabled = false

                    faderValue = maValue:GetFader(faderOptions)
                    isFlash = maValue.KEY == "Flash"

                    local myobject = maValue.Object
                    if myobject ~= nil then
                        buttonValue = myobject:HasActivePlayback() and true or false
                        if sendColors then
                            colorValue = getApereanceColor(myobject)
                        end
                        if sendNames then
                            nameValue = getName(myobject)
                        end
                    end

                end
            end

            -- Send Fader Value
            if (oldValues[listKey] ~= faderValue and not (isFlash and buttonValue and faderValue == 100)) or forceReload then
                hasFaderUpdated = true
                oldValues[listKey] = faderValue
                Cmd('SendOSC ' .. oscEntry .. '  "/Page' .. destPage .. '/Fader' .. listValue .. ',i,' ..
                        (faderValue * 1.27) .. '"')
            end

            -- Send Button Value
            if oldButtonValues[listKey] ~= buttonValue or forceReload or forceReloadButtons then
                oldButtonValues[listKey] = buttonValue
                Cmd('SendOSC ' .. oscEntry .. '  "/Page' .. destPage .. '/Button' .. listValue .. ',s,' ..
                        (buttonValue and "On" or "Off") .. '"')
            end

            -- Send Color Value
            if sendColors and (oldColorValues[listKey] ~= colorValue or forceReload) then
                oldColorValues[listKey] = colorValue
                local newValue = string.gsub(colorValue, ",", ";")
                Cmd('SendOSC ' .. oscEntry .. '  "/Page' .. destPage .. '/Color' .. listValue .. ',s,' .. newValue ..
                        '"')
            end

            -- Send Name Value
            if sendNames and (oldNameValues[listKey] ~= nameValue or forceReload) then
                oldNameValues[listKey] = nameValue
                Cmd('SendOSC ' .. oscEntry .. '  "/Page' .. destPage .. '/Name' .. listValue .. ',s,' .. nameValue ..
                        '"')
            end
        end

        if oldExpandedTimecode ~= expandedTimecode or forceReload then
            oldExpandedTimecode = expandedTimecode
            Cmd('SendOSC ' .. oscEntry .. ' "/expandTimecode,' ..
                    (expandedTimecode and "T" or "F") .. '"')
        end

        -- Preserve the selected feature-group feedback used by the custom
        -- X-Touch mapping and its button LEDs.
        local selectedFeature = SelectedFeature()
        if selectedFeature ~= nil and selectedFeature.name ~= nil then
            local selectedFeatureGroup = selectedFeature.name
            if selectedFeatureGroup ~= oldSelectedFeatureGroup or forceReload then
                oldSelectedFeatureGroup = selectedFeatureGroup
                Cmd('SendOSC ' .. oscEntry .. ' "/selectedFeatureGroup,s,' ..
                        selectedFeatureGroup .. '"')
            end
        end
        
        -- Send Timecode
        if sendTimecode then
            local slots = Root().TimecodeSlots
                
            for _, slot in pairs(slots:Children()) do
                local time = slot.timestring
                
                if oldTimecodes[slot.no] ~= time or oldTimecodes[slot.no] == nil or forceReload == true then
                    oldTimecodes[slot.no] = time
                        
                    Cmd('SendOSC ' .. oscEntry .. ' "/Timecode' .. slot.no .. ',s,' .. time .. '"')
                end
            end
        end
        
        forceReload = false
        forceReloadButtons = false

        -- delay
        coroutine.yield(tick)
    end

end


return main
