-- DaVinci Resolve Bin Creator Script with Presets and Expandable Sub-bins
-- Creates multiple user-defined bins in the Media Pool with preset functionality and sub-bin support
-- Version: 1.01

local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)

-- ============================================================================
-- CONSTANTS
-- ============================================================================
local MAX_BINS = 20
local MAX_SUBBINS_PER_BIN = 5
local BASE_WINDOW_HEIGHT = 280
local BIN_ROW_HEIGHT = 30
local SUBBIN_ROW_HEIGHT = 25
local SUBBIN_INDENT = 45

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

-- Module-level state variables
local presets = {}
local expandedBins = {}

-- Get script directory for storing presets
local presetFile = os.getenv("APPDATA") and 
    os.getenv("APPDATA") .. "\\Blackmagic Design\\DaVinci Resolve\\bin_creator_presets.txt" or
    os.getenv("HOME") .. "/.davinci_bin_creator_presets.txt"

-- Default presets with sub-bin structure
local defaultPresets = {
    ["Basic"] = {
        bins = {"OCF", "Sound", "Timelines"},
        subbins = {
            ["Sound"] = {"Location-Sound", "Temp-Mix", "Final-Mix"}
        }
    },
    ["Dailies"] = {
        bins = {"OCF", "Sound", "Reference", "Timelines"},
        subbins = {
            ["Sound"] = {"Location-Sound", "Temp-Mix", "Final-Mix"}
        }
    },
    ["Scan"] = {
        bins = {"Scans", "Timelines"},
        subbins = {}
    },
    ["Post"] = {
        bins = {"OCF", "Sound", "Online", "VFX", "QC", "Deliverables"},
        subbins = {
            ["Online"] = {"Data", "Graphics", "Titles", "Credits", "OfflineRef"},
            ["Sound"] = {"Location-Sound", "Temp-Mix", "Final-Mix"},
            ["VFX"] = {"Temp-VFX", "Final-VFX"}
        }
    }
}

-- Preset management functions
function savePresets()
    local file = io.open(presetFile, "w")
    if file then
        for name, preset in pairs(presets) do
            -- Save bins
            file:write(name .. ":")
            for i, bin in ipairs(preset.bins) do
                file:write(bin)
                if i < #preset.bins then file:write(",") end
            end
            file:write("|")
            
            -- Save subbins
            local subBinPairs = {}
            for parentBin, subBins in pairs(preset.subbins) do
                local subBinStr = parentBin .. ">" .. table.concat(subBins, ";")
                table.insert(subBinPairs, subBinStr)
            end
            file:write(table.concat(subBinPairs, "&"))
            file:write("\n")
        end
        file:close()
        return true
    end
    return false
end

function loadPresets()
    presets = {}
    
    -- Load default presets first
    for name, preset in pairs(defaultPresets) do
        presets[name] = preset
    end
    
    -- Try to load saved presets (only custom ones, not old defaults)
    local file = io.open(presetFile, "r")
    if file then
        for line in file:lines() do
            local name, data = line:match("^([^:]+):(.+)$")
            if name and data then
                -- Skip old default presets that are no longer wanted
                if not (name == "Commercial" or name == "Corporate" or name == "Documentary" or name == "Event" or name == "Music Video") then
                    local binData, subBinData = data:match("^([^|]+)|?(.*)$")
                    
                    local bins = {}
                    if binData then
                        for bin in binData:gmatch("[^,]+") do
                            table.insert(bins, bin:match("^%s*(.-)%s*$"))
                        end
                    end
                    
                    local subbins = {}
                    if subBinData and subBinData ~= "" then
                        for subBinPair in subBinData:gmatch("[^&]+") do
                            local parentBin, subBinList = subBinPair:match("^([^>]+)>(.+)$")
                            if parentBin and subBinList then
                                subbins[parentBin] = {}
                                for subBin in subBinList:gmatch("[^;]+") do
                                    table.insert(subbins[parentBin], subBin:match("^%s*(.-)%s*$"))
                                end
                            end
                        end
                    end
                    
                    presets[name] = {bins = bins, subbins = subbins}
                end
            end
        end
        file:close()
    end
    
    updatePresetDropdown()
