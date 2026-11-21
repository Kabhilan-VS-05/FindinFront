# FindInFront

Emergency assistive mobile app for **visually impaired and deaf-blind users**. It uses the phone camera to detect obstacles ahead, estimates how far away they are, and warns the user with **speech and vibration**, so no screen reading is needed.

## How it works

1. **Camera** streams frames (`lib/screens/camera_screen.dart`).
2. **Object detection** runs a YOLOv8-nano model on-device (`detector_service.dart`, `yolov8n.onnx`).
3. **Depth and distance** estimation turns each detection into an approximate distance (`depth_service.dart`, `distance_estimator.dart`).
4. **Alerts**: spoken warnings via text-to-speech (`tts_service.dart`) and vibration patterns for deaf-blind users (`vibration_service.dart`).
5. **Overlay** draws the detected boxes on screen for sighted helpers (`detection_overlay.dart`).

## Tech stack

`Flutter` · `Dart` · `YOLOv8n (ONNX)` · `Text-to-Speech` · `Haptics`

## Run it

```bash
flutter pub get
flutter run
```

Needs a physical Android device with a camera.

## Status

Ongoing project. Detection, distance estimation, speech and vibration services are implemented; testing and tuning on real devices continue.

## Author

Kabhilan V. S, [LinkedIn](https://linkedin.com/in/kabhilan-vs) · [Portfolio](https://kabhilan-vs-05.github.io/Portfolio/)
