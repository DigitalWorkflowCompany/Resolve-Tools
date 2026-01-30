-- DaVinci Resolve - Create Dailies v2.00
-- Combined script: Import multiple camera rolls, create timelines, apply DRX grades, apply CDL values, sync audio
-- New in v2.00: OCF Master Timeline with ALE+CDL export, Audio dailies workflow

local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)

-- ============================================================================
-- CONSTANTS
-- ============================================================================
local WINDOW_WIDTH = 1200
local WINDOW_HEIGHT = 800
local MAX_LUT_SEARCH_DEPTH = 10

-- Supported video file extensions
local VIDEO_EXTENSIONS = {
    ".mov", ".mp4", ".avi", ".mkv", ".mxf", ".r3d", ".braw",
    ".dng", ".dpx", ".exr", ".tiff", ".tif", ".jpg", ".png",
    ".prores", ".dnxhd", ".h264", ".h265", ".webm"
}

-- Supported audio file extensions
local AUDIO_EXTENSIONS = {
    ".wav", ".mp3", ".aif", ".aiff", ".m4a", ".aac",
    ".flac", ".ogg", ".wma"
}

-- LUT search paths
local LUT_SEARCH_PATHS = {
    {path = "/Volumes/Dailies-Storage/2_Resolve/LUT", isSystem = false},
    {path = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT", isSystem = true}
}

-- ============================================================================
-- MODULE STATE
-- ============================================================================
local cameraRolls = {}

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

--- Parse timecode string to frame count for comparison
-- @param timecode string Timecode in format HH:MM:SS:FF or HH:MM:SS;FF
-- @param frameRate number Frame rate (default 24)
-- @return number Frame count
local function timecodeToFrames(timecode, frameRate)
    frameRate = frameRate or 24
    if not timecode or timecode == "" then
        return 0
    end

    -- Handle both : and ; separators (drop frame)
    local h, m, s, f = timecode:match("(%d+)[:%s;](%d+)[:%s;](%d+)[:%s;](%d+)")
    if not h then
        return 0
    end

    h, m, s, f = tonumber(h), tonumber(m), tonumber(s), tonumber(f)
    return ((h * 3600 + m * 60 + s) * frameRate) + f
end

--- Extract camera letter and roll number from clip/bin name for sorting
-- @param name string Clip or bin name (e.g., "A001", "B002_001")
-- @return string, number Camera letter and roll number
local function extractCameraAndRoll(name)
    if not name then
        return "Z", 999999
    end

    -- Match patterns like: A001, A_001, A-001, A001R001, etc.
    local camera = name:match("^([A-Za-z]+)")
    local roll = name:match("^[A-Za-z]+[_%-]?(%d+)")

    camera = camera and camera:upper() or "Z"
    roll = roll and tonumber(roll) or 999999

    return camera, roll
end

--- Find a subfolder by name within a parent folder
-- @param parentFolder Folder The parent folder to search in
-- @param name string The name of the subfolder to find
-- @return Folder|nil The found folder or nil if not found
local function findSubFolderByName(parentFolder, name)
    if not parentFolder then
        return nil
    end

    local subFolders = parentFolder:GetSubFolderList()
    if not subFolders then
        return nil
    end

    for _, folder in ipairs(subFolders) do
        if folder:GetName() == name then
            return folder
        end
    end

    return nil
end

--- Parse a channel selection string into a list of channel numbers
-- Supports formats like: "1,2,5,8" or "1-4,7,8" or "1,3-5,8"
-- @param channelStr string The channel selection string
-- @param maxChannels number Maximum valid channel number (default 16)
-- @return table Array of channel numbers (sorted, unique)
local function parseChannelSelection(channelStr, maxChannels)
    maxChannels = maxChannels or 16
    local channels = {}
    local seen = {}

    if not channelStr or channelStr == "" then
        return channels
    end

    -- Split by comma
    for part in channelStr:gmatch("[^,]+") do
        part = part:match("^%s*(.-)%s*$")  -- Trim whitespace

        -- Check for range (e.g., "1-4")
        local rangeStart, rangeEnd = part:match("^(%d+)%s*%-%s*(%d+)$")
        if rangeStart and rangeEnd then
            rangeStart = tonumber(rangeStart)
            rangeEnd = tonumber(rangeEnd)
            if rangeStart and rangeEnd then
                for ch = rangeStart, rangeEnd do
                    if ch >= 1 and ch <= maxChannels and not seen[ch] then
                        table.insert(channels, ch)
                        seen[ch] = true
                    end
                end
            end
        else
            -- Single number
            local ch = tonumber(part)
            if ch and ch >= 1 and ch <= maxChannels and not seen[ch] then
                table.insert(channels, ch)
                seen[ch] = true
            end
        end
    end

    -- Sort channels
    table.sort(channels)
    return channels
end

-- ============================================================================
-- CCC/EDL PARSING FUNCTIONS
-- ============================================================================

--- Parse a CCC (Color Correction Collection) file
-- @param filepath string Path to the CCC file
-- @return table|nil CDL data table keyed by clip name, or nil on error
-- @return string|nil Error message if parsing failed
local function parseCCC(filepath)
    local cdlData = {}
    local file = io.open(filepath, "r")

    if not file then
        return nil, "Could not open file"
    end

    local content = file:read("*all")
    file:close()

    print("\n=== Parsing CCC File ===")
    print("File length: " .. #content .. " characters")

    local entryCount = 0

    -- Parse each ColorCorrection entry
    local position = 1
    while true do
        local ccStart, ccEnd = content:find("<ColorCorrection", position)
        if not ccStart then
            break
        end

        local closeStart, closeEnd = content:find("</ColorCorrection>", ccEnd)
        if not closeStart then
            break
        end

        local colorCorrection = content:sub(ccStart, closeEnd)
        entryCount = entryCount + 1

        local clipName = colorCorrection:match('id%s*=%s*"([^"]+)"')

        if clipName then
            print("Found entry #" .. entryCount .. ": '" .. clipName .. "'")
            local cdl = {}

            local sopNode = colorCorrection:match("<SOPNode>(.-)</SOPNode>")
            if sopNode then
                local slope = sopNode:match('<Slope>([^<]+)</Slope>')
                local offset = sopNode:match('<Offset>([^<]+)</Offset>')
                local power = sopNode:match('<Power>([^<]+)</Power>')

                if slope then
                    cdl.slope = slope:match("^%s*(.-)%s*$")
                end
                if offset then
                    cdl.offset = offset:match("^%s*(.-)%s*$")
                end
                if power then
                    cdl.power = power:match("^%s*(.-)%s*$")
                end
            end

            local satNode = colorCorrection:match("<SATNode>(.-)</SATNode>")
            if satNode then
                local saturation = satNode:match('<Saturation>([^<]+)</Saturation>')
                if saturation then
                    cdl.saturation = saturation:match("^%s*(.-)%s*$")
                end
            end

            local lutValue = colorCorrection:match("<LUT>([^<]+)</LUT>")
            if lutValue then
                cdl.lut = lutValue:gsub("%s+", "")
            end

            -- Extract metadata fields (Episode, Scene, Shot, Take, Camera)
            local episode = colorCorrection:match("<Episode>([^<]+)</Episode>")
            if episode then
                cdl.episode = episode:match("^%s*(.-)%s*$")
            end

            local scene = colorCorrection:match("<Scene>([^<]+)</Scene>")
            if scene then
                cdl.scene = scene:match("^%s*(.-)%s*$")
            end

            local shot = colorCorrection:match("<Shot>([^<]+)</Shot>")
            if shot then
                cdl.shot = shot:match("^%s*(.-)%s*$")
            end

            local take = colorCorrection:match("<Take>([^<]+)</Take>")
            if take then
                cdl.take = take:match("^%s*(.-)%s*$")
            end

            local camera = colorCorrection:match("<Camera>([^<]+)</Camera>")
            if camera then
                cdl.camera = camera:match("^%s*(.-)%s*$")
            end

            -- Log metadata if present
            if cdl.episode or cdl.scene or cdl.shot or cdl.take or cdl.camera then
                print(string.format("  Metadata: Ep:%s Sc:%s Sh:%s Tk:%s Cam:%s",
                    cdl.episode or "-",
                    cdl.scene or "-",
                    cdl.shot or "-",
                    cdl.take or "-",
                    cdl.camera or "-"))
            end

            cdlData[clipName] = cdl
        end

        position = closeEnd + 1
    end

    print("Total entries parsed: " .. entryCount)
    print("=== End of CCC Parsing ===\n")

    return cdlData
end

--- Parse an EDL (Edit Decision List) file for CDL values
-- @param filepath string Path to the EDL file
-- @return table|nil CDL data table keyed by clip name, or nil on error
local function parseEDL(filepath)
    local cdlData = {}
    local file = io.open(filepath, "r")

    if not file then
        return nil, "Could not open file"
    end

    local currentClip = nil

    for line in file:lines() do
        local eventNum = line:match("^%d+%s+")
        if eventNum then
            local fields = {}
            for field in line:gmatch("[^\t]+") do
                table.insert(fields, field)
            end

            if #fields >= 2 then
                currentClip = fields[2]:match("^%s*(.-)%s*$")
            end
        end

        if currentClip and line:match("%*%s*ASC_SOP") then
            if not cdlData[currentClip] then
                cdlData[currentClip] = {}
            end

            local sop = line:match("%*%s*ASC_SOP%s+%(([^)]+)%)")
            if sop then
                local values = {}
                for val in sop:gmatch("[^%s]+") do
                    table.insert(values, val)
                end

                if #values >= 9 then
                    cdlData[currentClip].slope = values[1] .. " " .. values[2] .. " " .. values[3]
                    cdlData[currentClip].offset = values[4] .. " " .. values[5] .. " " .. values[6]
                    cdlData[currentClip].power = values[7] .. " " .. values[8] .. " " .. values[9]
                end
            end
        end

        if currentClip and line:match("%*%s*ASC_SAT") then
            if not cdlData[currentClip] then
                cdlData[currentClip] = {}
            end

            local sat = line:match("%*%s*ASC_SAT%s+([%d%.]+)")
            if sat then
                cdlData[currentClip].saturation = sat
            end
        end
    end

    file:close()
    return cdlData
end

--- Recursively search for a LUT file by name
-- @param lutName string Name of the LUT file to find
-- @param searchPath string Directory to search in
-- @param depth number Current recursion depth (optional)
-- @return string|nil Full path to LUT if found
local function findLUTFile(lutName, searchPath, depth)
    depth = depth or 0

    if depth > MAX_LUT_SEARCH_DEPTH then
        return nil
    end

    local handle = io.popen('ls "' .. searchPath .. '" 2>/dev/null')
    if not handle then
        return nil
    end

    local items = handle:read("*a")
    handle:close()

    for item in items:gmatch("[^\r\n]+") do
        local fullPath = searchPath .. "/" .. item

        if item == lutName then
            return fullPath
        end

        local dirCheck = io.popen('test -d "' .. fullPath .. '" && echo "dir"')
        if dirCheck then
            local isDir = dirCheck:read("*l")
            dirCheck:close()

            if isDir == "dir" then
                local found = findLUTFile(lutName, fullPath, depth + 1)
                if found then
                    return found
                end
            end
        end
    end

    return nil
end

--- Search for LUT in standard locations
-- @param lutName string Name of the LUT file to find
-- @return string|nil Absolute path to LUT if found
-- @return string|nil Relative path from LUT root if found
local function searchForLUT(lutName)
    if not lutName or lutName == "" then
        return nil
    end

    print("\nSearching for LUT: " .. lutName)

    for _, searchInfo in ipairs(LUT_SEARCH_PATHS) do
        print("Searching in: " .. searchInfo.path)
        local found = findLUTFile(lutName, searchInfo.path)
        if found then
            local relativePath = found:gsub("^" .. searchInfo.path:gsub("([^%w])", "%%%1") .. "/", "")
            return found, relativePath
        end
    end

    print("LUT not found in any search location: " .. lutName)
    return nil, nil
end

--- Apply CDL values to a timeline clip
-- @param clip TimelineItem The timeline clip to apply CDL to
-- @param cdl table CDL data containing slope, offset, power, saturation values
-- @return boolean True if CDL was applied successfully
local function applyCDL(clip, cdl)
    local cdlMap = {
        NodeIndex = "1"
    }

    if cdl.slope then
        cdlMap["Slope"] = cdl.slope
    end

    if cdl.offset then
        cdlMap["Offset"] = cdl.offset
    end

    if cdl.power then
        cdlMap["Power"] = cdl.power
    end

    if cdl.saturation then
        cdlMap["Saturation"] = cdl.saturation
    end

    local success = clip:SetCDL(cdlMap)

    if success then
        print("    CDL applied successfully")
    end

    return success
end

--- Apply metadata from CCC to a timeline clip's source MediaPoolItem
-- @param clip TimelineItem The timeline clip
-- @param cdl table CDL data containing episode, scene, shot, take, camera values
-- @return boolean True if any metadata was applied successfully
local function applyMetadata(clip, cdl)
    -- Check if there's any metadata to apply
    if not (cdl.episode or cdl.scene or cdl.shot or cdl.take or cdl.camera) then
        return false
    end

    -- Get the MediaPoolItem from the timeline clip
    local mediaPoolItem = clip:GetMediaPoolItem()
    if not mediaPoolItem then
        print("    Warning: Could not get MediaPoolItem for metadata")
        return false
    end

    local appliedCount = 0

    -- Apply Episode metadata (Resolve UI shows "Episode #")
    if cdl.episode then
        local success = mediaPoolItem:SetMetadata("Episode #", cdl.episode)
        if success then
            appliedCount = appliedCount + 1
        else
            print("    Warning: Failed to set Episode # metadata")
        end
    end

    -- Apply Scene metadata
    if cdl.scene then
        local success = mediaPoolItem:SetMetadata("Scene", cdl.scene)
        if success then
            appliedCount = appliedCount + 1
        else
            print("    Warning: Failed to set Scene metadata")
        end
    end

    -- Apply Shot metadata
    if cdl.shot then
        local success = mediaPoolItem:SetMetadata("Shot", cdl.shot)
        if success then
            appliedCount = appliedCount + 1
        else
            print("    Warning: Failed to set Shot metadata")
        end
    end

    -- Apply Take metadata
    if cdl.take then
        local success = mediaPoolItem:SetMetadata("Take", cdl.take)
        if success then
            appliedCount = appliedCount + 1
        else
            print("    Warning: Failed to set Take metadata")
        end
    end

    -- Apply Camera metadata (Resolve UI shows "Camera #")
    if cdl.camera then
        local success = mediaPoolItem:SetMetadata("Camera #", cdl.camera)
        if success then
            appliedCount = appliedCount + 1
        else
            print("    Warning: Failed to set Camera # metadata")
        end
    end

    if appliedCount > 0 then
        print(string.format("    Metadata applied: Ep:%s Sc:%s Sh:%s Tk:%s Cam:%s",
            cdl.episode or "-",
            cdl.scene or "-",
            cdl.shot or "-",
            cdl.take or "-",
            cdl.camera or "-"))
    end

    return appliedCount > 0
end

-- ============================================================================
-- IMPORT HELPER FUNCTIONS
-- ============================================================================

--- Check if a file has a supported video extension
-- @param fileName string The filename to check
-- @return boolean True if file has a video extension
local function isVideoFile(fileName)
    if not fileName then return false end

    local lowerName = fileName:lower()
    for _, ext in ipairs(VIDEO_EXTENSIONS) do
        if lowerName:sub(-#ext) == ext then
            return true
        end
    end
    return false
end

--- Check if a file has a supported audio extension
-- @param fileName string The filename to check
-- @return boolean True if file has an audio extension
local function isAudioFile(fileName)
    if not fileName then return false end

    local lowerName = fileName:lower()
    for _, ext in ipairs(AUDIO_EXTENSIONS) do
        if lowerName:sub(-#ext) == ext then
            return true
        end
    end
    return false
end

--- Recursively scan directory for audio files
-- @param mediaStorage MediaStorage Resolve MediaStorage object
-- @param basePath string Base path to scan
-- @param audioFiles table Table to accumulate found files (optional)
-- @param depth number Current recursion depth (optional)
-- @return table Array of full paths to audio files
local function scanAudioRecursive(mediaStorage, basePath, audioFiles, depth)
    audioFiles = audioFiles or {}
    depth = depth or 0
    local indent = string.rep("  ", depth)

    print(indent .. "Scanning: " .. basePath)

    local subFolders = mediaStorage:GetSubFolderList(basePath)
    local items = mediaStorage:GetFileList(basePath)

    if items and #items > 0 then
        for _, item in ipairs(items) do
            local fullPath
            local fileName

            if item:sub(1, 1) == "/" or item:sub(2, 2) == ":" then
                fullPath = item
                fileName = item:match("([^/]+)$")
            else
                fullPath = basePath .. "/" .. item
                fileName = item
            end

            if isAudioFile(fileName) then
                print(indent .. "  + Audio file: " .. fileName)
                table.insert(audioFiles, fullPath)
            end
        end
    end

    if subFolders and #subFolders > 0 then
        for _, subFolder in ipairs(subFolders) do
            local subFolderPath
            if subFolder:sub(1, 1) == "/" or subFolder:sub(2, 2) == ":" then
                subFolderPath = subFolder
            else
                subFolderPath = basePath .. "/" .. subFolder
            end
            scanAudioRecursive(mediaStorage, subFolderPath, audioFiles, depth + 1)
        end
    end

    return audioFiles
end

--- Recursively scan directories and collect all video files
-- @param mediaStorage MediaStorage Resolve MediaStorage object
-- @param basePath string Base path to scan
-- @param videoFiles table Table to accumulate found files (optional)
-- @param depth number Current recursion depth (optional)
-- @return table Array of full paths to video files
local function scanDirectoryRecursive(mediaStorage, basePath, videoFiles, depth)
    videoFiles = videoFiles or {}
    depth = depth or 0

    local indent = string.rep("  ", depth)
    print(indent .. "Scanning: " .. basePath)

    local subFolders = mediaStorage:GetSubFolderList(basePath)

    if subFolders and #subFolders > 0 then
        print(indent .. "Found " .. #subFolders .. " subdirectories")
    end

    local items = mediaStorage:GetFileList(basePath)

    if items and #items > 0 then
        for _, item in ipairs(items) do
            local fullPath
            local fileName

            if item:sub(1, 1) == "/" or item:sub(2, 2) == ":" then
                fullPath = item
                fileName = item:match("([^/]+)$")
            else
                fullPath = basePath .. "/" .. item
                fileName = item
            end

            if isVideoFile(fileName) then
                print(indent .. "  + Video file: " .. fileName)
                table.insert(videoFiles, fullPath)
            end
        end
    end

    if subFolders and #subFolders > 0 then
        for _, subFolder in ipairs(subFolders) do
            local subFolderPath
            if subFolder:sub(1, 1) == "/" or subFolder:sub(2, 2) == ":" then
                subFolderPath = subFolder
            else
                subFolderPath = basePath .. "/" .. subFolder
            end
            scanDirectoryRecursive(mediaStorage, subFolderPath, videoFiles, depth + 1)
        end
    end

    return videoFiles
end

-- ============================================================================
-- OCF MASTER TIMELINE FUNCTIONS (NEW IN v2.00)
-- ============================================================================

--- Collect all clips from OCF bins recursively
-- @param mediaPool MediaPool The media pool object
-- @return table Array of {clip, camera, roll, binName} tables
local function collectAllOCFClips(mediaPool)
    local allClips = {}
    local rootFolder = mediaPool:GetRootFolder()

    -- Find OCF folder using helper function
    local ocfFolder = findSubFolderByName(rootFolder, "OCF")

    if not ocfFolder then
        print("Warning: OCF folder not found in Media Pool")
        return allClips
    end

    print("\n=== Collecting clips from OCF folder ===")

    -- Iterate through camera folders (A-Cam, B-Cam, etc.)
    local cameraFolders = ocfFolder:GetSubFolderList()
    if not cameraFolders then
        print("No camera folders found in OCF")
        return allClips
    end

    for _, camFolder in ipairs(cameraFolders) do
        local camName = camFolder:GetName()
        print("Scanning camera folder: " .. camName)

        -- Get roll folders inside camera folder
        local rollFolders = camFolder:GetSubFolderList()
        if rollFolders then
            for _, rollFolder in ipairs(rollFolders) do
                local rollName = rollFolder:GetName()
                print("  Scanning roll: " .. rollName)

                local clipsInRoll = rollFolder:GetClipList()
                if clipsInRoll then
                    local camera, roll = extractCameraAndRoll(rollName)

                    for _, clip in ipairs(clipsInRoll) do
                        -- Get clip start timecode for sorting
                        local startTC = clip:GetClipProperty("Start TC") or "00:00:00:00"
                        local frameRate = tonumber(clip:GetClipProperty("FPS")) or 24
                        local startFrames = timecodeToFrames(startTC, frameRate)

                        table.insert(allClips, {
                            clip = clip,
                            camera = camera,
                            roll = roll,
                            binName = rollName,
                            startTC = startTC,
                            startFrames = startFrames,
                            clipName = clip:GetName()
                        })
                    end
                    print("    Found " .. #clipsInRoll .. " clips")
                end
            end
        end
    end

    print("Total clips collected from OCF: " .. #allClips)
    return allClips
end

--- Sort clips by Camera -> Roll -> Start Timecode
-- @param clips table Array of clip info tables from collectAllOCFClips
-- @return table Sorted array
local function sortClipsByCameraRollTimecode(clips)
    table.sort(clips, function(a, b)
        -- First sort by camera letter
        if a.camera ~= b.camera then
            return a.camera < b.camera
        end
        -- Then by roll number
        if a.roll ~= b.roll then
            return a.roll < b.roll
        end
        -- Finally by start timecode (frame count)
        return a.startFrames < b.startFrames
    end)

    return clips
end

--- Create a master timeline from all OCF clips
-- @param mediaPool MediaPool The media pool object
-- @param project Project The current project
-- @param timelineName string Name for the new timeline
-- @return Timeline|nil The created timeline or nil on failure
local function createOCFMasterTimeline(mediaPool, project, timelineName)
    print("\n=== Creating OCF Master Timeline ===")
    print("Timeline name: " .. timelineName)

    -- Collect all OCF clips
    local allClipInfo = collectAllOCFClips(mediaPool)

    if #allClipInfo == 0 then
        print("Error: No clips found in OCF bins")
        return nil
    end

    -- Sort by Camera -> Roll -> Timecode
    print("\nSorting clips by Camera -> Roll -> Timecode...")
    sortClipsByCameraRollTimecode(allClipInfo)

    -- Print sorted order
    print("\nClip order for timeline:")
    for i, info in ipairs(allClipInfo) do
        print(string.format("  %d. [%s] %s - %s (TC: %s)",
            i, info.camera, info.binName, info.clipName, info.startTC))
    end

    -- Extract just the MediaPoolItem objects in sorted order
    local sortedClips = {}
    for _, info in ipairs(allClipInfo) do
        table.insert(sortedClips, info.clip)
    end

    -- Find or create Timelines folder
    local rootFolder = mediaPool:GetRootFolder()
    local timelinesFolder = findSubFolderByName(rootFolder, "Timelines")

    if not timelinesFolder then
        timelinesFolder = mediaPool:AddSubFolder(rootFolder, "Timelines")
        if timelinesFolder then
            print("Created 'Timelines' bin")
        end
    end

    -- Set Timelines folder as current
    if timelinesFolder then
        mediaPool:SetCurrentFolder(timelinesFolder)
    end

    -- Create timeline with all clips
    print("\nCreating timeline with " .. #sortedClips .. " clips...")
    local newTimeline = mediaPool:CreateTimelineFromClips(timelineName, sortedClips)

    if newTimeline then
        print("Successfully created timeline: " .. timelineName)
        project:SetCurrentTimeline(newTimeline)
        return newTimeline
    else
        print("Error: Failed to create timeline")
        return nil
    end
end

--- Export timeline as ALE with CDL values
-- @param timeline Timeline The timeline to export
-- @param resolve Resolve The Resolve API object
-- @param exportPath string Full path for the ALE file
-- @return boolean True if export was successful
local function exportALEWithCDL(timeline, resolve, exportPath)
    if not timeline then
        print("Error: No timeline provided for ALE export")
        return false
    end

    print("\n=== Exporting ALE with CDL ===")
    print("Timeline: " .. timeline:GetName())
    print("Export path: " .. exportPath)

    -- Ensure path has .ale extension
    if not exportPath:lower():match("%.ale$") then
        exportPath = exportPath .. ".ale"
    end

    -- Export using EXPORT_ALE_CDL
    local success = timeline:Export(exportPath, resolve.EXPORT_ALE_CDL, resolve.EXPORT_NONE)

    if success then
        print("Successfully exported ALE with CDL: " .. exportPath)
    else
        print("Failed to export ALE")
    end

    return success
end

-- ============================================================================
-- AUDIO DAILIES FUNCTIONS (NEW IN v2.00)
-- ============================================================================

--- Import audio files and create a timeline with ALE export
-- @param mediaPool MediaPool The media pool object
-- @param mediaStorage MediaStorage The media storage object
-- @param project Project The current project
-- @param resolve Resolve The Resolve API object
-- @param audioPath string Path to audio directory
-- @param binName string Name for the audio bin
-- @param timelineName string Name for the timeline
-- @param aleExportPath string Path for ALE export
-- @return boolean True if successful
local function createAudioDailies(mediaPool, mediaStorage, project, resolve, audioPath, binName, timelineName, aleExportPath)
    print("\n" .. string.rep("=", 70))
    print("=== AUDIO DAILIES WORKFLOW ===")
    print(string.rep("=", 70))
    print("Audio source: " .. audioPath)
    print("Bin name: " .. binName)
    print("Timeline name: " .. timelineName)
    print("ALE export: " .. aleExportPath)

    -- Remove trailing slash
    audioPath = audioPath:gsub("/$", "")

    -- Scan audio directory
    print("\nScanning audio directory recursively...")
    local audioFiles = scanAudioRecursive(mediaStorage, audioPath, {}, 0)

    if not audioFiles or #audioFiles == 0 then
        print("Error: No audio files found in " .. audioPath)
        return false
    end

    print("Found " .. #audioFiles .. " audio files")

    -- Create audio bin
    local rootFolder = mediaPool:GetRootFolder()

    -- Check if bin already exists
    local audioFolder = findSubFolderByName(rootFolder, binName)

    if audioFolder then
        print("Using existing bin: " .. binName)
    else
        audioFolder = mediaPool:AddSubFolder(rootFolder, binName)
        if audioFolder then
            print("Created audio bin: " .. binName)
        else
            print("Error: Failed to create audio bin: " .. binName)
            return false
        end
    end

    -- Set audio folder as current
    mediaPool:SetCurrentFolder(audioFolder)

    -- Import audio files
    print("\nImporting audio files...")
    local importedClips = mediaStorage:AddItemListToMediaPool(audioFiles)

    if not importedClips or #importedClips == 0 then
        print("Batch import failed, trying individual imports...")
        importedClips = {}
        for _, file in ipairs(audioFiles) do
            local fileName = file:match("([^/]+)$")
            local singleImport = mediaStorage:AddItemListToMediaPool({file})
            if singleImport and #singleImport > 0 then
                for _, clip in ipairs(singleImport) do
                    table.insert(importedClips, clip)
                end
            end
        end
    end

    if not importedClips or #importedClips == 0 then
        print("Error: Failed to import any audio files")
        return false
    end

    print("Successfully imported " .. #importedClips .. " audio clips")

    -- Get clips from bin and sort by timecode
    local clipsInBin = audioFolder:GetClipList()
    if not clipsInBin or #clipsInBin == 0 then
        print("Error: No clips found in audio bin")
        return false
    end

    -- Sort audio clips by start timecode
    print("\nSorting audio clips by timecode...")
    local clipInfoArray = {}
    for _, clip in ipairs(clipsInBin) do
        local startTC = clip:GetClipProperty("Start TC") or "00:00:00:00"
        local frameRate = tonumber(clip:GetClipProperty("FPS")) or 24
        local startFrames = timecodeToFrames(startTC, frameRate)

        table.insert(clipInfoArray, {
            clip = clip,
            startTC = startTC,
            startFrames = startFrames,
            clipName = clip:GetName()
        })
    end

    table.sort(clipInfoArray, function(a, b)
        return a.startFrames < b.startFrames
    end)

    -- Extract sorted clips
    local sortedClips = {}
    print("\nAudio clip order:")
    for i, info in ipairs(clipInfoArray) do
        print(string.format("  %d. %s (TC: %s)", i, info.clipName, info.startTC))
        table.insert(sortedClips, info.clip)
    end

    -- Find or create Timelines folder
    local timelinesFolder = findSubFolderByName(rootFolder, "Timelines")

    if not timelinesFolder then
        timelinesFolder = mediaPool:AddSubFolder(rootFolder, "Timelines")
    end

    if timelinesFolder then
        mediaPool:SetCurrentFolder(timelinesFolder)
    end

    -- Create audio timeline
    print("\nCreating audio timeline: " .. timelineName)
    local audioTimeline = mediaPool:CreateTimelineFromClips(timelineName, sortedClips)

    if not audioTimeline then
        print("Error: Failed to create audio timeline")
        return false
    end

    print("Successfully created audio timeline: " .. timelineName)
    project:SetCurrentTimeline(audioTimeline)

    -- Export ALE
    local aleSuccess = exportALEWithCDL(audioTimeline, resolve, aleExportPath)

    print("\n=== Audio Dailies Complete ===")
    return aleSuccess
end

-- ============================================================================
-- CAMERA ROLL PROCESSING FUNCTION
-- ============================================================================

--- Process a single camera roll: import clips, optionally create timeline, apply grades
-- @param cameraRoll table Camera roll configuration (clipPath, binName, timelineName, drxPath)
-- @param resolve Resolve The Resolve API object
-- @param project Project The current project
-- @param mediaPool MediaPool The media pool object
-- @param mediaStorage MediaStorage The media storage object
-- @param cdlPath string|nil Path to CDL file (optional)
-- @param skipTimeline boolean If true, skip timeline creation (for audio sync workflow)
-- @return boolean True if processing was successful
local function processCameraRoll(cameraRoll, resolve, project, mediaPool, mediaStorage, cdlPath, skipTimeline)
    print("\n=== Processing Camera Roll: " .. cameraRoll.binName .. " ===")

    local clipPath = cameraRoll.clipPath
    local binName = cameraRoll.binName
    local timelineName = cameraRoll.timelineName
    local drxPath = cameraRoll.drxPath

    -- ========================================================================
    -- STEP 1: CREATE BIN AND IMPORT CLIPS
    -- ========================================================================

    local rootFolder = mediaPool:GetRootFolder()

    local cameraDesignation = binName:match("^([A-Za-z]+)")
    local cameraFolderName = "Unknown-Cam"

    if cameraDesignation then
        cameraFolderName = cameraDesignation:upper() .. "-Cam"
        print("Detected camera designation: " .. cameraFolderName)
    end

    -- Create or find "OCF" bin
    local ocfFolder = findSubFolderByName(rootFolder, "OCF")

    if not ocfFolder then
        ocfFolder = mediaPool:AddSubFolder(rootFolder, "OCF")
        if ocfFolder then
            print("Created new 'OCF' bin")
        else
            print("Error: Failed to create 'OCF' bin")
            return false
        end
    end

    -- Create or find camera folder inside OCF
    mediaPool:SetCurrentFolder(ocfFolder)
    local cameraFolder = findSubFolderByName(ocfFolder, cameraFolderName)

    if not cameraFolder then
        cameraFolder = mediaPool:AddSubFolder(ocfFolder, cameraFolderName)
        if cameraFolder then
            print("Created new '" .. cameraFolderName .. "' bin inside OCF")
        else
            print("Error: Failed to create camera folder")
            return false
        end
    end

    -- Create roll-specific bin
    mediaPool:SetCurrentFolder(cameraFolder)
    local targetFolder = mediaPool:AddSubFolder(cameraFolder, binName)

    if not targetFolder then
        print("Error: Failed to create bin '" .. binName .. "'")
        return false
    end

    print("Created: OCF/" .. cameraFolderName .. "/" .. binName)

    mediaPool:SetCurrentFolder(targetFolder)

    clipPath = clipPath:gsub("/$", "")

    print("Scanning directory: " .. clipPath)
    local videoFiles = scanDirectoryRecursive(mediaStorage, clipPath)

    if not videoFiles or #videoFiles == 0 then
        print("Error: No video files found")
        return false
    end

    print("Found " .. #videoFiles .. " video files")

    print("\nImporting files...")
    local importedClips = mediaStorage:AddItemListToMediaPool(videoFiles)

    if not importedClips or #importedClips == 0 then
        print("Batch import failed, trying individual imports...")
        importedClips = {}
        for _, file in ipairs(videoFiles) do
            local singleImport = mediaStorage:AddItemListToMediaPool({file})
            if singleImport and #singleImport > 0 then
                for _, clip in ipairs(singleImport) do
                    table.insert(importedClips, clip)
                end
            end
        end
    end

    if not importedClips or #importedClips == 0 then
        print("Error: Failed to import files")
        return false
    end

    print("Imported " .. #importedClips .. " clips")

    -- If skipTimeline is true, we're done (audio sync workflow will create timelines later)
    if skipTimeline then
        print("Skipping timeline creation (will be created after audio sync)")
        resolve:OpenPage("media")
        mediaPool:SetCurrentFolder(rootFolder)
        print("=== Camera Roll Import Complete: " .. binName .. " ===")
        return true
    end

    -- ========================================================================
    -- STEP 2: CREATE TIMELINE
    -- ========================================================================

    local timelinesFolder = findSubFolderByName(rootFolder, "Timelines")

    if not timelinesFolder then
        timelinesFolder = mediaPool:AddSubFolder(rootFolder, "Timelines")
    end

    mediaPool:SetCurrentFolder(targetFolder)
    local clipsInBin = targetFolder:GetClipList()
    if not clipsInBin or #clipsInBin == 0 then
        print("Error: No clips in bin")
        return false
    end

    if timelinesFolder then
        mediaPool:SetCurrentFolder(timelinesFolder)
    end

    print("Creating timeline: " .. timelineName)
    local newTimeline = mediaPool:CreateTimelineFromClips(timelineName, clipsInBin)

    local timelineItems = {}

    if newTimeline then
        print("Created timeline: " .. timelineName)
        project:SetCurrentTimeline(newTimeline)

        local trackCount = newTimeline:GetTrackCount("video")
        for track = 1, trackCount do
            local items = newTimeline:GetItemListInTrack("video", track)
            if items then
                for _, item in ipairs(items) do
                    table.insert(timelineItems, item)
                end
            end
        end
    else
        print("CreateTimelineFromClips failed, trying fallback...")
        local emptyTimeline = mediaPool:CreateEmptyTimeline(timelineName)
        if not emptyTimeline then
            print("Error: Failed to create timeline")
            return false
        end

        project:SetCurrentTimeline(emptyTimeline)
        mediaPool:SetCurrentFolder(targetFolder)

        local appendResult = mediaPool:AppendToTimeline(clipsInBin)
        if appendResult and #appendResult > 0 then
            timelineItems = appendResult
        end
        newTimeline = emptyTimeline
    end

    if #timelineItems == 0 then
        print("Error: No clips in timeline")
        return false
    end

    print("Timeline has " .. #timelineItems .. " clips")

    -- ========================================================================
    -- STEP 3: APPLY DRX FILE
    -- ========================================================================

    if drxPath and drxPath ~= "" then
        local file = io.open(drxPath, "r")
        if not file then
            print("Error: DRX file not found: " .. drxPath)
            return false
        else
            file:close()
        end

        resolve:OpenPage("color")

        print("Applying DRX grades...")
        local successCount = 0

        for _, timelineItem in ipairs(timelineItems) do
            local nodeGraph = timelineItem:GetNodeGraph()
            if nodeGraph then
                local success = nodeGraph:ApplyGradeFromDRX(drxPath, 0)
                if success then
                    successCount = successCount + 1
                end
            end
        end

        print("DRX applied to " .. successCount .. " clips")
    end

    -- ========================================================================
    -- STEP 4: APPLY CDL VALUES AND LUTS
    -- ========================================================================

    if cdlPath and cdlPath ~= "" then
        project:RefreshLUTList()

        local cdlData = nil
        local fileExt = cdlPath:match("%.([^%.]+)$")

        if not fileExt then
            print("Error: Could not determine CDL file extension")
            return false
        end

        fileExt = fileExt:lower()

        if fileExt == "ccc" then
            cdlData = parseCCC(cdlPath)
        elseif fileExt == "edl" then
            cdlData = parseEDL(cdlPath)
        else
            print("Error: Unsupported CDL format")
            return false
        end

        if not cdlData then
            print("Error: Failed to parse CDL file")
            return false
        end

        resolve:OpenPage("color")

        local appliedCount = 0

        for _, clip in ipairs(timelineItems) do
            local clipName = clip:GetName()
            local cdlEntry = nil
            local matchedName = nil

            if cdlData[clipName] then
                cdlEntry = cdlData[clipName]
                matchedName = clipName
            else
                local clipNameNoExt = clipName:match("(.+)%.[^.]+$") or clipName
                if cdlData[clipNameNoExt] then
                    cdlEntry = cdlData[clipNameNoExt]
                    matchedName = clipNameNoExt
                else
                    for cdlName, cdl in pairs(cdlData) do
                        if clipName:find(cdlName, 1, true) or cdlName:find(clipName, 1, true) then
                            cdlEntry = cdl
                            matchedName = cdlName
                            break
                        end
                        if clipNameNoExt:find(cdlName, 1, true) or cdlName:find(clipNameNoExt, 1, true) then
                            cdlEntry = cdl
                            matchedName = cdlName
                            break
                        end
                    end
                end
            end

            if cdlEntry then
                print("  Matching clip '" .. clipName .. "' to CDL entry '" .. matchedName .. "'")
                local success = applyCDL(clip, cdlEntry)
                if success then
                    appliedCount = appliedCount + 1
                else
                    print("    Warning: Failed to apply CDL to clip '" .. clipName .. "'")
                end

                -- Apply metadata (Episode, Scene, Shot, Take, Camera)
                applyMetadata(clip, cdlEntry)

                if cdlEntry.lut then
                    local lutAbsolutePath, lutRelativePath = searchForLUT(cdlEntry.lut)
                    if lutAbsolutePath then
                        local nodeGraph = clip:GetNodeGraph()
                        local numNodes = nodeGraph and nodeGraph:GetNumNodes() or 0
                        if numNodes >= 2 then
                            local lutSuccess = clip:SetLUT(2, lutRelativePath)
                            if not lutSuccess then
                                clip:SetLUT(2, lutAbsolutePath)
                            end
                        end
                    end
                end
            else
                print("  No CDL match found for clip '" .. clipName .. "'")
            end
        end

        print("CDLs applied to " .. appliedCount .. " of " .. #timelineItems .. " clips")
    end

    -- ========================================================================
    -- STEP 5: FINALIZE
    -- ========================================================================

    resolve:OpenPage("media")
    mediaPool:SetCurrentFolder(rootFolder)

    print("=== Camera Roll Complete: " .. binName .. " ===")
    return true
end

-- ============================================================================
-- CREATE TIMELINES FROM SYNCED CLIPS
-- ============================================================================

--- Create a timeline from synced clips for a specific camera roll
-- @param cameraRoll table Camera roll configuration
-- @param syncedClips table Array of synced MediaPoolItems
-- @param resolve Resolve The Resolve API object
-- @param project Project The current project
-- @param mediaPool MediaPool The media pool object
-- @param cdlPath string|nil Path to CDL file (optional)
-- @return boolean True if timeline was created successfully
local function createTimelineFromSyncedClips(cameraRoll, syncedClips, resolve, project, mediaPool, cdlPath, audioTrackSettings)
    local binName = cameraRoll.binName
    local timelineName = cameraRoll.timelineName
    local drxPath = cameraRoll.drxPath

    -- Default audio track settings if not provided
    audioTrackSettings = audioTrackSettings or { allMonoTracks = true, selectedChannels = {} }

    print("\n=== Creating Timeline for: " .. binName .. " ===")
    print("  Timeline name: " .. (timelineName or "nil"))
    print("  DRX path: " .. (drxPath or "none"))
    print("  Input clips: " .. #syncedClips)

    -- Build audio tracks description for logging
    local audioTrackDesc = "All mono"
    if not audioTrackSettings.allMonoTracks and audioTrackSettings.selectedChannels and #audioTrackSettings.selectedChannels > 0 then
        audioTrackDesc = "Selected channels: " .. table.concat(audioTrackSettings.selectedChannels, ", ")
    end
    print("  Audio tracks: " .. audioTrackDesc)

    -- Find synced clips that match this roll's clips
    -- Synced clips should have names like "A001C001..." matching the original clips
    local rollPrefix = binName:match("^([A-Za-z]+%d+)") or binName
    print("  Roll prefix for matching: '" .. rollPrefix .. "'")

    local matchingClips = {}

    for _, clip in ipairs(syncedClips) do
        local clipName = clip:GetName() or ""
        -- Check if clip name contains the roll prefix (e.g., A001)
        if clipName:find(rollPrefix, 1, true) then
            table.insert(matchingClips, clip)
        end
    end

    print("  Matching clips found: " .. #matchingClips)

    if #matchingClips == 0 then
        print("Warning: No clips found matching roll prefix '" .. rollPrefix .. "'")
        print("Available clip names:")
        for i, clip in ipairs(syncedClips) do
            print("  " .. i .. ": " .. (clip:GetName() or "Unknown"))
        end
        return false
    end

    print("Found " .. #matchingClips .. " synced clips for roll " .. binName)

    -- Sort clips by start timecode
    table.sort(matchingClips, function(a, b)
        local tcA = a:GetClipProperty("Start TC") or "00:00:00:00"
        local tcB = b:GetClipProperty("Start TC") or "00:00:00:00"
        return timecodeToFrames(tcA, 24) < timecodeToFrames(tcB, 24)
    end)

    -- Create or find Timelines folder
    local rootFolder = mediaPool:GetRootFolder()
    local timelinesFolder = findSubFolderByName(rootFolder, "Timelines")

    if not timelinesFolder then
        timelinesFolder = mediaPool:AddSubFolder(rootFolder, "Timelines")
    end

    if timelinesFolder then
        mediaPool:SetCurrentFolder(timelinesFolder)
    end

    -- Determine audio channel count from first clip
    local maxAudioChannels = 16  -- Default maximum
    if #matchingClips > 0 then
        local audioMapping = matchingClips[1]:GetAudioMapping()
        if audioMapping then
            -- Try to parse channel count from linked audio
            local linkedChannels = audioMapping:match('"channels"%s*:%s*(%d+)')
            if linkedChannels then
                maxAudioChannels = math.min(tonumber(linkedChannels), 16)
                print("  Detected " .. maxAudioChannels .. " audio channels from linked audio")
            end
        end
    end

    -- Create empty timeline with mono audio tracks
    print("Creating timeline with mono audio tracks: " .. timelineName)
    local newTimeline = mediaPool:CreateEmptyTimeline(timelineName)

    if not newTimeline then
        print("Error: Failed to create empty timeline for " .. binName)
        return false
    end

    project:SetCurrentTimeline(newTimeline)

    -- Determine which audio tracks to create based on settings
    local numAudioTracks = 1
    local selectedChannels = {}

    if audioTrackSettings.allMonoTracks then
        -- All channels as separate mono tracks
        numAudioTracks = maxAudioChannels
        for i = 1, maxAudioChannels do
            table.insert(selectedChannels, i)
        end
        print("  Will create " .. numAudioTracks .. " mono audio tracks (all channels)")
    elseif audioTrackSettings.selectedChannels and #audioTrackSettings.selectedChannels > 0 then
        -- User-selected channels
        selectedChannels = audioTrackSettings.selectedChannels
        numAudioTracks = #selectedChannels
        local channelList = table.concat(selectedChannels, ", ")
        print("  Will create " .. numAudioTracks .. " mono audio tracks (channels: " .. channelList .. ")")
    else
        -- Fallback: just channel 1
        numAudioTracks = 1
        selectedChannels = {1}
        print("  Will create 1 mono audio track (channel 1)")
    end

    -- Strategy: Replace default stereo track with mono tracks BEFORE appending clips
    -- CreateEmptyTimeline creates a default stereo track at index 1

    print("  Configuring audio tracks...")

    -- Step 1: Add first mono track at index 1 (pushes stereo to index 2)
    local firstTrackAdded = newTimeline:AddTrack("audio", {audioType = "mono", index = 1})
    if firstTrackAdded then
        print("    Inserted mono track at index 1")
    else
        -- Fallback: add normally
        newTimeline:AddTrack("audio", "mono")
        print("    Added mono track (fallback method)")
    end

    -- Step 2: Delete the stereo track (now at index 2)
    local audioTrackCount = newTimeline:GetTrackCount("audio")
    if audioTrackCount >= 2 then
        local track2Type = newTimeline:GetTrackSubType("audio", 2)
        print("    Track 2 type: " .. (track2Type or "unknown"))
        if track2Type and track2Type ~= "mono" then
            local deleted = newTimeline:DeleteTrack("audio", 2)
            if deleted then
                print("    Deleted stereo track at index 2")
            else
                print("    Warning: Could not delete stereo track")
            end
        end
    end

    -- Step 3: Add remaining mono tracks
    for i = 2, numAudioTracks do
        local trackAdded = newTimeline:AddTrack("audio", "mono")
        if trackAdded then
            print("    Added mono track " .. i .. " (for channel " .. selectedChannels[i] .. ")")
        end
    end

    -- Verify track configuration before appending clips
    audioTrackCount = newTimeline:GetTrackCount("audio")
    print("  Audio tracks configured: " .. audioTrackCount)
    for i = 1, math.min(audioTrackCount, 3) do
        local trackType = newTimeline:GetTrackSubType("audio", i)
        print("    Track " .. i .. ": " .. (trackType or "unknown"))
    end

    -- Step 4: Append clips to timeline
    print("  Appending " .. #matchingClips .. " clips to timeline...")
    local appendResult = mediaPool:AppendToTimeline(matchingClips)

    if not appendResult or #appendResult == 0 then
        print("Warning: AppendToTimeline returned no items, trying alternative method...")
        for _, clip in ipairs(matchingClips) do
            mediaPool:AppendToTimeline({clip})
        end
    end

    print("Created timeline: " .. timelineName)

    -- Get timeline items
    local timelineItems = {}
    local trackCount = newTimeline:GetTrackCount("video")
    for track = 1, trackCount do
        local items = newTimeline:GetItemListInTrack("video", track)
        if items then
            for _, item in ipairs(items) do
                table.insert(timelineItems, item)
            end
        end
    end

    print("Timeline has " .. #timelineItems .. " clips")

    -- Apply DRX if specified
    if drxPath and drxPath ~= "" then
        local file = io.open(drxPath, "r")
        if file then
            file:close()
            resolve:OpenPage("color")

            print("Applying DRX grades...")
            local successCount = 0

            for _, timelineItem in ipairs(timelineItems) do
                local nodeGraph = timelineItem:GetNodeGraph()
                if nodeGraph then
                    local success = nodeGraph:ApplyGradeFromDRX(drxPath, 0)
                    if success then
                        successCount = successCount + 1
                    end
                end
            end

            print("DRX applied to " .. successCount .. " clips")
        end
    end

    -- Apply CDL if specified
    if cdlPath and cdlPath ~= "" then
        project:RefreshLUTList()

        local cdlData = nil
        local fileExt = cdlPath:match("%.([^%.]+)$")

        if fileExt then
            fileExt = fileExt:lower()
            if fileExt == "ccc" then
                cdlData = parseCCC(cdlPath)
            elseif fileExt == "edl" then
                cdlData = parseEDL(cdlPath)
            end
        end

        if cdlData then
            resolve:OpenPage("color")
            local appliedCount = 0

            for _, clip in ipairs(timelineItems) do
                local clipName = clip:GetName()
                local cdlEntry = nil
                local matchedName = nil

                -- Try exact match
                if cdlData[clipName] then
                    cdlEntry = cdlData[clipName]
                    matchedName = clipName
                else
                    -- Try without extension
                    local clipNameNoExt = clipName:match("(.+)%.[^.]+$") or clipName
                    if cdlData[clipNameNoExt] then
                        cdlEntry = cdlData[clipNameNoExt]
                        matchedName = clipNameNoExt
                    else
                        -- Try fuzzy match
                        for cdlName, cdl in pairs(cdlData) do
                            if clipName:find(cdlName, 1, true) or cdlName:find(clipName, 1, true) then
                                cdlEntry = cdl
                                matchedName = cdlName
                                break
                            end
                        end
                    end
                end

                if cdlEntry then
                    local success = applyCDL(clip, cdlEntry)
                    if success then
                        appliedCount = appliedCount + 1
                    end
                    applyMetadata(clip, cdlEntry)

                    if cdlEntry.lut then
                        local lutAbsolutePath, lutRelativePath = searchForLUT(cdlEntry.lut)
                        if lutAbsolutePath then
                            local nodeGraph = clip:GetNodeGraph()
                            local numNodes = nodeGraph and nodeGraph:GetNumNodes() or 0
                            if numNodes >= 2 then
                                local lutSuccess = clip:SetLUT(2, lutRelativePath)
                                if not lutSuccess then
                                    clip:SetLUT(2, lutAbsolutePath)
                                end
                            end
                        end
                    end
                end
            end

            print("CDLs applied to " .. appliedCount .. " of " .. #timelineItems .. " clips")
        end
    end

    print("=== Timeline Complete: " .. binName .. " ===")
    return true
end

-- ============================================================================
-- MAIN DAILIES CREATION FUNCTION
-- ============================================================================

--- Main entry point for dailies creation
-- @param cameraRolls table Array of camera roll configurations
-- @param cdlPath string|nil Path to CDL file (optional)
-- @param audioPath string|nil Path to audio directory (optional)
-- @param syncAudio boolean Whether to sync audio to video using timecode
-- @param audioTrackSettings table Audio track configuration {allMonoTracks, selectedChannels}
-- @param masterTimelineSettings table Master timeline configuration (optional)
-- @return boolean True if all rolls processed successfully
local function createDailies(cameraRolls, cdlPath, audioPath, syncAudio, audioTrackSettings, masterTimelineSettings)
    print("=== DaVinci Resolve - Create Dailies v2.00 ===")

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
        print("Error: No project is open")
        return false
    end

    local mediaPool = project:GetMediaPool()
    local mediaStorage = resolve:GetMediaStorage()

    local successCount = 0
    local failCount = 0

    -- Determine if we should skip timeline creation (when audio sync is enabled)
    local skipTimeline = (audioPath and audioPath ~= "" and syncAudio)

    if skipTimeline then
        print("\nAudio sync enabled - timelines will be created AFTER audio sync")
    end

    for i, cameraRoll in ipairs(cameraRolls) do
        print("\n" .. string.rep("=", 70))
        print("IMPORTING CAMERA ROLL " .. i .. " OF " .. #cameraRolls)
        print(string.rep("=", 70))

        local success = processCameraRoll(cameraRoll, resolve, project, mediaPool, mediaStorage, cdlPath, skipTimeline)

        if success then
            successCount = successCount + 1
        else
            failCount = failCount + 1
        end
    end

    -- Audio sync (if enabled)
    if audioPath and audioPath ~= "" and syncAudio then
        print("\n" .. string.rep("=", 70))
        print("=== AUDIO IMPORT AND SYNC ===")
        print(string.rep("=", 70))

        audioPath = audioPath:gsub("/$", "")

        local audioFiles = scanAudioRecursive(mediaStorage, audioPath, {}, 0)

        if not audioFiles or #audioFiles == 0 then
            print("Error: No audio files found in " .. audioPath)
        else
            print("Found " .. #audioFiles .. " audio files")

            local rootFolder = mediaPool:GetRootFolder()

            -- Step 1: Create temporary Sync bin for the sync operation
            print("\nCreating temporary Sync bin...")
            local syncFolder = findSubFolderByName(rootFolder, "Sync")
            if syncFolder then
                -- Delete existing Sync folder contents or use it
                print("Using existing 'Sync' bin")
            else
                syncFolder = mediaPool:AddSubFolder(rootFolder, "Sync")
                if syncFolder then
                    print("Created 'Sync' bin")
                else
                    print("Error: Failed to create 'Sync' bin")
                end
            end

            if syncFolder then
                -- Step 2: Import audio files directly into Sync bin
                mediaPool:SetCurrentFolder(syncFolder)

                print("\nImporting audio files into Sync bin...")
                local importedAudioClips = mediaStorage:AddItemListToMediaPool(audioFiles)

                if not importedAudioClips or #importedAudioClips == 0 then
                    print("Error: Failed to import audio files")
                else
                    print("Imported " .. #importedAudioClips .. " audio clips")

                    -- Step 3: Collect video clips from OCF and track their source folders
                    print("\nCollecting video clips from OCF bins...")
                    local videoClipInfo = {}  -- {clip, sourceFolder}
                    local clipsWithEmbeddedAudio = 0
                    local ocfFolder = findSubFolderByName(rootFolder, "OCF")

                    if not ocfFolder then
                        print("Error: OCF folder not found in Media Pool")
                    else
                        local cameraFolders = ocfFolder:GetSubFolderList()
                        if cameraFolders then
                            for _, camFolder in ipairs(cameraFolders) do
                                local rollFolders = camFolder:GetSubFolderList()
                                if rollFolders then
                                    for _, rollFolder in ipairs(rollFolders) do
                                        local clipsInRoll = rollFolder:GetClipList()
                                        if clipsInRoll then
                                            for _, clip in ipairs(clipsInRoll) do
                                                table.insert(videoClipInfo, {
                                                    clip = clip,
                                                    sourceFolder = rollFolder
                                                })

                                                -- Check for embedded audio
                                                local audioMapping = clip:GetAudioMapping()
                                                if audioMapping then
                                                    local embeddedChannels = audioMapping:match('"embedded_audio_channels"%s*:%s*(%d+)')
                                                    if embeddedChannels and tonumber(embeddedChannels) > 0 then
                                                        clipsWithEmbeddedAudio = clipsWithEmbeddedAudio + 1
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end

                    print("Found " .. #videoClipInfo .. " video clips in OCF")
                    if clipsWithEmbeddedAudio > 0 then
                        print("Note: " .. clipsWithEmbeddedAudio .. " video clips have embedded audio")
                        print("      Embedded audio will NOT be retained in synced clips")
                    end

                    if #videoClipInfo == 0 then
                        print("Error: No video clips found in OCF bins for audio sync")
                    else
                        -- Log sample timecodes for debugging
                        print("\nSample video clip timecodes:")
                        for i = 1, math.min(3, #videoClipInfo) do
                            local info = videoClipInfo[i]
                            local startTC = info.clip:GetClipProperty("Start TC") or "Unknown"
                            local clipName = info.clip:GetName() or "Unknown"
                            print("  " .. clipName .. " - Start TC: " .. startTC)
                        end

                        print("\nSample audio clip timecodes:")
                        for i = 1, math.min(3, #importedAudioClips) do
                            local clip = importedAudioClips[i]
                            local startTC = clip:GetClipProperty("Start TC") or "Unknown"
                            local clipName = clip:GetName() or "Unknown"
                            print("  " .. clipName .. " - Start TC: " .. startTC)
                        end

                        -- Step 4: Move video clips to Sync bin
                        print("\nMoving video clips to Sync bin...")
                        local allVideoClips = {}
                        for _, info in ipairs(videoClipInfo) do
                            table.insert(allVideoClips, info.clip)
                        end

                        local moveSuccess = mediaPool:MoveClips(allVideoClips, syncFolder)
                        if moveSuccess then
                            print("Moved " .. #allVideoClips .. " video clips to Sync bin")
                        else
                            print("Warning: Failed to move video clips to Sync bin")
                        end

                        -- Step 5: Perform audio sync (all clips now in same bin)
                        local clipsToSync = {}
                        for _, clip in ipairs(allVideoClips) do
                            table.insert(clipsToSync, clip)
                        end
                        for _, clip in ipairs(importedAudioClips) do
                            table.insert(clipsToSync, clip)
                        end

                        local syncSettings = {
                            [resolve.AUDIO_SYNC_MODE] = resolve.AUDIO_SYNC_TIMECODE,
                            [resolve.AUDIO_SYNC_RETAIN_VIDEO_METADATA] = true,
                            [resolve.AUDIO_SYNC_RETAIN_EMBEDDED_AUDIO] = false
                        }

                        print("\nStarting audio sync...")
                        print("  Mode: Timecode matching")
                        print("  Retain video metadata: Yes")
                        print("  Retain embedded audio: No")
                        print("  Clips to sync: " .. #clipsToSync .. " (" .. #allVideoClips .. " video + " .. #importedAudioClips .. " audio)")

                        local syncSuccess = mediaPool:AutoSyncAudio(clipsToSync, syncSettings)

                        if syncSuccess then
                            print("\nAudio sync completed successfully!")

                            -- Step 6: Move original video clips back to their source folders
                            print("\nMoving original video clips back to OCF bins...")
                            for _, info in ipairs(videoClipInfo) do
                                mediaPool:MoveClips({info.clip}, info.sourceFolder)
                            end
                            print("Restored video clips to original locations")

                            -- Step 7: Create OSF bin and move original audio clips there
                            local osfFolder = findSubFolderByName(rootFolder, "OSF")
                            if not osfFolder then
                                osfFolder = mediaPool:AddSubFolder(rootFolder, "OSF")
                            end
                            if osfFolder then
                                print("\nMoving original audio clips to OSF bin...")
                                mediaPool:MoveClips(importedAudioClips, osfFolder)
                                print("Moved audio clips to OSF bin")
                            end

                            -- Step 8: Get synced clips from Sync bin and create timelines
                            print("\n" .. string.rep("=", 70))
                            print("=== CREATING TIMELINES FROM SYNCED CLIPS ===")
                            print(string.rep("=", 70))

                            -- After moving originals out, remaining clips in Sync bin are synced clips
                            local syncedClips = syncFolder:GetClipList()
                            print("Clips remaining in Sync bin: " .. (syncedClips and #syncedClips or 0))

                            if syncedClips and #syncedClips > 0 then
                                -- List all synced clips for debugging
                                print("\nSynced clips found:")
                                for i, clip in ipairs(syncedClips) do
                                    local clipName = clip:GetName() or "Unknown"
                                    print("  " .. i .. ": " .. clipName)
                                end

                                -- Create timeline for each camera roll
                                print("\nCreating timelines for " .. #cameraRolls .. " camera rolls...")
                                for _, cameraRoll in ipairs(cameraRolls) do
                                    createTimelineFromSyncedClips(cameraRoll, syncedClips, resolve, project, mediaPool, cdlPath, audioTrackSettings)
                                end
                            else
                                print("Warning: No synced clips found in Sync bin after moving originals")
                                print("This may indicate audio sync modified clips in place (not creating new clips)")
                                print("Creating timelines from clips in OCF bins (which now have synced audio)...")

                                -- Fallback: create timelines from clips in OCF (which may now have synced audio)
                                print("\nProcessing " .. #cameraRolls .. " camera rolls:")
                                for i, cameraRoll in ipairs(cameraRolls) do
                                    print("  Roll " .. i .. ": binName='" .. (cameraRoll.binName or "nil") .. "', timelineName='" .. (cameraRoll.timelineName or "nil") .. "'")
                                end

                                local ocfFolder = findSubFolderByName(rootFolder, "OCF")
                                if not ocfFolder then
                                    print("Error: OCF folder not found!")
                                else
                                    print("\nSearching OCF folder structure...")
                                    local cameraFolders = ocfFolder:GetSubFolderList()
                                    if cameraFolders then
                                        print("Found " .. #cameraFolders .. " camera folders in OCF")
                                        for _, camFolder in ipairs(cameraFolders) do
                                            local camName = camFolder:GetName()
                                            local rollFolders = camFolder:GetSubFolderList()
                                            if rollFolders then
                                                print("  " .. camName .. ": " .. #rollFolders .. " roll folders")
                                                for _, rollFolder in ipairs(rollFolders) do
                                                    local rollName = rollFolder:GetName()
                                                    local clips = rollFolder:GetClipList() or {}
                                                    print("    - " .. rollName .. ": " .. #clips .. " clips")
                                                end
                                            end
                                        end
                                    end

                                    -- Now create timelines
                                    for _, cameraRoll in ipairs(cameraRolls) do
                                        local originalClips = {}
                                        if cameraFolders then
                                            for _, camFolder in ipairs(cameraFolders) do
                                                local rollFolders = camFolder:GetSubFolderList()
                                                if rollFolders then
                                                    for _, rollFolder in ipairs(rollFolders) do
                                                        if rollFolder:GetName() == cameraRoll.binName then
                                                            originalClips = rollFolder:GetClipList() or {}
                                                            print("\nFound " .. #originalClips .. " clips for roll '" .. cameraRoll.binName .. "'")
                                                            break
                                                        end
                                                    end
                                                end
                                                if #originalClips > 0 then break end
                                            end
                                        end
                                        if #originalClips > 0 then
                                            createTimelineFromSyncedClips(cameraRoll, originalClips, resolve, project, mediaPool, cdlPath, audioTrackSettings)
                                        else
                                            print("Warning: No clips found for roll '" .. cameraRoll.binName .. "'")
                                        end
                                    end
                                end
                            end

                            resolve:OpenPage("media")
                        else
                            print("\nError: Audio sync failed")
                            print("Possible causes:")
                            print("  - Video and audio timecodes do not overlap")
                            print("  - Clips have incompatible frame rates")
                            print("  - No matching timecode found between video and audio")

                            -- Move video clips back even if sync failed
                            print("\nMoving video clips back to OCF bins...")
                            for _, info in ipairs(videoClipInfo) do
                                mediaPool:MoveClips({info.clip}, info.sourceFolder)
                            end
                            print("Restored video clips to original locations")

                            -- Move audio to OSF bin
                            local osfFolder = findSubFolderByName(rootFolder, "OSF")
                            if not osfFolder then
                                osfFolder = mediaPool:AddSubFolder(rootFolder, "OSF")
                            end
                            if osfFolder then
                                mediaPool:MoveClips(importedAudioClips, osfFolder)
                            end

                            -- Still create timelines even though sync failed (without synced audio)
                            print("\n" .. string.rep("=", 70))
                            print("=== CREATING TIMELINES (WITHOUT SYNCED AUDIO) ===")
                            print(string.rep("=", 70))

                            for _, cameraRoll in ipairs(cameraRolls) do
                                local originalClips = {}
                                local ocfFolder = findSubFolderByName(rootFolder, "OCF")
                                if ocfFolder then
                                    local cameraFolders = ocfFolder:GetSubFolderList()
                                    if cameraFolders then
                                        for _, camFolder in ipairs(cameraFolders) do
                                            local rollFolders = camFolder:GetSubFolderList()
                                            if rollFolders then
                                                for _, rollFolder in ipairs(rollFolders) do
                                                    if rollFolder:GetName() == cameraRoll.binName then
                                                        originalClips = rollFolder:GetClipList() or {}
                                                        break
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                                if #originalClips > 0 then
                                    createTimelineFromSyncedClips(cameraRoll, originalClips, resolve, project, mediaPool, cdlPath, audioTrackSettings)
                                end
                            end

                            resolve:OpenPage("media")
                        end
                    end
                end
            end
        end
    end

    -- Create master timelines if requested
    if masterTimelineSettings and (masterTimelineSettings.createEditorial or masterTimelineSettings.createDailies) then
        print("\n" .. string.rep("=", 70))
        print("=== CREATING MASTER TIMELINES ===")
        print(string.rep("=", 70))

        -- Collect all clips from all camera roll timelines
        local allClips = {}
        local rootFolder = mediaPool:GetRootFolder()
        local ocfFolder = findSubFolderByName(rootFolder, "OCF")

        if ocfFolder then
            local cameraFolders = ocfFolder:GetSubFolderList()
            if cameraFolders then
                for _, camFolder in ipairs(cameraFolders) do
                    local rollFolders = camFolder:GetSubFolderList()
                    if rollFolders then
                        for _, rollFolder in ipairs(rollFolders) do
                            local clips = rollFolder:GetClipList()
                            if clips then
                                for _, clip in ipairs(clips) do
                                    table.insert(allClips, clip)
                                end
                            end
                        end
                    end
                end
            end
        end

        print("Collected " .. #allClips .. " clips for master timelines")

        -- Sort clips by start timecode
        table.sort(allClips, function(a, b)
            local tcA = a:GetClipProperty("Start TC") or "00:00:00:00"
            local tcB = b:GetClipProperty("Start TC") or "00:00:00:00"
            return timecodeToFrames(tcA, 24) < timecodeToFrames(tcB, 24)
        end)

        -- Create MasterTimeline_Editorial
        if masterTimelineSettings.createEditorial and #allClips > 0 then
            print("\nCreating MasterTimeline_Editorial...")
            local editorialRoll = {
                binName = "MasterTimeline_Editorial",
                timelineName = "MasterTimeline_Editorial",
                drxPath = cameraRolls[1] and cameraRolls[1].drxPath or ""
            }
            createTimelineFromSyncedClips(editorialRoll, allClips, resolve, project, mediaPool, cdlPath, masterTimelineSettings.editorialAudio)
        end

        -- Create MasterTimeline_Dailies
        if masterTimelineSettings.createDailies and #allClips > 0 then
            print("\nCreating MasterTimeline_Dailies...")
            local dailiesRoll = {
                binName = "MasterTimeline_Dailies",
                timelineName = "MasterTimeline_Dailies",
                drxPath = cameraRolls[1] and cameraRolls[1].drxPath or ""
            }
            createTimelineFromSyncedClips(dailiesRoll, allClips, resolve, project, mediaPool, cdlPath, masterTimelineSettings.dailiesAudio)
        end
    end

    -- Delete Sync bin if it exists (cleanup)
    local rootFolder = mediaPool:GetRootFolder()
    local syncFolder = findSubFolderByName(rootFolder, "Sync")
    if syncFolder then
        print("\nCleaning up Sync bin...")
        local deleted = mediaPool:DeleteFolders({syncFolder})
        if deleted then
            print("Deleted Sync bin")
        else
            print("Warning: Could not delete Sync bin")
        end
    end

    -- Print summary
    print("\n" .. string.rep("=", 70))
    print("=== CREATE DAILIES SUMMARY ===")
    print(string.rep("=", 70))
    print("Camera rolls processed: " .. #cameraRolls)
    print("Successful: " .. successCount)
    print("Failed: " .. failCount)
    if masterTimelineSettings then
        if masterTimelineSettings.createEditorial then
            print("Master timeline created: MasterTimeline_Editorial")
        end
        if masterTimelineSettings.createDailies then
            print("Master timeline created: MasterTimeline_Dailies")
        end
    end

    return failCount == 0
end

-- ============================================================================
-- GUI SETUP
-- ============================================================================

local win = disp:AddWindow({
    ID = 'DailiesWin',
    TargetID = 'DailiesWin',
    WindowTitle = 'Create Dailies v2.00',
    Geometry = {200, 100, WINDOW_WIDTH, WINDOW_HEIGHT},
    Spacing = 10,

    ui:VGroup{
        ID = 'root',

        -- Tab Widget for different workflows
        ui:TabBar{
            ID = "MainTabs",
            Weight = 0
        },

        ui:Stack{
            ID = "MainStack",
            Weight = 1,

            -- ================================================================
            -- TAB 1: Camera Roll Import (Original functionality)
            -- ================================================================
            ui:VGroup{
                ID = "CameraRollTab",

                ui:Label{
                    Weight = 0,
                    Text = "Camera Rolls Configuration",
                    Font = ui:Font{PixelSize = 14, StyleName = "Bold"},
                    Alignment = {AlignHCenter = true}
                },
                ui:VGap(5),

                ui:HGroup{
                    Weight = 0,
                    ui:HGap(0, 1),
                    ui:Button{
                        ID = "QuickAddCameraBtn",
                        Text = "Add Camera Rolls",
                        Weight = 0,
                        MinimumSize = {200, 32}
                    },
                    ui:HGap(0, 1)
                },
                ui:VGap(10),

                ui:Label{
                    Weight = 0,
                    Text = "Camera Rolls:",
                },
                ui:Tree{
                    ID = "CameraRollsList",
                    Weight = 1,
                    UniformRowHeights = true,
                    SortingEnabled = false
                },

                ui:HGroup{
                    Weight = 0,
                    ui:HGap(0, 1),
                    ui:Button{
                        ID = "RemoveRollBtn",
                        Text = "Remove Selected",
                        Weight = 0,
                        MinimumSize = {130, 28}
                    },
                    ui:HGap(5),
                    ui:Button{
                        ID = "ClearAllBtn",
                        Text = "Clear All",
                        Weight = 0,
                        MinimumSize = {100, 28}
                    },
                    ui:HGap(0, 1)
                },
                ui:VGap(10),

                ui:Label{
                    Weight = 0,
                    Text = "CDL File (.ccc or .edl - applies to all rolls):",
                },
                ui:HGroup{
                    Weight = 0,
                    ui:LineEdit{
                        ID = "CDLPath",
                        Text = "",
                        PlaceholderText = "/path/to/file.ccc or .edl",
                        Weight = 1
                    },
                    ui:Button{
                        ID = "BrowseCDLBtn",
                        Text = "Browse CDL...",
                        Weight = 0,
                        MinimumSize = {110, 28}
                    }
                },
                ui:VGap(10),

                ui:Label{
                    Weight = 0,
                    Text = "Audio Directory (Optional - for timecode sync):",
                    Font = ui:Font{PixelSize = 12, StyleName = "Bold"},
                },
                ui:HGroup{
                    Weight = 0,
                    ui:LineEdit{
                        ID = "AudioPath",
                        Text = "",
                        PlaceholderText = "Select audio directory...",
                        Weight = 1
                    },
                    ui:Button{
                        ID = "BrowseAudioBtn",
                        Text = "Browse Audio...",
                        Weight = 0,
                        MinimumSize = {120, 28}
                    }
                },
                ui:CheckBox{
                    ID = "SyncAudio",
                    Text = "Auto-sync audio to video using timecode",
                    Checked = true
                },

                -- Audio Track Configuration
                ui:VGap(5),
                ui:HGroup{
                    Weight = 0,
                    ui:Label{
                        Weight = 0,
                        Text = "Audio Tracks:",
                        MinimumSize = {100, 24}
                    },
                    ui:ComboBox{
                        ID = "AudioTrackMode",
                        Weight = 0.4,
                        MinimumSize = {220, 24}
                    },
                    ui:Label{
                        ID = "AudioChannelsLabel",
                        Weight = 0,
                        Text = "Channels:",
                        MinimumSize = {65, 24},
                        Visible = false
                    },
                    ui:LineEdit{
                        ID = "AudioChannelSelect",
                        Text = "1,2",
                        PlaceholderText = "e.g., 1,2,5-8",
                        Weight = 0.3,
                        MinimumSize = {120, 24},
                        Visible = false
                    }
                },

                -- Master Timeline Configuration
                ui:VGap(10),
                ui:Label{
                    Weight = 0,
                    Text = "Master Timelines (Optional):",
                    Font = ui:Font{PixelSize = 12, StyleName = "Bold"},
                },

                -- Editorial Master Timeline
                ui:HGroup{
                    Weight = 0,
                    ui:CheckBox{
                        ID = "CreateEditorialMaster",
                        Text = "Create MasterTimeline_Editorial",
                        Checked = false,
                        MinimumSize = {250, 24}
                    },
                    ui:Label{
                        ID = "EditorialAudioLabel",
                        Weight = 0,
                        Text = "Audio:",
                        MinimumSize = {50, 24},
                        Visible = false
                    },
                    ui:ComboBox{
                        ID = "EditorialAudioMode",
                        Weight = 0.3,
                        MinimumSize = {180, 24},
                        Visible = false
                    },
                    ui:LineEdit{
                        ID = "EditorialChannels",
                        Text = "1,2",
                        PlaceholderText = "e.g., 1,2",
                        Weight = 0.2,
                        MinimumSize = {80, 24},
                        Visible = false
                    }
                },

                -- Dailies Master Timeline
                ui:HGroup{
                    Weight = 0,
                    ui:CheckBox{
                        ID = "CreateDailiesMaster",
                        Text = "Create MasterTimeline_Dailies",
                        Checked = false,
                        MinimumSize = {250, 24}
                    },
                    ui:Label{
                        ID = "DailiesAudioLabel",
                        Weight = 0,
                        Text = "Audio:",
                        MinimumSize = {50, 24},
                        Visible = false
                    },
                    ui:ComboBox{
                        ID = "DailiesAudioMode",
                        Weight = 0.3,
                        MinimumSize = {180, 24},
                        Visible = false
                    },
                    ui:LineEdit{
                        ID = "DailiesChannels",
                        Text = "1,2",
                        PlaceholderText = "e.g., 1,2",
                        Weight = 0.2,
                        MinimumSize = {80, 24},
                        Visible = false
                    }
                },

                ui:VGap(10),
                ui:HGroup{
                    Weight = 0,
                    ui:HGap(0, 1),
                    ui:Button{
                        Weight = 0,
                        ID = "CreateBtn",
                        Text = "Create Dailies",
                        MinimumSize = {150, 32}
                    },
                    ui:HGap(10),
                    ui:Button{
                        Weight = 0,
                        ID = "CancelBtn",
                        Text = "Cancel",
                        MinimumSize = {120, 32}
                    },
                    ui:HGap(0, 1)
                }
            },

            -- ================================================================
            -- TAB 2: OCF Master Timeline (NEW in v2.00)
            -- ================================================================
            ui:VGroup{
                ID = "OCFMasterTab",

                ui:Label{
                    Weight = 0,
                    Text = "Create OCF Master Timeline",
                    Font = ui:Font{PixelSize = 14, StyleName = "Bold"},
                    Alignment = {AlignHCenter = true}
                },
                ui:VGap(10),

                ui:Label{
                    Weight = 0,
                    Text = "This will create a timeline containing all clips from the OCF bins,\nsorted by Camera → Roll → Start Timecode.",
                    Alignment = {AlignHCenter = true},
                    StyleSheet = "QLabel { color: #888; }"
                },
                ui:VGap(20),

                ui:HGroup{
                    Weight = 0,
                    ui:Label{
                        Weight = 0.3,
                        Text = "Timeline Name:",
                        MinimumSize = {120, 28}
                    },
                    ui:LineEdit{
                        ID = "OCFTimelineName",
                        Text = "",
                        PlaceholderText = "e.g., Day01_Master",
                        Weight = 0.7
                    }
                },
                ui:VGap(10),

                ui:HGroup{
                    Weight = 0,
                    ui:Label{
                        Weight = 0.3,
                        Text = "ALE Export Name:",
                        MinimumSize = {120, 28}
                    },
                    ui:LineEdit{
                        ID = "OCFALEName",
                        Text = "",
                        PlaceholderText = "e.g., Day01_Master.ale",
                        Weight = 0.7
                    }
                },
                ui:VGap(5),

                ui:Label{
                    Weight = 0,
                    Text = "Note: You will be prompted to select a save location for the ALE file.",
                    StyleSheet = "QLabel { font-style: italic; color: #666; font-size: 11px; }"
                },

                ui:VGap(0, 1),

                ui:HGroup{
                    Weight = 0,
                    ui:HGap(0, 1),
                    ui:Button{
                        ID = "CreateOCFMasterBtn",
                        Text = "Create Master Timeline + Export ALE",
                        MinimumSize = {280, 36}
                    },
                    ui:HGap(0, 1)
                },
                ui:VGap(10)
            },

            -- ================================================================
            -- TAB 3: Audio Dailies (NEW in v2.00)
            -- ================================================================
            ui:VGroup{
                ID = "AudioDailiesTab",

                ui:Label{
                    Weight = 0,
                    Text = "Create Audio Dailies",
                    Font = ui:Font{PixelSize = 14, StyleName = "Bold"},
                    Alignment = {AlignHCenter = true}
                },
                ui:VGap(10),

                ui:Label{
                    Weight = 0,
                    Text = "Import audio files into a new bin, create a timeline sorted by timecode,\nand export an ALE file.",
                    Alignment = {AlignHCenter = true},
                    StyleSheet = "QLabel { color: #888; }"
                },
                ui:VGap(20),

                ui:HGroup{
                    Weight = 0,
                    ui:Label{
                        Weight = 0.3,
                        Text = "Audio Source:",
                        MinimumSize = {120, 28}
                    },
                    ui:LineEdit{
                        ID = "AudioDailiesPath",
                        Text = "",
                        PlaceholderText = "/path/to/audio/files",
                        Weight = 0.6
                    },
                    ui:Button{
                        ID = "BrowseAudioDailiesBtn",
                        Text = "Browse...",
                        Weight = 0.1,
                        MinimumSize = {80, 28}
                    }
                },
                ui:VGap(10),

                ui:HGroup{
                    Weight = 0,
                    ui:Label{
                        Weight = 0.3,
                        Text = "Bin Name:",
                        MinimumSize = {120, 28}
                    },
                    ui:LineEdit{
                        ID = "AudioBinName",
                        Text = "",
                        PlaceholderText = "e.g., Audio_Day01",
                        Weight = 0.7
                    }
                },
                ui:VGap(10),

                ui:HGroup{
                    Weight = 0,
                    ui:Label{
                        Weight = 0.3,
                        Text = "Timeline Name:",
                        MinimumSize = {120, 28}
                    },
                    ui:LineEdit{
                        ID = "AudioTimelineName",
                        Text = "",
                        PlaceholderText = "e.g., Audio_Day01_TL",
                        Weight = 0.7
                    }
                },
                ui:VGap(10),

                ui:HGroup{
                    Weight = 0,
                    ui:Label{
                        Weight = 0.3,
                        Text = "ALE Export Name:",
                        MinimumSize = {120, 28}
                    },
                    ui:LineEdit{
                        ID = "AudioALEName",
                        Text = "",
                        PlaceholderText = "e.g., Audio_Day01.ale",
                        Weight = 0.7
                    }
                },
                ui:VGap(5),

                ui:Label{
                    Weight = 0,
                    Text = "Note: You will be prompted to select a save location for the ALE file.",
                    StyleSheet = "QLabel { font-style: italic; color: #666; font-size: 11px; }"
                },

                ui:VGap(0, 1),

                ui:HGroup{
                    Weight = 0,
                    ui:HGap(0, 1),
                    ui:Button{
                        ID = "CreateAudioDailiesBtn",
                        Text = "Import Audio + Create Timeline + Export ALE",
                        MinimumSize = {320, 36}
                    },
                    ui:HGap(0, 1)
                },
                ui:VGap(10)
            }
        }
    }
})

local itm = win:GetItems()

-- Setup tabs
itm.MainTabs:AddTab("Camera Roll Import")
itm.MainTabs:AddTab("OCF Master Timeline")
itm.MainTabs:AddTab("Audio Dailies")

-- Tab switching handler
function win.On.MainTabs.CurrentChanged(ev)
    itm.MainStack.CurrentIndex = ev.Index
end

--- Check if a folder name matches camera roll naming pattern
-- Roll names are typically: A001, B002, A_001, A001R1AB
-- This should NOT match clip names like A001C001, A001_C001
-- @param folderName string The folder name to check
-- @return boolean True if it matches camera roll pattern
local function isCameraRollFolder(folderName)
    -- First check: must start with letter(s) + optional separator + 3+ digits
    if not folderName:match("^[A-Za-z]+[_%-]?%d%d%d") then
        return false
    end

    -- Exclude clip folders: these have "C" followed by digits after the roll number
    -- Examples to exclude: A001C001, A001_C001, A001C001_xxxxxx
    -- But allow: A001, A001R1AB, A001_
    if folderName:match("^[A-Za-z]+[_%-]?%d%d%d+[_%-]?[Cc]%d") then
        return false
    end

    return true
end

--- Check if a file is a video media file
-- @param fileName string The filename to check
-- @return boolean True if it's a video file
local function isVideoMediaFile(fileName)
    local lowerName = fileName:lower()
    return lowerName:match("%.mov$") or lowerName:match("%.mxf$") or
           lowerName:match("%.r3d$") or lowerName:match("%.braw$") or
           lowerName:match("%.ari$") or lowerName:match("%.arx$") or
           lowerName:match("%.mp4$") or lowerName:match("%.avi$") or
           lowerName:match("%.dng$") or lowerName:match("%.cri$")
end

--- Check if a folder contains video media files directly
-- @param mediaStorage MediaStorage The media storage object
-- @param folderPath string Path to check
-- @return boolean True if folder contains video files directly
local function folderContainsMediaDirect(mediaStorage, folderPath)
    local files = mediaStorage:GetFileList(folderPath)
    if not files or #files == 0 then
        return false
    end

    for _, file in ipairs(files) do
        local fileName = file:match("([^/]+)$") or file
        if isVideoMediaFile(fileName) then
            return true
        end
    end

    return false
end

--- Recursively check if a folder or any of its subfolders contain video media
-- @param mediaStorage MediaStorage The media storage object
-- @param folderPath string Path to check
-- @param depth number Current depth (to prevent infinite recursion)
-- @return boolean True if media found anywhere inside
local function folderContainsMediaRecursive(mediaStorage, folderPath, depth)
    depth = depth or 0
    if depth > 10 then
        return false
    end

    -- Check this folder directly
    if folderContainsMediaDirect(mediaStorage, folderPath) then
        return true
    end

    -- Check subfolders
    local subFolders = mediaStorage:GetSubFolderList(folderPath)
    if subFolders then
        for _, subFolder in ipairs(subFolders) do
            local subPath
            if subFolder:sub(1, 1) == "/" or subFolder:sub(2, 2) == ":" then
                subPath = subFolder
            else
                subPath = folderPath .. "/" .. subFolder
            end
            if folderContainsMediaRecursive(mediaStorage, subPath, depth + 1) then
                return true
            end
        end
    end

    return false
end

--- Recursively detect camera roll folders across multiple directory levels
-- When a folder matches the roll pattern AND contains media (directly or in subfolders),
-- it is added as a roll and we do NOT recurse into it (to avoid detecting clip folders as rolls)
-- @param mediaStorage MediaStorage The media storage object
-- @param basePath string Path to scan
-- @param detectedRolls table Table to accumulate found rolls
-- @param depth number Current recursion depth
-- @param maxDepth number Maximum recursion depth (default 10)
-- @return table Array of detected rolls
local function detectCameraRollsRecursive(mediaStorage, basePath, detectedRolls, depth, maxDepth)
    detectedRolls = detectedRolls or {}
    depth = depth or 0
    maxDepth = maxDepth or 10

    if depth > maxDepth then
        return detectedRolls
    end

    local indent = string.rep("  ", depth)
    local subFolders = mediaStorage:GetSubFolderList(basePath)

    if not subFolders or #subFolders == 0 then
        return detectedRolls
    end

    for _, subFolder in ipairs(subFolders) do
        local folderName
        local folderPath

        if subFolder:sub(1, 1) == "/" or subFolder:sub(2, 2) == ":" then
            folderPath = subFolder
            folderName = subFolder:match("([^/]+)$")
        else
            folderPath = basePath .. "/" .. subFolder
            folderName = subFolder
        end

        -- Check if this folder matches camera roll naming pattern (not clip pattern)
        if isCameraRollFolder(folderName) then
            -- Check if it contains media ANYWHERE inside (directly or in subfolders)
            if folderContainsMediaRecursive(mediaStorage, folderPath, 0) then
                print(indent .. "  Detected roll: " .. folderName)
                table.insert(detectedRolls, {
                    name = folderName,
                    path = folderPath
                })
                -- DO NOT recurse into this folder - it's a complete roll
            else
                -- Matches pattern but no media anywhere inside - skip it
                print(indent .. "  Skipping: " .. folderName .. " (no media found)")
            end
        else
            -- Folder doesn't match roll pattern, recurse to check for rolls inside
            print(indent .. "  Scanning: " .. folderName)
            detectCameraRollsRecursive(mediaStorage, folderPath, detectedRolls, depth + 1, maxDepth)
        end
    end

    return detectedRolls
end

--- Detect numbered camera roll subdirectories across multiple directory levels
-- @param parentPath string Path to parent camera folder
-- @return table|nil Array of detected rolls
local function detectCameraRolls(parentPath)
    local resolve = Resolve()
    if not resolve then
        return nil
    end

    local mediaStorage = resolve:GetMediaStorage()
    local detectedRolls = {}

    print("\n=== Scanning for camera rolls ===")
    print("Root path: " .. parentPath)
    print("Scanning multiple directory levels...\n")

    detectCameraRollsRecursive(mediaStorage, parentPath, detectedRolls, 0, 10)

    -- Sort by name
    table.sort(detectedRolls, function(a, b)
        return a.name < b.name
    end)

    print("\n=== Scan complete ===")
    print("Found " .. #detectedRolls .. " camera rolls")

    return detectedRolls
end

--- Update the camera rolls list display
local function updateCameraRollsList()
    local tree = itm.CameraRollsList
    tree:Clear()

    if #cameraRolls == 0 then
        local emptyItem = tree:NewItem()
        emptyItem.Text[0] = "No camera rolls added yet."
        tree:AddTopLevelItem(emptyItem)
    else
        for i, roll in ipairs(cameraRolls) do
            local item = tree:NewItem()
            local drxFileName = "None"
            if roll.drxPath and roll.drxPath ~= "" then
                drxFileName = roll.drxPath:match("([^/]+)$") or roll.drxPath
            end
            item.Text[0] = string.format("%d. %s | DRX: %s", i, roll.clipPath, drxFileName)
            tree:AddTopLevelItem(item)
        end
    end
end

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

function win.On.DailiesWin.Close(ev)
    disp:ExitLoop()
end

function win.On.CancelBtn.Clicked(ev)
    print("Cancelled by user")
    disp:ExitLoop()
end

function win.On.BrowseAudioBtn.Clicked(ev)
    local selectedPath = fu:RequestDir("Select Audio Directory")
    if selectedPath then
        itm.AudioPath.Text = selectedPath
    end
end

-- Audio track configuration ComboBox handler
function win.On.AudioTrackMode.CurrentIndexChanged(ev)
    -- Show channel selector only when "User selected channels" is selected (index 1)
    local showChannels = (ev.Index == 1)
    itm.AudioChannelsLabel.Visible = showChannels
    itm.AudioChannelSelect.Visible = showChannels
end

-- Master Timeline checkbox handlers
function win.On.CreateEditorialMaster.Clicked(ev)
    local show = itm.CreateEditorialMaster.Checked
    itm.EditorialAudioLabel.Visible = show
    itm.EditorialAudioMode.Visible = show
    -- Show channels field only if "User selected" mode
    itm.EditorialChannels.Visible = show and (itm.EditorialAudioMode.CurrentIndex == 1)
end

function win.On.CreateDailiesMaster.Clicked(ev)
    local show = itm.CreateDailiesMaster.Checked
    itm.DailiesAudioLabel.Visible = show
    itm.DailiesAudioMode.Visible = show
    -- Show channels field only if "User selected" mode
    itm.DailiesChannels.Visible = show and (itm.DailiesAudioMode.CurrentIndex == 1)
end

function win.On.EditorialAudioMode.CurrentIndexChanged(ev)
    itm.EditorialChannels.Visible = itm.CreateEditorialMaster.Checked and (ev.Index == 1)
end

function win.On.DailiesAudioMode.CurrentIndexChanged(ev)
    itm.DailiesChannels.Visible = itm.CreateDailiesMaster.Checked and (ev.Index == 1)
end

function win.On.BrowseAudioDailiesBtn.Clicked(ev)
    local selectedPath = fu:RequestDir("Select Audio Source Directory")
    if selectedPath then
        itm.AudioDailiesPath.Text = selectedPath
    end
end

function win.On.QuickAddCameraBtn.Clicked(ev)
    local parentPath = fu:RequestDir("Select Camera Folder (e.g., A-Cam)")
    if not parentPath then
        return
    end

    local detectedRolls = detectCameraRolls(parentPath)

    if not detectedRolls or #detectedRolls == 0 then
        print("No camera rolls detected in: " .. parentPath)
        return
    end

    print("\n" .. string.rep("=", 50))
    print("Detected " .. #detectedRolls .. " camera rolls")
    print("Now select a DRX grade file to apply to all rolls")
    print("(Press Cancel/Escape to skip DRX grading)")
    print(string.rep("=", 50))

    local drxPath = fu:RequestFile("Select DRX Grade File for ALL Rolls (Cancel to Skip)")
    local drxPathStr = drxPath or ""

    if drxPathStr ~= "" then
        print("DRX selected: " .. drxPathStr)
    else
        print("No DRX file selected - skipping grade application")
    end

    for _, roll in ipairs(detectedRolls) do
        table.insert(cameraRolls, {
            clipPath = roll.path,
            binName = roll.name,
            timelineName = roll.name,
            drxPath = drxPathStr
        })
    end

    print("Added " .. #detectedRolls .. " camera rolls to list")
    updateCameraRollsList()
end

function win.On.RemoveRollBtn.Clicked(ev)
    local tree = itm.CameraRollsList
    local selected = tree:CurrentItem()

    if not selected or #cameraRolls == 0 then
        return
    end

    local index = tree:IndexOfTopLevelItem(selected) + 1

    if index > 0 and index <= #cameraRolls then
        table.remove(cameraRolls, index)
        updateCameraRollsList()
    end
end

function win.On.ClearAllBtn.Clicked(ev)
    cameraRolls = {}
    updateCameraRollsList()
end

function win.On.BrowseCDLBtn.Clicked(ev)
    local selectedCDL = fu:RequestFile("Select CDL File (.ccc or .edl)")
    if selectedCDL then
        itm.CDLPath.Text = selectedCDL
    end
end

function win.On.CreateBtn.Clicked(ev)
    local cdlPath = itm.CDLPath.Text
    local audioPath = itm.AudioPath.Text
    local syncAudio = itm.SyncAudio.Checked

    -- Audio track settings (ComboBox index: 0 = All mono, 1 = User selected)
    local audioTrackSettings = {
        allMonoTracks = (itm.AudioTrackMode.CurrentIndex == 0),
        selectedChannels = {}  -- Will be populated if user selected mode
    }

    -- Parse user-selected channels if in that mode
    if itm.AudioTrackMode.CurrentIndex == 1 then
        local channelStr = itm.AudioChannelSelect.Text
        audioTrackSettings.selectedChannels = parseChannelSelection(channelStr, 16)
        if #audioTrackSettings.selectedChannels == 0 then
            print("Error: No valid channels specified. Use format like: 1,2,5-8")
            return
        end
        print("Selected channels: " .. table.concat(audioTrackSettings.selectedChannels, ", "))
    end

    -- Master timeline settings
    local masterTimelineSettings = {
        createEditorial = itm.CreateEditorialMaster.Checked,
        createDailies = itm.CreateDailiesMaster.Checked,
        editorialAudio = {
            allMonoTracks = (itm.EditorialAudioMode.CurrentIndex == 0),
            selectedChannels = {}
        },
        dailiesAudio = {
            allMonoTracks = (itm.DailiesAudioMode.CurrentIndex == 0),
            selectedChannels = {}
        }
    }

    -- Parse Editorial audio channels if needed
    if masterTimelineSettings.createEditorial and itm.EditorialAudioMode.CurrentIndex == 1 then
        masterTimelineSettings.editorialAudio.selectedChannels = parseChannelSelection(itm.EditorialChannels.Text, 16)
    end

    -- Parse Dailies audio channels if needed
    if masterTimelineSettings.createDailies and itm.DailiesAudioMode.CurrentIndex == 1 then
        masterTimelineSettings.dailiesAudio.selectedChannels = parseChannelSelection(itm.DailiesChannels.Text, 16)
    end

    if #cameraRolls == 0 then
        print("Error: Please add at least one camera roll")
        return
    end

    if cdlPath and cdlPath ~= "" then
        local file = io.open(cdlPath, "r")
        if not file then
            print("Error: CDL file not found: " .. cdlPath)
            return
        else
            file:close()
        end
    end

    local success = createDailies(cameraRolls, cdlPath, audioPath, syncAudio, audioTrackSettings, masterTimelineSettings)

    if success then
        print("\n=== Create Dailies completed successfully ===")
    else
        print("\n=== Create Dailies completed with errors ===")
    end

    disp:ExitLoop()
end

-- ============================================================================
-- OCF MASTER TIMELINE EVENT HANDLER (NEW in v2.00)
-- ============================================================================

function win.On.CreateOCFMasterBtn.Clicked(ev)
    local timelineName = itm.OCFTimelineName.Text
    local aleName = itm.OCFALEName.Text

    if not timelineName or timelineName == "" then
        print("Error: Timeline name is required")
        return
    end

    if not aleName or aleName == "" then
        print("Error: ALE export name is required")
        return
    end

    -- Prompt for ALE save location
    local aleExportPath = fu:RequestFile("Save ALE File", aleName)
    if not aleExportPath then
        print("ALE export cancelled")
        return
    end

    local resolve = Resolve()
    if not resolve then
        print("Error: Could not connect to DaVinci Resolve")
        return
    end

    local projectManager = resolve:GetProjectManager()
    if not projectManager then
        print("Error: Could not get Project Manager")
        return
    end

    local project = projectManager:GetCurrentProject()
    if not project then
        print("Error: No project is open")
        return
    end

    local mediaPool = project:GetMediaPool()

    -- Create master timeline
    local masterTimeline = createOCFMasterTimeline(mediaPool, project, timelineName)

    if masterTimeline then
        -- Export ALE with CDL
        local aleSuccess = exportALEWithCDL(masterTimeline, resolve, aleExportPath)

        if aleSuccess then
            print("\n=== OCF Master Timeline + ALE Export Complete ===")
        else
            print("\n=== Timeline created but ALE export failed ===")
        end
    else
        print("\n=== Failed to create OCF Master Timeline ===")
    end
end

-- ============================================================================
-- AUDIO DAILIES EVENT HANDLER (NEW in v2.00)
-- ============================================================================

function win.On.CreateAudioDailiesBtn.Clicked(ev)
    local audioPath = itm.AudioDailiesPath.Text
    local binName = itm.AudioBinName.Text
    local timelineName = itm.AudioTimelineName.Text
    local aleName = itm.AudioALEName.Text

    if not audioPath or audioPath == "" then
        print("Error: Audio source path is required")
        return
    end

    if not binName or binName == "" then
        print("Error: Bin name is required")
        return
    end

    if not timelineName or timelineName == "" then
        print("Error: Timeline name is required")
        return
    end

    if not aleName or aleName == "" then
        print("Error: ALE export name is required")
        return
    end

    -- Prompt for ALE save location
    local aleExportPath = fu:RequestFile("Save ALE File", aleName)
    if not aleExportPath then
        print("ALE export cancelled")
        return
    end

    local resolve = Resolve()
    if not resolve then
        print("Error: Could not connect to DaVinci Resolve")
        return
    end

    local projectManager = resolve:GetProjectManager()
    if not projectManager then
        print("Error: Could not get Project Manager")
        return
    end

    local project = projectManager:GetCurrentProject()
    if not project then
        print("Error: No project is open")
        return
    end

    local mediaPool = project:GetMediaPool()
    local mediaStorage = resolve:GetMediaStorage()

    -- Create audio dailies
    local success = createAudioDailies(
        mediaPool, mediaStorage, project, resolve,
        audioPath, binName, timelineName, aleExportPath
    )

    if success then
        print("\n=== Audio Dailies Complete ===")
    else
        print("\n=== Audio Dailies Failed ===")
    end
end

-- ============================================================================
-- RUN THE SCRIPT
-- ============================================================================

updateCameraRollsList()

-- Initialize Audio Track Mode ComboBox
itm.AudioTrackMode:AddItem("All channels as separate mono tracks")
itm.AudioTrackMode:AddItem("User selected channels")
itm.AudioTrackMode.CurrentIndex = 0  -- Default to "All channels"

-- Initialize channel selector visibility (hidden by default for "All channels" mode)
itm.AudioChannelsLabel.Visible = false
itm.AudioChannelSelect.Visible = false

-- Initialize Master Timeline Audio Mode ComboBoxes
itm.EditorialAudioMode:AddItem("All channels as separate mono tracks")
itm.EditorialAudioMode:AddItem("User selected channels")
itm.EditorialAudioMode.CurrentIndex = 0

itm.DailiesAudioMode:AddItem("All channels as separate mono tracks")
itm.DailiesAudioMode:AddItem("User selected channels")
itm.DailiesAudioMode.CurrentIndex = 0

win:Show()
disp:RunLoop()
win:Hide()
