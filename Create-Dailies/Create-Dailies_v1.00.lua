-- DaVinci Resolve - Create Dailies v1.00
-- Combined script: Import multiple camera rolls, create timelines, apply DRX grades, apply CDL values, and sync audio

local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)

-- ============================================================================
-- CONSTANTS
-- ============================================================================
local WINDOW_WIDTH = 1200
local WINDOW_HEIGHT = 700
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
    ".flac", ".ogg", ".wma", ".mxf"
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
    -- Using a more robust pattern that handles multiline content
    local position = 1
    while true do
        -- Find the start of a ColorCorrection tag
        local ccStart, ccEnd = content:find("<ColorCorrection", position)
        if not ccStart then
            break
        end

        -- Find the corresponding closing tag
        local closeStart, closeEnd = content:find("</ColorCorrection>", ccEnd)
        if not closeStart then
            break
        end

        -- Extract the full ColorCorrection block
        local colorCorrection = content:sub(ccStart, closeEnd)
        entryCount = entryCount + 1

        -- Extract the id attribute - look for it anywhere in the ColorCorrection block
        -- since the opening tag might span multiple lines
        local clipName = colorCorrection:match('id%s*=%s*"([^"]+)"')

        if clipName then
            print("Found entry #" .. entryCount .. ": '" .. clipName .. "'")
            local cdl = {}

            -- Extract SOPNode values
            local sopNode = colorCorrection:match("<SOPNode>(.-)</SOPNode>")
            if sopNode then
                local slope = sopNode:match('<Slope>([^<]+)</Slope>')
                local offset = sopNode:match('<Offset>([^<]+)</Offset>')
                local power = sopNode:match('<Power>([^<]+)</Power>')

                if slope then
                    cdl.slope = slope:match("^%s*(.-)%s*$") -- Trim whitespace
                    print("  Slope: " .. cdl.slope)
                end
                if offset then
                    cdl.offset = offset:match("^%s*(.-)%s*$")
                    print("  Offset: " .. cdl.offset)
                end
                if power then
                    cdl.power = power:match("^%s*(.-)%s*$")
                    print("  Power: " .. cdl.power)
                end
            end

            -- Extract SATNode values
            local satNode = colorCorrection:match("<SATNode>(.-)</SATNode>")
            if satNode then
                local saturation = satNode:match('<Saturation>([^<]+)</Saturation>')
                if saturation then
                    cdl.saturation = saturation:match("^%s*(.-)%s*$")
                    print("  Saturation: " .. cdl.saturation)
                end
            end

            -- Extract LUT value if present
            local lutValue = colorCorrection:match("<LUT>([^<]+)</LUT>")
            if lutValue then
                -- Trim all whitespace including spaces within the filename
                cdl.lut = lutValue:gsub("%s+", "")
                print("  LUT: " .. cdl.lut)
            end

            cdlData[clipName] = cdl
        else
            print("Warning: Found ColorCorrection block without valid id attribute")
        end

        -- Move position forward to continue searching
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
        -- Check for edit entry line (starts with event number)
        local eventNum = line:match("^%d+%s+")
        if eventNum then
            -- Extract clip name from second tab-delimited field
            local fields = {}
            for field in line:gmatch("[^\t]+") do
                table.insert(fields, field)
            end

            if #fields >= 2 then
                currentClip = fields[2]:match("^%s*(.-)%s*$") -- Trim whitespace
            end
        end

        -- Check for ASC_SOP line
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

        -- Check for ASC_SAT line
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

    -- Prevent infinite recursion
    if depth > MAX_LUT_SEARCH_DEPTH then
        return nil
    end

    local indent = string.rep("  ", depth)

    -- Get list of files in current directory
    local handle = io.popen('ls "' .. searchPath .. '" 2>/dev/null')
    if not handle then
        return nil
    end

    local items = handle:read("*a")
    handle:close()

    -- Check each item in the directory
    for item in items:gmatch("[^\r\n]+") do
        local fullPath = searchPath .. "/" .. item

        -- Check if this is the LUT file we're looking for
        if item == lutName then
            print(indent .. "Found LUT: " .. fullPath)
            return fullPath
        end

        -- Check if this is a directory and search recursively
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
            -- Return both absolute path and relative path from LUT root
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
    -- Build the CDL map for SetCDL method
    local cdlMap = {
        NodeIndex = "1"  -- Apply to Node 1
    }

    -- Add Slope if present
    if cdl.slope then
        cdlMap["Slope"] = cdl.slope
    end

    -- Add Offset if present
    if cdl.offset then
        cdlMap["Offset"] = cdl.offset
    end

    -- Add Power if present
    if cdl.power then
        cdlMap["Power"] = cdl.power
    end

    -- Add Saturation if present
    if cdl.saturation then
        cdlMap["Saturation"] = cdl.saturation
    end

    -- Apply the CDL to the clip
    local success = clip:SetCDL(cdlMap)

    if success then
        print("    CDL applied successfully with values:")
        if cdl.slope then print("      Slope: " .. cdl.slope) end
        if cdl.offset then print("      Offset: " .. cdl.offset) end
        if cdl.power then print("      Power: " .. cdl.power) end
        if cdl.saturation then print("      Saturation: " .. cdl.saturation) end
    end

    return success
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

    -- Print current directory being scanned
    local indent = string.rep("  ", depth)
    print(indent .. "Scanning: " .. basePath)

    -- Get subdirectories first
    local subFolders = mediaStorage:GetSubFolderList(basePath)

    if subFolders and #subFolders > 0 then
        print(indent .. "Found " .. #subFolders .. " subdirectories")
        for _, subFolder in ipairs(subFolders) do
            print(indent .. "  - " .. subFolder)
        end
    end

    -- Get list of items in current directory
    local items = mediaStorage:GetFileList(basePath)

    if items and #items > 0 then
        print(indent .. "Found " .. #items .. " items in current directory")

        -- Process files in current directory
        for _, item in ipairs(items) do
            -- Check if item is already a full path or just a filename
            local fullPath
            local fileName

            if item:sub(1, 1) == "/" or item:sub(2, 2) == ":" then
                -- Item is already a full path
                fullPath = item
                fileName = item:match("([^/]+)$")
            else
                -- Item is just a filename
                fullPath = basePath .. "/" .. item
                fileName = item
            end

            if isVideoFile(fileName) then
                print(indent .. "  + Video file: " .. fileName)
                table.insert(videoFiles, fullPath)
            end
        end
    else
        print(indent .. "No items found in current directory")
    end

    -- Recursively process subdirectories
    if subFolders and #subFolders > 0 then
        for _, subFolder in ipairs(subFolders) do
            -- Check if subFolder is already a full path or just a folder name
            local subFolderPath
            if subFolder:sub(1, 1) == "/" or subFolder:sub(2, 2) == ":" then
                -- subFolder is already a full path
                subFolderPath = subFolder
            else
                -- subFolder is just a name, construct full path
                subFolderPath = basePath .. "/" .. subFolder
            end
            scanDirectoryRecursive(mediaStorage, subFolderPath, videoFiles, depth + 1)
        end
    end

    return videoFiles
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

    -- Extract camera designation from bin name (e.g., "A001" -> "A-Cam")
    -- Pattern matches: A001 -> A, B002 -> B, A_001 -> A, etc.
    local cameraDesignation = binName:match("^([A-Za-z]+)")
    local cameraFolderName = "Unknown-Cam"

    if cameraDesignation then
        cameraFolderName = cameraDesignation:upper() .. "-Cam"
        print("Detected camera designation: " .. cameraFolderName)
    else
        print("Warning: Could not detect camera designation from '" .. binName .. "', using 'Unknown-Cam'")
    end

    -- Create or find "OCF" bin
    local ocfFolder = nil
    local subFolders = rootFolder:GetSubFolderList()
    for _, folder in ipairs(subFolders) do
        if folder:GetName() == "OCF" then
            ocfFolder = folder
            print("Found existing 'OCF' bin")
            break
        end
    end

    -- Create "OCF" bin if it doesn't exist
    if not ocfFolder then
        ocfFolder = mediaPool:AddSubFolder(rootFolder, "OCF")
        if ocfFolder then
            print("Created new 'OCF' bin")
        else
            print("Error: Failed to create 'OCF' bin")
            return false
        end
    end

    -- Create or find camera designation folder inside OCF (e.g., "A-Cam")
    mediaPool:SetCurrentFolder(ocfFolder)
    local cameraFolder = nil
    local ocfSubFolders = ocfFolder:GetSubFolderList()
    for _, folder in ipairs(ocfSubFolders) do
        if folder:GetName() == cameraFolderName then
            cameraFolder = folder
            print("Found existing '" .. cameraFolderName .. "' bin inside OCF")
            break
        end
    end

    -- Create camera folder if it doesn't exist
    if not cameraFolder then
        cameraFolder = mediaPool:AddSubFolder(ocfFolder, cameraFolderName)
        if cameraFolder then
            print("Created new '" .. cameraFolderName .. "' bin inside OCF")
        else
            print("Error: Failed to create '" .. cameraFolderName .. "' bin inside OCF")
            return false
        end
    end

    -- Create the roll-specific bin inside camera folder (e.g., "A001" inside "A-Cam")
    mediaPool:SetCurrentFolder(cameraFolder)
    local targetFolder = mediaPool:AddSubFolder(cameraFolder, binName)

    if not targetFolder then
        print("Error: Failed to create bin '" .. binName .. "' inside " .. cameraFolderName)
        print("Bin may already exist with this name")
        return false
    end

    print("Created new bin '" .. binName .. "' inside 'OCF/" .. cameraFolderName .. "'")
    print("Full bin structure: OCF/" .. cameraFolderName .. "/" .. binName)

    -- Set the new bin as current folder for import
    mediaPool:SetCurrentFolder(targetFolder)

    -- Remove trailing slash if present
    clipPath = clipPath:gsub("/$", "")

    -- Recursively scan directory and all subdirectories for video files
    print("Scanning directory recursively: " .. clipPath)
    local videoFiles = scanDirectoryRecursive(mediaStorage, clipPath)

    if not videoFiles or #videoFiles == 0 then
        print("Error: No supported video files found in directory or subdirectories")
        print("Make sure the path is correct and contains media files")
        return false
    end

    print("Found " .. #videoFiles .. " supported video files (including subdirectories)")

    -- Import files to Media Pool
    print("\nImporting files to bin '" .. binName .. "'...")
    local importedClips = mediaStorage:AddItemListToMediaPool(videoFiles)

    if not importedClips or #importedClips == 0 then
        print("Batch import failed, trying individual file imports...")

        -- Try importing files one by one
        importedClips = {}
        for i, file in ipairs(videoFiles) do
            local fileName = file:match("([^/]+)$")
            print("Attempting to import: " .. fileName)

            local singleImport = mediaStorage:AddItemListToMediaPool({file})
            if singleImport and #singleImport > 0 then
                print("  Success: " .. fileName)
                for j, clip in ipairs(singleImport) do
                    table.insert(importedClips, clip)
                end
            else
                print("  Failed: " .. fileName)
            end
        end
    end

    if not importedClips or #importedClips == 0 then
        print("Error: Failed to import any files to Media Pool")
        return false
    end

    print("Successfully imported " .. #importedClips .. " clips to bin '" .. binName .. "'")

    -- Show imported clip names
    print("\nImported clips:")
    for i, clip in ipairs(importedClips) do
        local clipName = clip:GetName()
        if clipName then
            print("  " .. i .. ". " .. clipName)
        else
            print("  " .. i .. ". [Unknown clip name]")
        end
    end

    -- ========================================================================
    -- STEP 2: CREATE TIMELINE
    -- ========================================================================

    -- Create or find "Timelines" bin
    local timelinesFolder = nil
    subFolders = rootFolder:GetSubFolderList()
    for _, folder in ipairs(subFolders) do
        if folder:GetName() == "Timelines" then
            timelinesFolder = folder
            print("\nFound existing 'Timelines' bin")
            break
        end
    end

    -- Create "Timelines" bin if it doesn't exist
    if not timelinesFolder then
        timelinesFolder = mediaPool:AddSubFolder(rootFolder, "Timelines")
        if timelinesFolder then
            print("Created new 'Timelines' bin")
        else
            print("Warning: Failed to create 'Timelines' bin")
        end
    end

    -- Get clips from the target folder for timeline creation
    mediaPool:SetCurrentFolder(targetFolder)
    local clipsInBin = targetFolder:GetClipList()
    if not clipsInBin or #clipsInBin == 0 then
        print("Error: No clips found in bin '" .. binName .. "'")
        return false
    end
    print("Found " .. #clipsInBin .. " clips in bin for timeline creation")

    -- Set the Timelines folder as current before creating the timeline
    if timelinesFolder then
        mediaPool:SetCurrentFolder(timelinesFolder)
        print("Set current folder to 'Timelines'")
    end

    -- Use CreateTimelineFromClips instead of CreateEmptyTimeline + AppendToTimeline
    -- This is more reliable as it creates the timeline with clips in a single atomic operation
    print("Creating timeline '" .. timelineName .. "' with " .. #clipsInBin .. " clips...")
    local newTimeline = mediaPool:CreateTimelineFromClips(timelineName, clipsInBin)

    local timelineItems = {}

    if newTimeline then
        print("Successfully created timeline '" .. timelineName .. "' with clips!")

        -- Set the new timeline as current
        project:SetCurrentTimeline(newTimeline)

        -- Get timeline items for further processing (CDL, DRX, etc.)
        local trackCount = newTimeline:GetTrackCount("video")
        for track = 1, trackCount do
            local items = newTimeline:GetItemListInTrack("video", track)
            if items then
                for _, item in ipairs(items) do
                    table.insert(timelineItems, item)
                end
            end
        end
        print("Timeline has " .. #timelineItems .. " clips on video tracks")
    else
        -- Fallback to CreateEmptyTimeline + AppendToTimeline
        print("CreateTimelineFromClips failed, trying fallback method...")

        local emptyTimeline = mediaPool:CreateEmptyTimeline(timelineName)
        if not emptyTimeline then
            print("Error: Failed to create timeline '" .. timelineName .. "'")
            print("Timeline may already exist with this name")
            return false
        end

        print("Created empty timeline, attempting to append clips...")
        project:SetCurrentTimeline(emptyTimeline)
        mediaPool:SetCurrentFolder(targetFolder)

        local appendResult = mediaPool:AppendToTimeline(clipsInBin)
        if appendResult and #appendResult > 0 then
            print("Fallback succeeded: Added " .. #appendResult .. " clips")
            timelineItems = appendResult
            newTimeline = emptyTimeline
        else
            print("Fallback also failed to add clips")

            -- Try individual clip append
            for i, clip in ipairs(clipsInBin) do
                local clipName = clip:GetName()
                print("  Attempting to append clip " .. i .. ": " .. clipName)
                local singleResult = mediaPool:AppendToTimeline({clip})
                if singleResult and #singleResult > 0 then
                    print("    Success")
                    for _, item in ipairs(singleResult) do
                        table.insert(timelineItems, item)
                    end
                else
                    print("    Failed")
                end
            end

            newTimeline = emptyTimeline
        end
    end

    if #timelineItems == 0 then
        print("Error: Failed to add any clips to timeline")
        return false
    end

    print("Successfully added " .. #timelineItems .. " clips to timeline '" .. timelineName .. "'")

    -- ========================================================================
    -- STEP 3: APPLY DRX FILE
    -- ========================================================================

    if drxPath and drxPath ~= "" then
        -- Check if DRX file exists
        local file = io.open(drxPath, "r")
        if not file then
            print("Error: DRX file not found at: " .. drxPath)
            return false
        else
            file:close()
            print("Found DRX file: " .. drxPath)
        end

        -- Switch to Color page for applying grades
        print("\nSwitching to Color page to apply DRX grades...")
        resolve:OpenPage("color")

        print("Applying DRX file to " .. #timelineItems .. " timeline clips...")
        local successCount = 0
        local failCount = 0

        for i, timelineItem in ipairs(timelineItems) do
            local itemName = timelineItem:GetName()
            print("Processing clip " .. i .. ": " .. (itemName or "Unknown"))

            -- Get the node graph for the timeline item
            local nodeGraph = timelineItem:GetNodeGraph()
            if nodeGraph then
                -- Apply grade from DRX file (gradeMode: 0 = "No keyframes")
                local success = nodeGraph:ApplyGradeFromDRX(drxPath, 0)
                if success then
                    print("  Applied DRX grade successfully")
                    successCount = successCount + 1
                else
                    print("  Failed to apply DRX grade")
                    failCount = failCount + 1
                end
            else
                print("  Could not get node graph for clip")
                failCount = failCount + 1
            end
        end

        print("\nDRX Application Results:")
        print("  Successful: " .. successCount .. " clips")
        print("  Failed: " .. failCount .. " clips")
    else
        print("\nNo DRX file specified for this camera roll")
    end

    -- ========================================================================
    -- STEP 4: APPLY CDL VALUES AND LUTS
    -- ========================================================================

    if cdlPath and cdlPath ~= "" then
        -- IMPORTANT: Refresh the project's LUT list so Resolve knows about all available LUTs
        print("\nRefreshing project LUT list...")
        local refreshSuccess = project:RefreshLUTList()
        if refreshSuccess then
            print("LUT list refreshed successfully")
        else
            print("Warning: Failed to refresh LUT list, LUT application may fail")
        end

        -- Parse the CDL file
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
            print("Error: Unsupported CDL file format (must be .ccc or .edl)")
            return false
        end

        if not cdlData then
            print("Error: Failed to parse CDL file")
            return false
        end

        -- Count total CDL entries
        local totalCDLs = 0
        for _ in pairs(cdlData) do
            totalCDLs = totalCDLs + 1
        end

        print("\n=== Applying CDL Values ===")
        print("CDL entries found in file: " .. totalCDLs)

        -- Switch to Color page
        resolve:OpenPage("color")

        -- Apply CDL to timeline items
        local appliedCount = 0

        print("\n=== Matching CDL to Timeline Clips ===")
        for i, clip in ipairs(timelineItems) do
            local clipName = clip:GetName()
            print("Clip " .. i .. ": '" .. clipName .. "'")

            -- Try to match clip name with or without file extension
            local cdlEntry = nil
            local matchedName = nil

            -- First try exact match
            if cdlData[clipName] then
                cdlEntry = cdlData[clipName]
                matchedName = clipName
            else
                -- Try removing file extension from clip name
                local clipNameNoExt = clipName:match("(.+)%.[^.]+$") or clipName
                if cdlData[clipNameNoExt] then
                    cdlEntry = cdlData[clipNameNoExt]
                    matchedName = clipNameNoExt
                else
                    -- Try matching CDL entries that might have the clip name as a substring
                    for cdlName, cdl in pairs(cdlData) do
                        if clipName:find(cdlName, 1, true) or cdlName:find(clipName, 1, true) then
                            cdlEntry = cdl
                            matchedName = cdlName
                            break
                        end
                        -- Also try without extension
                        if clipNameNoExt:find(cdlName, 1, true) or cdlName:find(clipNameNoExt, 1, true) then
                            cdlEntry = cdl
                            matchedName = cdlName
                            break
                        end
                    end
                end
            end

            if cdlEntry then
                print("  -> Match found with CDL entry: '" .. matchedName .. "'")
                print("  -> Applying CDL...")
                local success = applyCDL(clip, cdlEntry)
                if success then
                    appliedCount = appliedCount + 1
                    print("  -> SUCCESS: Applied CDL to: " .. clipName)
                else
                    print("  -> FAILED: Could not apply CDL to: " .. clipName)
                end

                -- Apply LUT if specified in CDL entry
                if cdlEntry.lut then
                    print("  -> LUT specified: " .. cdlEntry.lut)
                    local lutAbsolutePath, lutRelativePath = searchForLUT(cdlEntry.lut)
                    if lutAbsolutePath then
                        print("  -> Found LUT absolute path: " .. lutAbsolutePath)
                        print("  -> LUT relative path: " .. lutRelativePath)
                        print("  -> Applying LUT to Node 2...")

                        -- Get the number of nodes in the timeline item
                        local numNodes = clip:GetNumNodes()
                        print("  -> Current number of nodes: " .. numNodes)

                        -- Since DRX has been applied, nodes should exist
                        if numNodes < 2 then
                            print("  -> WARNING: Only " .. numNodes .. " node(s) exist - Node 2 not available")
                        else
                            -- Try 1: TimelineItem:SetLUT() with relative path
                            print("  -> Attempt 1: TimelineItem:SetLUT() with relative path")
                            local lutSuccess = clip:SetLUT(2, lutRelativePath)
                            if lutSuccess then
                                print("  -> SUCCESS: Applied LUT to Node 2")
                            else
                                print("  -> Failed with relative path, trying absolute path...")

                                -- Try 2: TimelineItem:SetLUT() with absolute path
                                lutSuccess = clip:SetLUT(2, lutAbsolutePath)
                                if lutSuccess then
                                    print("  -> SUCCESS: Applied LUT with absolute path")
                                else
                                    print("  -> Failed with absolute path, trying NodeGraph...")

                                    -- Try 3: NodeGraph:SetLUT() with relative path
                                    local nodeGraph = clip:GetNodeGraph()
                                    if nodeGraph then
                                        local graphSuccess = nodeGraph:SetLUT(2, lutRelativePath)
                                        if graphSuccess then
                                            print("  -> SUCCESS: Applied LUT via NodeGraph (relative)")
                                        else
                                            -- Try 4: NodeGraph:SetLUT() with absolute path
                                            graphSuccess = nodeGraph:SetLUT(2, lutAbsolutePath)
                                            if graphSuccess then
                                                print("  -> SUCCESS: Applied LUT via NodeGraph (absolute)")
                                            else
                                                print("  -> FAILED: All methods failed to apply LUT")
                                            end
                                        end
                                    else
                                        print("  -> FAILED: Could not get NodeGraph")
                                    end
                                end
                            end
                        end
                    else
                        print("  -> WARNING: LUT file not found, skipping")
                    end
                end
            else
                print("  -> No matching CDL entry")
            end
        end

        print("\n=== CDL Application Results ===")
        print("CDL entries in file: " .. totalCDLs)
        print("CDLs successfully applied: " .. appliedCount)
    else
        print("\nNo CDL file specified")
    end

    -- ========================================================================
    -- STEP 5: RETURN TO MEDIA POOL AND PREPARE FOR NEXT ROLL
    -- ========================================================================

    print("\n=== Finalizing Camera Roll: " .. binName .. " ===")

    -- Switch back to Media Pool page
    resolve:OpenPage("media")
    print("Switched back to Media Pool page")

    -- Reset to root folder in Media Pool for next camera roll
    mediaPool:SetCurrentFolder(rootFolder)
    print("Reset Media Pool to root folder")

    print("=== Camera Roll Processing Complete: " .. binName .. " ===")
    return true
end

-- ============================================================================
-- MAIN DAILIES CREATION FUNCTION
-- ============================================================================

--- Main entry point for dailies creation
-- Processes multiple camera rolls sequentially
-- @param cameraRolls table Array of camera roll configurations
-- @param cdlPath string|nil Path to CDL file (optional)
-- @param audioPath string|nil Path to audio directory (optional)
-- @param syncAudio boolean Whether to sync audio to video using timecode
-- @return boolean True if all rolls processed successfully
local function createDailies(cameraRolls, cdlPath, audioPath, syncAudio)
    print("=== DaVinci Resolve - Create Dailies v1.00 ===")

    -- Access API objects
    local resolve = Resolve()
    if not resolve then
        print("Error: Could not connect to DaVinci Resolve")
        return false
    end

    local projectManager = resolve:GetProjectManager()
    local project = projectManager:GetCurrentProject()

    if not project then
        print("Error: No project is open")
        print("Please open or create a project before running this script")
        return false
    end

    local mediaPool = project:GetMediaPool()
    local mediaStorage = resolve:GetMediaStorage()

    -- Process each camera roll sequentially
    local successCount = 0
    local failCount = 0

    for i, cameraRoll in ipairs(cameraRolls) do
        print("\n" .. string.rep("=", 70))
        print("PROCESSING CAMERA ROLL " .. i .. " OF " .. #cameraRolls)
        print(string.rep("=", 70))

        -- Process this camera roll completely before moving to the next
        local success = processCameraRoll(cameraRoll, resolve, project, mediaPool, mediaStorage, cdlPath)

        if success then
            successCount = successCount + 1
            print("\n>>> Camera Roll " .. i .. " completed successfully")
        else
            failCount = failCount + 1
            print("\n>>> Camera Roll " .. i .. " failed - continuing to next roll")
        end

        -- Add a pause between rolls to ensure Resolve catches up
        if i < #cameraRolls then
            print("\nPreparing for next camera roll...")
        end
    end

    -- ========================================================================
    -- AUDIO IMPORT AND SYNC
    -- ========================================================================

    if audioPath and audioPath ~= "" and syncAudio then
        print("\n" .. string.rep("=", 70))
        print("=== AUDIO IMPORT AND SYNC ===")
        print(string.rep("=", 70))
        print("Audio directory: " .. audioPath)

        -- Remove trailing slash
        audioPath = audioPath:gsub("/$", "")

        -- Scan audio directory for audio files
        print("\nScanning audio directory recursively: " .. audioPath)
        local audioFiles = scanAudioRecursive(mediaStorage, audioPath, {}, 0)

        if not audioFiles or #audioFiles == 0 then
            print("Warning: No audio files found in " .. audioPath)
            print("Skipping audio sync")
        else
            print("Found " .. #audioFiles .. " audio files")

            -- Create "Audio" bin
            local rootFolder = mediaPool:GetRootFolder()
            local audioFolder = nil

            -- Check if "Audio" bin already exists
            local subFolders = rootFolder:GetSubFolderList()
            for _, folder in ipairs(subFolders) do
                if folder:GetName() == "Audio" then
                    audioFolder = folder
                    print("Found existing 'Audio' bin")
                    break
                end
            end

            -- Create "Audio" bin if it doesn't exist
            if not audioFolder then
                audioFolder = mediaPool:AddSubFolder(rootFolder, "Audio")
                if audioFolder then
                    print("Created new 'Audio' bin")
                else
                    print("Warning: Failed to create 'Audio' bin")
                    audioFolder = rootFolder
                end
            end

            -- Set audio folder as current for import
            mediaPool:SetCurrentFolder(audioFolder)

            -- Import audio files
            print("\nImporting audio files...")
            local importedAudioClips = mediaStorage:AddItemListToMediaPool(audioFiles)

            if not importedAudioClips or #importedAudioClips == 0 then
                print("Batch audio import failed, trying individual imports...")
                importedAudioClips = {}
                for i, file in ipairs(audioFiles) do
                    local fileName = file:match("([^/]+)$")
                    print("Importing: " .. fileName)
                    local singleImport = mediaStorage:AddItemListToMediaPool({file})
                    if singleImport and #singleImport > 0 then
                        for j, clip in ipairs(singleImport) do
                            table.insert(importedAudioClips, clip)
                        end
                    end
                end
            end

            if not importedAudioClips or #importedAudioClips == 0 then
                print("Error: Failed to import any audio files")
            else
                print("Successfully imported " .. #importedAudioClips .. " audio clips")

                -- Collect all imported video clips from all camera roll bins
                print("\n=== Syncing Audio to Video ===")
                print("Collecting all imported video clips for sync...")

                -- Get all clips from camera roll bins (OCF structure)
                local allVideoClips = {}
                local ocfFolder = nil

                -- Find OCF folder
                for _, folder in ipairs(subFolders) do
                    if folder:GetName() == "OCF" then
                        ocfFolder = folder
                        break
                    end
                end

                if ocfFolder then
                    -- Iterate through camera folders inside OCF (A-Cam, B-Cam, etc.)
                    local cameraFolders = ocfFolder:GetSubFolderList()
                    if cameraFolders then
                        for _, camFolder in ipairs(cameraFolders) do
                            print("Scanning camera folder: " .. camFolder:GetName())
                            -- Get roll folders inside camera folder
                            local rollFolders = camFolder:GetSubFolderList()
                            if rollFolders then
                                for _, rollFolder in ipairs(rollFolders) do
                                    print("  Scanning roll: " .. rollFolder:GetName())
                                    local clipsInRoll = rollFolder:GetClipList()
                                    if clipsInRoll then
                                        for _, clip in ipairs(clipsInRoll) do
                                            table.insert(allVideoClips, clip)
                                        end
                                        print("    Found " .. #clipsInRoll .. " clips")
                                    end
                                end
                            end
                        end
                    end
                else
                    print("Warning: OCF folder not found, searching root folder for clips")
                    -- Fallback: search in bins matching camera roll names
                    for _, cameraRoll in ipairs(cameraRolls) do
                        local binName = cameraRoll.binName
                        for _, folder in ipairs(subFolders) do
                            if folder:GetName() == binName then
                                local clipsInBin = folder:GetClipList()
                                if clipsInBin then
                                    for _, clip in ipairs(clipsInBin) do
                                        table.insert(allVideoClips, clip)
                                    end
                                end
                                break
                            end
                        end
                    end
                end

                print("Found " .. #allVideoClips .. " video clips to sync")
                print("Found " .. #importedAudioClips .. " audio clips to sync")

                if #allVideoClips == 0 then
                    print("Warning: No video clips found for sync")
                else
                    -- Perform audio sync using timecode
                    local syncSettings = {
                        [resolve.AUDIO_SYNC_MODE] = resolve.AUDIO_SYNC_TIMECODE,
                        [resolve.AUDIO_SYNC_RETAIN_VIDEO_METADATA] = true,
                        [resolve.AUDIO_SYNC_RETAIN_EMBEDDED_AUDIO] = false
                    }

                    -- Combine video and audio clips for sync
                    local clipsToSync = {}
                    for _, clip in ipairs(allVideoClips) do
                        table.insert(clipsToSync, clip)
                    end
                    for _, clip in ipairs(importedAudioClips) do
                        table.insert(clipsToSync, clip)
                    end

                    print("\nAttempting to sync " .. #allVideoClips .. " video clips with " .. #importedAudioClips .. " audio clips using timecode...")

                    local syncSuccess = mediaPool:AutoSyncAudio(clipsToSync, syncSettings)

                    if syncSuccess then
                        print("Audio sync completed successfully!")
                        print("\nSync Results:")
                        print("  - Synced clips will appear in the Media Pool with audio linked")
                        print("  - Check the Media Pool for clips with '_synced' suffix or linked audio")
                        print("  - Any clips that failed to sync will remain unlinked")
                    else
                        print("Audio sync failed")
                        print("\nPossible reasons for sync failure:")
                        print("  1. No matching timecode between video and audio clips")
                        print("  2. Timecode metadata missing or incorrect")
                        print("  3. Clips may already be synced")
                        print("  4. Not enough clips to sync (need at least 1 video + 1 audio)")
                        print("\nTroubleshooting:")
                        print("  - Verify timecode metadata in clip properties")
                        print("  - Check that video and audio were recorded with matching timecode")
                        print("  - Try manually syncing a pair in the UI to verify timecode matching")
                    end
                end
            end
        end
    elseif audioPath and audioPath ~= "" and not syncAudio then
        print("\nAudio directory specified but sync is disabled")
    end

    -- Print final summary
    print("\n" .. string.rep("=", 70))
    print("=== CREATE DAILIES SUMMARY ===")
    print(string.rep("=", 70))
    print("Total camera rolls processed: " .. #cameraRolls)
    print("Successful: " .. successCount)
    print("Failed: " .. failCount)
    print(string.rep("=", 70))

    if failCount == 0 then
        print("\nAll camera rolls processed successfully!")
    else
        print("\nSome camera rolls failed - check the log above for details")
    end

    return failCount == 0
end

-- ============================================================================
-- GUI SETUP
-- ============================================================================

-- Create main GUI window
local win = disp:AddWindow({
    ID = 'DailiesWin',
    TargetID = 'DailiesWin',
    WindowTitle = 'Create Dailies v1.00',
    Geometry = {200, 100, WINDOW_WIDTH, WINDOW_HEIGHT},
    Spacing = 10,

    ui:VGroup{
        ID = 'root',
        ui:VGroup{
            ui:Label{
                Weight = 0,
                Text = "Camera Rolls Configuration",
                Font = ui:Font{PixelSize = 14, StyleName = "Bold"},
                Alignment = {AlignHCenter = true}
            },
            ui:VGap(5),

            -- Camera roll path input
            ui:Label{
                Weight = 0,
                Text = "Camera Roll Path: (Select the folder containing media files)",
                WordWrap = true
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
                    MinimumSize = {80, 28},
                    MaximumSize = {80, 28}
                }
            },
            ui:VGap(10),

            -- Bin/Timeline name prefix section
            ui:Label{
                Weight = 0,
                Text = "Bin & Timeline Name: (e.g., A001, B002)",
                WordWrap = true
            },
            ui:LineEdit{
                ID = "BaseName",
                Text = "",
                PlaceholderText = "e.g., A001",
                Weight = 0
            },
            ui:VGap(10),

            -- DRX file input for new roll
            ui:Label{
                Weight = 0,
                Text = "Path to Grade .drx: (Optional - Select a .drx grade file)",
                WordWrap = true
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
                    MinimumSize = {110, 28},
                    MaximumSize = {110, 28}
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
                    MinimumSize = {150, 28},
                    MaximumSize = {150, 28}
                },
                ui:HGap(10),
                ui:Button{
                    ID = "QuickAddCameraBtn",
                    Text = "Add Multiple Camera Rolls",
                    Weight = 0,
                    MinimumSize = {200, 28},
                    MaximumSize = {200, 28}
                },
                ui:HGap(0, 1)
            },
            ui:VGap(5),
            ui:Label{
                Weight = 0,
                Text = "Add Multiple Camera Rolls Instructions:\n" ..
                       "1. Click the button above to select a camera folder (e.g., A-Cam, B-Camera)\n" ..
                       "2. The script will auto-detect numbered rolls inside (A001, A002, etc.)\n" ..
                       "3. A second window will open asking for an optional DRX file to apply to all detected rolls\n" ..
                       "   (You can click Cancel on the DRX window if you don't need to apply a grade)",
                WordWrap = true,
                StyleSheet = "QLabel { font-style: italic; color: #666; font-size: 11px; }"
            },
            ui:VGap(10),

            -- Camera rolls list
            ui:Label{
                Weight = 0,
                Text = "Camera Rolls:",
                WordWrap = true
            },
            ui:Tree{
                ID = "CameraRollsList",
                Weight = 1,
                UniformRowHeights = true,
                SortingEnabled = false
            },

            ui:VGap(5),
            ui:HGroup{
                Weight = 0,
                ui:HGap(0, 1),
                ui:Button{
                    ID = "RemoveRollBtn",
                    Text = "Remove Selected",
                    Weight = 0,
                    MinimumSize = {150, 28},
                    MaximumSize = {150, 28}
                },
                ui:HGap(5),
                ui:Button{
                    ID = "ClearAllBtn",
                    Text = "Clear All",
                    Weight = 0,
                    MinimumSize = {100, 28},
                    MaximumSize = {100, 28}
                },
                ui:HGap(0, 1)
            },
            ui:VGap(10),

            -- CDL file section
            ui:Label{
                Weight = 0,
                Text = "CDL File: (Select .ccc or .edl file - applies to all camera rolls)",
                WordWrap = true
            },
            ui:HGroup{
                Weight = 0,
                ui:LineEdit{
                    ID = "CDLPath",
                    Text = "",
                    PlaceholderText = "/path/to/your/file.ccc or .edl",
                    Weight = 1
                },
                ui:Button{
                    ID = "BrowseCDLBtn",
                    Text = "Browse CDL...",
                    Weight = 0,
                    MinimumSize = {110, 28},
                    MaximumSize = {110, 28}
                }
            },
            ui:VGap(10),

            -- Audio Directory Section
            ui:Label{
                Weight = 0,
                Text = "Audio Directory: (Optional - for timecode-based audio sync)",
                Font = ui:Font{PixelSize = 13, StyleName = "Bold"},
                WordWrap = true
            },
            ui:HGroup{
                Weight = 0,
                ui:LineEdit{
                    ID = "AudioPath",
                    Text = "",
                    PlaceholderText = "Select audio directory for sync...",
                    Weight = 1
                },
                ui:Button{
                    ID = "BrowseAudioBtn",
                    Text = "Browse Audio...",
                    Weight = 0,
                    MinimumSize = {120, 28},
                    MaximumSize = {120, 28}
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
                    MinimumSize = {150, 32},
                    MaximumSize = {150, 32}
                },
                ui:HGap(10),
                ui:Button{
                    Weight = 0,
                    ID = "CancelBtn",
                    Text = "Cancel",
                    MinimumSize = {120, 32},
                    MaximumSize = {120, 32}
                },
                ui:HGap(0, 1)
            }
        }
    }
})

local itm = win:GetItems()

--- Detect numbered camera roll subdirectories in a parent folder
-- @param parentPath string Path to parent camera folder (e.g., A-Cam)
-- @return table|nil Array of detected rolls with name and path, or nil if none found
local function detectCameraRolls(parentPath)
    local resolve = Resolve()
    if not resolve then
        print("Error: Could not connect to DaVinci Resolve")
        return nil
    end

    local mediaStorage = resolve:GetMediaStorage()
    local detectedRolls = {}

    -- Get subdirectories in parent path
    local subFolders = mediaStorage:GetSubFolderList(parentPath)

    if not subFolders or #subFolders == 0 then
        return detectedRolls
    end

    print("\nScanning for camera rolls in: " .. parentPath)
    print("Found " .. #subFolders .. " subdirectories")

    -- Pattern to match camera roll naming: A001, A002, B001, etc.
    -- Also matches: A_001, A-001, etc.
    for _, subFolder in ipairs(subFolders) do
        local folderName
        local folderPath

        -- Check if subFolder is full path or just name
        if subFolder:sub(1, 1) == "/" or subFolder:sub(2, 2) == ":" then
            folderPath = subFolder
            folderName = subFolder:match("([^/]+)$")
        else
            folderPath = parentPath .. "/" .. subFolder
            folderName = subFolder
        end

        -- Match patterns like: A001, A002, B001, A_001, A-001, etc.
        -- Pattern: one or more letters, optional separator, 3+ digits
        if folderName:match("^[A-Za-z]+[_%-]?%d%d%d+") then
            print("  Detected roll: " .. folderName)
            table.insert(detectedRolls, {
                name = folderName,
                path = folderPath
            })
        end
    end

    print("Total camera rolls detected: " .. #detectedRolls)

    -- Sort by name for consistent ordering
    table.sort(detectedRolls, function(a, b)
        return a.name < b.name
    end)

    return detectedRolls
end

--- Update the camera rolls list display in the UI
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
-- MAIN WINDOW EVENT HANDLERS
-- ============================================================================

-- Window close event
function win.On.DailiesWin.Close(ev)
    disp:ExitLoop()
end

-- Cancel button
function win.On.CancelBtn.Clicked(ev)
    print("Create Dailies cancelled by user")
    disp:ExitLoop()
end

-- Browse new roll path button
function win.On.BrowseNewRollBtn.Clicked(ev)
    local selectedPath = fu:RequestDir("Select Camera Roll Folder")
    if selectedPath then
        itm.NewRollPath.Text = selectedPath
        print("Selected camera roll path: " .. selectedPath)
    end
end

-- Browse new roll DRX button
function win.On.BrowseNewDRXBtn.Clicked(ev)
    local selectedDRX = fu:RequestFile("Select DRX Grade File")
    if selectedDRX then
        itm.NewRollDRX.Text = selectedDRX
        print("Selected DRX file: " .. selectedDRX)
    end
end

-- Browse audio directory button
function win.On.BrowseAudioBtn.Clicked(ev)
    local selectedPath = fu:RequestDir("Select Audio Directory")
    if selectedPath then
        itm.AudioPath.Text = selectedPath
        print("Selected audio directory: " .. selectedPath)
    end
end

-- Add Multiple Camera Rolls button
function win.On.QuickAddCameraBtn.Clicked(ev)
    print("\n=== Add Multiple Camera Rolls ===")

    -- Browse for parent directory (e.g., A-Cam or B-Camera)
    local parentPath = fu:RequestDir("Select Camera Folder (e.g., A-Cam, B-Camera)")
    if not parentPath then
        print("Add Multiple Camera Rolls cancelled - no directory selected")
        return
    end

    print("Selected parent directory: " .. parentPath)

    -- Detect camera rolls in the directory
    local detectedRolls = detectCameraRolls(parentPath)

    if not detectedRolls or #detectedRolls == 0 then
        print("No camera rolls detected in: " .. parentPath)
        print("Camera rolls should be named like: A001, A002, B001, etc.")
        return
    end

    -- Ask user for optional DRX file to apply to all rolls
    print("\nSelect DRX file to apply to all " .. #detectedRolls .. " rolls (or cancel to skip)")
    local drxPath = fu:RequestFile("Select DRX Grade File (Optional - Cancel to Skip)")
    local drxPathStr = drxPath or ""

    if drxPathStr ~= "" then
        print("DRX file selected: " .. drxPathStr)
    else
        print("No DRX file selected - rolls will be added without DRX")
    end

    -- Add all detected rolls
    print("\nAdding " .. #detectedRolls .. " camera rolls...")
    local addedCount = 0

    for i, roll in ipairs(detectedRolls) do
        local cameraRoll = {
            clipPath = roll.path,
            binName = roll.name,
            timelineName = roll.name,
            drxPath = drxPathStr
        }

        table.insert(cameraRolls, cameraRoll)
        addedCount = addedCount + 1

        print("  Added: " .. roll.name .. " -> " .. roll.path)
    end

    print("\nSuccessfully added " .. addedCount .. " camera rolls")

    -- Update the display
    updateCameraRollsList()
end

-- Add camera roll button
function win.On.AddRollBtn.Clicked(ev)
    local baseName = itm.BaseName.Text
    local rollPath = itm.NewRollPath.Text
    local drxPath = itm.NewRollDRX.Text

    -- Validate required fields
    if not baseName or baseName == "" then
        print("Error: Bin & Timeline Name is required")
        return
    end

    if not rollPath or rollPath == "" then
        print("Error: Camera roll path is required")
        return
    end

    -- Create camera roll entry - use base name as-is for both bin and timeline
    local roll = {
        clipPath = rollPath,
        binName = baseName,
        timelineName = baseName,
        drxPath = drxPath or ""
    }

    table.insert(cameraRolls, roll)

    print("Added camera roll: " .. rollPath)
    print("  Bin: " .. baseName)
    print("  Timeline: " .. baseName)

    -- Clear all input fields
    itm.BaseName.Text = ""
    itm.NewRollPath.Text = ""
    itm.NewRollDRX.Text = ""

    updateCameraRollsList()
end

-- Remove camera roll button
function win.On.RemoveRollBtn.Clicked(ev)
    local tree = itm.CameraRollsList
    local selected = tree:CurrentItem()

    if not selected then
        print("Please select a camera roll to remove")
        return
    end

    if #cameraRolls == 0 then
        print("No camera rolls to remove")
        return
    end

    -- Get the index of the selected item
    local index = tree:IndexOfTopLevelItem(selected) + 1

    if index > 0 and index <= #cameraRolls then
        local removedRoll = table.remove(cameraRolls, index)
        print("Removed camera roll: " .. removedRoll.clipPath)
        updateCameraRollsList()
    end
end

-- Clear all button
function win.On.ClearAllBtn.Clicked(ev)
    if #cameraRolls > 0 then
        cameraRolls = {}
        print("Cleared all camera rolls")
        updateCameraRollsList()
    else
        print("No camera rolls to clear")
    end
end

-- Browse CDL button
function win.On.BrowseCDLBtn.Clicked(ev)
    local selectedCDL = fu:RequestFile("Select CDL File (.ccc or .edl)")
    if selectedCDL then
        itm.CDLPath.Text = selectedCDL
        print("Selected CDL file: " .. selectedCDL)
    end
end

-- Create Dailies button
function win.On.CreateBtn.Clicked(ev)
    local cdlPath = itm.CDLPath.Text
    local audioPath = itm.AudioPath.Text
    local syncAudio = itm.SyncAudio.Checked

    -- Validate that at least one camera roll has been added
    if #cameraRolls == 0 then
        print("Error: Please add at least one camera roll")
        return
    end

    -- Validate CDL path if provided
    if cdlPath and cdlPath ~= "" then
        local file = io.open(cdlPath, "r")
        if not file then
            print("Error: CDL file not found at: " .. cdlPath)
            return
        else
            file:close()
        end
    end

    print("Audio path: " .. (audioPath or ""))
    print("Sync audio: " .. tostring(syncAudio))

    local success = createDailies(cameraRolls, cdlPath, audioPath, syncAudio)

    if success then
        print("\n=== Create Dailies completed successfully ===")
    else
        print("\n=== Create Dailies completed with errors ===")
    end

    -- Close the window after completion
    disp:ExitLoop()
end

-- ============================================================================
-- RUN THE SCRIPT
-- ============================================================================

-- Initialize the camera rolls list
updateCameraRollsList()

-- Show window and run
win:Show()
disp:RunLoop()
win:Hide()
