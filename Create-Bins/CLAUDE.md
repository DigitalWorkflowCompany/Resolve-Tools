# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a DaVinci Resolve Lua script that creates bins and sub-bins in the Media Pool. It runs within DaVinci Resolve's scripting environment (Fusion UI framework).

## Running the Script

The script runs inside DaVinci Resolve:
1. Open DaVinci Resolve with a project loaded
2. Run via Workspace > Scripts or place in Resolve's Scripts folder

**Note:** Cannot be tested outside of DaVinci Resolve as it requires the Resolve scripting API (`Resolve()`, `fu.UIManager`, `bmd.UIDispatcher`).

## Architecture

**Single-file Lua script** using Resolve's Fusion UI framework for the interface.

Key components:
- **Presets system**: Saves/loads bin configurations to a local file (`bin_creator_presets.txt`)
- **Dynamic UI**: Bin rows and sub-bin rows are created upfront (MAX_BINS=20, MAX_SUBBINS_PER_BIN=5) then shown/hidden dynamically
- **Window resizing**: `updateWindowSize()` recalculates height based on visible elements

Preset file locations:
- Windows: `%APPDATA%\Blackmagic Design\DaVinci Resolve\bin_creator_presets.txt`
- macOS/Linux: `~/.davinci_bin_creator_presets.txt`

## Key Functions

- `createBins()` - Main action: creates folders in Media Pool via `mediaPool:AddSubFolder()`
- `updateBinFields(numBins)` - Shows/hides bin input rows
- `toggleSubBins(binIndex)` - Expands/collapses sub-bin section for a bin
- `loadPresets()/savePresets()` - Persistence using custom text format with delimiters (`:`, `,`, `|`, `>`, `;`, `&`)

## Resolve API Used

- `Resolve()` - Entry point
- `resolve:GetProjectManager()` / `projectManager:GetCurrentProject()`
- `project:GetMediaPool()` / `mediaPool:GetRootFolder()`
- `mediaPool:AddSubFolder(parentFolder, name)` - Creates bins
