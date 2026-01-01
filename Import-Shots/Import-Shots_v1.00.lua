-- DaVinci Resolve - Import Clips to Media Pool v1.03
-- Imports clips from user-defined directories with metadata and per-camera-roll bin creation
-- Version 1.01 changes:
--   - Added Shoot Day and Date Recorded metadata fields
--   - Support for multiple camera roll directories
--   - Creates separate bins per camera roll when bin creation is enabled
-- Version 1.02 changes:
--   - Added audio directory selection and import
--   - Automatic audio sync using timecode matching
--   - Comprehensive debug output for sync failures
-- Version 1.03 changes:
--   - Fixed timeline clip addition by retrieving clips fresh from bin
--   - Added detailed debugging for AppendToTimeline failures

local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)
local width, height = 600, 580

-- Create GUI window for path input
win = disp:AddWindow({
    ID = 'ImportWin',
    TargetID = 'ImportWin',
    WindowTitle = 'Import Clips to Media Pool v1.03',
    Geometry = {200, 200, width, height},
    Spacing = 10,

    ui:VGroup{
        ID = 'root',
        ui:VGroup{
            -- Metadata Fields Section
            ui:Label{
                Weight = 1,
                Text = "Metadata Fields:",
                Font = ui:Font{PixelSize = 13, StyleName = "Bold"},
                WordWrap = true
            },
            ui:HGroup{
                ui:Label{
                    Text = "Shoot Day:",
                    Weight = 1
                },
                ui:LineEdit{
                    ID = "ShootDay",
                    Text = "",
                    PlaceholderText = "e.g., Day 1",
                    Weight = 2
                },
                ui:Label{
                    Text = "Date Recorded:",
                    Weight = 1
                },
                ui:LineEdit{
                    ID = "DateRecorded",
                    Text = "",
                    PlaceholderText = "e.g., 2025-01-15",
                    Weight = 2
                }
            },
            ui:VGap(15),

            -- Camera Rolls Section
            ui:Label{
                Weight = 1,
                Text = "Camera Roll Directories:",
                Font = ui:Font{PixelSize = 13, StyleName = "Bold"},
                WordWrap = true
            },
            ui:Tree{
                ID = "CameraRollsList",
                SortingEnabled = false,
                MinimumSize = {width, 120}
            },
            ui:HGroup{
                ui:Button{
                    ID = "AddRollBtn",
                    Text = "Add Camera Roll...",
                    Weight = 1
                },
                ui:Button{
                    ID = "RemoveRollBtn",
                    Text = "Remove Selected",
                    Weight = 1
                }
            },
            ui:VGap(10),

            -- Audio Directory Section
            ui:Label{
                Weight = 1,
                Text = "Audio Directory (Optional):",
                Font = ui:Font{PixelSize = 13, StyleName = "Bold"},
                WordWrap = true
            },
            ui:HGroup{
                ui:LineEdit{
                    ID = "AudioPath",
                    Text = "",
                    PlaceholderText = "Select audio directory for sync...",
                    Weight = 3
                },
                ui:Button{
                    ID = "BrowseAudioBtn",
                    Text = "Browse Audio...",
                    Weight = 1
                }
            },
            ui:CheckBox{
                ID = "SyncAudio",
                Text = "Auto-sync audio to video using timecode",
                Checked = true
            },
            ui:VGap(10),

            -- Bin Options
            ui:CheckBox{
                ID = "CreateBin",
                Text = "Create bins for imported clips (one bin per camera roll)",
                Checked = true
            },
            ui:VGap(5),

            -- Timeline Options
            ui:CheckBox{
                ID = "CreateTimeline",
                Text = "Create new timeline and add clips to it",
                Checked = false
            },
            ui:HGroup{
                ui:Label{
                    Text = "Timeline Name:",
                    Weight = 1
                },
                ui:LineEdit{
                    ID = "TimelineName",
                    Text = "",
                    PlaceholderText = "Enter timeline name",
                    Weight = 3
                }
            },
            ui:VGap(5),

            -- DRX Options
            ui:CheckBox{
                ID = "ApplyDRX",
                Text = "Apply DRX file to timeline clips",
                Checked = false
            },
            ui:HGroup{
                ui:LineEdit{
                    ID = "DRXPath",
                    Text = "",
                    PlaceholderText = "/path/to/your/grade.drx",
                    Weight = 3
                },
                ui:Button{
                    ID = "BrowseDRXBtn",
                    Text = "Browse DRX...",
                    Weight = 1
                }
            },
            ui:VGap(10),

            -- Action Buttons
            ui:HGroup{
                ui:Button{Weight = 1, ID = "ImportBtn", Text = "Import Clips"},
                ui:Button{Weight = 1, ID = "CancelBtn", Text = "Cancel"}
            }
        }
    }
})

