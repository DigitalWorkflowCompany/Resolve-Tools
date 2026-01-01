# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains Lua scripts for DaVinci Resolve that rename clips in the Media Pool using customizable token-based patterns. The scripts are designed for professional post-production workflows, with particular support for ARRI camera naming conventions.

## Running Scripts

Scripts run inside DaVinci Resolve's scripting environment:
- **Workspace > Console** - Run scripts and view output
- **Workspace > Scripts** - Access saved scripts

Scripts use `fu.UIManager` and `bmd.UIDispatcher` for GUI elements (Fusion-based UI system).

## Architecture

### Script Structure
1. **Initialization** - Connect to Resolve API hierarchy: `Resolve() → GetProjectManager() → GetCurrentProject() → GetMediaPool() → GetCurrentFolder() → GetClipList()`
2. **Helper Functions** - Token generation, date/time formatting, pattern application
3. **UI Setup** - Window creation with `disp:AddWindow()`, input widgets, event handlers
4. **Event Loop** - `disp:RunLoop()` for UI interaction

### Token System
The naming pattern uses replaceable tokens with optional zero-padding:
- `{TOKEN}` - Raw value
- `{TOKEN:N}` - Zero-padded to N digits (e.g., `{REEL:4}` → `0001`)

Pattern matching uses Lua's `gsub` with capture groups: `{(%w+):?(%d*)}`

### Key API Patterns
- Use `clip:SetName()` instead of `clip:SetClipProperty("Clip Name", ...)` - the latter doesn't reliably return success status
- Verify renames by checking `clip:GetName()` after setting
- ComboBox indices are 0-based but Lua arrays are 1-indexed - offset by +1 when looking up values

## Resolve API Notes

- API methods may return `nil` or `false` even on success - always verify operations by reading back values
- `fu.UIManager` is the Fusion-based UI system available in Resolve scripts
- Event handlers follow the pattern: `win.On.{WidgetID}.{EventName}(ev)`
