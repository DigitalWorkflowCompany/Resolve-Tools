# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains Lua scripts for DaVinci Resolve automation. The scripts interact with Resolve's API to perform color grading and media management tasks.

## Scripts

### Create-Dailies_v2.00.lua (Current)
Enhanced dailies creation script with tabbed interface supporting three workflows:

**Tab 1: Camera Roll Import** (Original v1.00 functionality)
- Imports multiple camera rolls with per-roll DRX grade application
- Creates organized bin structure: OCF/{Camera}-Cam/{RollName}
- Creates timelines in a "Timelines" bin using `CreateTimelineFromClips()` for reliability
- Applies DRX grade files to timeline clips
- Parses and applies CDL values from CCC or EDL files
- Extracts and applies metadata from CCC files (Episode, Scene, Shot, Take, Camera) to Resolve metadata columns
- Searches for and applies LUTs referenced in CCC files
- Audio sync: Imports audio files and syncs to video using timecode matching

**Tab 2: OCF Master Timeline** (New in v2.00)
- Collects all clips from OCF/*/\* bins
- Sorts clips by Camera → Roll → Start Timecode for consistent ordering
- Creates a single master timeline with all OCF clips
- Exports ALE with CDL values to user-selected location
- User prompted for timeline name and ALE filename

**Tab 3: Audio Dailies** (New in v2.00)
- Imports audio files from user-selected directory into new bin
- Creates timeline sorted by start timecode
- Exports ALE to user-selected location
- User prompted for bin name, timeline name, and ALE filename

**Key v2.00 additions:**
- `collectAllOCFClips()` - Recursively collects clips from all OCF sub-bins
- `sortClipsByCameraRollTimecode()` - Sorts clips by Camera → Roll → Start TC
- `createOCFMasterTimeline()` - Creates master timeline from sorted OCF clips
- `exportALEWithCDL()` - Exports timeline as ALE with CDL using `resolve.EXPORT_ALE_CDL`
- `createAudioDailies()` - Complete audio import → timeline → ALE workflow
- `timecodeToFrames()` - Converts timecode strings to frame counts for sorting
- `applyMetadata()` - Applies Episode, Scene, Shot, Take, Camera metadata from CCC to MediaPoolItem

**Running the script:**
- Run from DaVinci Resolve's Workspace > Scripts menu
- Select appropriate tab for desired workflow
- All ALE exports prompt for save location

### Create-Dailies_v1.00.lua (Legacy)
Original version - still functional but superseded by v2.00.

## DaVinci Resolve API Usage Patterns
- Please refer to the DaVinciResolve_Scripting_README.txt file included in the repository for all Resolve API queries.

**Core API objects:**
```lua
local resolve = Resolve()
local projectManager = resolve:GetProjectManager()
local project = projectManager:GetCurrentProject()
local mediaPool = project:GetMediaPool()
local mediaStorage = resolve:GetMediaStorage()
local timeline = project:GetCurrentTimeline()
```

**Fusion UI setup:**
```lua
local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)
```

**Common operations:**
- Switch pages: `resolve:OpenPage("color")` or `resolve:OpenPage("edit")`
- Get timeline items: `timeline:GetItemListInTrack("video", trackIndex)`
- Apply CDL: `clip:SetCDL({NodeIndex = "1", Slope = "...", Offset = "...", Power = "...", Saturation = "..."})`
- Apply DRX: `timelineItem:GetNodeGraph():ApplyGradeFromDRX(filepath, gradeMode)` where gradeMode: 0 = No keyframes, 1 = Source Timecode aligned, 2 = Start Frames aligned
- Create timeline with clips: `mediaPool:CreateTimelineFromClips(timelineName, clipsArray)` - more reliable than CreateEmptyTimeline + AppendToTimeline
- Audio sync: `mediaPool:AutoSyncAudio(clipsToSync, syncSettings)` where syncSettings includes:
  - `[resolve.AUDIO_SYNC_MODE] = resolve.AUDIO_SYNC_TIMECODE`
  - `[resolve.AUDIO_SYNC_RETAIN_VIDEO_METADATA] = true`
  - `[resolve.AUDIO_SYNC_RETAIN_EMBEDDED_AUDIO] = false` (creates synced clips WITHOUT embedded audio; does NOT modify source clips)
- Check for embedded audio: `mediaPoolItem:GetAudioMapping()` returns JSON with `embedded_audio_channels` field
- Export ALE with CDL: `timeline:Export(filePath, resolve.EXPORT_ALE_CDL, resolve.EXPORT_NONE)`
- Get clip metadata: `clip:GetClipProperty("Start TC")`, `clip:GetClipProperty("FPS")`
- Set clip metadata: `mediaPoolItem:SetMetadata("Episode #", value)` - field names must match Resolve UI labels exactly (e.g., "Episode #", "Scene", "Shot", "Take", "Camera #")
- Get MediaPoolItem from timeline clip: `timelineItem:GetMediaPoolItem()`

## Development Notes

**Pattern matching for CCC files:**
- The CCC parser handles multiline ColorCorrection tags by searching for start/end tags rather than single-line patterns
- ID attributes are extracted from anywhere in the ColorCorrection block to handle formatting variations
- Whitespace is trimmed from all extracted values
- Metadata elements parsed: `<Episode>`, `<Scene>`, `<Shot>`, `<Take>`, `<Camera>`
- Metadata is applied to MediaPoolItem using `SetMetadata()` with Resolve UI field names: "Episode #", "Scene", "Shot", "Take", "Camera #"

**Clip name matching strategy (CCC-Import):**
1. Exact match by name
2. Match without file extension
3. Fuzzy substring matching (bidirectional)

**File path handling (Import-Shots):**
- The script normalizes paths and removes trailing slashes
- Handles both absolute paths and relative filenames from Resolve API
- Uses recursive directory scanning with `GetSubFolderList()` and `GetFileList()`

**Error handling:**
- Both scripts include verbose console logging for debugging
- Import-Shots attempts batch import first, falls back to individual file imports on failure
- Validation checks for required fields (bin names, timeline names, DRX paths) before operations