end

function updatePresetDropdown()
    local presetCombo = dlg:Find("PresetCombo")
    if presetCombo then
        presetCombo:Clear()
        presetCombo:AddItem("-- Select Preset --")
        
        local sortedNames = {}
        for name in pairs(presets) do
            table.insert(sortedNames, name)
        end
        table.sort(sortedNames)
        
        for _, name in ipairs(sortedNames) do
            presetCombo:AddItem(name)
        end
    end
end

function saveCurrentAsPreset()
    local numBins = tonumber(dlg:Find("NumBinsSpinBox").Value)
    local presetNameDialog = disp:AddWindow({
        ID = "PresetNameDialog",
        WindowTitle = "Save Preset",
        Geometry = {200, 200, 300, 120},
        Spacing = 10,
        Margin = 15,
        
        ui:VGroup{
            ui:Label{Text = "Enter preset name:"},
            ui:LineEdit{
                ID = "PresetNameEdit",
                PlaceholderText = "My Custom Preset"
            },
            ui:HGroup{
                ui:HGap(0, 1),
                ui:Button{ID = "SavePresetOK", Text = "Save"},
                ui:Button{ID = "SavePresetCancel", Text = "Cancel"}
            }
        }
    })
    
    function presetNameDialog.On.SavePresetOK.Clicked(ev)
        local presetName = presetNameDialog:Find("PresetNameEdit").Text
        if presetName and presetName:match("%S") then
            local bins = {}
            for i = 1, numBins do
                local binNameField = dlg:Find("BinName" .. i)
                if binNameField and binNameField.Text:match("%S") then
                    table.insert(bins, binNameField.Text)
                end
            end
            
            if #bins > 0 then
                presets[presetName] = {bins = bins, subbins = {}}
                savePresets()
                updatePresetDropdown()
                dlg:Find("StatusLabel").Text = "Preset '" .. presetName .. "' saved successfully!"
                print("Preset saved: " .. presetName)
            end
        end
        presetNameDialog:Hide()
    end
    
    function presetNameDialog.On.SavePresetCancel.Clicked(ev)
        presetNameDialog:Hide()
    end
    
    presetNameDialog:Show()
end

