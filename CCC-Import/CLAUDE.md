# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

CCC-Import is a DaVinci Resolve 20 Lua script that imports CDL (Color Decision List) values from `.ccc` (Color Correction Collection) or `.edl` (Edit Decision List) files and applies them to matching timeline clips.

## Running the Script

This script runs inside DaVinci Resolve's scripting environment. To execute:
1. Open DaVinci Resolve
2. Go to Workspace > Console (or use the Scripts menu)
3. Load/run `CCC-Import_v1.00.lua`

The script cannot be run standalone outside of Resolve.

## Architecture

The script is a single-file Lua application with these main components:

### Parsing Functions
- `parseCCC(filepath)` - Parses XML-based CCC files, extracting `<ColorCorrection>` blocks with SOPNode (Slope/Offset/Power) and SATNode (Saturation) values keyed by clip ID
- `parseEDL(filepath)` - Parses EDL files, extracting `ASC_SOP` and `ASC_SAT` comments associated with edit events
- `parseCDLValues(cdlString)` - Utility to convert space-separated CDL strings to number arrays

### Application Function
- `applyCDL(clip, cdl)` - Applies CDL values to a Resolve TimelineItem using the `SetCDL()` API with NodeIndex "1"

### Clip Matching Logic
The script matches CDL entries to timeline clips using a fallback strategy:
1. Exact clip name match
2. Clip name without file extension
3. Substring match in either direction (clip name in CDL name or vice versa)

### UI Components
Uses Resolve's Fusion UI framework (`fu.UIManager`, `bmd.UIDispatcher`) for:
- File selection dialog with CCC/EDL filter
- Import summary display

## DaVinci Resolve API Dependencies

Key Resolve API objects used:
- `Resolve()` - Main entry point
- `ProjectManager:GetCurrentProject()` - Access current project
- `Project:GetCurrentTimeline()` - Access active timeline
- `Timeline:GetTrackCount()`, `Timeline:GetItemListInTrack()` - Iterate video tracks/clips
- `TimelineItem:GetName()`, `TimelineItem:SetCDL()` - Clip name matching and CDL application
- `resolve:OpenPage("color")` - Switch to Color page before applying grades