itm = win:GetItems()

-- Initialize camera rolls list storage (must be global for event handlers)
cameraRolls = {}

-- Function to update the camera rolls tree display
function updateCameraRollsTree()
    local tree = itm.CameraRollsList
    tree:Clear()

    -- Set up tree headers if not already set
    tree:SetHeaderHidden(false)
    tree.ColumnCount = 1
    tree:SetHeaderLabels({"Camera Roll Directories"})

    if #cameraRolls == 0 then
        local item = tree:NewItem()
        item.Text[0] = "No camera rolls added yet - click 'Add Camera Roll...'"
        tree:AddTopLevelItem(item)
    else
        for i, rollPath in ipairs(cameraRolls) do
            local rollName = rollPath:match("([^/]+)$") or rollPath
            local item = tree:NewItem()
            item.Text[0] = i .. ". " .. rollName
            tree:AddTopLevelItem(item)
        end
    end
end

-- Function to check if a file has a video extension
function isVideoFile(fileName)
    local videoExtensions = {
        ".mov", ".mp4", ".avi", ".mkv", ".mxf", ".r3d", ".braw",
        ".dng", ".dpx", ".exr", ".tiff", ".tif", ".jpg", ".png",
        ".prores", ".dnxhd", ".h264", ".h265", ".webm"
    }

    local lowerName = fileName:lower()
    for _, ext in ipairs(videoExtensions) do
        if lowerName:sub(-#ext) == ext then
            return true
        end
    end
    return false
end

-- Function to check if a file has an audio extension
function isAudioFile(fileName)
    local audioExtensions = {
        ".wav", ".mp3", ".aif", ".aiff", ".m4a", ".aac",
        ".flac", ".ogg", ".wma", ".mxf"
    }

    local lowerName = fileName:lower()
    for _, ext in ipairs(audioExtensions) do
        if lowerName:sub(-#ext) == ext then
            return true
        end
    end
    return false
end

-- Recursive function to scan directories and collect all video files
function scanDirectoryRecursive(mediaStorage, basePath, videoFiles, depth)
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

-- Main import function
function importClips(cameraRollPaths, createBin, createTimeline, timelineName, applyDRX, drxPath, shootDay, dateRecorded, audioPath, syncAudio)
    print("=== DaVinci Resolve - Import Clips v1.02 ===")

    -- Access API objects directly (like in working scripts)
    projectManager = resolve:GetProjectManager()
    project = projectManager:GetCurrentProject()

    if not project then
        print("Error: No project is open")
        print("Please open or create a project before running this script")
        return false
    end

    mediaPool = project:GetMediaPool()
    mediaStorage = resolve:GetMediaStorage()

    -- Store all timeline items for DRX application later
    local allTimelineItems = {}

    -- Process each camera roll separately
    for rollIndex, clipPath in ipairs(cameraRollPaths) do
        -- Extract folder name from path (handle both forward and back slashes, remove trailing slashes)
        local cleanPath = clipPath:gsub("[\\/]+$", "")  -- Remove trailing slashes
        local rollName = cleanPath:match("([^\\/]+)$") or cleanPath  -- Extract last component

        print("\n=== Processing Camera Roll " .. rollIndex .. ": " .. rollName .. " ===")
        print("Full path: " .. clipPath)

        -- Handle bin creation if requested
        local targetFolder = nil
        if createBin then
            local rootFolder = mediaPool:GetRootFolder()
            local binName = rollName  -- Use camera roll directory name as bin name
            targetFolder = mediaPool:AddSubFolder(rootFolder, binName)

            if not targetFolder then
                print("Error: Failed to create bin '" .. binName .. "'")
                print("Bin may already exist with this name, trying to find it...")

                -- Try to find existing bin with this name
                local subFolders = rootFolder:GetSubFolderList()
                for _, folder in ipairs(subFolders) do
                    if folder:GetName() == binName then
                        targetFolder = folder
                        print("Found existing bin: " .. binName)
                        break
                    end
                end

                if not targetFolder then
                    print("Could not create or find bin, skipping this camera roll")
                    goto continue
                end
            else
                print("Created new bin: " .. binName)
            end

            -- Set the new bin as current folder for import
            mediaPool:SetCurrentFolder(targetFolder)
        else
            -- Use current folder if not creating a new bin
            targetFolder = mediaPool:GetCurrentFolder()
            print("Using current folder: " .. targetFolder:GetName())
        end

        -- Remove trailing slash if present
        clipPath = clipPath:gsub("/$", "")

        -- Recursively scan directory and all subdirectories for video files
        print("Scanning directory recursively: " .. clipPath)
        local videoFiles = scanDirectoryRecursive(mediaStorage, clipPath)

        if not videoFiles or #videoFiles == 0 then
            print("Warning: No supported video files found in " .. rollName)
            goto continue
        end

        print("Found " .. #videoFiles .. " supported video files")

        -- Import files to Media Pool
        if createBin then
            print("\nImporting files to bin '" .. rollName .. "'...")
        else
            print("\nImporting files to current Media Pool folder...")
        end

        -- Attempt import with the collected video files
        print("Attempting import with collected file paths...")
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
            print("Warning: Failed to import any files from " .. rollName)
            goto continue
        end

        -- Success message for import
        print("Successfully imported " .. #importedClips .. " clips from " .. rollName)

        -- Apply metadata to imported clips
        if shootDay ~= "" or dateRecorded ~= "" then
            print("\nApplying metadata to imported clips...")
            local metadataTable = {}

            if shootDay ~= "" then
                metadataTable["Shoot Day"] = shootDay
            end

            if dateRecorded ~= "" then
                metadataTable["Date Recorded"] = dateRecorded
            end

            local metadataSuccessCount = 0
            for i, clip in ipairs(importedClips) do
                local success = clip:SetMetadata(metadataTable)
                if success then
                    metadataSuccessCount = metadataSuccessCount + 1
                end
            end

            print("Applied metadata to " .. metadataSuccessCount .. " of " .. #importedClips .. " clips")
        end

        -- Handle timeline creation and clip addition
        if createTimeline then
            if not timelineName or timelineName == "" then
                print("Error: Timeline name is required when 'Create new timeline' is checked")
                return false
            end

            -- Set the target folder as current to ensure clips are accessible
            if targetFolder then
                mediaPool:SetCurrentFolder(targetFolder)
                print("Set current folder to: " .. targetFolder:GetName())
            end

            -- Retrieve clips from the bin
            local clipsToAdd = {}
            if targetFolder then
                local binClips = targetFolder:GetClipList()
                if binClips and #binClips > 0 then
                    print("Found " .. #binClips .. " clips in bin '" .. targetFolder:GetName() .. "'")
                    clipsToAdd = binClips
                else
                    print("Warning: No clips found in target bin, using imported clips")
                    clipsToAdd = importedClips
                end
            else
                clipsToAdd = importedClips
            end

            if rollIndex == 1 then
                -- First camera roll: Create timeline WITH clips using CreateTimelineFromClips
                print("\nCreating timeline '" .. timelineName .. "' with " .. #clipsToAdd .. " clips...")

                -- Create or find "Timelines" bin
                local rootFolder = mediaPool:GetRootFolder()
                local timelinesFolder = nil

                local subFolders = rootFolder:GetSubFolderList()
                for _, folder in ipairs(subFolders) do
                    if folder:GetName() == "Timelines" then
                        timelinesFolder = folder
                        print("Found existing 'Timelines' bin")
                        break
                    end
                end

                if not timelinesFolder then
                    timelinesFolder = mediaPool:AddSubFolder(rootFolder, "Timelines")
                    if timelinesFolder then
                        print("Created new 'Timelines' bin")
                    end
                end

                -- Set Timelines folder as current for timeline creation
                if timelinesFolder then
                    mediaPool:SetCurrentFolder(timelinesFolder)
                end

                -- Use CreateTimelineFromClips instead of CreateEmptyTimeline + AppendToTimeline
                local newTimeline = mediaPool:CreateTimelineFromClips(timelineName, clipsToAdd)

                if newTimeline then
                    print("Successfully created timeline '" .. timelineName .. "' with clips!")
                    project:SetCurrentTimeline(newTimeline)

                    -- Get timeline items for DRX application
                    local trackCount = newTimeline:GetTrackCount("video")
                    for track = 1, trackCount do
                        local items = newTimeline:GetItemListInTrack("video", track)
                        if items then
                            for _, item in ipairs(items) do
                                table.insert(allTimelineItems, item)
                            end
                        end
                    end
                    print("Timeline has " .. #allTimelineItems .. " clips")
                else
                    print("Error: CreateTimelineFromClips failed")
                    print("Trying fallback: CreateEmptyTimeline + AppendToTimeline...")

                    -- Fallback to old method
                    local emptyTimeline = mediaPool:CreateEmptyTimeline(timelineName)
                    if emptyTimeline then
                        project:SetCurrentTimeline(emptyTimeline)
                        -- Restore folder and try append
                        if targetFolder then
                            mediaPool:SetCurrentFolder(targetFolder)
                        end
                        local timelineItems = mediaPool:AppendToTimeline(clipsToAdd)
                        if timelineItems and #timelineItems > 0 then
                            print("Fallback succeeded: Added " .. #timelineItems .. " clips")
                            for _, item in ipairs(timelineItems) do
                                table.insert(allTimelineItems, item)
                            end
                        else
                            print("Fallback also failed to add clips to timeline")
                        end
                    else
                        print("Failed to create timeline")
                        return false
                    end
                end

                -- Restore folder context
                if targetFolder then
                    mediaPool:SetCurrentFolder(targetFolder)
                end
            else
                -- Subsequent camera rolls: Append to existing timeline
                local currentTimeline = project:GetCurrentTimeline()
                if currentTimeline then
                    print("Appending " .. #clipsToAdd .. " clips from " .. rollName .. " to timeline...")
                    local timelineItems = mediaPool:AppendToTimeline(clipsToAdd)

                    if timelineItems and #timelineItems > 0 then
                        print("Successfully added " .. #timelineItems .. " clips to timeline")
                        for _, item in ipairs(timelineItems) do
                            table.insert(allTimelineItems, item)
                        end
                    else
                        print("Warning: Failed to append clips from " .. rollName)
                    end
                else
                    print("Warning: No current timeline for appending")
                end
            end
        end

        ::continue::
    end

    -- Handle audio import and sync if requested
    if audioPath and audioPath ~= "" and syncAudio then
        print("\n=== Audio Import and Sync ===")
        print("Audio directory: " .. audioPath)

        -- Remove trailing slash
        audioPath = audioPath:gsub("/$", "")

        -- Scan audio directory for audio files
        print("Scanning audio directory recursively: " .. audioPath)
        local audioFiles = {}

        -- Reuse the scanDirectoryRecursive function but filter for audio
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

        audioFiles = scanAudioRecursive(mediaStorage, audioPath, audioFiles, 0)

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

                -- Collect all imported video clips from all camera rolls
                print("\n=== Syncing Audio to Video ===")
                print("Collecting all imported video clips for sync...")

                -- Get all clips from camera roll bins
                local allVideoClips = {}
                for rollIndex, clipPath in ipairs(cameraRollPaths) do
                    local rollName = clipPath:match("([^/]+)$") or clipPath

                    -- Find the bin for this camera roll
                    local binFolder = nil
                    if createBin then
                        local rootFolder = mediaPool:GetRootFolder()
                        local subFolders = rootFolder:GetSubFolderList()
                        for _, folder in ipairs(subFolders) do
                            if folder:GetName() == rollName then
                                binFolder = folder
                                break
                            end
                        end
                    else
                        binFolder = mediaPool:GetCurrentFolder()
                    end

                    if binFolder then
                        local clipsInBin = binFolder:GetClipList()
                        if clipsInBin then
                            for _, clip in ipairs(clipsInBin) do
                                table.insert(allVideoClips, clip)
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
                        print("✓ Audio sync completed successfully!")
                        print("\nSync Results:")
                        print("  - Synced clips will appear in the Media Pool with audio linked")
                        print("  - Check the Media Pool for clips with '_synced' suffix or linked audio")
                        print("  - Any clips that failed to sync will remain unlinked")
                    else
                        print("✗ Audio sync failed")
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

    -- Handle DRX application if requested and timeline was created
    if applyDRX and createTimeline and #allTimelineItems > 0 then
        if not drxPath or drxPath == "" then
            print("Error: DRX file path is required when 'Apply DRX file' is checked")
            return false
        end

        -- Check if DRX file exists
        local file = io.open(drxPath, "r")
        if not file then
            print("Error: DRX file not found at: " .. drxPath)
            return false
        else
            file:close()
        end

        -- Switch to Color page for applying grades
        print("\nSwitching to Color page to apply DRX grades...")
        resolve:OpenPage("color")

        print("Applying DRX file to " .. #allTimelineItems .. " timeline clips...")
        local successCount = 0
        local failCount = 0

        for i, timelineItem in ipairs(allTimelineItems) do
            local itemName = timelineItem:GetName()
            print("Processing clip " .. i .. ": " .. (itemName or "Unknown"))

            local nodeGraph = timelineItem:GetNodeGraph()
            if nodeGraph then
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

        -- Switch back to Edit page
        print("Switching back to Edit page...")
        resolve:OpenPage("edit")
    elseif applyDRX and not createTimeline then
        print("Warning: DRX application requires timeline creation to be enabled")
    end

    return true
end

-- Window close event
function win.On.ImportWin.Close(ev)
    disp:ExitLoop()
end

-- Cancel button
function win.On.CancelBtn.Clicked(ev)
    print("Import cancelled by user")
    disp:ExitLoop()
end

-- Add Camera Roll button
function win.On.AddRollBtn.Clicked(ev)
    print("\n=== Add Camera Roll Button Clicked ===")
    local selectedPath = fu:RequestDir()
    print("Selected path: " .. tostring(selectedPath))
    if selectedPath then
        table.insert(cameraRolls, selectedPath)
        print("Added camera roll: " .. selectedPath)
        print("Total camera rolls: " .. #cameraRolls)
        updateCameraRollsTree()
    else
        print("No path selected")
    end
end

-- Browse Audio button
function win.On.BrowseAudioBtn.Clicked(ev)
    local selectedPath = fu:RequestDir()
    if selectedPath then
        itm.AudioPath.Text = selectedPath
        print("Selected audio directory: " .. selectedPath)
    end
end

-- Remove Camera Roll button
function win.On.RemoveRollBtn.Clicked(ev)
    local tree = itm.CameraRollsList
    local selected = tree:CurrentItem()

    if selected then
        local itemText = selected.Text[0]
        local rollIndex = tonumber(itemText:match("^(%d+)%."))

        if rollIndex and cameraRolls[rollIndex] then
            local removedPath = cameraRolls[rollIndex]
            table.remove(cameraRolls, rollIndex)
            print("Removed camera roll: " .. removedPath)
            updateCameraRollsTree()
        end
    else
        print("Please select a camera roll to remove")
    end
end

-- Browse DRX button
function win.On.BrowseDRXBtn.Clicked(ev)
    local selectedDRX = fu:RequestFile()
    if selectedDRX then
        itm.DRXPath.Text = selectedDRX
        print("Selected DRX file: " .. selectedDRX)
    end
end

-- Import button
function win.On.ImportBtn.Clicked(ev)
    print("\n=== Import Button Clicked ===")

    local createBin = itm.CreateBin.Checked
    local createTimeline = itm.CreateTimeline.Checked
    local timelineName = itm.TimelineName.Text
    local applyDRX = itm.ApplyDRX.Checked
    local drxPath = itm.DRXPath.Text
    local shootDay = itm.ShootDay.Text
    local dateRecorded = itm.DateRecorded.Text
    local audioPath = itm.AudioPath.Text
    local syncAudio = itm.SyncAudio.Checked

    print("Camera rolls count: " .. #cameraRolls)
    print("Create bin: " .. tostring(createBin))
    print("Create timeline: " .. tostring(createTimeline))
    print("Timeline name: " .. timelineName)
    print("Shoot Day: " .. shootDay)
    print("Date Recorded: " .. dateRecorded)
    print("Audio path: " .. audioPath)
    print("Sync audio: " .. tostring(syncAudio))

    if #cameraRolls == 0 then
        print("Error: Please add at least one camera roll directory")
        return
    end

    -- If creating a timeline, validate timeline name
    if createTimeline and (not timelineName or timelineName == "") then
        print("Error: Please enter a timeline name or uncheck 'Create new timeline'")
        return
    end

    -- If applying DRX, validate DRX path and timeline creation
    if applyDRX then
        if not createTimeline then
            print("Error: DRX application requires timeline creation to be enabled")
            return
        end
        if not drxPath or drxPath == "" then
            print("Error: Please select a DRX file or uncheck 'Apply DRX file'")
            return
        end
    end

    local success = importClips(cameraRolls, createBin, createTimeline, timelineName, applyDRX, drxPath, shootDay, dateRecorded, audioPath, syncAudio)

    if success then
        print("\n=== Import completed successfully ===")
    else
        print("\n=== Import failed ===")
    end

    -- Close the window after import attempt
    disp:ExitLoop()
end

-- Show window and run
updateCameraRollsTree()
win:Show()
disp:RunLoop()
win:Hide()
