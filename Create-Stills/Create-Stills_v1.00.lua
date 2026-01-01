-- Create Stills from Markers Script for DaVinci Resolve
-- Extracts still frames from timeline clips based on marker positions
-- Version: 1.00

local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)

-- ============================================================================
-- CONSTANTS
-- ============================================================================
local WINDOW_WIDTH = 270
local WINDOW_HEIGHT = 150
local ONE_HOUR_FRAMES_MULTIPLIER = 3600  -- Seconds in one hour
local MAX_FOLDER_SEARCH_DEPTH = 10

-- ============================================================================
-- MODULE STATE
-- ============================================================================
local isRunning = false

-- ============================================================================
-- UI SETUP
-- ============================================================================
local win = disp:AddWindow({
	ID = 'MyWin',
	TargetID = 'MyWin',
	WindowTitle = 'Create Stills v1.00',
    Geometry = {200, 250, WINDOW_WIDTH, WINDOW_HEIGHT},
	Spacing = 0,

	ui:VGroup{
		ID = 'root',
		ui:VGroup {
		Weight = 0,
		ID = "GQuick",
            ui:HGroup{
                ui:Label    { Weight = 1, Text = "Marker Type", },
                ui:ComboBox { Weight = 1, ID = "qMarkerColor", CurrentText = "Ref - Blue", Editable = false, Events = { TextChanged = true, },},
            },
			ui:VGap(8),
			ui:HGroup{
				ui:Button{ Weight = 1, ID = "qCreateStills", Text = "Create Stills From Markers",},
			},
		},
    },
})

local itm = win:GetItems()
local notify = ui:AddNotify('Comp_Activate_Tool')

local combobox = win:GetItems().qMarkerColor
combobox:AddItem('Ref - Blue')
combobox:AddItem('QC - Yellow')

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

--- Round a number to specified decimal places
-- @param num number The number to round
-- @param numDecimalPlaces number Number of decimal places (default 0)
-- @return number Rounded number
local function round(num, numDecimalPlaces)
    local mult = 10^(numDecimalPlaces or 0)
    return math.floor(num * mult + 0.5) / mult
end

--- Get the fractional part of a number
-- @param x number The input number
-- @return number The fractional part
local function fract(x)
    return x - math.floor(x)
end

