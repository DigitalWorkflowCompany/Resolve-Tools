-- DaVinci Resolve Script: Write File Size to Media Pool Metadata
-- Gets file size from OS for selected clips and writes to "Size" metadata field
-- Version: 1.00

-- ============================================================================
-- CONSTANTS
-- ============================================================================
-- Size calculation uses decimal GB (1 GB = 1,000,000,000 bytes) to match Finder/macOS
local BYTES_PER_GB = 1000000000

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

local mediaPool = project:GetMediaPool()
if not mediaPool then
    print("Error: Could not access Media Pool")
    return
end

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

--- Parse image sequence path from Resolve format
-- @param filePath string Path in Resolve image sequence format
-- @return string|nil Directory path, or nil if not a sequence
local function parseImageSequencePath(filePath)
    -- Remove any newlines or extra whitespace
    filePath = filePath:gsub("[\n\r]", " "):gsub("%s+", " ")

    -- Check if path contains frame range notation [start-end]
    -- If so, extract just the directory path
    local dir = filePath:match("^(.*/)[^/]+%s*%[%d+[%-–—]?%d*%]")

    if dir then
        return dir
    end

    return nil
end

--- Check if file is an R3D file
-- @param filePath string Path to check
-- @return boolean True if file has .r3d extension
local function isR3DFile(filePath)
    if not filePath then return false end
    return filePath:lower():match("%.r3d$") ~= nil
end

--- Get total size of all R3D parts for a given R3D file
-- R3D files can be split into parts: clip_001.R3D, clip_002.R3D, clip_003.R3D, etc.
-- Resolve typically reports the first part (_001) as the file path
-- @param filePath string Path to the R3D file
-- @return number|nil Total size in bytes, or nil on error
local function getR3DPartsSize(filePath)
    local totalSize = 0
    local sep = package.config:sub(1,1)

    -- Extract directory and base filename
    local dir, filename
    if sep == '\\' then
        dir, filename = filePath:match("^(.+\\)([^\\]+)$")
    else
        dir, filename = filePath:match("^(.+/)([^/]+)$")
    end

    if not dir or not filename then
        -- No directory separator, file is in current directory
        dir = ""
        filename = filePath
    end

    -- Extract base name without .R3D extension
    local baseName = filename:match("^(.+)%.[Rr]3[Dd]$")
    if not baseName then
        return nil
    end

    -- Check if the baseName already ends with _XXX (part number suffix)
    -- If so, strip it to get the true base name
    local trueBaseName = baseName:match("^(.+)_%d%d%d$")
    if trueBaseName then
        baseName = trueBaseName
        print("  Detected as R3D multi-part file")
        print("  Base name (stripped part suffix): " .. baseName)
    else
        print("  Detected as R3D file")
        print("  Base name: " .. baseName)
    end

    -- Iterate through all parts starting from _001
    local partNum = 1
    local partsFound = 0
    while true do
        local partSuffix = string.format("_%03d", partNum)
        local partPath = dir .. baseName .. partSuffix .. ".R3D"

        local partFile = io.open(partPath, "rb")
        if not partFile then
            -- Also try lowercase extension
            partPath = dir .. baseName .. partSuffix .. ".r3d"
            partFile = io.open(partPath, "rb")
        end

        if partFile then
            local partSize = partFile:seek("end")
            partFile:close()
            if partSize then
                totalSize = totalSize + partSize
                print("  Part " .. partNum .. " (" .. baseName .. partSuffix .. ".R3D): " .. partSize .. " bytes")
                partsFound = partsFound + 1
            end
            partNum = partNum + 1
        else
            -- No more parts found
            break
        end
    end

    if partsFound > 0 then
        print("  Total parts found: " .. partsFound)
        print("  Total size: " .. totalSize .. " bytes")
        return totalSize
    end

    -- If no _XXX parts found, try reading the file as-is (single R3D file without parts)
    print("  No multi-part files found, reading single file")
    local singleFile = io.open(filePath, "rb")
    if singleFile then
        totalSize = singleFile:seek("end")
        singleFile:close()
        print("  Single file size: " .. totalSize .. " bytes")
        return totalSize
    end

    return nil
end

