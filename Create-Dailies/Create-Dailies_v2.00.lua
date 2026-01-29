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

--- Process a single camera roll: import clips, create timeline, apply grades
-- @param cameraRoll table Camera roll configuration (clipPath, binName, timelineName, drxPath)
-- @param resolve Resolve The Resolve API object
-- @param project Project The current project
-- @param mediaPool MediaPool The media pool object
-- @param mediaStorage MediaStorage The media storage object
-- @param cdlPath string|nil Path to CDL file (optional)
-- @return boolean True if processing was successful
local function processCameraRoll(cameraRoll, resolve, project, mediaPool, mediaStorage, cdlPath)
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
-- MAIN DAILIES CREATION FUNCTION
-- ============================================================================

--- Main entry point for dailies creation
-- @param cameraRolls table Array of camera roll configurations
-- @param cdlPath string|nil Path to CDL file (optional)
-- @param audioPath string|nil Path to audio directory (optional)
-- @param syncAudio boolean Whether to sync audio to video using timecode
-- @return boolean True if all rolls processed successfully
local function createDailies(cameraRolls, cdlPath, audioPath, syncAudio)
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

    for i, cameraRoll in ipairs(cameraRolls) do
        print("\n" .. string.rep("=", 70))
        print("PROCESSING CAMERA ROLL " .. i .. " OF " .. #cameraRolls)
        print(string.rep("=", 70))

        local success = processCameraRoll(cameraRoll, resolve, project, mediaPool, mediaStorage, cdlPath)

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

        if audioFiles and #audioFiles > 0 then
            local rootFolder = mediaPool:GetRootFolder()
            local audioFolder = findSubFolderByName(rootFolder, "Audio")

            if not audioFolder then
                audioFolder = mediaPool:AddSubFolder(rootFolder, "Audio")
            end

            if audioFolder then
                mediaPool:SetCurrentFolder(audioFolder)

                local importedAudioClips = mediaStorage:AddItemListToMediaPool(audioFiles)

                if importedAudioClips and #importedAudioClips > 0 then
                    -- Collect video clips for sync
                    local allVideoClips = {}
                    local ocfFolder = findSubFolderByName(rootFolder, "OCF")

                    if ocfFolder then
                        local cameraFolders = ocfFolder:GetSubFolderList()
                        if cameraFolders then
                            for _, camFolder in ipairs(cameraFolders) do
                                local rollFolders = camFolder:GetSubFolderList()
                                if rollFolders then
                                    for _, rollFolder in ipairs(rollFolders) do
                                        local clipsInRoll = rollFolder:GetClipList()
                                        if clipsInRoll then
                                            for _, clip in ipairs(clipsInRoll) do
                                                table.insert(allVideoClips, clip)
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end

                    if #allVideoClips > 0 then
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

                        print("Syncing " .. #allVideoClips .. " video + " .. #importedAudioClips .. " audio clips...")
                        local syncSuccess = mediaPool:AutoSyncAudio(clipsToSync, syncSettings)

                        if syncSuccess then
                            print("Audio sync completed!")
                        else
                            print("Audio sync failed")
                        end
                    end
                end
            end
        end
    end

    -- Print summary
    print("\n" .. string.rep("=", 70))
    print("=== CREATE DAILIES SUMMARY ===")
    print(string.rep("=", 70))
    print("Camera rolls processed: " .. #cameraRolls)
    print("Successful: " .. successCount)
    print("Failed: " .. failCount)

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

                ui:Label{
                    Weight = 0,
                    Text = "Camera Roll Path:",
                },
                ui:HGroup{
                    Weight = 0,
                    ui:LineEdit{
                        ID = "NewRollPath",
                        Text = "",
                        PlaceholderText = "/path/to/camera/roll",
                        Weight = 1
                    },
                    ui:Button{
                        ID = "BrowseNewRollBtn",
                        Text = "Browse...",
                        Weight = 0,
                        MinimumSize = {80, 28}
                    }
                },
                ui:VGap(5),

                ui:Label{
                    Weight = 0,
                    Text = "Bin & Timeline Name (e.g., A001):",
                },
                ui:LineEdit{
                    ID = "BaseName",
                    Text = "",
                    PlaceholderText = "e.g., A001",
                    Weight = 0
                },
                ui:VGap(5),

                ui:Label{
                    Weight = 0,
                    Text = "DRX Grade File (Optional):",
                },
                ui:HGroup{
                    Weight = 0,
                    ui:LineEdit{
                        ID = "NewRollDRX",
                        Text = "",
                        PlaceholderText = "/path/to/grade.drx",
                        Weight = 1
                    },
                    ui:Button{
                        ID = "BrowseNewDRXBtn",
                        Text = "Browse DRX...",
                        Weight = 0,
                        MinimumSize = {110, 28}
                    }
                },
                ui:VGap(5),
                ui:HGroup{
                    Weight = 0,
                    ui:HGap(0, 1),
                    ui:Button{
                        ID = "AddRollBtn",
                        Text = "Add Camera Roll",
                        Weight = 0,
                        MinimumSize = {150, 28}
                    },
                    ui:HGap(10),
                    ui:Button{
                        ID = "QuickAddCameraBtn",
                        Text = "Add Multiple Camera Rolls",
                        Weight = 0,
                        MinimumSize = {200, 28}
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

--- Detect numbered camera roll subdirectories in a parent folder
-- @param parentPath string Path to parent camera folder
-- @return table|nil Array of detected rolls
local function detectCameraRolls(parentPath)
    local resolve = Resolve()
    if not resolve then
        return nil
    end

    local mediaStorage = resolve:GetMediaStorage()
    local detectedRolls = {}

    local subFolders = mediaStorage:GetSubFolderList(parentPath)

    if not subFolders or #subFolders == 0 then
        return detectedRolls
    end

    print("\nScanning for camera rolls in: " .. parentPath)

    for _, subFolder in ipairs(subFolders) do
        local folderName
        local folderPath

        if subFolder:sub(1, 1) == "/" or subFolder:sub(2, 2) == ":" then
            folderPath = subFolder
            folderName = subFolder:match("([^/]+)$")
        else
            folderPath = parentPath .. "/" .. subFolder
            folderName = subFolder
        end

        if folderName:match("^[A-Za-z]+[_%-]?%d%d%d+") then
            print("  Detected roll: " .. folderName)
            table.insert(detectedRolls, {
                name = folderName,
                path = folderPath
            })
        end
    end

    table.sort(detectedRolls, function(a, b)
        return a.name < b.name
    end)

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

function win.On.BrowseNewRollBtn.Clicked(ev)
    local selectedPath = fu:RequestDir("Select Camera Roll Folder")
    if selectedPath then
        itm.NewRollPath.Text = selectedPath
    end
end

function win.On.BrowseNewDRXBtn.Clicked(ev)
    local selectedDRX = fu:RequestFile("Select DRX Grade File")
    if selectedDRX then
        itm.NewRollDRX.Text = selectedDRX
    end
end

function win.On.BrowseAudioBtn.Clicked(ev)
    local selectedPath = fu:RequestDir("Select Audio Directory")
    if selectedPath then
        itm.AudioPath.Text = selectedPath
    end
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

    local drxPath = fu:RequestFile("Select DRX Grade File (Optional - Cancel to Skip)")
    local drxPathStr = drxPath or ""

    for _, roll in ipairs(detectedRolls) do
        table.insert(cameraRolls, {
            clipPath = roll.path,
            binName = roll.name,
            timelineName = roll.name,
            drxPath = drxPathStr
        })
    end

    print("Added " .. #detectedRolls .. " camera rolls")
    updateCameraRollsList()
end

function win.On.AddRollBtn.Clicked(ev)
    local baseName = itm.BaseName.Text
    local rollPath = itm.NewRollPath.Text
    local drxPath = itm.NewRollDRX.Text

    if not baseName or baseName == "" then
        print("Error: Bin & Timeline Name is required")
        return
    end

    if not rollPath or rollPath == "" then
        print("Error: Camera roll path is required")
        return
    end

    table.insert(cameraRolls, {
        clipPath = rollPath,
        binName = baseName,
        timelineName = baseName,
        drxPath = drxPath or ""
    })

    itm.BaseName.Text = ""
    itm.NewRollPath.Text = ""
    itm.NewRollDRX.Text = ""

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

    local success = createDailies(cameraRolls, cdlPath, audioPath, syncAudio)

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
win:Show()
disp:RunLoop()
win:Hide()
