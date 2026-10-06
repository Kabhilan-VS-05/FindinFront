# FindInFront — AI-Powered Assistive Vision & Haptic Navigation

> **Emergency & Daily Assistive Mobile Application for Visually Impaired and Deaf-Blind Users**

**FindInFront** is an intelligent assistive mobile application engineered to provide real-time spatial awareness and navigation independence for visually impaired and deaf-blind individuals. By running lightweight edge Computer Vision and monocular depth estimation on-device, the app detects surrounding obstacles, calculates distance proximities, and delivers multi-sensory feedback via spatial Text-To-Speech (TTS) audio narration and patterned haptic vibrations.

---

## 🌟 Assistive Capabilities

- **On-Device Obstacle & Object Detection**:
  - Accelerated on-device inference using quantized [TensorFlow Lite](https://www.tensorflow.org/lite) (`efficientdet_lite0.tflite`, `efficientdet_lite2.tflite`) and YOLOv8 models.
  - Recognizes dynamic obstacles, furniture, doorways, pedestrians, and everyday objects in real time.
- **Monocular Depth & Proximity Estimation (`depth_service.dart`)**:
  - Leverages [MiDaS Small](https://github.com/isl-org/MiDaS) for real-time monocular relative depth estimation without requiring LiDAR or specialized hardware.
  - Computes accurate obstacle distances (`distance_estimator.dart`) to prevent collisions.
- **Multi-Sensory Accessibility Output**:
  - **Spatial Text-to-Speech (TTS)**: Verbal cues informing users of object identities and relative directions (e.g., *"Chair ahead, 1.5 meters"*).
  - **Haptic Vibration Engine (`vibration_service.dart`)**: Coded haptic pulse patterns and frequencies tailored specifically for deaf-blind individuals to convey proximity and urgent stop warnings.

---

## 🛠️ Technology Stack

- **Framework**: [Flutter](https://flutter.dev/) (Dart)
- **Edge AI & Vision**: TensorFlow Lite (TFLite Flutter), ONNX Runtime, OpenCV
- **Core Models**:
  - `efficientdet_lite0.tflite` / `efficientdet_lite2.tflite` (COPO-trained object detection)
  - `midas_small.tflite` (Dense depth estimation)
  - `yolov8n.onnx` / `yolov8n.pt`
- **Sensory & Haptics**: Flutter TTS, Native Vibration API, CameraX / AVFoundation

---

## 📁 Repository Structure

```
FindinFront/
├── assets/
│   └── models/
│       ├── coco_labels.txt              # Object label mappings (80 classes)
│       ├── efficientdet_lite0.tflite     # Lightweight detection model
│       ├── efficientdet_lite2.tflite     # Enhanced accuracy detection model
│       └── midas_small.tflite           # Monocular depth neural network
├── lib/
│   ├── main.dart                        # Application bootstrap & permissions
│   ├── screens/
│   │   └── camera_screen.dart           # Live vision feed & viewfinder
│   ├── services/
│   │   ├── detector_service.dart        # TFLite inference pipeline
│   │   ├── depth_service.dart           # MiDaS depth tensor processing
│   │   ├── distance_estimator.dart      # Real-time obstacle distance logic
│   │   ├── tts_service.dart             # Voice feedback engine
│   │   └── vibration_service.dart       # Deaf-blind haptic vibration patterns
│   └── widgets/
│       └── detection_overlay.dart       # Bounding box & distance HUD
```

---

## 🚀 Getting Started

### Prerequisites
- [Flutter SDK](https://flutter.dev) (v3.0+)
- Physical Android or iOS device with a camera (simulators cannot run live camera feeds)

### Installation
1. Clone the repository:
   ```bash
   git clone https://github.com/Kabhilan-VS-05/FindinFront.git
   cd FindinFront
   ```

2. Fetch Flutter packages:
   ```bash
   flutter pub get
   ```

3. Connect your mobile device and launch:
   ```bash
   flutter run
   ```

---

## 📄 License
Developed for assistive healthcare and inclusive technology by [Kabhilan VS](https://github.com/Kabhilan-VS-05). All rights reserved.
