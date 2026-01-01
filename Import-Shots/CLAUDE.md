# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a DaVinci Resolve Lua script that imports video clips to the Media Pool with metadata, audio sync, timeline creation, and DRX grade application capabilities.

## Running the Script

The script runs inside DaVinci Resolve's console or script execution environment. It cannot be run standalone. To execute:
1. Open DaVinci Resolve
2. Navigate to Workspace > Console
3. Run the script via `Lua > Import-Shots_v1.00.lua` or use the built-in Script menu

## Architecture

**Single-file Lua script** (`Import-Shots_v1.00.lua`) with:

- **GUI Layer** (lines 15-170): Uses `fu.UIManager` and `bmd.UIDispatcher` to build a native Resolve UI with metadata fields, directory lists, and options checkboxes
- **File Scanning** (lines 201-301): Recursive directory traversal using `mediaStorage:GetSubFolderList()` and `mediaStorage:GetFileList()`
- **Core Import Logic** (lines 303-836): The `importClips()` function handles bin creation, clip import, metadata application, timeline creation, audio sync, and DRX grade application
- **Event Handlers** (lines 839-964): GUI button callbacks and window lifecycle

## Key DaVinci Resolve API Objects

- `resolve` - Global Resolve instance
- `fu.UIManager` / `bmd.UIDispatcher` - GUI framework
- `resolve:GetProjectManager()` → `project` → `mediaPool`
- `resolve:GetMediaStorage()` - File system access
- `mediaPool:AddSubFolder()`, `SetCurrentFolder()`, `CreateTimelineFromClips()`
- `mediaStorage:AddItemListToMediaPool()` - Clip import

## Important Patterns

- Camera rolls are stored in the global `cameraRolls` table and displayed via tree widget
- File type detection uses extension matching in `isVideoFile()` and `isAudioFile()`
- Timeline creation uses `CreateTimelineFromClips()` with fallback to `CreateEmptyTimeline()` + `AppendToTimeline()`
- Audio sync uses `mediaPool:AutoSyncAudio()` with timecode matching
- DRX application requires switching to Color page via `resolve:OpenPage("color")`

## Versioning

Version history is tracked in comments at the top of the file. Current version: 1.03
