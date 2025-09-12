# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is "Oskar_RPI" - a Godot-based rehabilitation gaming platform designed for stroke patients. The project contains multiple mini-games and a comprehensive patient progress tracking system. It's built using Godot 4.4 with GDScript.

## Key Architecture

### Global Systems (Autoloads)
- **Manager** (`Main_screen/Scripts/manager.gd`) - Handles game log file creation and data management
- **GlobalScript** (`Main_screen/Scripts/global_script.gd`) - Core game state, UDP networking, screen positioning, and session management
- **GlobalSignals** (`Main_screen/Scripts/global_signals.gd`) - Event system for inter-component communication
- **ScoreManager** (`Main_screen/Scripts/score_manager.gd`) - Manages scoring and progress tracking
- **GlobalTimer** (`Main_screen/Scripts/global_timer.gd`) - Centralized timer management
- **DebugSettings** (`Main_screen/Scripts/debug_settings.gd`) - Debug configuration handling

### Directory Structure
- **Games/** - Individual rehabilitation games (flappy_bird, ping_pong, fruit_catcher, Jumpify, random_reach, assessment)
- **Main_screen/** - Main menu, patient registration, and core UI systems
- **Results/** - Patient progress analysis and data visualization
- **Assets/** - Game assets and resources
- **addons/easy_charts/** - Third-party charting library for progress visualization

### Patient Data System
- Patient data stored in `data.json` with fields: name, hospital_id, age, gender, dominant_hand, affected_hand, stroke_time, comments
- Game session data logged as CSV files in format: `{game}_S{session}_T{trial}_{date}.csv`
- Data path management through GlobalSignals.data_path
- Debug mode controlled via `debug.json`

### Game Architecture Pattern
Each game follows a consistent pattern:
- Main scene controller (e.g., `flappy_main.gd`)
- Player/character scripts (e.g., `pilot.gd`, `2Dplayer.gd`) 
- Game-specific mechanics (obstacles, scoring, timers)
- UI management and score tracking
- CSV data logging for rehabilitation metrics

## Development Commands

### Running the Game
The project runs through Godot Editor. Open `project.godot` in Godot 4.4+.

### Export/Build
Export presets are configured in `export_presets.cfg` for:
- Linux/X11 (ARM64) - Primary target platform
- Android - Mobile platform
- Includes SSH remote deploy configuration for Raspberry Pi deployment

### Debug Mode
Toggle debug mode by editing `debug.json`:
```json
{"debug": true}  // Uses 'vvv' as patient ID for testing
{"debug": false} // Uses actual patient IDs
```

## Key Configuration

### Input Map
- **Movement**: WASD + Arrow keys
- **Jump**: Space
- **Quit**: Escape
- **Reset**: R
- **Mouse**: Left click interactions

### Display Settings
- Fullscreen mode (window/size/mode=2)
- Canvas items stretch mode
- OpenGL compatibility renderer for broader device support

### Networking
- UDP-based communication system in GlobalScript
- Threading support for network operations
- Python integration capabilities

## Important Implementation Notes

- All games use the Manager autoload for data logging
- Session and trial IDs managed globally through GlobalScript
- Screen positioning uses configurable offset scalers for different devices
- Patient progress data visualization through EasyCharts addon
- File operations handle both debug and production patient ID modes
- CSV headers include metadata: game_name, h_id, device_location, device_version, protocol_version, start_time