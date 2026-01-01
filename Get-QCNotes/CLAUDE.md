# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a DaVinci Resolve Lua script that automates the process of copying yellow clip markers to QC Notes metadata. The script is designed for DaVinci Resolve 20 and operates within the Resolve scripting API environment.

## Script Architecture

The main script (`Get-QCNotes_v1.00.lua`) follows this execution flow:

1. **Initialization**: Connects to DaVinci Resolve via the `Resolve()` API and validates that a project and timeline are open
2. **Timeline Processing**: Iterates through all video tracks in the current timeline
3. **Marker Detection**: For each clip, scans all markers and identifies those with "Yellow" color
4. **Metadata Update**: Formats yellow marker data as `[timecode] marker_name` and writes to the clip's "QC Notes" metadata field

Key functions:
- `formatTimecode(frames, framerate)`: Converts frame numbers to HH:MM:SS:FF format

## DaVinci Resolve API Usage

The script uses these Resolve API objects and methods:
- `Resolve()` - Entry point to the Resolve API
- `ProjectManager:GetCurrentProject()` - Access the active project
- `Project:GetCurrentTimeline()` - Get the active timeline
- `Timeline:GetSetting("timelineFrameRate")` - Retrieve timeline framerate
- `Timeline:GetTrackCount("video")` - Get number of video tracks
- `Timeline:GetItemListInTrack("video", trackIndex)` - Get clips on a track
- `Clip:GetMarkers()` - Retrieve all markers on a clip
- `MediaPoolItem:GetMetadata()` / `MediaPoolItem:SetMetadata({key = value})` - Read/write clip metadata (dictionary format)

Please refer to the DaVinciResolve_Scripting_README.txt file included in the repository for all Resolve API queries.

## Running the Script

This script must be executed from within DaVinci Resolve:
- Place the script in Resolve's script directory (typically `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/`)
- Run via Workspace menu → Scripts → Get-QCNotes

The script cannot be run standalone as it requires the Resolve scripting environment.

## Marker Color Reference

The script specifically filters for markers with `color == "Yellow"`. DaVinci Resolve supports other colors (Blue, Cyan, Green, Pink, Purple, Red, White) which can be targeted by modifying line 85.

## Output Format

QC Notes are formatted as multi-line entries:
```
[HH:MM:SS:FF] Marker Name
[HH:MM:SS:FF] Another Marker
```

Each yellow marker on a clip becomes one line in the clip's QC Notes metadata field.


