# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains Lua scripts for DaVinci Resolve automation. The scripts interact with Resolve's API to perform color grading and media management tasks.

## Scripts

### Create-Dailies_v1.00.lua
Combined dailies creation script that imports multiple camera rolls, creates timelines, applies DRX grades, applies CDL values, and syncs audio.

**Key functionality:**
- Imports multiple camera rolls with per-roll DRX grade application
- Creates organized bin structure: OCF/{Camera}-Cam/{RollName}
- Creates timelines in a "Timelines" bin using `CreateTimelineFromClips()` for reliability
- Applies DRX grade files to timeline clips
- Parses and applies CDL values from CCC or EDL files
- Searches for and applies LUTs referenced in CCC files
- Audio sync: Imports audio files and syncs to video using timecode matching via `mediaPool:AutoSyncAudio()`
- Supports batch processing of multiple camera rolls with auto-detection

**Running the script:**
- Run from DaVinci Resolve's Workspace > Scripts menu
- GUI allows adding individual camera rolls or auto-detecting rolls in a parent folder
- Optional CDL file applies to all camera rolls
- Optional audio directory for timecode-based audio sync

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
  - `[resolve.AUDIO_SYNC_RETAIN_EMBEDDED_AUDIO] = false`

## Development Notes

**Pattern matching for CCC files:**
- The CCC parser handles multiline ColorCorrection tags by searching for start/end tags rather than single-line patterns
- ID attributes are extracted from anywhere in the ColorCorrection block to handle formatting variations
- Whitespace is trimmed from all extracted values

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
