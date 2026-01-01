-- DaVinci Resolve Script: Rename Clips with Custom Format
-- Renames all clips in the currently selected bin using customizable tokens
-- Supports: {CAM}, {REEL}, {N}, {DATE}, {TIME}, {UID}
-- Version: 1.03

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

local currentFolder = mediaPool:GetCurrentFolder()
if not currentFolder then
    print("Error: No bin is currently selected")
    return
end

-- Get all clips in the current bin
local clips = currentFolder:GetClipList()
if not clips or #clips == 0 then
    print("Error: No clips found in the selected bin")
    return
end

print("Found " .. #clips .. " clip(s) in the selected bin")

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Get current date in YYMMDD format
local function getCurrentDate()
    return os.date("%y%m%d")
end

-- Get current time in HHMMSS format
local function getCurrentTime()
    return os.date("%H%M%S")
end

-- Generate a unique identifier (ARRI-style hash)
-- Format: single lowercase letter + digit + 3 uppercase letters (e.g., h1CEI)
local function generateUID(seed)
    math.randomseed(seed or os.time())
    local firstLetter = string.char(97 + math.random(0, 25))  -- a-z
    local digit = tostring(math.random(0, 9))
    local letters = ""
    for i = 1, 3 do
        letters = letters .. string.char(65 + math.random(0, 25))  -- A-Z
    end
    return firstLetter .. digit .. letters
end

-- Zero-pad a number to specified width
local function zeroPad(num, width)
    return string.format("%0" .. width .. "d", num)
end

-- Camera letters lookup (A-Z)
local cameraLetters = {
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
    "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"
}

-- Apply naming pattern to generate clip name
local function applyPattern(pattern, values)
    local result = pattern

    -- Replace tokens with values
    result = result:gsub("{(%w+):?(%d*)}", function(name, width)
        local value = values[name:upper()]
        if value then
            if width and width ~= "" then
                if type(value) == "number" then
                    return zeroPad(value, tonumber(width))
                else
                    return value
                end
            else
                if type(value) == "number" then
                    return tostring(value)
                else
                    return value
                end
            end
        end
        return "{" .. name .. "}"  -- Return unchanged if not found
    end)

    return result
end

-- ============================================================================
-- UI SETUP
-- ============================================================================
-- Note: Using fu.UIManager for consistency with other Resolve scripts
local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)

local win = disp:AddWindow({
    ID = "RenameWindow",
    WindowTitle = "Rename Clips v1.03",
    Geometry = {100, 100, 520, 370},

    ui:VGroup{
        ID = "root",
        Spacing = 8,

        ui:Label{
            ID = "InfoLabel",
            Text = "Enter naming pattern using tokens:",
            Weight = 0,
        },

        ui:LineEdit{
            ID = "PatternInput",
            Text = "{CAM}_{REEL:4}C{N:3}_{DATE}_{TIME}_{UID}",
            PlaceholderText = "{CAM}_{REEL:4}C{N:3}_{DATE}_{TIME}_{UID}",
        },

        ui:Label{
            ID = "TokensLabel",
            Text = "Available tokens:",
            Weight = 0,
            StyleSheet = "font-weight: bold; margin-top: 5px;",
        },

        ui:Label{
            ID = "HelpLabel",
            Text = "{CAM}      = Camera letter (A, B, C...)\n{REEL:4}  = Reel number (0001, 0002...)\n{N:3}       = Clip counter (001, 002, 003...)\n{DATE}    = Today's date (YYMMDD)\n{TIME}    = Current time (HHMMSS)\n{UID}      = Unique ID (e.g., h1CEI)\n\nAdd :N for zero-padding (e.g., {REEL:4} = 0001)",
            Weight = 0,
            StyleSheet = "font-size: 11px; color: #aaa;",
        },

        ui:HGroup{
            Weight = 0,
            ui:Label{ Text = "Camera:", Weight = 0 },
            ui:ComboBox{
                ID = "CameraSelect",
                Weight = 0.3,
            },
            ui:Label{ Text = "Reel:", Weight = 0 },
            ui:SpinBox{
                ID = "ReelNumber",
                Value = 1,
                Minimum = 1,
                Maximum = 9999,
            },
            ui:Label{ Text = "Start #:", Weight = 0 },
            ui:SpinBox{
                ID = "StartCounter",
                Value = 1,
                Minimum = 1,
                Maximum = 9999,
            },
        },

        ui:HGroup{
            Weight = 0,
            ui:Label{ Text = "UID:", Weight = 0 },
            ui:LineEdit{
                ID = "UIDInput",
                PlaceholderText = "Leave blank for auto-generate",
                Weight = 1,
            },
        },

        ui:Label{
            ID = "PreviewLabel",
            Text = "Preview: A_0001C001_" .. getCurrentDate() .. "_" .. getCurrentTime() .. "_x0XXX",
            Weight = 0,
            StyleSheet = "font-style: italic; color: #8af;",
        },

        ui:HGroup{
            Weight = 0,
            ui:Button{
                ID = "OkButton",
                Text = "Rename",
            },
            ui:Button{
                ID = "CancelButton",
                Text = "Cancel",
            },
        },
    },
})

