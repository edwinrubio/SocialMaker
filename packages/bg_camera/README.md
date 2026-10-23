# bg_camera

Local Flutter plugin used by SocialMaker. It captures camera + microphone,
segments the person and composites them over an image or a looping video
**natively**, so the preview texture and the recorded fragments already have
the background replaced.

| | iOS (15+) | Android (24+) |
|---|---|---|
| Capture | AVCaptureSession | CameraX `ImageAnalysis` + `AudioRecord` |
| Segmentation | Vision `VNGeneratePersonSegmentationRequest` | MediaPipe `ImageSegmenter` (`selfie_segmenter.tflite`) |
| Compositing | Core Image `CIBlendWithMask` | OpenGL ES 2 shader |
| Recording | `AVAssetWriter` | `MediaCodec` + `MediaMuxer` |
| Merge | `AVMutableComposition` | Media3 `Transformer` |

Output frames are 720×1280 (portrait). See [lib/bg_camera.dart](lib/bg_camera.dart)
for the Dart API.