--- Get total size of a directory (for image sequences)
-- @param dir string Directory path
-- @return number Total size in bytes
local function getDirectorySize(dir)
    local totalSize = 0
    local sep = package.config:sub(1,1)

    local success, result = pcall(function()
        if sep == '\\' then
            -- Windows: use dir command to get file sizes
            local command = 'dir "' .. dir .. '" /s /a-d'
            local handle = io.popen(command)
            if handle then
                for line in handle:lines() do
                    local size = line:match("^%s*(%d+)%s+")
                    if size then
                        totalSize = totalSize + tonumber(size)
                    end
                end
                handle:close()
            end
        else
            -- Unix/Mac/Linux: use du command to get directory size in bytes
            local command = 'du -sk "' .. dir .. '"'
            local handle = io.popen(command)
            if handle then
                local output = handle:read("*a")
                handle:close()
                -- du -sk returns size in KB, extract the number
                local sizeKB = output:match("^(%d+)")
                if sizeKB then
                    totalSize = tonumber(sizeKB) * 1024  -- Convert KB to bytes
                end
            end
        end
        return totalSize
    end)

    if not success then
        print("Error reading directory size: " .. tostring(result))
        return 0
    end

    return totalSize
end

--- Get file size in GB from file path
-- Handles single files, image sequences, and R3D multi-part files
-- @param filePath string Path to the file
-- @return number|nil Size in GB (decimal, matching Finder/macOS), or nil on error
local function getFileSizeGB(filePath)
    if not filePath or filePath == "" then
        return nil
    end

    local totalSize = 0

    -- Check if it's an image sequence path (contains frame range [xxxx-yyyy])
    local dir = parseImageSequencePath(filePath)

    if dir then
        -- Image sequence - get directory size
        print("  Detected as image sequence")
        print("  Directory: " .. tostring(dir))
        totalSize = getDirectorySize(dir)
        if not totalSize or totalSize == 0 then
            return nil
        end
    elseif isR3DFile(filePath) then
        -- R3D file - may have multiple parts
        totalSize = getR3DPartsSize(filePath)
        if not totalSize or totalSize == 0 then
            return nil
        end
    else
        -- Single file
        local file = io.open(filePath, "rb")
        if not file then
            return nil
        end

        totalSize = file:seek("end")
        file:close()

        if not totalSize then
            return nil
        end
    end

    -- Convert bytes to GB using constant (decimal/SI units to match Finder)
    local sizeGB = totalSize / BYTES_PER_GB
    -- Round up to 4 decimal places
    return math.ceil(sizeGB * 10000) / 10000
end

-- ============================================================================
-- MAIN PROCESSING FUNCTION
-- ============================================================================

--- Process all selected clips and write their file sizes to metadata
-- @return boolean True if processing was successful
local function processSelectedClips()
    
    -- Get selected clips from media pool
    local selectedClips = mediaPool:GetSelectedClips()
    
    if not selectedClips or #selectedClips == 0 then
        print("No clips selected in media pool")
        return false
    end
    
    print("Processing " .. #selectedClips .. " selected clip(s)...")
    
    local successCount = 0
    local failCount = 0
    
    -- Process each selected clip
    for i, clip in ipairs(selectedClips) do
        local clipName = clip:GetName()
        local filePath = clip:GetClipProperty("File Path")
        
        print("\nProcessing: " .. clipName)
        print("File path: " .. tostring(filePath))
        
        if filePath and filePath ~= "" then
            -- Wrap in pcall to catch any errors
            local success, sizeGB = pcall(function()
                return getFileSizeGB(filePath)
            end)
            
            if not success then
                print("✗ Error occurred: " .. tostring(sizeGB))
                failCount = failCount + 1
            elseif sizeGB then
                -- Set the Size metadata field (number only, no units)
                local metaSuccess = clip:SetMetadata("Size", tostring(sizeGB))
                
                if metaSuccess then
                    print("✓ Size written: " .. sizeGB .. " GB")
                    successCount = successCount + 1
                else
                    print("✗ Failed to write metadata (check if 'Size' field exists)")
                    failCount = failCount + 1
                end
            else
                print("✗ Could not read file size")
                failCount = failCount + 1
            end
        else
            print("✗ No valid file path found")
            failCount = failCount + 1
        end
    end
    
    -- Summary
    print("\n" .. string.rep("=", 50))
    print("SUMMARY:")
    print("Total clips: " .. #selectedClips)
    print("Successful: " .. successCount)
    print("Failed: " .. failCount)
    print(string.rep("=", 50))
    
    return true
end

-- Main execution
print("Starting Media Pool File Size Script...")
print(string.rep("=", 50))

local success = processSelectedClips()

if success then
    print("\nScript completed!")
else
    print("\nScript failed to execute properly")
end