--- Convert frame count to timecode string (HH:MM:SS:FF)
-- @param tlLen number Frame count
-- @param fps number Frames per second (optional, fetched from timeline if nil)
-- @return string Timecode string
local function BMDLength(tlLen, fps)
    -- Get FPS from timeline if not provided
    if not fps then
        local resolve = Resolve()
        if not resolve then return "00:00:00:00" end
        local pm = resolve:GetProjectManager()
        if not pm then return "00:00:00:00" end
        local proj = pm:GetCurrentProject()
        if not proj then return "00:00:00:00" end
        local tl = proj:GetCurrentTimeline()
        if not tl then return "00:00:00:00" end
        fps = tl:GetSetting('timelineFrameRate')
    end

    local secSum = math.floor(tlLen / fps)

    local hours = math.floor(secSum / 3600)
    local minutes = math.floor((secSum % 3600) / 60)
    local seconds = secSum % 60
    local frames = round(fract(tlLen / fps) * fps, 0)

    return string.format("%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
end

--- Convert timecode string to frame count
-- @param tm string Timecode string (HH:MM:SS:FF or subsets)
-- @param fps number Frames per second (optional, fetched from timeline if nil)
-- @return number Frame count
local function BMDTimeFrames(tm, fps)
    -- Get FPS from timeline if not provided
    if not fps then
        local resolve = Resolve()
        if not resolve then return 0 end
        local pm = resolve:GetProjectManager()
        if not pm then return 0 end
        local proj = pm:GetCurrentProject()
        if not proj then return 0 end
        local tl = proj:GetCurrentTimeline()
        if not tl then return 0 end
        fps = tl:GetSetting('timelineFrameRate')
    end

    local sign = 1
    if string.find(tm, "-") then sign = -1 end

    local _, _, hr, mi, se, fr = string.find(tm, "(%d+):(%d+):(%d+):(%d+)")
    if not hr then
        hr = 0
        _, _, mi, se, fr = string.find(tm, "(%d+):(%d+):(%d+)")
    end
    if not mi then
        mi = 0
        _, _, se, fr = string.find(tm, "(%d+):(%d+)")
    end
    if not se then
        se = 0
        _, _, fr = string.find(tm, "(%d+)")
    end
    if not fr then fr = 0 end

    local totalFrames = (hr * 3600 + mi * 60 + se) * fps + fr
    return totalFrames * sign
end

function disp.On.Comp_Activate_Tool(ev)
end

function win.On.MyWin.Close(ev)
	disp:ExitLoop()
end

-- ============================================================================
-- MEDIA POOL SEARCH FUNCTIONS
-- ============================================================================

--- Recursively search for a clip by name in a folder and its subfolders
-- @param folder Folder The folder to search in
-- @param targetName string The clip name to find
-- @param depth number Current recursion depth (for safety)
-- @return table|nil clips Array of clips if found
-- @return number clipIndex Index of found clip (0 if not found)
local function searchFolderRecursive(folder, targetName, depth)
    depth = depth or 0

    -- Prevent infinite recursion
    if depth > MAX_FOLDER_SEARCH_DEPTH then
        return nil, 0
    end

    -- Search clips in this folder
    local clips = folder:GetClipList()
    if clips then
        for i, clip in ipairs(clips) do
            local clipName = clip:GetClipProperty('Clip Name')
            if clipName == targetName then
                return clips, i
            end
        end
    end

    -- Recurse into subfolders
    local subfolders = folder:GetSubFolderList()
    if subfolders then
        for i, subfolder in pairs(subfolders) do
            if i ~= "__flags" then
                local foundClips, foundIndex = searchFolderRecursive(subfolder, targetName, depth + 1)
                if foundClips and foundIndex > 0 then
                    return foundClips, foundIndex
                end
            end
        end
    end

    return nil, 0
end

--- Find a clip in the media pool by name
-- @param timelineItemName string The name of the clip to find
-- @return table|nil clips Array of clips containing the found clip
-- @return number clipIndex Index of found clip (0 if not found)
local function findClipInMediaPool(timelineItemName)
    local resolve = Resolve()
    if not resolve then
        print("Error: Could not connect to DaVinci Resolve")
        return nil, 0
    end

    local pm = resolve:GetProjectManager()
    if not pm then
        print("Error: Could not get Project Manager")
        return nil, 0
    end

    local proj = pm:GetCurrentProject()
    if not proj then
        print("Error: No project is currently open")
        return nil, 0
    end

    local mp = proj:GetMediaPool()
    if not mp then
        print("Error: Could not access Media Pool")
        return nil, 0
    end

    local rootFolder = mp:GetRootFolder()
    if not rootFolder then
        print("Error: Could not access root folder")
        return nil, 0
    end

    return searchFolderRecursive(rootFolder, timelineItemName, 0)
end

-- ============================================================================
-- MAIN MARKER PROCESSING FUNCTION
-- ============================================================================

--- Process markers and create stills timeline
-- @return boolean True if successful
local function RunMarkers()
    local offset = 0
    local duration = 1

    -- Get Resolve objects with nil safety
    local resolve = Resolve()
    if not resolve then
        print("Error: Could not connect to DaVinci Resolve")
        return false
    end

    local projectManager = resolve:GetProjectManager()
    if not projectManager then
        print("Error: Could not get Project Manager")
        return false
    end

    local project = projectManager:GetCurrentProject()
    if not project then
        print("Error: No project is currently open")
        return false
    end

    local mediapool = project:GetMediaPool()
    if not mediapool then
        print("Error: Could not access Media Pool")
        return false
    end

    local timeline = project:GetCurrentTimeline()
    if not timeline then
        print("Error: No timeline is currently selected")
        return false
    end

    local timelineName = timeline:GetName()
    local timelineFPS = timeline:GetSetting('timelineFrameRate')
    local timelineVideoTrackCount = timeline:GetTrackCount("video")

    if not timelineVideoTrackCount or timelineVideoTrackCount == 0 then
        print("Error: No video tracks in timeline")
        return false
    end

    local markerType = tostring(itm.qMarkerColor.CurrentText)
    local colorMarker = ""

    if markerType == "Ref - Blue" then
        colorMarker = "Blue"
    elseif markerType == "QC - Yellow" then
        colorMarker = "Yellow"
    end

    local trackNum = 1
    local clipArr = {}

    local extractedTimeline = nil
    local extractedTimelineName = ""

    -- Always create new timeline
    if markerType == "Ref - Blue" then
        extractedTimelineName = "Ref-Stills_" .. timelineName
    elseif markerType == "QC - Yellow" then
        extractedTimelineName = "QC-Stills_" .. timelineName
    else
        extractedTimelineName = "Stills_" .. timelineName
    end

    -- Prepare folder structure BEFORE creating timeline
    local rootFolder = mediapool:GetRootFolder()
    local timelinesFolder = nil
    local targetBinName = ""

    -- Determine target bin name based on marker type
    if markerType == "Ref - Blue" then
        targetBinName = "Ref-Stills"
    elseif markerType == "QC - Yellow" then
        targetBinName = "QC-Stills"
    end

    -- Get or create Timelines folder
    local timelinesFolderName = "Timelines"
    local subfolders = rootFolder:GetSubFolderList()
    for i, folder in pairs(subfolders) do
        if i ~= "__flags" and folder:GetName() == timelinesFolderName then
            timelinesFolder = folder
            break
        end
    end

    if not timelinesFolder then
        timelinesFolder = mediapool:AddSubFolder(rootFolder, timelinesFolderName)
        print("Created folder: " .. timelinesFolderName)
    end

    -- Get or create target bin folder (Ref-Stills or QC-Stills)
    local targetFolder = nil
    if timelinesFolder and targetBinName ~= "" then
        local targetSubfolders = timelinesFolder:GetSubFolderList()
        for i, folder in pairs(targetSubfolders) do
            if i ~= "__flags" and folder:GetName() == targetBinName then
                targetFolder = folder
                break
            end
        end

        if not targetFolder then
            targetFolder = mediapool:AddSubFolder(timelinesFolder, targetBinName)
            print("Created folder: " .. timelinesFolderName .. "/" .. targetBinName)
        end

        -- Set the target folder as current so timeline will be created there
        mediapool:SetCurrentFolder(targetFolder)
    end

    -- Get source timeline items first (before creating new timeline)
    local timelineItems = timeline:GetItemsInTrack("video", trackNum)
    if not timelineItems then
        print("Error: Could not get items from track " .. trackNum)
        return false
    end

    -- Collect all clips with markers
    for timelineItem in pairs(timelineItems) do
        local currentItem = timelineItems[timelineItem]
        local timelineItemName = currentItem:GetName()
        local timelineItemStartFrame = currentItem:GetStart()
        local timelineItemLeftOffset = currentItem:GetLeftOffset()
        local markers = currentItem:GetMarkers()

        if markers then
            for markerStartFrame in pairs(markers) do
                local markerName = markers[markerStartFrame]['name']
                local markerColor = markers[markerStartFrame]['color']

                if colorMarker == markerColor then
                    local SubClip = {}

                    -- Get MediaPoolItem directly from TimelineItem (more reliable than name search)
                    local clipItm = currentItem:GetMediaPoolItem()
                    if clipItm then
                        local clipFPS = tonumber(clipItm:GetClipProperty('FPS')) or timelineFPS
                        local clipFrames = tonumber(clipItm:GetClipProperty('Frames')) or 0

                        SubClip["mediaPoolItem"] = clipItm

                        local sourceStartFrame = currentItem:GetSourceStartFrame()
                        local actualSourceFrame = sourceStartFrame + markerStartFrame + offset

                        -- Calculate frame positions (ensure within clip bounds)
                        local calcStartFrame = math.floor(actualSourceFrame * clipFPS / timelineFPS)
                        local calcEndFrame = calcStartFrame + math.floor(duration * clipFPS / timelineFPS)

                        -- Clamp to valid range
                        if calcStartFrame < 0 then calcStartFrame = 0 end
                        if calcEndFrame > clipFrames then calcEndFrame = clipFrames end
                        if calcEndFrame <= calcStartFrame then calcEndFrame = calcStartFrame + 1 end

                        SubClip["startFrame"] = calcStartFrame
                        SubClip["endFrame"] = calcEndFrame

                        print("  Found marker at frame " .. markerStartFrame .. " -> source frame " .. calcStartFrame .. "-" .. calcEndFrame .. " (clip has " .. clipFrames .. " frames)")

                        SubClip["originalMarkerFrame"] = markerStartFrame
                        SubClip["markerName"] = markerName
                        SubClip["markerColor"] = markerColor
                        SubClip["calculatedSourceFrame"] = actualSourceFrame
                        SubClip["sourceStartFrame"] = sourceStartFrame
                        SubClip["leftOffset"] = timelineItemLeftOffset

                        local startTimecodeFrames = ONE_HOUR_FRAMES_MULTIPLIER * timelineFPS
                        local timelineClipDuration = duration
                        SubClip["recordFrame"] = startTimecodeFrames + (#clipArr * timelineClipDuration)
                        if #clipArr == 0 then
                            SubClip["recordFrame"] = startTimecodeFrames
                        end

                        SubClip["sourceTimelineItem"] = currentItem
                        SubClip["sourceTimelineName"] = timelineName
                        SubClip["sourceItemStart"] = timelineItemStartFrame
                        SubClip["sourceItemOffset"] = timelineItemLeftOffset

                        table.insert(clipArr, SubClip)
                    else
                        print("Warning: Could not get MediaPoolItem for '" .. timelineItemName .. "'")
                        -- Fallback to search
                        local clipItms, clipIndx = findClipInMediaPool(timelineItemName)
                        if clipItms and clipIndx > 0 then
                            print("    Found via search instead")
                            local foundClip = clipItms[clipIndx]
                            SubClip["mediaPoolItem"] = foundClip
                            SubClip["startFrame"] = 0
                            SubClip["endFrame"] = 1
                            SubClip["sourceTimelineItem"] = currentItem
                            table.insert(clipArr, SubClip)
                        else
                            print("    Could not find clip in Media Pool either")
                        end
                    end
                end
            end
        end
    end

    -- Sort clips by timeline position
    table.sort(clipArr,function(k1,k2)
        return (k1.Position or k1.recordFrame or 0) < (k2.Position or k2.recordFrame or 0)
    end)

    if #clipArr == 0 then
        print("No markers found")
        return false
    end

    -- Build clip arrays for API
    local clipInfoArr = {}  -- With frame ranges
    local mediaPoolItems = {}  -- Just the MediaPoolItems

    for i, SubClip in ipairs(clipArr) do
        local cleanClip = {
            ["mediaPoolItem"] = SubClip["mediaPoolItem"],
            ["startFrame"] = math.floor(SubClip["startFrame"]),
            ["endFrame"] = math.floor(SubClip["endFrame"])
        }
        table.insert(clipInfoArr, cleanClip)
        table.insert(mediaPoolItems, SubClip["mediaPoolItem"])
    end

    -- Switch to Edit page and set folder for timeline creation
    resolve:OpenPage("edit")
    if targetFolder then
        mediapool:SetCurrentFolder(targetFolder)
    end

    -- Create timeline with clips using CreateTimelineFromClips
    print("Creating timeline '" .. extractedTimelineName .. "' with " .. #clipInfoArr .. " clips...")
    extractedTimeline = mediapool:CreateTimelineFromClips(extractedTimelineName, clipInfoArr)

    if extractedTimeline then
        print("Created new timeline: " .. extractedTimelineName)
        if targetFolder then
            print("Timeline created in: " .. timelinesFolderName .. "/" .. targetBinName)
        end

        local success = extractedTimeline:SetStartTimecode("01:00:00:00")
        if success then
            print("Set timeline start timecode to 01:00:00:00")
        else
            print("Warning: Failed to set timeline start timecode")
        end

        -- Switch to extracted timeline
        project:SetCurrentTimeline(extractedTimeline)
        print("Switched to timeline: " .. extractedTimelineName)

        -- Get the new timeline items to copy grades
        local newTimelineItems = extractedTimeline:GetItemsInTrack("video", 1)
        if newTimelineItems then
            -- Build a list to iterate in order
            local orderedNewItems = {}
            for idx, item in pairs(newTimelineItems) do
                if idx ~= "__flags" then
                    table.insert(orderedNewItems, {index = idx, item = item})
                end
            end
            table.sort(orderedNewItems, function(a, b) return a.index < b.index end)

            -- Copy grades from source clips to new clips
            for i, itemData in ipairs(orderedNewItems) do
                local newItem = itemData.item
                if i <= #clipArr then
                    local sourceTimelineItem = clipArr[i]["sourceTimelineItem"]
                    if sourceTimelineItem then
                        local gradesCopied = sourceTimelineItem:CopyGrades({newItem})
                        local clipName = sourceTimelineItem:GetName()
                        print("Added clip " .. i .. ": " .. clipName)
                        if gradesCopied then
                            print("  - Grade copied successfully")
                        else
                            print("  - Warning: Failed to copy grade")
                        end
                    end
                end
            end
        end

        print("\nCreated timeline '" .. extractedTimelineName .. "' with " .. #clipArr .. " clips")
    else
        -- Fallback to CreateEmptyTimeline + AppendToTimeline
        print("CreateTimelineFromClips failed, trying fallback method...")
        extractedTimeline = mediapool:CreateEmptyTimeline(extractedTimelineName)
        if not extractedTimeline then
            print("Failed to create new timeline")
            return false
        end

        print("Created empty timeline: " .. extractedTimelineName)
        extractedTimeline:SetStartTimecode("01:00:00:00")
        project:SetCurrentTimeline(extractedTimeline)

        local n = 0
        for i, SubClip in ipairs(clipArr) do
            n = n + 1
            -- Try adding with clipInfo (frame ranges)
            local cleanClip = {
                ["mediaPoolItem"] = SubClip["mediaPoolItem"],
                ["startFrame"] = math.floor(SubClip["startFrame"]),
                ["endFrame"] = math.floor(SubClip["endFrame"])
            }
            local newItems = mediapool:AppendToTimeline({cleanClip})
            if newItems and #newItems > 0 then
                local sourceTimelineItem = SubClip["sourceTimelineItem"]
                sourceTimelineItem:CopyGrades({newItems[1]})
                print("Added clip " .. n .. ": " .. sourceTimelineItem:GetName())
            else
                print("Failed to add clip " .. n .. " to timeline")
            end
        end

        print("\nCreated timeline '" .. extractedTimelineName .. "' with " .. n .. " clips")
    end

    -- Ensure we're working with the correct timeline
    project:SetCurrentTimeline(extractedTimeline)

    -- Switch to Delivery page
    resolve:OpenPage("deliver")
    print("Switched to Delivery page")

    -- Load Ref-Stills preset for this timeline
    local presetLoaded = project:LoadRenderPreset("Ref-Stills")
    if presetLoaded then
        print("Loaded render preset: Ref-Stills")
    else
        print("Warning: Failed to load Ref-Stills preset")
    end

    -- Add render job for the current timeline (append to existing jobs, don't delete)
    local jobAdded = project:AddRenderJob()
    if jobAdded then
        print("Added render job for timeline: " .. extractedTimelineName)
    else
        print("Warning: Failed to add render job")
    end

    return true
end

function win.On.qCreateStills.Clicked(ev)
    if isRunning then
        print("Script is already running, please wait...")
        return
    end

    isRunning = true
    stopFlag = 0
    RunMarkers()
    isRunning = false
end

--- Move playhead forward or backward
-- @param Forward number Direction: 1 for forward, -1 for backward
-- @param Fast number Fast mode multiplier: 1 for fast, 0 for normal
local function MovePlayhead(Forward, Fast)
    local resolve = Resolve()
    if not resolve then return end

    local pm = resolve:GetProjectManager()
    if not pm then return end

    local proj = pm:GetCurrentProject()
    if not proj then return end

    local tl = proj:GetCurrentTimeline()
    if not tl then return end

    local fps = tl:GetSetting('timelineFrameRate')
    local ctc = tl:GetCurrentTimecode()
    local Data = tl:GetMarkerCustomData(0)

    local _, _, track, clip, framesD, res, offset, length = string.find(Data, "(.+);(.+);(.+);(.+);(.+);(.+)")

    if not framesD then framesD = 1 end
    if not res then res = 1 end
    if not offset then offset = 0 end

    framesD = tonumber(framesD) or 1
    res = tonumber(res) or 1
    offset = tonumber(offset) or 0

    if Fast == 1 then framesD = framesD * res end

    local frames = BMDTimeFrames(ctc, fps)
    frames = frames + framesD * Forward

    if Forward == 1 then
        frames = math.floor((frames + 0.5) / framesD) * framesD + fract(offset / framesD) * framesD
    else
        frames = math.ceil((frames - 0.5 - fract(offset / framesD) * framesD) / framesD) * framesD + fract(offset / framesD) * framesD
    end

    local ctc2 = BMDLength(frames, fps)
    tl:SetCurrentTimecode(ctc2)
end

app:AddConfig('MyWin', {
	Target {
		ID = 'MyWin',
	},

	Hotkeys {
		Target = 'MyWin',
		Defaults = true,

		CONTROL_W = 'Execute{cmd = [[app.UIManager:QueueEvent(obj, "Close", {})]]}',
		CONTROL_F4 = 'Execute{cmd = [[app.UIManager:QueueEvent(obj, "Close", {})]]}',
	},
})

win:Show()

disp:RunLoop()
win:Hide()

app:RemoveConfig('MyWin')
collectgarbage()