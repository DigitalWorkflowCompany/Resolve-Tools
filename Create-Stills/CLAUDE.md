# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a DaVinci Resolve Lua script that extracts still frames from timeline clips based on marker positions. The script creates a UI dialog that allows users to select markers by color (Blue for "Ref" or Yellow for "QC") and either extract them to a new timeline or add them to the render queue.

## Architecture

### Core Components

**UI System** (lines 1-35)
- Built using Fusion UI Manager (`fu.UIManager`) and BMD UI Dispatcher
- Single-window interface with marker type selection, timeline creation option, and two action buttons
- Hotkeys configured for window closing (Ctrl+W, Ctrl+F4)

**Marker Processing Pipeline**
The script follows this flow:
1. User selects marker type (Blue/Yellow) and action (Extract/Render)
2. `RunMarkers()` iterates through timeline items and collects markers matching the selected color
3. For each matched marker:
   - **Extract mode**: Creates SubClip data structure with precise frame calculations
   - **Render mode**: Creates render settings with mark in/out points
4. Results are sorted by timeline position and processed

**Media Pool Item Access**
- Uses `TimelineItem:GetMediaPoolItem()` to get source MediaPoolItem directly from timeline clips
- Falls back to recursive folder search via `findClipInMediaPool()` if direct access fails
- `searchFolderRecursive()` searches up to MAX_FOLDER_SEARCH_DEPTH levels deep

### Key Functions

**Frame/Timecode Conversion**
- `BMDLength(tlLen)`: Converts frame count to timecode string (HH:MM:SS:FF)
- `BMDTimeFrames(tm)`: Converts timecode string to frame count
- Handles negative timecode values and various input formats

**Marker Extraction** (`RunMarkers(boolRender)`)
- `boolRender=0`: Extract to timeline (creates new timeline or appends to current)
- `boolRender=1`: Add to render queue (clears existing jobs, adds sorted jobs with sequential naming)
- Calculates source media frames accounting for:
  - Timeline item start frame
  - Left offset (handle position)
  - Source start frame
  - FPS conversion between timeline and source media
  - Marker position relative to clip

**Timeline Creation**
- When "Create Separate Timeline" is checked, creates new timeline with naming pattern: `[MarkerType]-Stills_[OriginalTimelineName]`
- Sets start timecode to 01:00:00:00
- Places clips sequentially starting at hour mark
- Prints detailed ColorTrace instructions for grade transfer workflow

### Data Structures

**SubClip Dictionary** (constructed in `RunMarkers()`)
```lua
SubClip["mediaPoolItem"]           -- Source media pool item
SubClip["startFrame"]              -- Source media start frame (FPS converted)
SubClip["endFrame"]                -- Source media end frame (FPS converted)
SubClip["recordFrame"]             -- Timeline position for new clip
SubClip["originalMarkerFrame"]     -- Marker position in original clip
SubClip["calculatedSourceFrame"]   -- Calculated source frame in media
SubClip["sourceStartFrame"]        -- GetSourceStartFrame() value
SubClip["leftOffset"]              -- Handle offset
```

**renderSettings Dictionary**
```lua
renderSettings["MarkIn"]      -- Render start frame
renderSettings["MarkOut"]     -- Render end frame
renderSettings["CustomName"]  -- Sanitized filename with sequence number prefix
```

## Important Implementation Details

1. **Frame Calculation**: The script uses `GetSourceStartFrame()` and adds the marker frame position to calculate the actual source media frame, then applies FPS conversion when timeline and source FPS differ.

2. **Sorting**: Both extract and render modes sort results by timeline position before processing to maintain temporal order.

3. **Render Job Naming**: Render jobs get sequential 3-digit prefixes (001_, 002_, etc.) and all special characters are replaced with underscores.

4. **Global State**: Uses `stopFlag` global variable to control recursive search termination.

5. **Duration**: Currently hardcoded to 1 frame (`duration = 1`) for still extraction.

6. **Offset**: Currently hardcoded to 0 (`offset = 0`) for marker position adjustment.

## DaVinci Resolve API Usage

The script relies on these key Resolve API objects and methods:
- `resolve:GetProjectManager()` → `GetCurrentProject()` → `GetCurrentTimeline()`
- Timeline: `GetItemsInTrack()`, `GetMarkers()`, `GetSetting()`, `GetStartFrame()`, `GetEndFrame()`
- Timeline Item: `GetName()`, `GetStart()`, `GetLeftOffset()`, `GetSourceStartFrame()`
- MediaPool: `CreateTimelineFromClips()` (primary), `CreateEmptyTimeline()`, `AppendToTimeline()` (fallback), `GetRootFolder()`
- TimelineItem: `GetMediaPoolItem()` - gets source MediaPoolItem directly from timeline clip
- Project: `SetRenderSettings()`, `AddRenderJob()`, `DeleteAllRenderJobs()`

## Common Modifications

- **Adjusting frame offset**: Modify `offset` variable in `RunMarkers()` (line 245)
- **Changing still duration**: Modify `duration` variable in `RunMarkers()` (line 246)
- **Adding marker colors**: Update combo box population (lines 41-42) and color mapping (lines 264-268)
- **Adjusting search depth**: Modify nested loop structure in `RunClips()` (currently 5 levels deep)
