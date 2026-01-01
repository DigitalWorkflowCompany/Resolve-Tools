-- CDL Import Script for DaVinci Resolve 20
-- Imports CDL values from .ccc or .edl files and applies them to matching clips
-- Version: 1.01

local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)

-- ============================================================================
-- CCC/EDL PARSING FUNCTIONS
-- ============================================================================

--- Parse a CCC (Color Correction Collection) file
-- @param filepath string The path to the CCC file
-- @return table|nil CDL data table keyed by clip name, or nil on error
-- @return string|nil Error message if parsing failed
function parseCCC(filepath)
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
-- @param filepath string The path to the EDL file
-- @return table|nil CDL data table keyed by clip name, or nil on error
-- @return string|nil Error message if parsing failed
function parseEDL(filepath)
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

--- Parse CDL string values into an array of numbers
-- @param cdlString string Space-separated CDL values (e.g., "1.0 1.0 1.0")
-- @return table Array of number values
function parseCDLValues(cdlString)
    local values = {}
    for val in cdlString:gmatch("[^%s]+") do
        table.insert(values, tonumber(val))
    end
    return values
end

--- Apply CDL values to a timeline clip
-- @param clip TimelineItem The timeline clip to apply CDL to
-- @param cdl table CDL data containing slope, offset, power, saturation values
-- @return boolean True if CDL was applied successfully
function applyCDL(clip, cdl)
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
-- MAIN FUNCTION
-- ============================================================================

--- Main entry point for the CDL Import script
function main()
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
    
    -- Create UI for file selection
    local win = disp:AddWindow({
        ID = "CDLImporter",
        WindowTitle = "CDL Importer",
        Geometry = {100, 100, 500, 150},
        
        ui:VGroup{
            ID = "root",
            
            ui:Label{
                ID = "InfoLabel",
                Text = "Select a CCC or EDL file to import CDL values:",
                Alignment = {AlignHCenter = true, AlignTop = true},
            },
            
            ui:HGroup{
                Weight = 0,
                ui:LineEdit{
                    ID = "FilePath",
                    PlaceholderText = "No file selected",
                    ReadOnly = true,
                },
                ui:Button{
                    ID = "BrowseButton",
                    Text = "Browse",
                },
            },
            
            ui:HGroup{
                Weight = 0,
                ui:Button{
                    ID = "ImportButton",
                    Text = "Import and Apply",
                },
                ui:Button{
                    ID = "CancelButton",
                    Text = "Cancel",
                },
            },
        },
    })
    
    local itm = win:GetItems()
    local selectedFile = nil
    
    -- Browse button handler
    function win.On.BrowseButton.Clicked(ev)
        selectedFile = fusion:RequestFile("", "", {
            FReqB_Listing = true,
            FReqS_Title = "Select CDL File (CCC or EDL)",
            FReqS_Filter = "CCC Files (*.ccc)|*.ccc|EDL Files (*.edl)|*.edl|All Files (*.*)|*.*",
        })
        
        if selectedFile then
            itm.FilePath.Text = selectedFile
        end
    end
    
    -- Import button handler
    function win.On.ImportButton.Clicked(ev)
        if not selectedFile then
            print("No file selected")
            return
        end
        
        -- Parse the file
        local cdlData = nil
        local fileExt = selectedFile:match("%.([^%.]+)$")

        if not fileExt then
            print("Error: Could not determine file extension")
            disp:ExitLoop()
            return
        end

        fileExt = fileExt:lower()

        if fileExt == "ccc" then
            cdlData = parseCCC(selectedFile)
        elseif fileExt == "edl" then
            cdlData = parseEDL(selectedFile)
        else
            print("Unsupported file format")
            disp:ExitLoop()
            return
        end
        
        if not cdlData then
            print("Failed to parse file")
            disp:ExitLoop()
            return
        end
        
        -- Count total CDL entries
        local totalCDLs = 0
        for _ in pairs(cdlData) do
            totalCDLs = totalCDLs + 1
        end
        
        -- Switch to Color page
        resolve:OpenPage("color")

        -- Get current timeline
        local timeline = project:GetCurrentTimeline()
        if not timeline then
            print("Error: No timeline is currently open")
            disp:ExitLoop()
            return
        end

        -- Get all timeline items
        local trackCount = timeline:GetTrackCount("video")
        if not trackCount or trackCount == 0 then
            print("Error: No video tracks in timeline")
            disp:ExitLoop()
            return
        end
        local appliedCount = 0
        local processedClips = 0
        
        -- Debug: Print all CDL entries
        print("\n=== CDL Data Found ===")
        for name, cdl in pairs(cdlData) do
            print("CDL Entry: '" .. name .. "'")
            if cdl.slope then print("  Slope: " .. cdl.slope) end
            if cdl.offset then print("  Offset: " .. cdl.offset) end
            if cdl.power then print("  Power: " .. cdl.power) end
            if cdl.saturation then print("  Saturation: " .. cdl.saturation) end
        end
        
        -- Loop through all video tracks
        print("\n=== Timeline Clips ===")
        print("Total video tracks: " .. trackCount)
        
        for trackIndex = 1, trackCount do
            local itemList = timeline:GetItemListInTrack("video", trackIndex)
            local itemCount = 0
            
            -- Count items in track
            if itemList then
                for _ in pairs(itemList) do
                    itemCount = itemCount + 1
                end
            end
            
            print("Track " .. trackIndex .. " has " .. itemCount .. " items")
            
            if itemList then
                for i, clip in ipairs(itemList) do
                    processedClips = processedClips + 1
                    local clipName = clip:GetName()
                    print("Clip " .. processedClips .. " (Track " .. trackIndex .. "): '" .. clipName .. "'")
                    
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
                    else
                        print("  -> No matching CDL entry")
                    end
                end
            end
        end
        print("\n=== End of Processing ===\n")
        
        -- Display summary
        local summary = string.format(
            "Import Complete!\n\n" ..
            "CDL entries found in file: %d\n" ..
            "Clips found in timeline: %d\n" ..
            "CDLs successfully applied: %d",
            totalCDLs, processedClips, appliedCount
        )
        
        print(summary)
        
        local summaryWin = disp:AddWindow({
            ID = "Summary",
            WindowTitle = "Import Summary",
            Geometry = {200, 200, 400, 200},
            
            ui:VGroup{
                ui:TextEdit{
                    ID = "SummaryText",
                    Text = summary,
                    ReadOnly = true,
                },
                ui:Button{
                    ID = "OKButton",
                    Text = "OK",
                },
            },
        })
        
        function summaryWin.On.OKButton.Clicked(ev)
            disp:ExitLoop()
        end
        
        summaryWin:Show()
        disp:ExitLoop()
    end
    
    -- Cancel button handler
    function win.On.CancelButton.Clicked(ev)
        disp:ExitLoop()
    end
    
    win:Show()
    disp:RunLoop()
    win:Hide()
end

-- Run the script
main()