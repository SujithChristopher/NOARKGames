# NOARKGames

A rehabilitation gaming platform designed for stroke patients, built with Godot 4.4. This project provides a collection of mini-games that help track patient progress and motor skills recovery.

## Features

- **Multiple Mini-Games**: Flappy Bird, Ping Pong, Fruit Catcher, Jumpify, Random Reach, and Assessment modules
- **Patient Management**: Registration system with detailed patient profiles
- **Progress Tracking**: Comprehensive data logging and visualization of rehabilitation metrics
- **Cross-Platform**: Supports Linux ARM64 and Android deployment
- **Real-time Monitoring**: UDP networking for external device integration

## Games Included

- **Flappy Bird**: Timing and coordination training
- **Ping Pong**: Hand-eye coordination and reaction time
- **Fruit Catcher**: Object tracking and movement precision  
- **Jumpify**: Platform game for motor control
- **Random Reach**: Target acquisition and reaching exercises
- **Assessment**: Evaluation and testing modules

## Getting Started

### Prerequisites
- Godot 4.4 or later
- For deployment: Linux ARM64 system (e.g., Raspberry Pi)

### Running the Project
1. Open `project.godot` in Godot Editor
2. Press F5 to run the project
3. Register a patient or use debug mode for testing

### Debug Mode
Edit `debug.json` to enable debug mode:
```json
{"debug": true}
```

## Patient Data

- Patient information stored in `data.json`
- Game sessions logged as CSV files with detailed metrics
- Progress visualization through integrated charts
- Data includes timing, accuracy, and motor control measurements

## Export Targets

- **Linux ARM64**: Primary deployment platform
- **Android**: Mobile platform support
- SSH remote deployment configured for Raspberry Pi

## License

See LICENSE file for details.