local itm = win:GetItems()

-- Populate camera dropdown
for i, letter in ipairs(cameraLetters) do
    itm.CameraSelect:AddItem(letter)
end
itm.CameraSelect.CurrentIndex = 0  -- Default to 'A'

-- Update preview when inputs change
local function updatePreview()
    local pattern = itm.PatternInput.Text
    local camIndex = itm.CameraSelect.CurrentIndex
    local camLetter = cameraLetters[camIndex + 1] or "A"
    local reelNum = itm.ReelNumber.Value
    local startNum = itm.StartCounter.Value
    local customUID = itm.UIDInput.Text

    -- Use custom UID if provided, otherwise generate one
    local uid = (customUID ~= "") and customUID or generateUID(os.time())

    local values = {
        CAM = camLetter,
        CAMERA = camLetter,
        N = startNum,
        REEL = reelNum,
        CLIP = startNum,
        DATE = getCurrentDate(),
        TIME = getCurrentTime(),
        UID = uid
    }

    local preview = applyPattern(pattern, values)
    itm.PreviewLabel.Text = "Preview: " .. preview
end

-- Connect change events
function win.On.PatternInput.TextChanged(ev)
    updatePreview()
end

function win.On.CameraSelect.CurrentIndexChanged(ev)
    updatePreview()
end

function win.On.ReelNumber.ValueChanged(ev)
    updatePreview()
end

function win.On.StartCounter.ValueChanged(ev)
    updatePreview()
end

function win.On.UIDInput.TextChanged(ev)
    updatePreview()
end

-- Button handlers
function win.On.OkButton.Clicked(ev)
    local pattern = itm.PatternInput.Text
    local camIndex = itm.CameraSelect.CurrentIndex
    local camLetter = cameraLetters[camIndex + 1] or "A"
    local reelNum = itm.ReelNumber.Value
    local startNum = itm.StartCounter.Value
    local customUID = itm.UIDInput.Text

    if pattern == "" then
        print("Error: Please enter a naming pattern")
        return
    end

    -- Capture time and UID at start of operation for consistency
    -- ARRI cameras use the same UID for all clips on a roll
    local operationTime = getCurrentTime()
    local rollUID = (customUID ~= "") and customUID or generateUID(os.time())

    -- Rename all clips
    local successCount = 0
    for i, clip in ipairs(clips) do
        -- Build values for this clip
        local clipNum = startNum + (i - 1)
        local values = {
            CAM = camLetter,
            CAMERA = camLetter,
            N = clipNum,
            REEL = reelNum,
            CLIP = clipNum,
            DATE = getCurrentDate(),
            TIME = operationTime,
            UID = rollUID  -- Same UID for all clips on the roll
        }

        -- Generate new name from pattern
        local newName = applyPattern(pattern, values)

        -- Rename the clip using SetName (more reliable than SetClipProperty)
        clip:SetName(newName)

        -- Verify the rename by checking the actual name
        local actualName = clip:GetName()
        if actualName == newName then
            print("Renamed clip " .. i .. " to: " .. newName)
            successCount = successCount + 1
        else
            print("Warning: Failed to rename clip " .. i .. " (expected: " .. newName .. ", got: " .. tostring(actualName) .. ")")
        end
    end

    print("\nRename complete: " .. successCount .. " of " .. #clips .. " clips renamed successfully")
    disp:ExitLoop()
end

function win.On.CancelButton.Clicked(ev)
    print("Rename operation cancelled")
    disp:ExitLoop()
end

function win.On.RenameWindow.Close(ev)
    disp:ExitLoop()
end

win:Show()
disp:RunLoop()
win:Hide()