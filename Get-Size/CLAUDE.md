# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a DaVinci Resolve Lua script (`Get-Size_v1.00.lua`) that calculates and writes file sizes to the Media Pool metadata. The script is part of a larger collection of Resolve tools (parent directory contains other tools like CCC-Import, Create-Bins, Import-Shots).

## DaVinci Resolve Script Architecture

**Main Components:**
- **Resolve API Integration**: Uses Resolve's Lua API to access project, media pool, and clip properties
- **File Size Calculation**: Handles single video files, image sequences, and R3D multi-part files
- **Metadata Writing**: Updates the "Size" metadata field in GB (rounded to 4 decimals)

**Key Functions:**
- `parseImageSequencePath()`: Parses Resolve's image sequence notation `/path/file. [1000-1100] ext`
- `getDirectorySize()`: Uses OS commands (`du -sk` on Unix, `dir /s` on Windows) to get directory size
- `isR3DFile()`: Detects R3D files by extension
- `getR3DPartsSize()`: Finds and sums all R3D parts (main file + `_001`, `_002`, etc.)
- `getFileSizeGB()`: Main entry point that detects file type and returns size in GB
- `processSelectedClips()`: Iterates selected media pool clips and updates their metadata

## Development Notes

**Platform Compatibility:**
- Cross-platform: Uses `package.config:sub(1,1)` to detect path separator
- Windows: Uses `dir /s /a-d` for directory size calculation
- Unix/Mac/Linux: Uses `du -sk` for directory size calculation

**Image Sequence Handling:**
- Resolve represents sequences as: `directory/basename. [start-end] ext`
- Pattern matching extracts directory, basename, frame range, and extension
- Uses `du -sk` (Unix) or `dir /s` (Windows) to get total directory size

**R3D Multi-Part File Handling:**
- RED camera R3D files are often split into multiple parts when exceeding ~2GB
- Naming convention: `clip_001.R3D`, `clip_002.R3D`, `clip_003.R3D`, etc.
- Resolve reports the first part (`_001`) as the file path
- Script detects and strips the `_XXX` suffix to get the true base name
- Iterates from `_001` to find and sum all parts
- Falls back to single file read if no numbered parts exist
- Handles both uppercase (.R3D) and lowercase (.r3d) extensions

**Error Handling:**
- Uses `pcall()` wrapper around file size calculation
- Validates Resolve API objects (project, mediaPool) before use
- Provides detailed console output for debugging

**Testing:**
Run scripts through DaVinci Resolve's script menu (Workspace > Scripts). Select clips in Media Pool before execution.
