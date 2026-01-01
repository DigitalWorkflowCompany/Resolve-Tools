-- Script: Copy Yellow Clip Markers to QC Notes
-- Description: Reads yellow clip markers from timeline and copies their name/time to QC Notes metadata
-- For: DaVinci Resolve 20
-- Version: 1.00

-- ============================================================================
-- INITIALIZATION
-- ============================================================================
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
    print("Error: No project is currently open")
    return
end

local timeline = project:GetCurrentTimeline()
if not timeline then
    print("Error: No timeline is currently open")
    return
end

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

--- Format frame number as timecode string (HH:MM:SS:FF)
-- @param frames number Frame count
-- @param framerate number Timeline framerate
-- @return string Formatted timecode
local function formatTimecode(frames, framerate)
    local fps = math.floor(framerate + 0.5)
    local hours = math.floor(frames / (fps * 3600))
    local minutes = math.floor((frames % (fps * 3600)) / (fps * 60))
    local seconds = math.floor((frames % (fps * 60)) / fps)
    local frameNum = frames % fps
    return string.format("%02d:%02d:%02d:%02d", hours, minutes, seconds, frameNum)
end

-- ============================================================================
-- MAIN PROCESSING
-- ============================================================================

-- Get timeline framerate
local framerate = timeline:GetSetting("timelineFrameRate")
if not framerate then
    print("Error: Could not get timeline framerate")
    return
end

-- Get all video tracks
local trackCount = timeline:GetTrackCount("video")
if not trackCount or trackCount == 0 then
    print("Error: No video tracks in timeline")
    return
end

print(string.format("Processing %d video tracks...", trackCount))

local markerCount = 0
local clipCount = 0

-- Iterate through all video tracks
for trackIndex = 1, trackCount do
    local clips = timeline:GetItemListInTrack("video", trackIndex)
    
    for _, clip in ipairs(clips) do
        clipCount = clipCount + 1
        local markers = clip:GetMarkers()
        local qcNotes = ""
        
        -- Iterate through markers and find yellow ones
        for frameId, markerData in pairs(markers) do
            -- Yellow color in Resolve is typically "Yellow"
            if markerData.color == "Yellow" then
                local markerName = markerData.name or "Unnamed"
                local timecode = formatTimecode(frameId, framerate)
                
                -- Build QC note entry
                local noteEntry = string.format("[%s] %s", timecode, markerName)
                
                if qcNotes == "" then
                    qcNotes = noteEntry
                else
                    qcNotes = qcNotes .. "\n" .. noteEntry
                end
                
                markerCount = markerCount + 1
                print(string.format("Found yellow marker: %s at %s on clip '%s'", 
                    markerName, timecode, clip:GetName()))
            end
        end
        
        -- Update QC Notes metadata if we found yellow markers
        if qcNotes ~= "" then
            -- Get the MediaPoolItem from the TimelineItem
            local mediaPoolItem = clip:GetMediaPoolItem()

            if mediaPoolItem then
                -- Write to QC Notes field
                local success = mediaPoolItem:SetMetadata({["QC Notes"] = qcNotes})

                if success then
                    -- Verify the write by reading it back
                    local verifyMetadata = mediaPoolItem:GetMetadata("QC Notes")
                    if verifyMetadata and verifyMetadata ~= "" then
                        print(string.format("SUCCESS: QC Notes written for '%s'", clip:GetName()))
                        print(string.format("  Value: %s", qcNotes))
                    else
                        print(string.format("WARNING: Write returned success but verification failed for '%s'", clip:GetName()))
                    end
                else
                    print(string.format("FAILED: Could not write QC Notes for '%s'", clip:GetName()))
                end
            else
                print(string.format("ERROR: Could not get MediaPoolItem for clip: %s", clip:GetName()))
            end
        end
    end
end

print(string.format("\nCompleted! Processed %d clips and found %d yellow markers",
    clipCount, markerCount))

if markerCount > 0 then
    print("\n=== WHERE TO VIEW QC NOTES IN RESOLVE ===")
    print("1. Go to Media Pool")
    print("2. Right-click on the column headers")
    print("3. Select 'Clip Information' or 'Metadata View'")
    print("4. Look for 'QC Notes' column (may need to scroll right)")
    print("   OR: Right-click headers > 'Metadata Columns' > ensure 'QC Notes' is checked")
    print("5. You can also see it in the Metadata panel (top-right of Media Pool)")
end