function loadPreset(presetName)
    if presets[presetName] then
        local preset = presets[presetName]
        local bins = preset.bins
        
        -- Update number of bins
        dlg:Find("NumBinsSpinBox").Value = #bins
        updateBinFields(#bins)
        
        -- Fill in bin names
        for i, binName in ipairs(bins) do
            local binField = dlg:Find("BinName" .. i)
            if binField then
                binField.Text = binName
            end
        end
        
        dlg:Find("StatusLabel").Text = "Loaded preset: " .. presetName
    end
end

function deletePreset()
    local presetCombo = dlg:Find("PresetCombo")
    local selectedIndex = presetCombo.CurrentIndex
    
    if selectedIndex > 0 then -- Skip "-- Select Preset --"
        local presetName = presetCombo.CurrentText
        
        -- Don't allow deletion of default presets
        if defaultPresets[presetName] then
            dlg:Find("StatusLabel").Text = "Cannot delete default preset: " .. presetName
            return
        end
        
        local confirmDialog = disp:AddWindow({
            ID = "ConfirmDeleteDialog",
            WindowTitle = "Delete Preset",
            Geometry = {200, 200, 300, 100},
            Spacing = 10,
            Margin = 15,
            
            ui:VGroup{
                ui:Label{Text = "Delete preset '" .. presetName .. "'?"},
                ui:HGroup{
                    ui:HGap(0, 1),
                    ui:Button{ID = "DeleteOK", Text = "Delete"},
                    ui:Button{ID = "DeleteCancel", Text = "Cancel"}
                }
            }
        })
        
        function confirmDialog.On.DeleteOK.Clicked(ev)
            presets[presetName] = nil
            savePresets()
            updatePresetDropdown()
            dlg:Find("StatusLabel").Text = "Deleted preset: " .. presetName
            confirmDialog:Hide()
        end
        
        function confirmDialog.On.DeleteCancel.Clicked(ev)
            confirmDialog:Hide()
        end
        
        confirmDialog:Show()
    end
end

--- Toggle sub-bin visibility for a specific bin
-- @param binIndex number The index of the bin to toggle
function toggleSubBins(binIndex)
    expandedBins[binIndex] = not expandedBins[binIndex]

    -- Update the expand button text
    local expandButton = dlg:Find("ExpandButton" .. binIndex)
    if expandButton then
        expandButton.Text = expandedBins[binIndex] and "−" or "+"
    end

    -- Show/hide sub-bin rows
    for j = 1, MAX_SUBBINS_PER_BIN do
        local subBinRow = dlg:Find("SubBinRow" .. binIndex .. "_" .. j)
        if subBinRow then
            subBinRow.Hidden = not expandedBins[binIndex]
        end
    end
    
    -- Recalculate window size
    updateWindowSize()
end

--- Update bin fields visibility based on number of bins
-- @param numBins number The number of bins to show
function updateBinFields(numBins)
    -- Hide all existing fields first
    for i = 1, MAX_BINS do
        local binRow = dlg:Find("BinRow" .. i)
        if binRow then
            binRow.Hidden = true
        end

        -- Also hide all sub-bin rows
        for j = 1, MAX_SUBBINS_PER_BIN do
            local subBinRow = dlg:Find("SubBinRow" .. i .. "_" .. j)
            if subBinRow then
                subBinRow.Hidden = true
            end
        end
    end
    
    -- Show and update the required number of fields
    for i = 1, numBins do
        local binRow = dlg:Find("BinRow" .. i)
        if binRow then
            binRow.Hidden = false
            local binField = dlg:Find("BinName" .. i)
            if binField and binField.Text == "" then
                binField.Text = "Bin " .. i
            end
            
            -- Reset expand button
            local expandButton = dlg:Find("ExpandButton" .. i)
            if expandButton then
                expandButton.Text = "+"
            end
            expandedBins[i] = false
        end
    end
    
    updateWindowSize()
end

--- Calculate and update window size based on visible elements
-- Adjusts window geometry based on number of bins and expanded sub-bins
function updateWindowSize()
    local numBins = tonumber(dlg:Find("NumBinsSpinBox").Value)

    -- Count expanded sub-bins
    local totalSubBinRows = 0
    for i = 1, numBins do
        if expandedBins[i] then
            -- Count how many sub-bins are visible for this bin
            for j = 1, MAX_SUBBINS_PER_BIN do
                local subBinRow = dlg:Find("SubBinRow" .. i .. "_" .. j)
                if subBinRow and not subBinRow.Hidden then
                    totalSubBinRows = totalSubBinRows + 1
                end
            end
        end
    end

    local newHeight = BASE_WINDOW_HEIGHT + (numBins * BIN_ROW_HEIGHT) + (totalSubBinRows * SUBBIN_ROW_HEIGHT)

    local currentGeometry = dlg.Geometry
    dlg.Geometry = {currentGeometry[1], currentGeometry[2], currentGeometry[3], newHeight}
end

--- Create bins and sub-bins in the Media Pool
-- Creates main bins from UI fields and sub-bins from both UI and preset definitions
function createBins()
    local numBins = tonumber(dlg:Find("NumBinsSpinBox").Value)
    local rootFolder = mediaPool:GetRootFolder()
    if not rootFolder then
        dlg:Find("StatusLabel").Text = "Error: Could not access Media Pool root folder"
        print("Error: Could not access Media Pool root folder")
        return
    end

    local createdBins = {}
    local createdSubBins = {}

    -- Get current preset to check for predefined sub-bins
    local presetCombo = dlg:Find("PresetCombo")
    local currentPreset = nil
    if presetCombo.CurrentIndex > 0 then
        currentPreset = presets[presetCombo.CurrentText]
    end

    -- Create main bins
    local binFolders = {}
    for i = 1, numBins do
        local binNameField = dlg:Find("BinName" .. i)
        if binNameField then
            local binName = binNameField.Text
            if binName and binName:match("%S") then -- Check if name is not empty or whitespace
                local newBin = mediaPool:AddSubFolder(rootFolder, binName)
                if newBin then
                    table.insert(createdBins, binName)
                    binFolders[binName] = newBin

                    -- Create user-defined sub-bins for this bin
                    for j = 1, MAX_SUBBINS_PER_BIN do
                        local subBinField = dlg:Find("SubBinName" .. i .. "_" .. j)
                        if subBinField and subBinField.Text:match("%S") then
                            local subBin = mediaPool:AddSubFolder(newBin, subBinField.Text)
                            if subBin then
                                table.insert(createdSubBins, binName .. "/" .. subBinField.Text)
                            else
                                print("Warning: Could not create sub-bin '" .. subBinField.Text .. "' in '" .. binName .. "'")
                            end
                        end
                    end
                else
                    print("Warning: Could not create bin '" .. binName .. "'")
                end
            end
        end
    end
    
    -- Create preset-defined sub-bins if using a preset
    if currentPreset and currentPreset.subbins then
        for parentBinName, subBinList in pairs(currentPreset.subbins) do
            local parentFolder = binFolders[parentBinName]
            if parentFolder then
                for _, subBinName in ipairs(subBinList) do
                    -- Check if this sub-bin wasn't already created by user input
                    local alreadyExists = false
                    for _, createdSubBin in ipairs(createdSubBins) do
                        if createdSubBin == parentBinName .. "/" .. subBinName then
                            alreadyExists = true
                            break
                        end
                    end
                    
                    if not alreadyExists then
                        local subBin = mediaPool:AddSubFolder(parentFolder, subBinName)
                        if subBin then
                            table.insert(createdSubBins, parentBinName .. "/" .. subBinName)
                        else
                            print("Warning: Could not create preset sub-bin '" .. subBinName .. "' in '" .. parentBinName .. "'")
                        end
                    end
                end
            end
        end
    end
    
    -- Show success message
    local totalCreated = #createdBins + #createdSubBins
    if totalCreated > 0 then
        local message = "Successfully created " .. #createdBins .. " bin(s)"
        if #createdSubBins > 0 then
            message = message .. " and " .. #createdSubBins .. " sub-bin(s)"
        end
        dlg:Find("StatusLabel").Text = message .. "!"
        print(message .. ":\nBins: " .. table.concat(createdBins, ", "))
        if #createdSubBins > 0 then
            print("Sub-bins: " .. table.concat(createdSubBins, ", "))
        end
    else
        dlg:Find("StatusLabel").Text = "No bins were created. Check bin names."
        print("No bins were created.")
    end
end

--- Create bin input rows and sub-bin rows (hidden by default)
-- @return table binRows Array of bin row UI elements
-- @return table subBinRows Array of sub-bin row UI elements
function createBinRows()
    local binRows = {}
    local subBinRows = {}

    -- Create main bin rows
    for i = 1, MAX_BINS do
        binRows[i] = ui:HGroup{
            ID = "BinRow" .. i,
            Hidden = true,
            ui:Label{
                Text = string.format("%2d:", i),
                Weight = 0,
                MinimumSize = {25, 25}
            },
            ui:LineEdit{
                ID = "BinName" .. i,
                Text = "Bin " .. i,
                PlaceholderText = "Enter bin name...",
                Weight = 1
            },
            ui:Button{
                ID = "ExpandButton" .. i,
                Text = "+",
                MinimumSize = {20, 25},
                MaximumSize = {20, 25}
            }
        }

        -- Create sub-bin rows for this main bin
        for j = 1, MAX_SUBBINS_PER_BIN do
            local subBinIndex = (i - 1) * MAX_SUBBINS_PER_BIN + j
            subBinRows[subBinIndex] = ui:HGroup{
                ID = "SubBinRow" .. i .. "_" .. j,
                Hidden = true,
                ui:HGap(SUBBIN_INDENT), -- Indent to show hierarchy
                ui:Label{
                    Text = "└─",
                    Weight = 0,
                    MinimumSize = {20, 25}
                },
                ui:LineEdit{
                    ID = "SubBinName" .. i .. "_" .. j,
                    PlaceholderText = "Sub-bin name...",
                    Weight = 1
                },
                ui:Button{
                    ID = "RemoveSubButton" .. i .. "_" .. j,
                    Text = "×",
                    MinimumSize = {20, 25},
                    MaximumSize = {20, 25}
                }
            }
        end
    end
    
    return binRows, subBinRows
end

-- Create the main UI
local binRows, subBinRows = createBinRows()

dlg = disp:AddWindow({
    ID = "BinCreatorWindow",
    WindowTitle = "Create Bins v1.01",
    Geometry = {100, 100, 420, 370},
    Spacing = 8,
    Margin = 12,
    
    ui:VGroup{
        ID = "MainGroup",
        
        -- Header
        ui:Label{
            ID = "HeaderLabel",
            Text = "Create Multiple Bins in the Media Pool",
            Weight = 0,
            Font = ui:Font{PixelSize = 14, Weight = 75},
            Alignment = {AlignHCenter = true}
        },
        
        ui:VGap(8),
        
        -- Preset section
        ui:VGroup{
            ui:Label{
                Text = "Presets:",
                Font = ui:Font{PixelSize = 11, Weight = 75}
            },
            ui:HGroup{
                ui:ComboBox{
                    ID = "PresetCombo",
                    Weight = 1
                },
                ui:Button{
                    ID = "LoadPresetButton",
                    Text = "Load",
                    MinimumSize = {50, 22}
                },
                ui:Button{
                    ID = "SavePresetButton",
                    Text = "Save",
                    MinimumSize = {50, 22}
                },
                ui:Button{
                    ID = "DeletePresetButton",
                    Text = "Delete",
                    MinimumSize = {50, 22}
                }
            }
        },
        
        ui:VGap(8),
        
        -- Number of bins selector - more compact
        ui:HGroup{
            Spacing = 5,
            ui:Label{
                ID = "NumBinsLabel",
                Text = "Number of bins:",
                Weight = 0,
                MinimumSize = {90, 25},
                Alignment = {AlignVCenter = true, AlignRight = true}
            },
            ui:SpinBox{
                ID = "NumBinsSpinBox",
                Value = 3,
                Minimum = 1,
                Maximum = 20,
                SingleStep = 1,
                Weight = 0,
                MinimumSize = {45, 25},
                MaximumSize = {45, 25},
                Alignment = {AlignVCenter = true}
            },
            ui:HGap(0, 1) -- Spacer
        },
        
        ui:VGap(8),
        
        -- Bin name fields with sub-bins
        ui:VGroup{
            ID = "BinListGroup",
            Weight = 1,
            Spacing = 2,
            
            -- Add all bin rows and sub-bin rows in sequence
            binRows[1], subBinRows[1], subBinRows[2], subBinRows[3], subBinRows[4], subBinRows[5],
            binRows[2], subBinRows[6], subBinRows[7], subBinRows[8], subBinRows[9], subBinRows[10],
            binRows[3], subBinRows[11], subBinRows[12], subBinRows[13], subBinRows[14], subBinRows[15],
            binRows[4], subBinRows[16], subBinRows[17], subBinRows[18], subBinRows[19], subBinRows[20],
            binRows[5], subBinRows[21], subBinRows[22], subBinRows[23], subBinRows[24], subBinRows[25],
            binRows[6], subBinRows[26], subBinRows[27], subBinRows[28], subBinRows[29], subBinRows[30],
            binRows[7], subBinRows[31], subBinRows[32], subBinRows[33], subBinRows[34], subBinRows[35],
            binRows[8], subBinRows[36], subBinRows[37], subBinRows[38], subBinRows[39], subBinRows[40],
            binRows[9], subBinRows[41], subBinRows[42], subBinRows[43], subBinRows[44], subBinRows[45],
            binRows[10], subBinRows[46], subBinRows[47], subBinRows[48], subBinRows[49], subBinRows[50],
            binRows[11], subBinRows[51], subBinRows[52], subBinRows[53], subBinRows[54], subBinRows[55],
            binRows[12], subBinRows[56], subBinRows[57], subBinRows[58], subBinRows[59], subBinRows[60],
            binRows[13], subBinRows[61], subBinRows[62], subBinRows[63], subBinRows[64], subBinRows[65],
            binRows[14], subBinRows[66], subBinRows[67], subBinRows[68], subBinRows[69], subBinRows[70],
            binRows[15], subBinRows[71], subBinRows[72], subBinRows[73], subBinRows[74], subBinRows[75],
            binRows[16], subBinRows[76], subBinRows[77], subBinRows[78], subBinRows[79], subBinRows[80],
            binRows[17], subBinRows[81], subBinRows[82], subBinRows[83], subBinRows[84], subBinRows[85],
            binRows[18], subBinRows[86], subBinRows[87], subBinRows[88], subBinRows[89], subBinRows[90],
            binRows[19], subBinRows[91], subBinRows[92], subBinRows[93], subBinRows[94], subBinRows[95],
            binRows[20], subBinRows[96], subBinRows[97], subBinRows[98], subBinRows[99], subBinRows[100]
        },
        
        ui:VGap(8),
        
        -- Status label
        ui:Label{
            ID = "StatusLabel",
            Text = "",
            Weight = 0,
            StyleSheet = "QLabel { color: #4CAF50; font-weight: bold; font-size: 10px; }",
            Alignment = {AlignHCenter = true}
        },
        
        -- Buttons
        ui:HGroup{
            ui:HGap(0, 1), -- Spacer
            ui:Button{
                ID = "CreateBinsButton",
                Text = "Create Bins",
                MinimumSize = {90, 30}
            },
            ui:Button{
                ID = "CloseButton",
                Text = "Close",
                MinimumSize = {60, 30}
            }
        }
    }
})

-- Event handlers
function dlg.On.NumBinsSpinBox.ValueChanged(ev)
    updateBinFields(ev.Value)
end

function dlg.On.CreateBinsButton.Clicked(ev)
    createBins()
end

function dlg.On.LoadPresetButton.Clicked(ev)
    local presetCombo = dlg:Find("PresetCombo")
    local selectedIndex = presetCombo.CurrentIndex
    if selectedIndex > 0 then -- Skip "-- Select Preset --"
        loadPreset(presetCombo.CurrentText)
    end
end

function dlg.On.SavePresetButton.Clicked(ev)
    saveCurrentAsPreset()
end

function dlg.On.DeletePresetButton.Clicked(ev)
    deletePreset()
end

function dlg.On.PresetCombo.CurrentTextChanged(ev)
    if ev.Text and ev.Text ~= "-- Select Preset --" then
        loadPreset(ev.Text)
    end
end

function dlg.On.CloseButton.Clicked(ev)
    disp:ExitLoop()
end

function dlg.On.BinCreatorWindow.Close(ev)
    disp:ExitLoop()
end

-- Add event handlers for expand buttons and remove sub-bin buttons
for i = 1, MAX_BINS do
    -- Expand button handlers
    local expandButtonHandler = function(ev)
        toggleSubBins(i)
    end
    dlg.On["ExpandButton" .. i] = {Clicked = expandButtonHandler}

    -- Remove sub-bin button handlers
    for j = 1, MAX_SUBBINS_PER_BIN do
        local removeButtonHandler = function(ev)
            local subBinField = dlg:Find("SubBinName" .. i .. "_" .. j)
            local subBinRow = dlg:Find("SubBinRow" .. i .. "_" .. j)
            if subBinField then
                subBinField.Text = ""
            end
            if subBinRow then
                subBinRow.Hidden = true
            end
            updateWindowSize()
        end
        dlg.On["RemoveSubButton" .. i .. "_" .. j] = {Clicked = removeButtonHandler}
    end
end

-- Initialize
loadPresets()
updateBinFields(3)

-- Show the dialog
dlg:Show()
disp:RunLoop()
dlg:Hide()

print("Bin Creator script with presets and expandable sub-bins completed.")